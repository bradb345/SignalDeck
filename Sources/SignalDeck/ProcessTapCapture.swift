import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum ProcessTapError: LocalizedError {
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case noOutputDevice
    /// The process objects we were handed no longer exist. Distinct from a permission failure:
    /// a TCC denial comes back as `kAudioHardwareIllegalOperationError`, a dead object as
    /// `kAudioHardwareBadObjectError`. Reporting this one as a denial sends the user to System
    /// Settings to fix something that isn't broken there.
    case staleProcessObjects
    /// `kAudioTapPropertyFormat` could not be read at all.
    case tapFormatUnreadable(OSStatus)
    /// The tap described a format we can't build an `AVAudioFormat` from. Carries the raw fields,
    /// because "can't handle it" with nothing else attached is not a debuggable report.
    case unsupportedTapFormat(sampleRate: Double, channels: UInt32, bitsPerChannel: UInt32)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "SignalDeck needs permission to record system audio. Open System Settings › Privacy & Security › Screen & System Audio Recording and enable SignalDeck."
        case .tapCreationFailed(let s):  return "Could not create the audio tap (OSStatus \(s))."
        case .aggregateCreationFailed(let s): return "Could not create the capture device (OSStatus \(s))."
        case .ioProcFailed(let s):       return "Could not start audio capture (OSStatus \(s))."
        case .noOutputDevice:            return "No default output device is available."
        case .staleProcessObjects:
            return "That app's audio changed while SignalDeck was starting. Try the toggle again."
        case .tapFormatUnreadable(let s):
            return "Could not read the tap's audio format (OSStatus \(s))."
        case .unsupportedTapFormat(let rate, let channels, let bits):
            // %g rather than Int(rate): a fractional or nonsensical rate is exactly the case this
            // error exists to report, and truncating it hides the evidence (Int() would also trap
            // on a non-finite one).
            let rateText = String(format: "%.10g", rate)
            return "The tap returned an audio format SignalDeck can't handle (\(rateText) Hz, \(channels) ch, \(bits)-bit)."
        }
    }
}

/// Captures the audio of one or more processes using the Core Audio process-tap API
/// (`AudioHardwareCreateProcessTap`, macOS 14.4+) and pushes it into an `AudioRingBuffer`.
///
/// Two objects get created:
///
///   1. **The tap** — a `CATapDescription` stereo mixdown of the target process objects.
///      `muteBehavior = .mutedWhenTapped` is the critical setting: it silences the target app's
///      own path to the hardware while we're reading, so the user hears *only* our compressed
///      copy instead of both streams at once.
///
///   2. **A private aggregate device** that owns the tap and is clocked by the current default
///      output device, with drift compensation enabled on the tap sub-device. Running an
///      `AudioDeviceIOProc` on that aggregate is what actually pulls samples.
///
/// The IOProc is a real-time thread: it only interleaves and memcpys into the ring buffer.
final class ProcessTapCapture: @unchecked Sendable {

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var scratch: UnsafeMutableBufferPointer<Float>?

    /// Format the tap actually delivers. Read this *after* `start` to configure the engine.
    private(set) var tapFormat: AVAudioFormat?

    let ringBuffer: AudioRingBuffer

    /// Level of what the tap is delivering, i.e. the *input* side of the rack. This is the
    /// meter that answers "is the app I selected actually producing audio?".
    let inputMeter = AudioLevelMeter()

