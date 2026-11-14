import AppKit
import CoreAudio
import UniformTypeIdentifiers
import HiFiGuardCore

struct AppRow: Identifiable, Equatable {
    let id: String
    let name: String
    let volume: AppVolume
    let isPlaying: Bool
    /// In a call: always plays untouched, so its slider is paused until the call ends.
    let isInCall: Bool
}

/// Everything the menu-bar panel shows, plus the jobs that run in the background:
/// keeping the default mic off Bluetooth, keeping each app's taps in step, and
/// cancelling the duck calls put on other audio.
@MainActor
final class AppModel: ObservableObject {
    private static let refreshInterval: TimeInterval = 2
    /// Apps stay listed this long after they last made sound, so pausing doesn't hide them.
    private static let listedAfterPlaying: TimeInterval = 10 * 60
    /// Taps keep running this long after an app goes quiet, so short pauses don't re-route.
    private static let playbackGrace: TimeInterval = 30
    private static let soundSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")
    private static let audioPrivacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")

    @Published private(set) var isGuardOn = Preferences.isGuardOn
    @Published private(set) var report: StatusReport?
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var currentInputID: AudioObjectID?
    @Published private(set) var currentOutputID: AudioObjectID?
    @Published private(set) var rows: [AppRow] = []
    @Published private(set) var permission = CapturePermission.status()
    @Published private(set) var isLoginItem = LoginItem.isEnabled
    @Published private(set) var isAntiDuckOn = Preferences.isAntiDuckOn
    @Published private(set) var antiDuckStatus: String?
    @Published private(set) var lastError: String?

    private let audio = CoreAudioSystem()
    private let resolver = AppResolver()
    private lazy var engine = VolumeEngine { [weak self] message in self?.lastError = message }
    private lazy var callDuck: CallDuckController = CallDuckController(engine: engine) { [weak self] in
        self?.antiDuckStatus = self?.callDuck.status
    }
    private var volumes = Preferences.volumes
    private var lastPlayed: [String: Date] = [:]
    private var apps: [AppAudio] = []
    private var callTracker = CallTracker()
    private var call = CallState.idle
    private var outputUID: String?
    private var timer: Timer?
    private var isRefreshScheduled = false
    private var isRequestingPermission = false

