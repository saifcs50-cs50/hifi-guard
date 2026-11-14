import CoreAudio

/// How a device is attached. Only the distinctions the guard acts on are kept.
public enum Transport: Equatable, Sendable {
    case builtIn, bluetooth, usb, virtual, aggregate, other

    public init(coreAudioCode code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }
}

/// A snapshot of one Core Audio device. A Bluetooth headset shows up as two of
/// these with the same name: one input-only, one output-only.
public struct AudioDevice: Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: Transport
    public let hasInput: Bool
    public let hasOutput: Bool
    public let sampleRate: Double

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        transport: Transport,
        hasInput: Bool,
        hasOutput: Bool,
        sampleRate: Double
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.sampleRate = sampleRate
    }

    public var isBluetoothMic: Bool { hasInput && transport == .bluetooth }
}

/// A client process of Core Audio, as reported by the HAL's process objects (macOS 14+).
public struct AudioProcess: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
    public let inputDeviceIDs: [AudioObjectID]

    public init(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        isRunningInput: Bool,
        isRunningOutput: Bool,
        inputDeviceIDs: [AudioObjectID]
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
        self.inputDeviceIDs = inputDeviceIDs
    }
}
