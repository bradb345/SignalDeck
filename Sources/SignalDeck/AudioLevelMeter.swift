import Foundation
import Synchronization

/// A stereo peak/RMS reading, in linear amplitude (0…1+).
struct AudioLevels: Equatable, Sendable {
    var peakLeft: Float = 0
    var peakRight: Float = 0
    var rmsLeft: Float = 0
    var rmsRight: Float = 0

    static let silent = AudioLevels()

    var peak: Float { max(peakLeft, peakRight) }
    var rms: Float { max(rmsLeft, rmsRight) }

    /// -100 dBFS. Below this we call it silence rather than "very quiet".
    static let silenceFloor: Float = 0.00001

    var hasSignal: Bool { peak > Self.silenceFloor }

    func scaled(by gain: Float) -> AudioLevels {
        AudioLevels(peakLeft: peakLeft * gain, peakRight: peakRight * gain,
                    rmsLeft: rmsLeft * gain, rmsRight: rmsRight * gain)
    }

    /// Linear amplitude → dBFS, clamped at `floor` so the UI never sees -infinity.
    static func decibels(_ amplitude: Float, floor: Float = -60) -> Float {
        guard amplitude > 0 else { return floor }
        return max(floor, 20 * log10(amplitude))
    }

    /// dBFS → 0…1 position on a meter that spans `floor…0` dB.
    static func fraction(ofDecibels db: Float, floor: Float = -60) -> Float {
        guard floor < 0 else { return 1 }
        return min(1, max(0, (db - floor) / -floor))
    }
}

/// Lock-free stereo level meter.
///
/// Written from a real-time audio thread (the tap's IOProc, or an `AVAudioEngine` tap block) and
/// read from the main thread at UI frame rate. Everything on the write path is branch-and-arithmetic
/// on stack values plus a handful of relaxed atomics — no allocation, no locks, no ObjC.
///
/// Peaks accumulate as a running maximum and are cleared by the reader, so a transient that lands
/// between two UI frames still shows up. RMS accumulates as a sum of squares plus a frame count and
/// is averaged by the reader.
final class AudioLevelMeter: @unchecked Sendable {

    private let peakLeftBits = Atomic<UInt32>(0)
    private let peakRightBits = Atomic<UInt32>(0)
    private let sumSquaresLeftBits = Atomic<UInt64>(0)
    private let sumSquaresRightBits = Atomic<UInt64>(0)
    private let frameCount = Atomic<Int>(0)

    init() {}

    // MARK: - Write path (real-time threads)

    /// Records `frameCount` interleaved frames. Channels beyond the first two are ignored;
    /// mono is mirrored to both meters.
    func record(interleaved source: UnsafePointer<Float>, frameCount frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }

        var peakL: Float = 0
        var peakR: Float = 0
        var sumL: Double = 0
        var sumR: Double = 0

        for frame in 0..<frames {
            let left = source[frame * channels]
            let right = channels > 1 ? source[frame * channels + 1] : left
            let absL = abs(left)
            let absR = abs(right)
            if absL > peakL { peakL = absL }
            if absR > peakR { peakR = absR }
            sumL += Double(left) * Double(left)
            sumR += Double(right) * Double(right)
        }

        commit(peakL: peakL, peakR: peakR, sumL: sumL, sumR: sumR, frames: frames)
    }

    /// Records planar (non-interleaved) channel buffers, one pointer per channel.
    func record(planar channels: UnsafeBufferPointer<UnsafePointer<Float>>, frameCount frames: Int) {
        guard frames > 0, let left = channels.first else { return }
        let right = channels.count > 1 ? channels[1] : left

        var peakL: Float = 0
        var peakR: Float = 0
        var sumL: Double = 0
        var sumR: Double = 0

        for frame in 0..<frames {
            let l = left[frame]
            let r = right[frame]
            let absL = abs(l)
            let absR = abs(r)
            if absL > peakL { peakL = absL }
            if absR > peakR { peakR = absR }
            sumL += Double(l) * Double(l)
            sumR += Double(r) * Double(r)
        }

        commit(peakL: peakL, peakR: peakR, sumL: sumL, sumR: sumR, frames: frames)
    }

    private func commit(peakL: Float, peakR: Float, sumL: Double, sumR: Double, frames: Int) {
        // Non-negative IEEE-754 floats/doubles order identically to their bit patterns,
        // so a max can be done directly on the integer representation.
        Self.updateMax(peakLeftBits, peakL.bitPattern)
        Self.updateMax(peakRightBits, peakR.bitPattern)
        Self.addDouble(sumSquaresLeftBits, sumL)
        Self.addDouble(sumSquaresRightBits, sumR)
        frameCount.add(frames, ordering: .relaxed)
    }

    // MARK: - Read path (main thread)

    /// Returns the levels accumulated since the previous call and resets the accumulators.
    func drain() -> AudioLevels {
        let frames = frameCount.exchange(0, ordering: .relaxed)
        let peakL = Float(bitPattern: peakLeftBits.exchange(0, ordering: .relaxed))
        let peakR = Float(bitPattern: peakRightBits.exchange(0, ordering: .relaxed))
        let sumL = Double(bitPattern: sumSquaresLeftBits.exchange(0, ordering: .relaxed))
        let sumR = Double(bitPattern: sumSquaresRightBits.exchange(0, ordering: .relaxed))

        guard frames > 0 else { return .silent }
        return AudioLevels(
            peakLeft: peakL,
            peakRight: peakR,
            rmsLeft: Float((sumL / Double(frames)).squareRoot()),
            rmsRight: Float((sumR / Double(frames)).squareRoot())
        )
    }

    func reset() {
        peakLeftBits.store(0, ordering: .relaxed)
        peakRightBits.store(0, ordering: .relaxed)
        sumSquaresLeftBits.store(0, ordering: .relaxed)
        sumSquaresRightBits.store(0, ordering: .relaxed)
        frameCount.store(0, ordering: .relaxed)
    }

    // MARK: - Atomic helpers

    private static func updateMax(_ atomic: borrowing Atomic<UInt32>, _ bits: UInt32) {
        var current = atomic.load(ordering: .relaxed)
        while bits > current {
            let (exchanged, original) = atomic.compareExchange(
                expected: current, desired: bits, ordering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }

    private static func addDouble(_ atomic: borrowing Atomic<UInt64>, _ value: Double) {
        var current = atomic.load(ordering: .relaxed)
        while true {
            let updated = (Double(bitPattern: current) + value).bitPattern
            let (exchanged, original) = atomic.compareExchange(
                expected: current, desired: updated, ordering: .relaxed
            )
            if exchanged { return }
            current = original
        }
    }
}
