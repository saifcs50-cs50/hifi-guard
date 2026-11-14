import CoreAudio
import Foundation

public enum VolumeCurve {
    public static let maxPercent = 150

    /// Squared taper: 50% on the slider is about -12 dB, which sounds like "half as loud"
    /// far more than a linear slider does. The top of the range boosts to 2.25x (+7 dB).
    public static func gain(percent: Int, isMuted: Bool) -> Float {
        guard !isMuted else { return 0 }
        let level = Float(min(max(percent, 0), maxPercent)) / 100
        return level * level
    }
}

public struct RenderStats: Equatable, Sendable {
    public let frames: Int
    public let peak: Float
}

/// A value that moves linearly from `start` to `end` across one buffer, so level
/// changes never click.
public struct Ramp: Equatable, Sendable {
    public let start: Float
    public let end: Float

    public static let unity = Ramp(1, 1)

    public init(_ start: Float, _ end: Float) {
        self.start = start
        self.end = end
    }

    @inline(__always)
    func value(at frame: Int, of frames: Int) -> Float {
        frames > 0 ? start + (end - start) * Float(frame) / Float(frames) : end
    }
}

/// Copies tapped audio to the output device with a gain applied.
///
/// Runs on Core Audio's real-time IO thread, so it must never allocate, lock, or call
/// into Objective-C. Everything here works on raw pointers.
public enum Mixer {
    /// Boosted audio above this level is gently compressed toward full scale.
    static let clipKnee: Float = 0.8

    /// `gain` is the user's level; boosted audio is soft-clipped at full scale. `makeup`
    /// is applied after that, to cancel a duck macOS applies downstream: output above 1.0
    /// is intended, because the duck scales it back to where it would have been.
    @discardableResult
    public static func render(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        gain: Ramp,
        makeup: Ramp = .unity
    ) -> RenderStats {
        let inputChannels = channelCount(input)
        let isMonoDownmix = channelCount(output) == 1 && inputChannels >= 2
        let isBoosting = gain.start > 1 || gain.end > 1
        var outputChannel = 0
        var peak: Float = 0
        var renderedFrames = 0

        for buffer in output {
            let stride = Int(buffer.mNumberChannels)
            guard stride > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                outputChannel += stride
                continue
            }
            let frames = Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float>.size)
            for offset in 0..<stride {
                let destination = Channel(base: data + offset, stride: stride, frames: frames)
                let left = locate(input, channel: isMonoDownmix ? 0 : outputChannel)
                let right = isMonoDownmix ? locate(input, channel: 1) : nil
                let written = fill(destination, left: left, right: right, gain: gain, makeup: makeup, shaping: isBoosting)
                peak = max(peak, written.peak)
                renderedFrames = max(renderedFrames, written.frames)
                outputChannel += 1
            }
        }
        return RenderStats(frames: renderedFrames, peak: peak)
    }

    /// Writes `left` (or the average of `left` and `right`) into `destination`,
    /// zero-filling whatever the source does not cover.
    private static func fill(
        _ destination: Channel,
        left: Channel?,
        right: Channel?,
        gain: Ramp,
        makeup: Ramp,
        shaping: Bool
    ) -> RenderStats {
        let available = min(left?.frames ?? 0, right?.frames ?? left?.frames ?? 0)
        let frames = min(destination.frames, available)
        var peak: Float = 0
        if let left {
            for frame in 0..<frames {
                let sample = right.map { (left[frame] + $0[frame]) * 0.5 } ?? left[frame]
                let gained = sample * gain.value(at: frame, of: frames)
                let shaped = (shaping ? softClip(gained) : gained) * makeup.value(at: frame, of: frames)
                destination[frame] = shaped
                peak = max(peak, abs(shaped))
            }
        }
        for frame in frames..<destination.frames {
            destination[frame] = 0
        }
        return RenderStats(frames: frames, peak: peak)
    }

    @inline(__always)
    static func softClip(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > clipKnee else { return sample }
        let headroom = 1 - clipKnee
        let shaped = clipKnee + headroom * tanhf((magnitude - clipKnee) / headroom)
        return sample < 0 ? -shaped : shaped
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var total = 0
        for buffer in list { total += Int(buffer.mNumberChannels) }
        return total
    }

    /// Finds channel `channel` across a buffer list that may be interleaved,
    /// non-interleaved, or a mix of both.
    private static func locate(_ list: UnsafeMutableAudioBufferListPointer, channel: Int) -> Channel? {
        var first = 0
        for buffer in list {
            let count = Int(buffer.mNumberChannels)
            if count > 0, channel < first + count, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(buffer.mDataByteSize) / (count * MemoryLayout<Float>.size)
                return Channel(base: data + (channel - first), stride: count, frames: frames)
            }
            first += count
        }
        return nil
    }
}

/// One channel inside an audio buffer, addressed with a stride so interleaved and
/// non-interleaved layouts read the same way.
private struct Channel {
    let base: UnsafeMutablePointer<Float>
    let stride: Int
    let frames: Int

    subscript(frame: Int) -> Float {
        get { base[frame * stride] }
        nonmutating set { base[frame * stride] = newValue }
    }
}
