import CoreAudio
import Foundation
import OSLog

/// Keeps one ProcessTap per turned-down app, in step with what the planner wants.
///
/// All tap work happens on a private serial queue rather than an actor: creating taps and
/// aggregate devices blocks inside Core Audio for tens of milliseconds, which shouldn't
/// tie up Swift's cooperative thread pool or the main thread.
public final class VolumeEngine {
    private static let retryDelay: TimeInterval = 30
    private static let log = Logger(subsystem: "com.saif.hifiguard", category: "engine")

    private static let probeDuration: TimeInterval = 0.15

    private let queue = DispatchQueue(label: "com.saif.hifiguard.engine", qos: .userInitiated)
    private let onFailure: (String) -> Void
    private let makeup = AtomicFloat(1)
    private var taps: [String: ProcessTap] = [:]
    private var failures: [String: Date] = [:]

    /// `onFailure` is called on the main queue with a message the user can read.
    public init(onFailure: @escaping (String) -> Void) {
        self.onFailure = onFailure
    }

    public func apply(_ desired: [DesiredTap], outputUID: String?) {
        queue.async { self.reconcile(desired, outputUID: outputUID) }
    }

    /// Boost applied to everything this process plays, to cancel a duck. Takes effect on
    /// the next IO buffer; safe to call from any thread.
    public func setMakeup(_ value: Float) {
        makeup.value = value
    }

    /// Briefly plays silence on `deviceID`. Starting IO makes coreaudiod recompute, and
    /// log, how much it is ducking this process; DuckMonitor picks that up.
    public func probeDuck(deviceID: AudioObjectID) {
        queue.async {
            var procID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, _, _, output, _ in
                for buffer in UnsafeMutableAudioBufferListPointer(output) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
            }
            guard status == noErr, let procID else { return }
            guard AudioDeviceStart(deviceID, procID) == noErr else {
                AudioDeviceDestroyIOProcID(deviceID, procID)
                return
            }
            self.queue.asyncAfter(deadline: .now() + Self.probeDuration) {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
        }
    }

    /// Removes every tap, returning all apps to their own audio. Blocks until done.
    public func shutdown() {
        queue.sync {
            for key in Array(taps.keys) { remove(key, reason: "shutting down") }
        }
    }

    private func reconcile(_ desired: [DesiredTap], outputUID: String?) {
        let wanted = outputUID == nil ? [:] : Dictionary(desired.map { ($0.key, $0) }) { first, _ in first }
        for key in Array(taps.keys) where wanted[key] == nil {
            remove(key, reason: "back to 100% or app gone")
        }
        failures = failures.filter { wanted[$0.key] != nil }
        guard let outputUID else { return }
        for tap in wanted.values {
            ensure(tap, outputUID: outputUID)
        }
    }

    private func ensure(_ desired: DesiredTap, outputUID: String) {
        if let failedAt = failures[desired.key], Date().timeIntervalSince(failedAt) < Self.retryDelay {
            return
        }
        do {
            let tap = try currentTap(for: desired, outputUID: outputUID)
            tap.setGain(desired.gain)
            if desired.isRunning, !tap.isRunning {
                try tap.start()
                Self.log.notice("Playing \(desired.name, privacy: .public) at gain \(desired.gain)")
            } else if !desired.isRunning, tap.isRunning {
                tap.stop()
                logStats(of: tap, name: desired.name, event: "Paused")
            }
            failures[desired.key] = nil
        } catch {
            // A tap that can't play would leave the app muted, so tear it down.
            remove(desired.key, reason: "failed")
            failures[desired.key] = Date()
            Self.log.error("\(desired.name, privacy: .public): \(String(describing: error), privacy: .public)")
            let message = "Couldn't change \(desired.name)'s volume (\(error)). It's playing normally."
            DispatchQueue.main.async { self.onFailure(message) }
        }
    }

    private func currentTap(for desired: DesiredTap, outputUID: String) throws -> ProcessTap {
        if let existing = taps[desired.key] {
            if existing.matches(processIDs: desired.processIDs, outputUID: outputUID), existing.isHealthy {
                return existing
            }
            remove(desired.key, reason: "processes or output device changed")
        }
        let tap = try ProcessTap(
            key: desired.key,
            name: desired.name,
            processIDs: desired.processIDs,
            outputUID: outputUID,
            gain: desired.gain,
            makeup: makeup
        )
        taps[desired.key] = tap
        Self.log.notice("Tapped \(desired.name, privacy: .public) (\(desired.processIDs.count) processes)")
        return tap
    }

    private func remove(_ key: String, reason: String) {
        guard let tap = taps.removeValue(forKey: key) else { return }
        tap.invalidate()
        logStats(of: tap, name: key, event: "Released (\(reason))")
    }

    private func logStats(of tap: ProcessTap, name: String, event: String) {
        let stats = tap.takeStats()
        Self.log.notice("\(event, privacy: .public) \(name, privacy: .public): \(stats.frames) frames, peak \(stats.peak)")
    }
}
