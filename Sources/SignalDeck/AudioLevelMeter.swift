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

    /// One interval's accumulators.
    ///
    /// There are two, and the reader flips which one the producer is aiming at before it drains
    /// the other. Draining a single shared bank meant exchanging five atomics one at a time while
    /// the producer was updating the same five in a different order, so a peak and sum from the
    /// new interval could land against the old frame count — RMS computed from a sum and a frame
    /// count that never belonged together.
    private final class Bank {
        let peakLeftBits = Atomic<UInt32>(0)
        let peakRightBits = Atomic<UInt32>(0)
        let sumSquaresLeftBits = Atomic<UInt64>(0)
        let sumSquaresRightBits = Atomic<UInt64>(0)
        let frameCount = Atomic<Int>(0)

        /// Odd while a commit is in flight. The flip can catch a producer that already picked this
        /// bank, so the reader needs to know when the bank has gone quiet.
        let commitSequence = Atomic<UInt64>(0)

        func clear() {
            peakLeftBits.store(0, ordering: .relaxed)
            peakRightBits.store(0, ordering: .relaxed)
            sumSquaresLeftBits.store(0, ordering: .relaxed)
            sumSquaresRightBits.store(0, ordering: .relaxed)
            frameCount.store(0, ordering: .relaxed)
        }
    }

    private let banks = (Bank(), Bank())
    private let epoch = Atomic<UInt64>(0)

    private func bank(for epoch: UInt64) -> Bank { epoch & 1 == 0 ? banks.0 : banks.1 }

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
        // Claim a bank, then confirm the reader didn't retire it in the gap between picking it and
        // marking the commit in flight — otherwise the reader sees a quiescent bank, starts
        // clearing it, and wipes half of what lands next. Re-checking the epoch after the mark
        // means the reader either sees the mark and waits, or the claim is void and we retry. At
        // 30 Hz drains a second pass is already vanishingly rare, and the loop is only atomics.
        var bank: Bank
        while true {
            let claimed = epoch.load(ordering: .acquiring)
            bank = self.bank(for: claimed)
            bank.commitSequence.add(1, ordering: .acquiringAndReleasing)
            if epoch.load(ordering: .acquiring) == claimed { break }
            bank.commitSequence.add(1, ordering: .releasing)
        }

        // Non-negative IEEE-754 floats/doubles order identically to their bit patterns,
        // so a max can be done directly on the integer representation.
        Self.updateMax(bank.peakLeftBits, peakL.bitPattern)
        Self.updateMax(bank.peakRightBits, peakR.bitPattern)
        Self.addDouble(bank.sumSquaresLeftBits, sumL)
        Self.addDouble(bank.sumSquaresRightBits, sumR)
        bank.frameCount.add(frames, ordering: .relaxed)

        bank.commitSequence.add(1, ordering: .releasing)
    }

    // MARK: - Read path (main thread)

    /// Returns the levels accumulated since the previous call, as one coherent snapshot.
    ///
    /// Retires the producer's current bank by flipping the epoch, then reads and clears it. The
    /// producer never touches a retired bank again, so peak, sums and frame count all come from
    /// the same interval.
    func drain() -> AudioLevels {
        let retired = epoch.load(ordering: .relaxed)
        epoch.store(retired &+ 1, ordering: .releasing)
        let bank = bank(for: retired)

        // A commit that chose this bank just before the flip may still be part-way through. It is
        // five atomic updates, so a brief spin covers it — but it runs on a real-time thread that
        // the scheduler can preempt, and blocking the UI thread on one is not worth a meter frame.
        // Bail out instead and let the caller's peak-hold ride over the gap.
        var spins = 0
        while bank.commitSequence.load(ordering: .acquiring) & 1 == 1 {
            spins += 1
            guard spins < 4096 else { return .silent }
        }

        let frames = bank.frameCount.load(ordering: .relaxed)
        let peakL = Float(bitPattern: bank.peakLeftBits.load(ordering: .relaxed))
        let peakR = Float(bitPattern: bank.peakRightBits.load(ordering: .relaxed))
        let sumL = Double(bitPattern: bank.sumSquaresLeftBits.load(ordering: .relaxed))
        let sumR = Double(bitPattern: bank.sumSquaresRightBits.load(ordering: .relaxed))
        bank.clear()

        guard frames > 0 else { return .silent }
        return AudioLevels(
            peakLeft: peakL,
            peakRight: peakR,
            rmsLeft: Float((sumL / Double(frames)).squareRoot()),
            rmsRight: Float((sumR / Double(frames)).squareRoot())
        )
    }

    func reset() {
        banks.0.clear()
        banks.1.clear()
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
