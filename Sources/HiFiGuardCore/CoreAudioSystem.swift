import CoreAudio
import Foundation

/// Reads and changes system-wide audio state. Never opens a stream itself, so it needs
/// no microphone permission and never lights the mic indicator.
public final class CoreAudioSystem {
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    public init() {}

    /// Every device the user can see, minus HiFi Guard's own private playback devices.
    public func devices() -> [AudioDevice] {
        HAL.objectIDs(of: HAL.system, kAudioHardwarePropertyDevices)
            .compactMap(device(id:))
            .filter { !$0.uid.hasPrefix(ProcessTap.aggregateUIDPrefix) }
    }

    public func defaultInputID() -> AudioObjectID? {
        known(HAL.scalar(of: HAL.system, kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self))
    }

    public func defaultOutputID() -> AudioObjectID? {
        known(HAL.scalar(of: HAL.system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self))
    }

    public func setDefaultInput(_ id: AudioObjectID) throws {
        try setDefault(kAudioHardwarePropertyDefaultInputDevice, to: id, "Setting the default mic")
    }

    public func setDefaultOutput(_ id: AudioObjectID) throws {
        try setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: id, "Setting the default output")
    }

    private func setDefault(_ selector: AudioObjectPropertySelector, to id: AudioObjectID, _ operation: String) throws {
        var address = HAL.address(selector)
        var value = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        try AudioError.check(AudioObjectSetPropertyData(HAL.system, &address, 0, nil, size, &value), operation)
    }

    public func processes() -> [AudioProcess] {
        HAL.objectIDs(of: HAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { id in
            guard let pid = HAL.scalar(of: id, kAudioProcessPropertyPID, as: pid_t.self) else { return nil }
            return AudioProcess(
                objectID: id,
                pid: pid,
                bundleID: HAL.string(of: id, kAudioProcessPropertyBundleID),
                isRunningInput: HAL.scalar(of: id, kAudioProcessPropertyIsRunningInput, as: UInt32.self) == 1,
                isRunningOutput: HAL.scalar(of: id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1,
                inputDeviceIDs: HAL.objectIDs(of: id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
            )
        }
    }

    /// Calls `handler` on the main queue when devices, defaults, or the set of audio
    /// client processes change.
    public func observeSystem(_ handler: @escaping () -> Void) {
        let selectors = [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyProcessObjectList
        ]
        for selector in selectors {
            var address = HAL.address(selector)
            AudioObjectAddPropertyListenerBlock(HAL.system, &address, .main) { _, _ in handler() }
        }
    }

    /// Watches when each process starts or stops playing or recording, so a turned-down
    /// app is re-routed the moment it presses play, and a call's end is seen the moment
    /// its mic closes (the anti-duck boost must drop right then). Call with the current
    /// process list; listeners on processes that have exited are dropped.
    public func observePlayback(of processIDs: Set<AudioObjectID>, _ handler: @escaping () -> Void) {
        let selectors = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput]
        for (id, block) in processListeners where !processIDs.contains(id) {
            for selector in selectors {
                var address = HAL.address(selector)
                AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
            }
            processListeners[id] = nil
        }
        for id in processIDs where processListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            for selector in selectors {
                var address = HAL.address(selector)
                AudioObjectAddPropertyListenerBlock(id, &address, .main, block)
            }
            processListeners[id] = block
        }
    }

    private func device(id: AudioObjectID) -> AudioDevice? {
        guard let name = HAL.string(of: id, kAudioObjectPropertyName) else { return nil }
        return AudioDevice(
            id: id,
            uid: HAL.string(of: id, kAudioDevicePropertyDeviceUID) ?? "",
            name: name,
            transport: Transport(coreAudioCode: HAL.scalar(of: id, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0),
            hasInput: HAL.hasStreams(id, scope: kAudioObjectPropertyScopeInput),
            hasOutput: HAL.hasStreams(id, scope: kAudioObjectPropertyScopeOutput),
            sampleRate: HAL.scalar(of: id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 0
        )
    }

    private func known(_ id: AudioObjectID?) -> AudioObjectID? {
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }
}
