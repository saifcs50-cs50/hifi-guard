import CoreAudio
import Foundation
import HiFiGuardCore

// Sample coreaudiod lines in the format macOS 26 logs during a call (device ID anonymised).
private let duckedLine = """
2026-09-27 21:14:32.762 Df coreaudiod[227:10ea36] (CoreAudio)           HALS_Device.cpp:2312   \
HALS_Device::_GetCombinedVolumeScalar: 00-11-22-33-44-55:output client 1731 (pid 14611) is not present, \
and is ducked with a combined volume scalar of 0.177828
"""
private let presentLine = """
2026-09-27 21:16:21.342 Df coreaudiod[227:10fa3b] (CoreAudio)           HALS_Device.cpp:2312   \
HALS_Device::_GetCombinedVolumeScalar: BuiltInMicrophoneDevice client 364 (pid 483) is present, \
and is ducked with a combined volume scalar of 1.000000
"""

func runAntiDuckTests() {
    Harness.suite("DuckLogParser") {
        Harness.test("reads device, client, pid, presence and scalar from a ducked line") {
            Harness.expect(
                DuckLogParser.parse(duckedLine),
                DuckReading(deviceUID: "00-11-22-33-44-55:output", clientID: 1731, pid: 14611, isPresent: false, scalar: 0.177828),
                "ducked"
            )
        }
        Harness.test("reads a 'present' (exempt) client") {
            Harness.expect(DuckLogParser.parse(presentLine)?.isPresent, true, "present")
            Harness.expect(DuckLogParser.parse(presentLine)?.scalar, 1, "scalar")
        }
        Harness.test("ignores unrelated log lines") {
            Harness.expectNil(DuckLogParser.parse("Filtering the log data using \"process == coreaudiod\""), "header")
            Harness.expectNil(DuckLogParser.parse(""), "empty")
        }
    }

    Harness.suite("LineBuffer") {
        Harness.test("splits streamed chunks into whole lines") {
            let buffer = LineBuffer()
            Harness.expect(buffer.append(Data("first\nsec".utf8)), ["first"], "first chunk")
            Harness.expect(buffer.append(Data("ond\nthird\n".utf8)), ["second", "third"], "second chunk")
            Harness.expect(buffer.append(Data("".utf8)), [], "empty chunk")
        }
    }

    let reading = DuckReading(deviceUID: "buds", clientID: 1, pid: 1, isPresent: false, scalar: 0.177828)
    func makeup(enabled: Bool = true, call: Bool = true, _ reading: DuckReading?, output: String? = "buds") -> Float {
        AntiDuck.makeup(isEnabled: enabled, isCallActive: call, reading: reading, outputUID: output)
    }

    Harness.suite("AntiDuck") {
        Harness.test("undoes the measured duck exactly") {
            Harness.expect(abs(makeup(reading) - 5.6234) < 0.001, true, "1/0.177828")
        }
        Harness.test("never boosts without a fresh reading, a call, or the setting") {
            Harness.expect(makeup(nil), 1, "no reading")
            Harness.expect(makeup(call: false, reading), 1, "call over")
            Harness.expect(makeup(enabled: false, reading), 1, "turned off")
        }
        Harness.test("ignores readings for another output device") {
            Harness.expect(makeup(reading, output: "speakers"), 1, "other device")
            Harness.expect(makeup(reading, output: nil), 1, "no output")
        }
        Harness.test("ignores exempt, silent and near-unity readings") {
            let present = DuckReading(deviceUID: "buds", clientID: 1, pid: 1, isPresent: true, scalar: 0.2)
            let muted = DuckReading(deviceUID: "buds", clientID: 1, pid: 1, isPresent: false, scalar: 0)
            let tiny = DuckReading(deviceUID: "buds", clientID: 1, pid: 1, isPresent: false, scalar: 0.99)
            Harness.expect(makeup(present), 1, "present")
            Harness.expect(makeup(muted), 1, "zero")
            Harness.expect(makeup(tiny), 1, "0.99")
        }
        Harness.test("caps the boost at +20 dB") {
            let deep = DuckReading(deviceUID: "buds", clientID: 1, pid: 1, isPresent: false, scalar: 0.01)
            Harness.expect(makeup(deep), AntiDuck.maxMakeup, "capped")
        }
    }

    Harness.suite("TapPlanner during calls") {
        let now = Date(timeIntervalSince1970: 1_000)
        let music = AppAudio(key: "music", name: "Music", processIDs: [1], isPlaying: true, isRecording: false)
        let call = AppAudio(key: "call", name: "Call", processIDs: [2], isPlaying: true, isRecording: true)
        // The same call with the user muted: mic stopped, call audio still playing.
        let mutedCall = AppAudio(key: "call", name: "Call", processIDs: [2], isPlaying: true, isRecording: false)
        let quiet = AppAudio(key: "quiet", name: "Quiet", processIDs: [3], isPlaying: false, isRecording: false)
        func plan(_ apps: [AppAudio], _ volumes: [String: AppVolume] = [:], routeAll: Bool, exempt: Set<String>) -> [String] {
            TapPlanner.desiredTaps(
                apps: apps,
                volumes: volumes,
                lastPlayed: [:],
                now: now,
                grace: 30,
                routeAllPlaying: routeAll,
                exempt: exempt
            ).map(\.key)
        }

        Harness.test("routes every playing app through the mixer while a call ducks audio") {
            Harness.expect(plan([music, call, quiet], routeAll: true, exempt: ["call"]), ["music"], "music only")
            Harness.expect(plan([music, call, quiet], routeAll: false, exempt: []), [], "nothing outside calls")
        }
        Harness.test("never taps the call app, even when the user changed its volume") {
            // Tapping it would expose the call voice to macOS's duck.
            let volumes = ["call": AppVolume(percent: 60, isMuted: false)]
            Harness.expect(plan([music, call], volumes, routeAll: true, exempt: ["call"]), ["music"], "call left alone")
        }
        Harness.test("keeps the call app untouched while the user is muted") {
            let volumes = ["call": AppVolume(percent: 60, isMuted: false)]
            Harness.expect(plan([music, mutedCall], volumes, routeAll: true, exempt: ["call"]), ["music"], "muted call")
        }
        Harness.test("applies the call app's volume again once it is out of the call") {
            let volumes = ["call": AppVolume(percent: 60, isMuted: false)]
            Harness.expect(plan([mutedCall], volumes, routeAll: false, exempt: []), ["call"], "after the call")
        }
    }

    Harness.suite("CallTracker") {
        let start = Date(timeIntervalSince1970: 5_000)
        let talking = AppAudio(key: "wa", name: "WhatsApp", processIDs: [1], isPlaying: true, isRecording: true)
        let muted = AppAudio(key: "wa", name: "WhatsApp", processIDs: [1], isPlaying: true, isRecording: false)
        let hungUp = AppAudio(key: "wa", name: "WhatsApp", processIDs: [1], isPlaying: false, isRecording: false)
        let music = AppAudio(key: "music", name: "Music", processIDs: [2], isPlaying: true, isRecording: false)
        let inCall = CallTracker().updated(with: [talking, music], now: start)

        Harness.test("an app using the mic is in a call; one only playing is not") {
            Harness.expect(inCall.callApps, ["wa"], "call apps")
            let state = CallState.make(tracker: inCall, apps: [talking, music])
            Harness.expect(state.isActive, true, "active")
            Harness.expect(state.isDuckerLive, true, "duck live")
            Harness.expect(state.isMicLive, true, "mic live")
        }
        Harness.test("muting yourself does not end the call") {
            let later = start.addingTimeInterval(60)
            let tracker = inCall.updated(with: [muted, music], now: later)
            let state = CallState.make(tracker: tracker, apps: [muted, music])
            Harness.expect(tracker.callApps, ["wa"], "still in call")
            Harness.expect(state.isDuckerLive, true, "duck still live")
            Harness.expect(state.isMicLive, false, "mic off")
        }
        Harness.test("hanging up stops the duck at once but keeps routing briefly") {
            let tracker = inCall.updated(with: [hungUp, music], now: start.addingTimeInterval(1))
            let state = CallState.make(tracker: tracker, apps: [hungUp, music])
            Harness.expect(state.isDuckerLive, false, "boost must drop immediately")
            Harness.expect(state.isActive, true, "brief hang so a blip doesn't re-route")
        }
        Harness.test("the call is over once the hang time passes") {
            let tracker = inCall
                .updated(with: [hungUp, music], now: start.addingTimeInterval(1))
                .updated(with: [hungUp, music], now: start.addingTimeInterval(1 + CallTracker.hangTime))
            Harness.expect(tracker.callApps, [], "ended")
        }
        Harness.test("playing without ever using the mic never starts a call") {
            Harness.expect(CallTracker().updated(with: [muted, music], now: start).callApps, [], "no call")
        }
    }
}
