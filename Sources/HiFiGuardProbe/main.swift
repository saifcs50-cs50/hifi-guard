import AppKit
import HiFiGuardCore

/// Usage:
///   HiFiGuardProbe status               devices, defaults, apps, and what the panel would say
///   HiFiGuardProbe set-input <name>     make the named device the default mic
let audio = CoreAudioSystem()
let resolver = AppResolver()
let arguments = Array(CommandLine.arguments.dropFirst())

func printStatus() {
    let snapshot = Snapshot.capture(from: audio)
    print("Devices:")
    for device in snapshot.devices {
        let io = [device.hasInput ? "in" : nil, device.hasOutput ? "out" : nil].compactMap { $0 }.joined(separator: "+")
        print("  [\(device.id)] \(device.name) — \(device.transport), \(io), \(Format.kHz(device.sampleRate))")
    }
    print("Default input:  \(snapshot.input?.name ?? "none")")
    print("Default output: \(snapshot.output?.name ?? "none")")
    print("Link mode:      \(LinkQuality.mode(of: snapshot.output))")
    let replacement = MicPolicy.replacement(for: snapshot.input, among: snapshot.devices)
    print("Guard would switch mic to: \(replacement?.name ?? "(no switch needed)")")
    print("Mic in use by another app: \(snapshot.isMicInUse)")

    print("\nApps with audio processes:")
    for app in AppGrouping.group(snapshot.processes, excluding: getpid(), identify: resolver.identity(for:)) {
        print("  \(app.name) [\(app.key)] processes \(app.processIDs.sorted()) \(app.isPlaying ? "PLAYING" : "idle")")
    }

    let report = StatusReport.make(from: snapshot.statusInput(isGuardOn: true, resolver: resolver))
    print("\nPanel would show (\(report.severity)):")
    for line in [report.outputLine, report.qualityLine, report.micLine, report.warning].compactMap({ $0 }) {
        print("  \(line)")
    }
    print("\nSystem audio recording permission (for this process): \(CapturePermission.status())")
}

func setInput(named name: String) -> Int32 {
    guard let device = audio.devices().first(where: { $0.hasInput && $0.name == name }) else {
        FileHandle.standardError.write(Data("No input device named “\(name)”\n".utf8))
        return 1
    }
    do {
        try audio.setDefaultInput(device.id)
        print("Default input set to \(device.name) [\(device.id)]")
        return 0
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 1
    }
}

switch arguments.first {
case "status", nil:
    printStatus()
case "set-input" where arguments.count == 2:
    exit(setInput(named: arguments[1]))
default:
    FileHandle.standardError.write(Data("usage: HiFiGuardProbe [status | set-input <device name>]\n".utf8))
    exit(2)
}