    /// ~20 ms at 48 kHz. Enough cushion to absorb the drift between the tap's clock and the
    /// output device's without adding latency anyone notices against video.
    init(ringCapacityFrames: Int = 48_000, primeFrames: Int = 960) {
        self.ringBuffer = AudioRingBuffer(
            capacityFrames: ringCapacityFrames, channels: 2, primeFrames: primeFrames
        )
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - processObjectIDs: the Core Audio process objects to mix down.
    ///   - bundleIDs: on macOS 26+, also pin the tap to these bundle IDs. Combined with
    ///     `isProcessRestoreEnabled`, this makes the tap survive the target app quitting and
    ///     relaunching — the difference between "a capture session" and "Plex just always
    ///     sounds like this", which is the SoundSource behaviour we're after.
    /// - Returns: the format the tap is delivering, to configure the engine with. Also available
    ///   afterwards as `tapFormat`; returning it saves callers from unwrapping an optional that
    ///   is always populated on success.
    @discardableResult
    func start(processObjectIDs: [AudioObjectID], bundleIDs: [String] = []) throws -> AVAudioFormat {
        stop()

        // --- 1. Tap -------------------------------------------------------------------
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "SignalDeck Tap"
        description.isPrivate = true            // invisible to other apps
        description.isExclusive = false         // don't stop other taps on the same process
        description.muteBehavior = .mutedWhenTapped

        if #available(macOS 26.0, *), !bundleIDs.isEmpty {
            description.bundleIDs = bundleIDs
            description.isProcessRestoreEnabled = true
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr else {
            // TCC denial surfaces as an illegal-operation error rather than a distinct code.
            //
            // `kAudioHardwareBadObjectError` used to be folded in here too, but it is what you get
            // for a process object that has gone away — the app restarted its audio between the
            // discovery poll and the toggle. Calling that a permission problem points the user at
            // System Settings, where there is nothing to fix.
            if tapStatus == kAudioHardwareIllegalOperationError {
                throw ProcessTapError.permissionDenied
            }
            if tapStatus == kAudioHardwareBadObjectError {
                throw ProcessTapError.staleProcessObjects
            }
            throw ProcessTapError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        // The pointer must not escape the closure — `withUnsafePointer(to:) { $0 }` hands back a
        // dangling pointer, so AVAudioFormat has to be built *inside* the scope.
        let asbd = try Self.tapStreamFormat(tapID)
        guard let format = withUnsafePointer(to: asbd, { AVAudioFormat(streamDescription: $0) }) else {
            throw ProcessTapError.unsupportedTapFormat(
                sampleRate: asbd.mSampleRate,
                channels: asbd.mChannelsPerFrame,
                bitsPerChannel: asbd.mBitsPerChannel
            )
        }
        tapFormat = format

        // --- 2. Aggregate device wrapping the tap --------------------------------------
        guard let outputUID = Self.defaultOutputDeviceUID() else { throw ProcessTapError.noOutputDevice }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SignalDeck Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,     // never appears in Sound settings
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggStatus == noErr else {
            stop()
            throw ProcessTapError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = aggregate

        // --- 3. IOProc -----------------------------------------------------------------
        let maxFrames = 4096
        let scratchBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: maxFrames * 2)
        scratchBuffer.initialize(repeating: 0)
        scratch = scratchBuffer

        let ring = ringBuffer
        let meter = inputMeter
        // How many of the aggregate's input channels belong to the tap, as opposed to the output
        // sub-device's own inputs. `consume` needs it to find the tap in the buffer list.
        let tapChannels = Int(asbd.mChannelsPerFrame)
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, nil
        ) { _, inInputData, _, _, _ in
            Self.consume(inInputData, into: ring, meter: meter,
                         scratch: scratchBuffer, maxFrames: maxFrames,
                         tapChannelCount: tapChannels)
        }
        guard ioStatus == noErr, let procID else {
            stop()
            throw ProcessTapError.ioProcFailed(ioStatus)
        }
        ioProcID = procID

        ringBuffer.reset()
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            stop()
            throw ProcessTapError.ioProcFailed(startStatus)
        }

        return format
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        scratch?.deallocate()
        scratch = nil
        tapFormat = nil
        inputMeter.reset()
    }

    // MARK: - Real-time path

