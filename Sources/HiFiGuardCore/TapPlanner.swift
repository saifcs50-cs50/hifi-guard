import CoreAudio
import Foundation

/// The user's setting for one app, keyed by bundle ID.
public struct AppVolume: Equatable, Codable, Sendable {
    public let percent: Int
    public let isMuted: Bool

    public static let unchanged = AppVolume(percent: 100, isMuted: false)

    public init(percent: Int, isMuted: Bool) {
        self.percent = percent
        self.isMuted = isMuted
    }

    /// Apps left at 100% are never touched: no tap, no added latency, no risk.
    public var needsTap: Bool { isMuted || percent != 100 }
    public var gain: Float { VolumeCurve.gain(percent: percent, isMuted: isMuted) }

    public func with(percent: Int) -> AppVolume { AppVolume(percent: percent, isMuted: isMuted) }
    public func with(isMuted: Bool) -> AppVolume { AppVolume(percent: percent, isMuted: isMuted) }
}

public struct AppIdentity: Equatable, Hashable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = Self.displayName(name)
    }

    /// Strips invisible formatting characters: WhatsApp's name, for one, starts with a
    /// left-to-right mark that would otherwise leak into sentences and alignment.
    static func displayName(_ raw: String) -> String {
        let visible = raw.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(visible)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Every audio process belonging to one app, e.g. Chrome plus its audio helper.
public struct AppAudio: Equatable, Sendable {
    public let key: String
    public let name: String
    public let processIDs: Set<AudioObjectID>
    public let isPlaying: Bool
    /// Using a mic, i.e. most likely the call app doing the ducking.
    public let isRecording: Bool

    public init(key: String, name: String, processIDs: Set<AudioObjectID>, isPlaying: Bool, isRecording: Bool) {
        self.key = key
        self.name = name
        self.processIDs = processIDs
        self.isPlaying = isPlaying
        self.isRecording = isRecording
    }
}

public enum AppGrouping {
    /// Folds processes into the apps the user recognises. Processes that belong to no
    /// regular app (daemons, system sound servers) and our own process are dropped.
    public static func group(
        _ processes: [AudioProcess],
        excluding ownPID: pid_t,
        identify: (AudioProcess) -> AppIdentity?
    ) -> [AppAudio] {
        let owned = processes
            .filter { $0.pid != ownPID }
            .compactMap { process in identify(process).map { (app: $0, process: process) } }
        return Dictionary(grouping: owned) { $0.app }
            .map { app, members in
                AppAudio(
                    key: app.bundleID,
                    name: app.name,
                    processIDs: Set(members.map { $0.process.objectID }),
                    isPlaying: members.contains { $0.process.isRunningOutput },
                    isRecording: members.contains { $0.process.isRunningInput }
                )
            }
            .sorted { ($0.name.lowercased(), $0.key) < ($1.name.lowercased(), $1.key) }
    }
}

/// A tap the engine should hold for one app.
public struct DesiredTap: Equatable, Sendable {
    public let key: String
    public let name: String
    public let processIDs: Set<AudioObjectID>
    public let gain: Float
    /// A tap that exists but isn't running keeps the app silent at zero cost; it starts
    /// the moment the app plays so there's never a burst at the wrong volume.
    public let isRunning: Bool

    public init(key: String, name: String, processIDs: Set<AudioObjectID>, gain: Float, isRunning: Bool) {
        self.key = key
        self.name = name
        self.processIDs = processIDs
        self.gain = gain
        self.isRunning = isRunning
    }
}

public enum TapPlanner {
    /// `routeAllPlaying` is set while a call is ducking other audio: every playing app then
    /// goes through the mixer, where the duck can be cancelled.
    ///
    /// `exempt` holds the apps in a call. They are never tapped, whatever their slider says:
    /// macOS never ducks a call app's own audio, but once HiFi Guard replays it, the duck
    /// applies and the other person's voice depends on the anti-duck boost being right.
    public static func desiredTaps(
        apps: [AppAudio],
        volumes: [String: AppVolume],
        lastPlayed: [String: Date],
        now: Date,
        grace: TimeInterval,
        routeAllPlaying: Bool = false,
        exempt: Set<String> = []
    ) -> [DesiredTap] {
        apps.compactMap { app in
            guard !exempt.contains(app.key) else { return nil }
            let volume = volumes[app.key] ?? .unchanged
            let playedRecently = lastPlayed[app.key].map { now.timeIntervalSince($0) < grace } ?? false
            let isActive = app.isPlaying || playedRecently
            let routeForCall = routeAllPlaying && isActive
            guard volume.needsTap || routeForCall, !app.processIDs.isEmpty else { return nil }
            return DesiredTap(
                key: app.key,
                name: app.name,
                processIDs: app.processIDs,
                gain: volume.gain,
                isRunning: isActive
            )
        }
    }
}
