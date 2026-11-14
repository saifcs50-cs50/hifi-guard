import CoreAudio
import Foundation
import Synchronization

/// A Float that one thread writes and Core Audio's IO thread reads. Lives behind a raw
/// pointer so the IO block captures no Swift references and never retains or releases on
/// the real-time thread.
public final class AtomicFloat {
    let pointer: UnsafeMutablePointer<Atomic<UInt32>>

    public init(_ value: Float) {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: Atomic(value.bitPattern))
    }

    public var value: Float {
        get { Float(bitPattern: pointer.pointee.load(ordering: .relaxed)) }
        set { pointer.pointee.store(newValue.bitPattern, ordering: .relaxed) }
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
}

/// Per-tap state shared with the IO thread.
final class TapControl {
    let targetGain: AtomicFloat
    /// Shared by every tap: macOS ducks this whole process at once.
    let makeup: AtomicFloat
    /// What the IO thread applied last buffer, used to ramp to the next one.
    let appliedGain: UnsafeMutablePointer<Float>
    let appliedMakeup: UnsafeMutablePointer<Float>
    let peak: UnsafeMutablePointer<Atomic<UInt32>>
    let frames: UnsafeMutablePointer<Atomic<UInt64>>

    init(gain: Float, makeup: AtomicFloat) {
        targetGain = AtomicFloat(gain)
        self.makeup = makeup
        appliedGain = .allocate(capacity: 1)
        appliedGain.initialize(to: gain)
        appliedMakeup = .allocate(capacity: 1)
        appliedMakeup.initialize(to: makeup.value)
        peak = .allocate(capacity: 1)
        peak.initialize(to: Atomic(0))
        frames = .allocate(capacity: 1)
        frames.initialize(to: Atomic(0))
    }

    func setGain(_ gain: Float) {
        targetGain.value = gain
    }

    /// Frames rendered and the loudest output sample since the last call.
    func takeStats() -> RenderStats {
        RenderStats(
            frames: Int(frames.pointee.exchange(0, ordering: .relaxed)),
            peak: Float(bitPattern: peak.pointee.exchange(0, ordering: .relaxed))
        )
    }

    deinit {
        appliedGain.deallocate()
        appliedMakeup.deallocate()
        peak.deinitialize(count: 1)
        peak.deallocate()
        frames.deinitialize(count: 1)
        frames.deallocate()
    }
}

/// Re-plays one app's audio at a chosen gain.
///
/// A process tap captures the app's output and mutes the original; a private aggregate
/// device pairs that tap with the real output device; an IO proc copies tap → output with
/// the gain applied. The tap is created with `.muted` (not `.mutedWhenTapped`) so the app
/// is silent while playback is stopped, meaning it can never blast out at full volume in the
/// moment before playback starts. If this process dies, Core Audio destroys the tap and
/// the app's own audio comes straight back.
final class ProcessTap {
    /// Our private playback devices are visible to this process; this marks them so they
    /// can be kept out of device lists.
    static let aggregateUIDPrefix = "com.saif.hifiguard."

    let key: String
    let processIDs: Set<AudioObjectID>
    let outputUID: String
    private(set) var isRunning = false

    private let control: TapControl
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(
        key: String,
        name: String,
        processIDs: Set<AudioObjectID>,
        outputUID: String,
        gain: Float,
        makeup: AtomicFloat
    ) throws {
        self.key = key
        self.processIDs = processIDs
        self.outputUID = outputUID
        control = TapControl(gain: gain, makeup: makeup)
        do {
            let tapUID = try createTap(name: name)
            try createAggregate(name: name, tapUID: tapUID)
            try createIOProc()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit {
        invalidate()
    }

    func matches(processIDs other: Set<AudioObjectID>, outputUID otherOutput: String) -> Bool {
        processIDs == other && outputUID == otherOutput
    }

    /// False once the output device has vanished or IO died under us, e.g. a Bluetooth
    /// disconnect. The engine rebuilds the tap when that happens.
    var isHealthy: Bool {
        let isAlive = HAL.scalar(of: aggregateID, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) == 1
        let isIORunning = HAL.scalar(of: aggregateID, kAudioDevicePropertyDeviceIsRunning, as: UInt32.self) == 1
        return isAlive && (!isRunning || isIORunning)
    }

    func setGain(_ gain: Float) {
        control.setGain(gain)
    }

    func takeStats() -> RenderStats {
        control.takeStats()
    }

    func start() throws {
        guard !isRunning, let procID else { return }
        try AudioError.check(AudioDeviceStart(aggregateID, procID), "Starting playback")
        isRunning = true
    }

    func stop() {
        guard isRunning, let procID else { return }
        AudioDeviceStop(aggregateID, procID)
        isRunning = false
    }

    /// Tears everything down; safe to call more than once. Destroying the tap is what
    /// unmutes the app, so it happens even if earlier steps fail.
    func invalidate() {
        stop()
        if let procID {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Setup

    private func createTap(name: String) throws -> String {
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs.sorted())
        description.uuid = UUID()
        description.name = "HiFi Guard: \(name)"
        description.isPrivate = true
        description.muteBehavior = .muted
        var id = AudioObjectID(kAudioObjectUnknown)
        try AudioError.check(AudioHardwareCreateProcessTap(description, &id), "Tapping \(name)")
        tapID = id
        return description.uuid.uuidString
    }

    private func createAggregate(name: String, tapUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HiFi Guard: \(name)",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID
            ]]
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try AudioError.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &id),
            "Creating the playback device for \(name)"
        )
        aggregateID = id
    }

    private func createIOProc() throws {
        let targetGain = control.targetGain.pointer
        let targetMakeup = control.makeup.pointer
        let appliedGain = control.appliedGain
        let appliedMakeup = control.appliedMakeup
        let peak = control.peak
        let frames = control.frames
        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, aggregateID, nil) { _, input, _, output, _ in
            let gain = Float(bitPattern: targetGain.pointee.load(ordering: .relaxed))
            let makeup = Float(bitPattern: targetMakeup.pointee.load(ordering: .relaxed))
            let stats = Mixer.render(
                input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                output: UnsafeMutableAudioBufferListPointer(output),
                gain: Ramp(appliedGain.pointee, gain),
                makeup: Ramp(appliedMakeup.pointee, makeup)
            )
            appliedGain.pointee = gain
            appliedMakeup.pointee = makeup
            frames.pointee.add(UInt64(stats.frames), ordering: .relaxed)
            if stats.peak > Float(bitPattern: peak.pointee.load(ordering: .relaxed)) {
                peak.pointee.store(stats.peak.bitPattern, ordering: .relaxed)
            }
        }
        try AudioError.check(status, "Creating the playback callback")
        procID = id
    }
}
