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
    case unsupportedTapFormat

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "SignalDeck needs permission to record system audio. Open System Settings › Privacy & Security › Screen & System Audio Recording and enable SignalDeck."
        case .tapCreationFailed(let s):  return "Could not create the audio tap (OSStatus \(s))."
        case .aggregateCreationFailed(let s): return "Could not create the capture device (OSStatus \(s))."
        case .ioProcFailed(let s):       return "Could not start audio capture (OSStatus \(s))."
        case .noOutputDevice:            return "No default output device is available."
        case .unsupportedTapFormat:      return "The tap returned an audio format SignalDeck can't handle."
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
    func start(processObjectIDs: [AudioObjectID], bundleIDs: [String] = []) throws {
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
            // TCC denial surfaces as a permission/illegal-operation error rather than a distinct code.
            if tapStatus == kAudioHardwareIllegalOperationError || tapStatus == kAudioHardwareBadObjectError {
                throw ProcessTapError.permissionDenied
            }
            throw ProcessTapError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        // The pointer must not escape the closure — `withUnsafePointer(to:) { $0 }` hands back a
        // dangling pointer, so AVAudioFormat has to be built *inside* the scope.
        let asbd = try Self.tapStreamFormat(tapID)
        guard let format = withUnsafePointer(to: asbd, { AVAudioFormat(streamDescription: $0) }) else {
            throw ProcessTapError.unsupportedTapFormat
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
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, nil
        ) { _, inInputData, _, _, _ in
            Self.consume(inInputData, into: ring, meter: meter,
                         scratch: scratchBuffer, maxFrames: maxFrames)
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
    /// could take a lock. Interleaves whatever layout the tap gave us into the ring buffer.
    private static func consume(_ inputData: UnsafePointer<AudioBufferList>,
                                into ring: AudioRingBuffer,
                                meter: AudioLevelMeter,
                                scratch: UnsafeMutableBufferPointer<Float>,
                                maxFrames: Int) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard ablPointer.count > 0 else { return }
        guard let dst = scratch.baseAddress else { return }

        if ablPointer.count == 1 {
            // Interleaved (or mono) in a single buffer.
            let buffer = ablPointer[0]
            guard let raw = buffer.mData else { return }
            let src = raw.assumingMemoryBound(to: Float.self)
            let inChannels = Int(buffer.mNumberChannels)
            guard inChannels > 0 else { return }
            let frames = min(Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels), maxFrames)
            guard frames > 0 else { return }

            if inChannels == 2 {
                meter.record(interleaved: src, frameCount: frames, channels: 2)
                ring.write(interleaved: src, frameCount: frames)
                return
            }
            for frame in 0..<frames {                       // mono -> stereo, or take first 2 chans
                let left = src[frame * inChannels]
                let right = inChannels > 1 ? src[frame * inChannels + 1] : left
                dst[frame * 2] = left
                dst[frame * 2 + 1] = right
            }
            meter.record(interleaved: dst, frameCount: frames, channels: 2)
            ring.write(interleaved: dst, frameCount: frames)
        } else {
            // Non-interleaved / planar: one buffer per channel.
            let left = ablPointer[0]
            guard let leftData = left.mData else { return }
            let frames = min(Int(left.mDataByteSize) / MemoryLayout<Float>.size, maxFrames)
            guard frames > 0 else { return }
            let leftPtr = leftData.assumingMemoryBound(to: Float.self)
            let rightPtr = ablPointer.count > 1
                ? (ablPointer[1].mData?.assumingMemoryBound(to: Float.self) ?? leftPtr)
                : leftPtr

            for frame in 0..<frames {
                dst[frame * 2] = leftPtr[frame]
                dst[frame * 2 + 1] = rightPtr[frame]
            }
            meter.record(interleaved: dst, frameCount: frames, channels: 2)
            ring.write(interleaved: dst, frameCount: frames)
        }
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
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else {
            throw ProcessTapError.unsupportedTapFormat
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
