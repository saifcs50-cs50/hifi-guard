import CoreAudio
import Foundation
import HiFiGuardCore

/// Cancels the duck that call apps (WhatsApp, FaceTime, Zoom…) put on every other app.
///
/// macOS turns down every client of the call's output device by a fixed factor
/// (0.178, i.e. -15 dB, measured on this Mac) and exempts only the call app. While a
/// call is live, every other playing app is routed through HiFi Guard's mixer; the
/// actual factor is read from coreaudiod's log and the mixer boosts by its inverse,
/// so after the duck the audio lands exactly where it was.
///
/// Safety over completeness: the boost is only applied with a reading taken during the
/// current call on the current device, and drops to 1 the moment the call's audio stops.
/// The call app itself is never routed (see TapPlanner), so the other person's voice
/// never depends on this boost.
@MainActor
final class CallDuckController {
    /// Probe right after a call starts (the duck can engage a moment after the call's
    /// audio does), then re-check now and then. Every reading so far has been the same
    /// 0.177828, so there's no need to start IO on the earbuds more often than this.
    private static let startupProbeDelays: [TimeInterval] = [0.4, 1.5]
    private static let probeInterval: TimeInterval = 15
    /// After this long in a call with no reading, measuring evidently doesn't work here.
    private static let measureTimeout: TimeInterval = 5

    private let engine: VolumeEngine
    private let onChange: () -> Void
    private var monitor: DuckMonitor?
    private var isEnabled = true
    private var call = CallState.idle
    private var outputUID: String?
    private var outputID: AudioObjectID?
    private var reading: DuckReading?
    private var lastProbe = Date.distantPast
    private var callStartedAt = Date.distantPast
    private(set) var makeup: Float = 1

    init(engine: VolumeEngine, onChange: @escaping () -> Void) {
        self.engine = engine
        self.onChange = onChange
    }

    func start() {
        let monitor = DuckMonitor { [weak self] reading in
            MainActor.assumeIsolated { self?.receive(reading) }
        }
        monitor.start()
        self.monitor = monitor
    }

    func stop() {
        monitor?.stop()
        engine.setMakeup(1)
    }

    /// Whether every playing app (except the call app) should go through the mixer.
    var shouldRouteAll: Bool { isEnabled && call.isActive }

    /// Whether the call's audio is live right now, i.e. macOS's duck is on.
    private var isDuckLive: Bool { isEnabled && call.isDuckerLive }

    var status: String? {
        guard isDuckLive else { return nil }
        if makeup > 1 {
            let decibels = Int((20 * log10(makeup)).rounded())
            return "A call is turning other audio down by \(decibels) dB. HiFi Guard is putting it back."
        }
        guard reading != nil else {
            return Date().timeIntervalSince(callStartedAt) < Self.measureTimeout
                ? "Call detected. Checking whether it's turning other audio down…"
                : "Call detected, but macOS isn't reporting how much it turns audio down, so it can't be undone here."
        }
        return "Call detected. It isn't turning other audio down."
    }

    func update(isEnabled: Bool, call: CallState, outputUID: String?, outputID: AudioObjectID?) {
        let duckStarted = call.isDuckerLive && !self.call.isDuckerLive
        // Mic stopped but the call audio plays on: usually a mute (duck still on), but
        // check right away rather than assume.
        let micPaused = self.call.isMicLive && !call.isMicLive && call.isDuckerLive
        let outputChanged = outputUID != self.outputUID
        self.isEnabled = isEnabled
        self.call = call
        self.outputUID = outputUID
        self.outputID = outputID
        if !call.isDuckerLive || duckStarted || outputChanged {
            // A measurement never outlives the call audio it was taken against, and never
            // carries over to another call or another device.
            reading = nil
        }
        if duckStarted || outputChanged {
            callStartedAt = Date()
            if isDuckLive { scheduleStartupProbes() }
        } else if isDuckLive, micPaused || Date().timeIntervalSince(lastProbe) >= Self.probeInterval {
            probe()
        }
        applyMakeup()
    }

    private func receive(_ reading: DuckReading) {
        log.debug("coreaudiod scalar \(reading.scalar) for this app on \(reading.deviceUID, privacy: .public)")
        guard reading.deviceUID == outputUID else { return }
        self.reading = reading
        applyMakeup()
    }

    private func applyMakeup() {
        let value = AntiDuck.makeup(
            isEnabled: isEnabled,
            isCallActive: call.isDuckerLive,
            reading: reading,
            outputUID: outputUID
        )
        guard value != makeup else { return }
        makeup = value
        engine.setMakeup(value)
        let source = reading.map { "macOS duck scalar \($0.scalar)" } ?? "no measurement"
        log.notice("Anti-duck boost now x\(value) (\(source, privacy: .public), call audio live: \(self.call.isDuckerLive))")
        onChange()
    }

    private func scheduleStartupProbes() {
        for delay in Self.startupProbeDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isDuckLive else { return }
                    self.probe()
                }
            }
        }
    }

    private func probe() {
        guard let outputID else { return }
        lastProbe = Date()
        engine.probeDuck(deviceID: outputID)
    }
}
