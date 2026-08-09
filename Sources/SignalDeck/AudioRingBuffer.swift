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

    /// Ceiling on how far behind the consumer is allowed to fall before it throws frames away.
    ///
    /// The producer refuses to overwrite unread frames, so without this a faster tap clock would
    /// fill the ring and simply park that much delay in front of the listener — a whole second at
    /// the default capacity, which A/V sync against Plex's video would show up immediately.
    private let maxBufferedFrames: Int

    init(capacityFrames: Int, channels: Int, primeFrames: Int = 0) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.primeFrames = min(max(primeFrames, 0), capacityFrames / 2)
        self.maxBufferedFrames = min(capacityFrames, max(self.primeFrames * 4, 2048))
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

    /// Writes as many of `frameCount` interleaved frames as there is free space for, counting an
    /// overrun if any had to be dropped.
    ///
    /// The producer never writes over frames the consumer hasn't taken. An earlier version did —
    /// dropping the *oldest* audio to bound latency — but the consumer can be copying out of those
    /// exact slots at that moment, and unsynchronised concurrent access to plain `Float` storage
    /// is a data race whatever the copy happens to produce. Detecting the overlap afterwards and
    /// discarding the result hides the splice without removing the race; ThreadSanitizer still
    /// reports it. Bounding latency is the consumer's job instead — see `maxBufferedFrames`.
    func write(interleaved source: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let free = max(capacityFrames - (write - read), 0)

        let writable = min(frameCount, free)
        if writable < frameCount { overrunCount.add(1, ordering: .relaxed) }
        guard writable > 0 else { return }

        let base = storage.baseAddress!
        var written = 0
        while written < writable {
            let position = (write + written) % capacityFrames
            let chunk = min(writable - written, capacityFrames - position)
            (base + position * channels).update(from: source + written * channels,
                                                count: chunk * channels)
            written += chunk
        }

        writeIndex.store(write + writable, ordering: .releasing)
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

        var buffered = write - read
        if buffered < 0 { buffered = 0 }

        // The tap and the output device are clocked separately, so a faster tap grows the backlog
        // and with it the delay the listener hears. Trimming it is the consumer's job: `readIndex`
        // is consumer-owned, so throwing frames away here needs no agreement with the producer and
        // touches no storage the producer is writing.
        //
        // The ceiling has to clear the priming gate below, which wants a whole render plus the
        // cushion. A device rendering slices larger than `maxBufferedFrames` would otherwise be
        // trimmed to below the threshold it is waiting on, never prime, and output silence for
        // ever — 4096-frame slices against the default 3840 ceiling do exactly that.
        let ceiling = max(maxBufferedFrames, max(primeFrames, frameCount) * 2)
        if buffered > ceiling {
            overrunCount.add(1, ordering: .relaxed)
            read = write - ceiling
            buffered = ceiling
        }

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
