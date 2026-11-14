import CoreAudio
import Foundation
import HiFiGuardCore

/// Owns an AudioBufferList whose buffers are filled from `channels`, laid out either
/// interleaved in one buffer or one buffer per channel. Test-only, so allocation is fine.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private let storage: [UnsafeMutablePointer<Float>]
    private let isInterleaved: Bool
    private let channelCount: Int
    private let frames: Int

    init(channels: [[Float]], interleaved: Bool) {
        let channelCount = channels.count
        let frames = channels.first?.count ?? 0
        let list = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channelCount)
        if interleaved {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(frames * channelCount, 1))
            for frame in 0..<frames {
                for channel in 0..<channelCount { data[frame * channelCount + channel] = channels[channel][frame] }
            }
            list[0] = AudioBuffer(
                mNumberChannels: UInt32(channelCount),
                mDataByteSize: UInt32(frames * channelCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(data)
            )
            storage = [data]
        } else {
            storage = channels.enumerated().map { index, samples in
                let data = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
                for (frame, sample) in samples.enumerated() { data[frame] = sample }
                list[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(data)
                )
                return data
            }
        }
        self.list = list
        self.channelCount = channelCount
        self.frames = frames
        isInterleaved = interleaved
    }

    convenience init(silentChannels: Int, frames: Int, interleaved: Bool) {
        self.init(channels: Array(repeating: Array(repeating: 9, count: frames), count: silentChannels), interleaved: interleaved)
    }

    func channel(_ index: Int) -> [Float] {
        (0..<frames).map { frame in
            isInterleaved ? storage[0][frame * channelCount + index] : storage[index][frame]
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

private func approx(_ a: [Float], _ b: [Float], tolerance: Float = 0.0001) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

func runMixerTests() {
    Harness.suite("VolumeCurve") {
        Harness.test("100% is unity gain and 0% is silence") {
            Harness.expect(VolumeCurve.gain(percent: 100, isMuted: false), 1, "unity")
            Harness.expect(VolumeCurve.gain(percent: 0, isMuted: false), 0, "zero")
        }
        Harness.test("uses a squared taper so the slider feels even") {
            Harness.expect(VolumeCurve.gain(percent: 50, isMuted: false), 0.25, "half")
        }
        Harness.test("boost tops out at the max and clamps beyond it") {
            Harness.expect(VolumeCurve.gain(percent: 150, isMuted: false), 2.25, "max")
            Harness.expect(VolumeCurve.gain(percent: 400, isMuted: false), 2.25, "clamped")
            Harness.expect(VolumeCurve.gain(percent: -20, isMuted: false), 0, "negative")
        }
        Harness.test("mute wins over any volume") {
            Harness.expect(VolumeCurve.gain(percent: 120, isMuted: true), 0, "muted")
        }
    }

    Harness.suite("Mixer") {
        Harness.test("copies stereo to stereo with gain (interleaved)") {
            let input = TestBufferList(channels: [[0.5, -0.5], [0.2, 0.4]], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 2, interleaved: true)
            let stats = Mixer.render(input: input.list, output: output.list, gain: Ramp(0.5, 0.5))
            Harness.expect(approx(output.channel(0), [0.25, -0.25]), true, "left")
            Harness.expect(approx(output.channel(1), [0.1, 0.2]), true, "right")
            Harness.expect(stats.frames, 2, "frames")
            Harness.expect(abs(stats.peak - 0.25) < 0.0001, true, "peak")
        }
        Harness.test("handles non-interleaved input into interleaved output") {
            let input = TestBufferList(channels: [[1, 1], [0.5, 0.5]], interleaved: false)
            let output = TestBufferList(silentChannels: 2, frames: 2, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1))
            Harness.expect(approx(output.channel(0), [1, 1]), true, "left")
            Harness.expect(approx(output.channel(1), [0.5, 0.5]), true, "right")
        }
        Harness.test("mixes stereo down for a mono output") {
            let input = TestBufferList(channels: [[1, 0.2], [0, 0.4]], interleaved: true)
            let output = TestBufferList(silentChannels: 1, frames: 2, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1))
            Harness.expect(approx(output.channel(0), [0.5, 0.3]), true, "mono")
        }
        Harness.test("silences output channels the tap does not have") {
            let input = TestBufferList(channels: [[0.3], [0.3]], interleaved: true)
            let output = TestBufferList(silentChannels: 4, frames: 1, interleaved: false)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1))
            Harness.expect(output.channel(2), [0], "ch3")
            Harness.expect(output.channel(3), [0], "ch4")
        }
        Harness.test("ramps gain across the buffer so slider moves don't click") {
            let input = TestBufferList(channels: [[1, 1, 1, 1], [1, 1, 1, 1]], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 4, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(0, 1))
            Harness.expect(approx(output.channel(0), [0, 0.25, 0.5, 0.75]), true, "ramp")
        }
        Harness.test("zero-fills output frames beyond the tapped input") {
            let input = TestBufferList(channels: [[1], [1]], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 3, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1))
            Harness.expect(output.channel(0), [1, 0, 0], "tail")
        }
        Harness.test("soft-clips boosted audio so it never exceeds full scale") {
            let input = TestBufferList(channels: [[0.9, -0.9, 0.1], [0.9, -0.9, 0.1]], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 3, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(2.25, 2.25))
            let left = output.channel(0)
            Harness.expect(left[0] <= 1 && left[0] > 0.8, true, "positive peak shaped")
            Harness.expect(left[1] >= -1 && left[1] < -0.8, true, "negative peak shaped")
            Harness.expect(abs(left[2] - 0.225) < 0.0001, true, "quiet samples untouched")
        }
        Harness.test("does not shape audio at or below unity gain") {
            let input = TestBufferList(channels: [[0.95], [0.95]], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 1, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1))
            Harness.expect(abs(output.channel(0)[0] - 0.95) < 0.0001, true, "untouched")
        }
        Harness.test("applies anti-duck makeup after clipping, so the duck brings it back to full scale") {
            let input = TestBufferList(channels: [[0.5, 1.0], [0.5, 1.0]], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 2, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1), makeup: Ramp(4, 4))
            Harness.expect(approx(output.channel(0), [2, 4]), true, "boosted past 1.0 for the duck to undo")
        }
        Harness.test("ramps makeup like gain") {
            let input = TestBufferList(channels: [[1, 1], [1, 1]], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 2, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1), makeup: Ramp(1, 3))
            Harness.expect(approx(output.channel(0), [1, 2]), true, "ramp")
        }
        Harness.test("an empty input produces silence") {
            let input = TestBufferList(channels: [], interleaved: true)
            let output = TestBufferList(silentChannels: 2, frames: 2, interleaved: true)
            Mixer.render(input: input.list, output: output.list, gain: Ramp(1, 1))
            Harness.expect(output.channel(0), [0, 0], "silent")
        }
    }
}
