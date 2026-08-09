import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free ring buffer of interleaved Float32 frames.
///
/// Producer  = the Core Audio `AudioDeviceIOProc` driving the tap (real-time thread A).
/// Consumer  = the `AVAudioSourceNode` render block inside `AVAudioEngine` (real-time thread B).
///
/// Both sides are wait-free: no locks, no allocation, no ObjC. That matters — either thread
/// blocking for even a millisecond produces an audible glitch.
///
/// The two threads are clocked by *different* devices in the general case (the tap's aggregate
/// clock vs. the output device clock), so their rates drift. Overruns/underruns are counted so
/// the controller can surface drift and so Phase 3 can add rate correction.
final class AudioRingBuffer: @unchecked Sendable {

    let channels: Int
    private let capacityFrames: Int
    private let storage: UnsafeMutableBufferPointer<Float>

    /// Monotonic frame counters; the modulo happens at access time.
    ///
    /// `writeIndex` is owned exclusively by the producer and `readIndex` exclusively by the
    /// consumer. Neither side ever writes the other's index — that's what makes this wait-free
    /// without a CAS loop, and an earlier version that let the producer shove `readIndex`
    /// forward on overrun could rewind the consumer mid-read.
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    private let overrunCount = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)

    /// Frames the consumer waits for before it starts handing out audio.
    ///
    /// Without this the consumer drains the buffer to empty on its very first pull and then sits
    /// permanently at zero fill, so every subsequent render underruns by a few frames and the
    /// output is a continuous crackle. Priming parks a small cushion between the two clocks.
    private let primeFrames: Int
    private let isPrimed = Atomic<Bool>(false)

    init(capacityFrames: Int, channels: Int, primeFrames: Int = 0) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.primeFrames = min(max(primeFrames, 0), capacityFrames / 2)
        let sampleCount = capacityFrames * channels
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: sampleCount)
        storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    var framesAvailable: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    var overruns: Int { overrunCount.load(ordering: .relaxed) }
    var underruns: Int { underrunCount.load(ordering: .relaxed) }

    // MARK: - Producer side (tap IOProc thread)

    /// Writes `frameCount` interleaved frames. If the buffer would overflow we just keep writing
    /// and count an overrun — dropping the *oldest* audio keeps latency bounded, which is what
    /// you want for live playback. The consumer notices it has been lapped and skips forward;
    /// the producer never touches `readIndex`.
    func write(interleaved source: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0, frameCount <= capacityFrames else { return }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacityFrames - (write - read)

        if frameCount > free {
            overrunCount.add(1, ordering: .relaxed)
        }

        let base = storage.baseAddress!
        var written = 0
        while written < frameCount {
            let offset = ((write + written) % capacityFrames) * channels
            let chunk = min(frameCount - written, capacityFrames - ((write + written) % capacityFrames))
            (base + offset).update(from: source + written * channels, count: chunk * channels)
            written += chunk
        }

        writeIndex.store(write + frameCount, ordering: .releasing)
    }

    // MARK: - Consumer side (AVAudioEngine render thread)

    /// Reads `frameCount` frames into non-interleaved (planar) destination buffers.
    /// Missing frames are filled with silence and counted as an underrun.
    /// - Returns: the number of real frames delivered.
    @discardableResult
    func read(intoPlanar destinations: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>,
              frameCount: Int) -> Int {
        var read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)

        let outChannels = min(destinations.count, channels)
        guard outChannels > 0, frameCount > 0 else { return 0 }

        // The producer lapped us: everything older than `capacityFrames` has been overwritten.
        if write - read > capacityFrames {
            read = write - capacityFrames
        }

        var buffered = write - read
        if buffered < 0 { buffered = 0 }

        // Hold output at silence until a cushion has built up, and re-arm after a dry spell.
        if !isPrimed.load(ordering: .relaxed) {
            guard buffered >= max(primeFrames, frameCount) else {
                for ch in 0..<outChannels {
                    destinations[ch].update(repeating: 0, count: frameCount)
                }
                readIndex.store(read, ordering: .releasing)
                return 0
            }
            isPrimed.store(true, ordering: .relaxed)
        }

        let available = min(frameCount, buffered)
        if available < frameCount {
            underrunCount.add(1, ordering: .relaxed)
            isPrimed.store(false, ordering: .relaxed)
        }

        let base = storage.baseAddress!
        for frame in 0..<available {
            let offset = ((read + frame) % capacityFrames) * channels
            for ch in 0..<outChannels {
                destinations[ch][frame] = base[offset + ch]
            }
        }
        if available < frameCount {
            for ch in 0..<outChannels {
                (destinations[ch] + available).update(repeating: 0, count: frameCount - available)
            }
        }

        readIndex.store(read + available, ordering: .releasing)
        return available
    }

    /// Drop everything buffered. Call on start/stop, never from a render thread.
    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
        overrunCount.store(0, ordering: .relaxed)
        underrunCount.store(0, ordering: .relaxed)
        isPrimed.store(false, ordering: .relaxed)
    }
}
