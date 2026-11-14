import CoreAudio

/// Decides which microphone to use so Bluetooth headphones stay in music mode.
///
/// Opening a Bluetooth headset's mic forces the headset from A2DP (stereo, 44.1/48 kHz)
/// into the hands-free profile (mono, 8-24 kHz). Keeping the system default mic on
/// something else means call apps that follow the default never trigger that switch.
public enum MicPolicy {
    /// The mic to switch to when `current` is a Bluetooth mic, or nil when no switch
    /// is needed or no real alternative exists.
    public static func replacement(for current: AudioDevice?, among devices: [AudioDevice]) -> AudioDevice? {
        guard let current, current.isBluetoothMic else { return nil }
        return preferredMic(among: devices)
    }

    /// The best non-Bluetooth mic: built-in first, then USB, then anything else real.
    public static func preferredMic(among devices: [AudioDevice]) -> AudioDevice? {
        devices
            .filter { $0.hasInput }
            .compactMap { device in rank(device.transport).map { (rank: $0, device: device) } }
            .min { $0.rank < $1.rank }?
            .device
    }

    /// Lower is better; nil means never pick it. Virtual and aggregate devices
    /// (eqMac, BlackHole, Multi-Output) are not microphones and would record silence.
    private static func rank(_ transport: Transport) -> Int? {
        switch transport {
        case .builtIn: return 0
        case .usb: return 1
        case .other: return 2
        case .bluetooth, .virtual, .aggregate: return nil
        }
    }
}

public enum LinkMode: Equatable, Sendable {
    case highQuality, callMode, notBluetooth
}

public enum LinkQuality {
    /// A2DP runs at 44.1 or 48 kHz; the hands-free profile at 8 (CVSD), 16 (mSBC)
    /// or 24 kHz (AAC-ELD). Anything below this line is a call-mode link.
    static let callModeCeiling: Double = 32_000

    public static func mode(of output: AudioDevice?) -> LinkMode {
        guard let output, output.transport == .bluetooth else { return .notBluetooth }
        let isKnownRate = output.sampleRate > 0
        return isKnownRate && output.sampleRate < callModeCeiling ? .callMode : .highQuality
    }
}

public enum MicUsers {
    /// Processes currently recording from any of `deviceIDs`, other than `ownPID`.
    public static func processes(
        using deviceIDs: Set<AudioObjectID>,
        among processes: [AudioProcess],
        excluding ownPID: pid_t
    ) -> [AudioProcess] {
        guard !deviceIDs.isEmpty else { return [] }
        return processes.filter { process in
            process.pid != ownPID
                && process.isRunningInput
                && process.inputDeviceIDs.contains(where: deviceIDs.contains)
        }
    }
}

public enum BundleIDs {
    /// "com.google.Chrome.helper" → ["com.google", "com.google.Chrome", "com.google.Chrome.helper"].
    /// Audio often runs in a helper process; walking up finds the app the user recognises.
    public static func lineage(of bundleID: String) -> [String] {
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count > 1 else { return [bundleID] }
        return (2...parts.count).map { parts.prefix($0).joined(separator: ".") }
    }
}

/// The device lists the panel offers, and what picking one means for the guard.
public enum DeviceChoice {
    public static func inputs(_ devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter { $0.hasInput && $0.transport != .aggregate }
    }

    public static func outputs(_ devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter(\.hasOutput)
    }

    /// Picking a Bluetooth mic is an explicit request to use it, so the guard turns off;
    /// otherwise it would switch the mic straight back. Any other pick leaves it alone.
    public static func isGuardOn(afterPicking mic: AudioDevice, wasOn: Bool) -> Bool {
        wasOn && !mic.isBluetoothMic
    }
}