    /// Runs on the Core Audio IO thread. No allocation, no locks, no Swift runtime calls that
    /// could take a lock. Pulls the tap's stereo pair out of whatever the aggregate hands us and
    /// writes it to the ring buffer.
    ///
    /// **The buffer list is not just the tap.** The aggregate is built from the default output
    /// device *plus* the tap, and Core Audio hands the IOProc every input stream the aggregate
    /// owns — sub-devices first, taps appended after them. On a plain pair of speakers the output
    /// device has no input streams and the tap is all there is, which is why treating buffer 0 as
    /// the tap's left channel appeared to work. Point the Mac at an audio interface and it stops:
    /// a Focusrite Scarlett 6i6 contributes six input channels of its own, so buffer 0 is the
    /// interface's mic preamps and the tap is somewhere behind it. The old code read the
    /// interface's inputs as the left channel, the tap's interleaved stereo as the right, and
    /// sized the copy from a six-channel buffer — one channel of live mic, one of scrambled
    /// double-rate audio, and a frame count six times too large.
    ///
    /// So: flatten the whole list into a channel index that honours each buffer's
    /// `mNumberChannels` (buffers can be planar, interleaved, or a mix), and take the tap's
    /// channels as the **last** `tapChannelCount` of it. That is where the aggregate puts them,
    /// and when the tap is the only input stream it degrades to offset 0 — the case that already
    /// worked.
    private static func consume(_ inputData: UnsafePointer<AudioBufferList>,
                                into ring: AudioRingBuffer,
                                meter: AudioLevelMeter,
                                scratch: UnsafeMutableBufferPointer<Float>,
                                maxFrames: Int,
                                tapChannelCount: Int) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard ablPointer.count > 0, tapChannelCount > 0 else { return }
        guard let dst = scratch.baseAddress else { return }

        var totalChannels = 0
        for index in 0..<ablPointer.count {
            totalChannels += Int(ablPointer[index].mNumberChannels)
        }
        guard totalChannels > 0 else { return }

        // Derived per callback rather than cached at start: the aggregate reports its stream
        // layout before the device is running, and a layout that changed underneath us would
        // otherwise leave a stale offset silently reading the wrong channels.
        //
        // The clamp is correct rather than merely defensive. If the list carries fewer channels
        // than the tap claims, it cannot also hold a sub-device stream ahead of the tap — there is
        // nothing in front of the tap to skip — so channel 0 is the tap's first channel.
        let offset = max(0, totalChannels - tapChannelCount)
        let leftChannel = offset
        let rightChannel = tapChannelCount > 1 ? offset + 1 : offset

        // Resolve both channels to a base pointer and a stride. Stride is the owning buffer's
        // channel count: 1 for planar, N for an N-channel interleaved buffer.
        var left: UnsafePointer<Float>?
        var right: UnsafePointer<Float>?
        var leftStride = 1
        var rightStride = 1
        var frames = maxFrames

        var channelBase = 0
        for index in 0..<ablPointer.count {
            let buffer = ablPointer[index]
            let bufferChannels = Int(buffer.mNumberChannels)
            guard bufferChannels > 0 else { continue }
            defer { channelBase += bufferChannels }
            guard let raw = buffer.mData else { continue }

            let base = raw.assumingMemoryBound(to: Float.self)
            let bufferFrames = Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * bufferChannels)

            if leftChannel >= channelBase, leftChannel < channelBase + bufferChannels {
                left = UnsafePointer(base + (leftChannel - channelBase))
                leftStride = bufferChannels
                frames = min(frames, bufferFrames)
            }
            if rightChannel >= channelBase, rightChannel < channelBase + bufferChannels {
                right = UnsafePointer(base + (rightChannel - channelBase))
                rightStride = bufferChannels
                frames = min(frames, bufferFrames)
            }
        }

        guard let leftPtr = left, frames > 0 else { return }
        // A mono tap mirrors to both sides rather than playing out of one speaker.
        let rightPtr = right ?? leftPtr
        let rightStep = right != nil ? rightStride : leftStride

        for frame in 0..<frames {
            dst[frame * 2] = leftPtr[frame * leftStride]
            dst[frame * 2 + 1] = rightPtr[frame * rightStep]
        }

        // The meter reads the same samples that reach the ring, so "Input" answers "what is the
        // rack actually being fed?" rather than "what did the tap hand the aggregate?".
        meter.record(interleaved: dst, frameCount: frames, channels: 2)
        ring.write(interleaved: dst, frameCount: frames)
    }

    // MARK: - Core Audio helpers

    private static func tapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw ProcessTapError.tapFormatUnreadable(status)
        }
        return asbd
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }
}
