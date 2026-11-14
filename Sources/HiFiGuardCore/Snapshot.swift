import CoreAudio
import Foundation

/// The live audio state the app and the probe render from.
public struct Snapshot {
    public let devices: [AudioDevice]
    public let input: AudioDevice?
    public let output: AudioDevice?
    public let processes: [AudioProcess]

    public static func capture(from audio: CoreAudioSystem) -> Snapshot {
        let devices = audio.devices()
        let byID = { (id: AudioObjectID?) in devices.first { $0.id == id } }
        return Snapshot(
            devices: devices,
            input: byID(audio.defaultInputID()),
            output: byID(audio.defaultOutputID()),
            processes: audio.processes()
        )
    }

    /// True while another app records from any mic, i.e. a call is probably on.
    public var isMicInUse: Bool {
        processes.contains { $0.isRunningInput && $0.pid != getpid() }
    }

    public func bluetoothMicApps(resolver: AppResolver) -> [String] {
        let mics = Set(devices.filter(\.isBluetoothMic).map(\.id))
        return MicUsers.processes(using: mics, among: processes, excluding: getpid())
            .map { resolver.identity(for: $0)?.name ?? $0.bundleID ?? "An app" }
            .reduce(into: [String]()) { names, name in
                if !names.contains(name) { names.append(name) }
            }
    }

    public func statusInput(isGuardOn: Bool, resolver: AppResolver) -> StatusInput {
        StatusInput(
            isGuardOn: isGuardOn,
            output: output,
            input: input,
            devices: devices,
            bluetoothMicApps: bluetoothMicApps(resolver: resolver)
        )
    }
}
