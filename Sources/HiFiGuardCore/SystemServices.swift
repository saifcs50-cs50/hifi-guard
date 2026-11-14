import AppKit
import CoreAudio
import Foundation

/// The "System Audio Recording" permission that process taps need.
///
/// macOS has no public API to check it, so this calls the private TCC functions that
/// open-source audio-capture tools (such as AudioCap) use. Checking first matters: without
/// the permission a muted tap delivers silence, which would make the app go quiet.
public enum CapturePermission {
    public enum State: Equatable, Sendable {
        case authorized, denied, undetermined
        /// The private API is missing on this macOS; taps are attempted anyway.
        case unavailable
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static func status() -> State {
        guard let symbol = framework.flatMap({ dlsym($0, "TCCAccessPreflight") }) else { return .unavailable }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt. `completion` runs on the main queue.
    public static func request(_ completion: @escaping (Bool) -> Void) {
        guard let symbol = framework.flatMap({ dlsym($0, "TCCAccessRequest") }) else {
            completion(false)
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

/// Maps an audio process to the app a person would recognise. Call on the main thread.
///
/// Audio often plays from a helper: Chrome from "Google Chrome Helper", Safari from a
/// WebKit media process. The kernel's "responsible process" points back at the app that
/// launched it, with bundle-ID prefixes as a fallback.
public final class AppResolver {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private let responsible: ResponsibleFn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }
    private var cache: [pid_t: AppIdentity] = [:]
    private var icons: [String: NSImage] = [:]

    public init() {}

    public func identity(for process: AudioProcess) -> AppIdentity? {
        if let cached = cache[process.pid] { return cached }
        let found = resolve(process)
        if let found { cache[process.pid] = found }
        return found
    }

    public func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
        if let icon { icons[bundleID] = icon }
        return icon
    }

    /// Drops cached answers for processes that have exited; PIDs get reused.
    public func forget(allExcept alivePIDs: Set<pid_t>) {
        cache = cache.filter { alivePIDs.contains($0.key) }
    }

    private func resolve(_ process: AudioProcess) -> AppIdentity? {
        if let owner = responsible.flatMap({ regularApp(pid: $0(process.pid)) }) {
            return owner
        }
        if let bundleID = process.bundleID,
           let owner = BundleIDs.lineage(of: bundleID).lazy.compactMap(regularApp(bundleID:)).first {
            return owner
        }
        return regularApp(pid: process.pid)
    }

    private func regularApp(pid: pid_t) -> AppIdentity? {
        NSRunningApplication(processIdentifier: pid).flatMap(identity(of:))
    }

    private func regularApp(bundleID: String) -> AppIdentity? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).lazy.compactMap(identity(of:)).first
    }

    private func identity(of app: NSRunningApplication) -> AppIdentity? {
        guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier else { return nil }
        return AppIdentity(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }
}
