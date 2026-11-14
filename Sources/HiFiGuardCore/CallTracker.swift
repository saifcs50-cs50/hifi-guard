import Foundation

/// Which apps are in a call.
///
/// An app joins when it uses the mic and stays while its call audio keeps playing:
/// muting yourself stops the mic, but not the call, and not macOS's duck either. Treating
/// "mic stopped" as "call ended" would make HiFi Guard drop its boost for as long as the
/// mute lasted, while macOS kept ducking the call voice it was replaying.
/// An app leaves `hangTime` after both its mic and its playback have stopped.
public struct CallTracker: Equatable, Sendable {
    public static let hangTime: TimeInterval = 5

    private let lastActive: [String: Date]

    public init() {
        lastActive = [:]
    }

    private init(lastActive: [String: Date]) {
        self.lastActive = lastActive
    }

    public var callApps: Set<String> { Set(lastActive.keys) }

    public func updated(with apps: [AppAudio], now: Date) -> CallTracker {
        let live = apps.filter { $0.isRecording || ($0.isPlaying && lastActive[$0.key] != nil) }
        let refreshed = live.reduce(into: lastActive) { active, app in active[app.key] = now }
        return CallTracker(lastActive: refreshed.filter { now.timeIntervalSince($0.value) < Self.hangTime })
    }
}

/// A snapshot of the call situation, as the mixer and the anti-duck need it.
public struct CallState: Equatable, Sendable {
    /// Apps in a call. Their audio is never tapped: macOS exempts a call app from its own
    /// duck, and replaying it through HiFi Guard would take that exemption away.
    public let callApps: Set<String>
    /// A call app is playing or recording right now, so macOS's duck is on. Goes false the
    /// instant the call's audio stops, which is when the anti-duck boost must drop.
    public let isDuckerLive: Bool
    /// A call app is using the mic right now.
    public let isMicLive: Bool

    public static let idle = CallState(callApps: [], isDuckerLive: false, isMicLive: false)

    public init(callApps: Set<String>, isDuckerLive: Bool, isMicLive: Bool) {
        self.callApps = callApps
        self.isDuckerLive = isDuckerLive
        self.isMicLive = isMicLive
    }

    /// Whether a call is on, counting the short hang after it ends.
    public var isActive: Bool { !callApps.isEmpty }

    public static func make(tracker: CallTracker, apps: [AppAudio]) -> CallState {
        let callApps = tracker.callApps
        let current = apps.filter { callApps.contains($0.key) }
        return CallState(
            callApps: callApps,
            isDuckerLive: current.contains { $0.isPlaying || $0.isRecording },
            isMicLive: current.contains { $0.isRecording }
        )
    }
}
