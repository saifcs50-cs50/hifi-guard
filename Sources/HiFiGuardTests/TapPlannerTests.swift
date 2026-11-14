import CoreAudio
import Foundation
import HiFiGuardCore

private func process(
    _ objectID: AudioObjectID,
    pid: pid_t,
    bundleID: String?,
    playing: Bool = false
) -> AudioProcess {
    AudioProcess(
        objectID: objectID,
        pid: pid,
        bundleID: bundleID,
        isRunningInput: false,
        isRunningOutput: playing,
        inputDeviceIDs: []
    )
}

private let chrome = AppIdentity(bundleID: "com.google.Chrome", name: "Google Chrome")
private let spotify = AppIdentity(bundleID: "com.spotify.client", name: "Spotify")

/// Stands in for AppResolver: helpers map to their parent app, daemons to nothing.
private func identify(_ process: AudioProcess) -> AppIdentity? {
    switch process.bundleID {
    case "com.google.Chrome", "com.google.Chrome.helper": return chrome
    case "com.spotify.client": return spotify
    default: return nil
    }
}

func runGroupingTests() {
    Harness.suite("AppGrouping") {
        let processes = [
            process(20, pid: 200, bundleID: "com.google.Chrome"),
            process(21, pid: 201, bundleID: "com.google.Chrome.helper", playing: true),
            process(30, pid: 300, bundleID: "com.spotify.client"),
            process(40, pid: 400, bundleID: "com.apple.systemsoundserverd", playing: true),
            process(50, pid: 999, bundleID: "com.google.Chrome", playing: true)
        ]
        let apps = AppGrouping.group(processes, excluding: 999, identify: identify)

        Harness.test("folds helper processes into their app") {
            Harness.expect(apps.first { $0.key == chrome.bundleID }?.processIDs, [20, 21], "chrome processes")
        }
        Harness.test("an app is playing when any of its processes is") {
            Harness.expect(apps.first { $0.key == chrome.bundleID }?.isPlaying, true, "chrome playing")
            Harness.expect(apps.first { $0.key == spotify.bundleID }?.isPlaying, false, "spotify idle")
        }
        Harness.test("app names lose invisible formatting characters") {
            Harness.expect(AppIdentity(bundleID: "net.whatsapp.WhatsApp", name: "\u{200E}WhatsApp").name, "WhatsApp", "LRM")
            Harness.expect(AppIdentity(bundleID: "x", name: " Zoom\u{200B} ").name, "Zoom", "ZWSP + spaces")
        }
        Harness.test("drops processes that belong to no app, and our own") {
            Harness.expect(apps.map(\.key), [chrome.bundleID, spotify.bundleID], "keys sorted by name")
        }
    }
}

func runTapPlannerTests() {
    let now = Date(timeIntervalSince1970: 1_000)
    let playing = AppAudio(key: "a", name: "A", processIDs: [1, 2], isPlaying: true, isRecording: false)
    let idle = AppAudio(key: "b", name: "B", processIDs: [3], isPlaying: false, isRecording: false)
    let gone = AppAudio(key: "c", name: "C", processIDs: [], isPlaying: false, isRecording: false)

    func plan(_ volumes: [String: AppVolume], lastPlayed: [String: Date] = [:]) -> [DesiredTap] {
        TapPlanner.desiredTaps(
            apps: [playing, idle, gone],
            volumes: volumes,
            lastPlayed: lastPlayed,
            now: now,
            grace: 30
        )
    }

    Harness.suite("AppVolume") {
        Harness.test("only non-default volumes need a tap") {
            Harness.expect(AppVolume.unchanged.needsTap, false, "100%")
            Harness.expect(AppVolume(percent: 80, isMuted: false).needsTap, true, "80%")
            Harness.expect(AppVolume(percent: 100, isMuted: true).needsTap, true, "muted")
        }
        Harness.test("copies change one field at a time") {
            let muted = AppVolume(percent: 70, isMuted: false).with(isMuted: true)
            Harness.expect(muted, AppVolume(percent: 70, isMuted: true), "mute keeps level")
            Harness.expect(muted.with(percent: 40), AppVolume(percent: 40, isMuted: true), "level keeps mute")
        }
    }

    Harness.suite("TapPlanner") {
        Harness.test("apps left at 100% are never tapped") {
            Harness.expect(plan([:]), [], "no volumes")
            Harness.expect(plan(["a": .unchanged]), [], "explicit 100")
        }
        Harness.test("a turned-down app that is playing gets a running tap") {
            let taps = plan(["a": AppVolume(percent: 50, isMuted: false)])
            Harness.expect(taps, [DesiredTap(key: "a", name: "A", processIDs: [1, 2], gain: 0.25, isRunning: true)], "a")
        }
        Harness.test("a turned-down idle app is tapped (so it starts muted) but not running") {
            let taps = plan(["b": AppVolume(percent: 50, isMuted: false)])
            Harness.expect(taps.first?.isRunning, false, "idle")
        }
        Harness.test("keeps running briefly after playback stops, so pauses don't cut in and out") {
            let recent = plan(["b": AppVolume(percent: 50, isMuted: false)], lastPlayed: ["b": now.addingTimeInterval(-10)])
            Harness.expect(recent.first?.isRunning, true, "within grace")
            let stale = plan(["b": AppVolume(percent: 50, isMuted: false)], lastPlayed: ["b": now.addingTimeInterval(-60)])
            Harness.expect(stale.first?.isRunning, false, "after grace")
        }
        Harness.test("apps with no live processes get no tap") {
            Harness.expect(plan(["c": AppVolume(percent: 10, isMuted: false)]), [], "gone")
        }
    }
}
