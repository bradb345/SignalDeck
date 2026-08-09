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
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    private let overrunCount = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = capacityFrames
        self.channels = channels
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

    /// Writes `frameCount` interleaved frames. If the buffer would overflow we advance the read
    /// index instead of blocking — dropping the *oldest* audio keeps latency bounded, which is
    /// what you want for live playback.
    func write(interleaved source: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0, frameCount <= capacityFrames else { return }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = capacityFrames - (write - read)

        if frameCount > free {
            overrunCount.add(1, ordering: .relaxed)
            readIndex.store(write + frameCount - capacityFrames, ordering: .releasing)
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
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let available = min(frameCount, write - read)

        if available < frameCount { underrunCount.add(1, ordering: .relaxed) }

        let base = storage.baseAddress!
        let outChannels = min(destinations.count, channels)

        for frame in 0..<max(available, 0) {
            let offset = ((read + frame) % capacityFrames) * channels
            for ch in 0..<outChannels {
                destinations[ch][frame] = base[offset + ch]
            }
        }
        if available < frameCount {
            for ch in 0..<outChannels {
                (destinations[ch] + max(available, 0)).update(
                    repeating: 0, count: frameCount - max(available, 0)
                )
            }
        }

        readIndex.store(read + max(available, 0), ordering: .releasing)
        return max(available, 0)
    }

    /// Drop everything buffered. Call on start/stop, never from a render thread.
    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
        overrunCount.store(0, ordering: .relaxed)
        underrunCount.store(0, ordering: .relaxed)
    }
}