    init() {
        audio.observeSystem { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.callDuck.stop()
                self?.engine.shutdown()
            }
        }
        callDuck.start()
        LoginItem.enableOnFirstLaunch()
        isLoginItem = LoginItem.isEnabled
        refresh()
    }

    /// Earbud with waves: none when the quality guard is off, a third while a call's
    /// duck is being cancelled, a warning triangle when something needs attention.
    var menuBarImage: NSImage {
        if report?.severity == .warning,
           let warning = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "HiFi Guard needs attention") {
            warning.isTemplate = true
            return warning
        }
        let waves: BrandGlyph.Waves = !isGuardOn ? .none : (callDuck.makeup > 1 ? .boosted : .normal)
        return BrandGlyph.menuBarImage(waves: waves)
    }

    func icon(for bundleID: String) -> NSImage {
        resolver.icon(for: bundleID) ?? NSWorkspace.shared.icon(for: .application)
    }

    // MARK: - Refresh

    /// Coalesces bursts of Core Audio notifications into one refresh.
    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isRefreshScheduled = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        enforceGuard()
        let snapshot = Snapshot.capture(from: audio)
        let now = Date()
        apps = AppGrouping.group(snapshot.processes, excluding: getpid(), identify: resolver.identity(for:))
        lastPlayed = apps.filter(\.isPlaying).reduce(into: lastPlayed) { $0[$1.key] = now }
        callTracker = callTracker.updated(with: apps, now: now)
        call = CallState.make(tracker: callTracker, apps: apps)
        outputUID = snapshot.output?.uid
        resolver.forget(allExcept: Set(snapshot.processes.map(\.pid)))
        audio.observePlayback(of: Set(snapshot.processes.map(\.objectID))) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        report = StatusReport.make(from: snapshot.statusInput(isGuardOn: isGuardOn, resolver: resolver))
        inputs = DeviceChoice.inputs(snapshot.devices)
        outputs = DeviceChoice.outputs(snapshot.devices)
        currentInputID = snapshot.input?.id
        currentOutputID = snapshot.output?.id
        callDuck.update(
            isEnabled: isAntiDuckOn,
            call: call,
            outputUID: snapshot.output?.uid,
            outputID: snapshot.output?.id
        )
        antiDuckStatus = callDuck.status
        permission = CapturePermission.status()
        rows = visibleRows(now: now)
        applyVolumes(now: now)
    }

    private func enforceGuard() {
        guard isGuardOn else { return }
        let devices = audio.devices()
        let current = devices.first { $0.id == audio.defaultInputID() }
        guard let target = MicPolicy.replacement(for: current, among: devices) else { return }
        do {
            try audio.setDefaultInput(target.id)
            log.notice("Switched default mic from \(current?.name ?? "?", privacy: .public) to \(target.name, privacy: .public)")
        } catch {
            log.error("\(String(describing: error), privacy: .public)")
            lastError = "Couldn't switch the mic to \(target.name)."
        }
    }

    private func visibleRows(now: Date) -> [AppRow] {
        apps
            .filter { app in
                let playedRecently = lastPlayed[app.key].map { now.timeIntervalSince($0) < Self.listedAfterPlaying } ?? false
                return app.isPlaying || playedRecently || volumes[app.key]?.needsTap == true
            }
            .map { app in
                AppRow(
                    id: app.key,
                    name: app.name,
                    volume: volumes[app.key] ?? .unchanged,
                    isPlaying: app.isPlaying,
                    isInCall: call.callApps.contains(app.key)
                )
            }
    }

    private func applyVolumes(now: Date = Date()) {
        let desired = TapPlanner.desiredTaps(
            apps: apps,
            volumes: volumes,
            lastPlayed: lastPlayed,
            now: now,
            grace: Self.playbackGrace,
            routeAllPlaying: callDuck.shouldRouteAll,
            exempt: call.callApps
        )
        engine.apply(desired.isEmpty || canTap() ? desired : [], outputUID: outputUID)
    }

    /// Without the permission a tap silences the app, so never tap until it's granted.
    private func canTap() -> Bool {
        switch CapturePermission.status() {
        case .authorized, .unavailable:
            return true
        case .denied:
            return false
        case .undetermined:
            requestPermission()
            return false
        }
    }

    private func requestPermission() {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        CapturePermission.request { [weak self] granted in
            MainActor.assumeIsolated {
                log.notice("System audio recording permission granted: \(granted)")
                self?.isRequestingPermission = false
                self?.refresh()
            }
        }
    }

    // MARK: - Actions

    func setVolume(_ percent: Int, for key: String) {
        updateVolume(for: key) { $0.with(percent: percent) }
    }

    func toggleMute(for key: String) {
        updateVolume(for: key) { $0.with(isMuted: !$0.isMuted) }
    }

    func resetVolume(for key: String) {
        updateVolume(for: key) { _ in .unchanged }
    }

    private func updateVolume(for key: String, _ change: (AppVolume) -> AppVolume) {
        let updated = change(volumes[key] ?? .unchanged)
        guard updated != volumes[key] ?? .unchanged else { return }
        volumes = volumes.merging([key: updated]) { _, new in new }
        Preferences.volumes = volumes
        lastError = nil
        rows = visibleRows(now: Date())
        applyVolumes()
    }

    /// Same as picking a mic in System Settings › Sound › Input, from the panel.
    func selectInput(_ device: AudioDevice) {
        let guardOn = DeviceChoice.isGuardOn(afterPicking: device, wasOn: isGuardOn)
        if guardOn != isGuardOn {
            isGuardOn = guardOn
            Preferences.isGuardOn = guardOn
        }
        do {
            try audio.setDefaultInput(device.id)
            log.notice("Mic set to \(device.name, privacy: .public) from the panel")
        } catch {
            lastError = "Couldn't switch the mic to \(device.name)."
        }
        refresh()
    }

    /// Same as picking an output in System Settings › Sound › Output, from the panel.
    func selectOutput(_ device: AudioDevice) {
        do {
            try audio.setDefaultOutput(device.id)
            log.notice("Output set to \(device.name, privacy: .public) from the panel")
        } catch {
            lastError = "Couldn't switch the output to \(device.name)."
        }
        refresh()
    }

    func toggleGuard() {
        isGuardOn.toggle()
        Preferences.isGuardOn = isGuardOn
        refresh()
    }

    func toggleAntiDuck() {
        isAntiDuckOn.toggle()
        Preferences.isAntiDuckOn = isAntiDuckOn
        refresh()
    }

    func toggleLoginItem() {
        do {
            try LoginItem.setEnabled(!isLoginItem)
        } catch {
            lastError = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        isLoginItem = LoginItem.isEnabled
    }

    func dismissError() {
        lastError = nil
    }

    func openSoundSettings() {
        Self.soundSettingsURL.map { _ = NSWorkspace.shared.open($0) }
    }

    func openPrivacySettings() {
        Self.audioPrivacyURL.map { _ = NSWorkspace.shared.open($0) }
    }
}
