import AVFoundation
import AudioToolbox
import Foundation

/// The playback half of the pipeline:
///
///     AudioRingBuffer → AVAudioSourceNode → [user rack: AU → AU → …] → mainMixer → output
///
/// The rack is fully dynamic. `AVAudioEngine` supports re-patching while running, so adding,
/// removing or reordering an insert doesn't interrupt playback — we ramp the mixer down for a
/// few milliseconds around the re-patch to avoid a click at the splice.
@MainActor
final class SignalDeckEngine {

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var renderFormat: AVAudioFormat?
    private var isOutputTapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var pendingGainRestore: DispatchWorkItem?
    private let ringBuffer: AudioRingBuffer

    let rack: Rack

    /// Level of what leaves the rack, i.e. what the user actually hears.
    let outputMeter = AudioLevelMeter()

    /// Called when `AVAudioEngine` tears its own graph down (hardware format change). The engine
    /// is unusable at that point and the whole capture chain has to be rebuilt.
    var onConfigurationChanged: (@MainActor () -> Void)?

    private(set) var isRunning = false

    /// Third-party AUs run in-process by default: lower latency, and we're not sandboxed so
    /// there's no restriction. Flip to `.loadOutOfProcess` if a flaky plugin is crashing
    /// SignalDeck — it costs some latency but a plugin crash then takes down only the AU host.
    var instantiationOptions: AudioComponentInstantiationOptions = []

    init(ringBuffer: AudioRingBuffer, rack: Rack) {
        self.ringBuffer = ringBuffer
        self.rack = rack
        rack.onTopologyChanged = { [weak self] in self?.repatch() }

        // AVAudioEngine detaches everything and stops itself when the hardware format changes
        // (switching to headphones, a display waking up). Without this the app looks active but
        // is silent until the user toggles it off and on.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRunning = false
                self.onConfigurationChanged?()
            }
        }
    }

    isolated deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - Lifecycle

    /// Builds the source node for the format the tap is producing.
    /// Call after `ProcessTapCapture.start`, once `tapFormat` is known.
    func prepare(sourceFormat: AVAudioFormat) throws {
        teardown()
        pinOutputToDefaultDevice()

        // The ring buffer already normalised layout, so the engine always sees planar stereo.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            // Report what the *tap* described, not the stereo/32-bit shape we were trying to build:
            // the only way this initialiser fails is a sample rate we can't use, and an error that
            // parrots our own constants back says nothing about which one.
            let asbd = sourceFormat.streamDescription.pointee
            throw ProcessTapError.unsupportedTapFormat(
                sampleRate: asbd.mSampleRate,
                channels: asbd.mChannelsPerFrame,
                bitsPerChannel: asbd.mBitsPerChannel
            )
        }
        renderFormat = format

        let ring = ringBuffer
        // `@Sendable` is load-bearing, not decoration. This class is `@MainActor`, and under Swift 6
        // a non-`Sendable` closure literal inherits the isolation of the context that forms it — so
        // without the annotation the render block becomes main-actor-isolated. Converting it to the
        // plain C-function type `AVAudioSourceNode` wants then makes the compiler emit a dynamic
        // "am I on the main actor?" precondition around the body, which the audio IO thread fails
        // the first time it renders: `dispatch_assert_queue` traps and the whole app dies the
        // instant the user flips the toggle on. Marking it `@Sendable` makes it non-isolated, which
        // is what a real-time render callback has to be. Everything it touches is `Sendable`.
        let node = AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let channelCount = ablPointer.count
            guard channelCount > 0 else { return noErr }

            // Stack-allocated channel pointers; no heap traffic on the render thread.
            withUnsafeTemporaryAllocation(
                of: UnsafeMutablePointer<Float>.self, capacity: channelCount
            ) { pointers in
                var valid = 0
                for channel in 0..<channelCount {
                    guard let data = ablPointer[channel].mData else { break }
                    pointers[valid] = data.assumingMemoryBound(to: Float.self)
                    valid += 1
                }
                guard valid > 0 else { return }
                ring.read(
                    intoPlanar: UnsafeMutableBufferPointer(start: pointers.baseAddress!, count: valid),
                    frameCount: Int(frameCount)
                )
            }
            return noErr
        }
        sourceNode = node
        engine.attach(node)

        buildConnections()
        installOutputMeterTap()
        engine.prepare()
    }

    /// Levels leaving the rack, as heard.
    ///
    /// A tap on `mainMixerNode` is taken *before* the node's `outputVolume` is applied, so the
    /// trim slider would otherwise be invisible on the meter — a user who pulled the trim to
    /// -24 dB would see a healthy bar and hear nothing. Fold the volume back in here.
    func drainOutputLevels() -> AudioLevels {
        outputMeter.drain().scaled(by: engine.mainMixerNode.outputVolume)
    }

    /// Meters the mixer's output, i.e. post-rack, so the UI shows what came out the far end of
    /// the effect chain rather than what the tap handed in.
    private func installOutputMeterTap() {
        guard !isOutputTapInstalled else { return }
        let mixer = engine.mainMixerNode
        let meter = outputMeter
        // `@Sendable` for the same reason as the render block above: the tap is delivered on an
        // internal AVAudioEngine queue, never the main thread, and an inherited main-actor
        // precondition here would trap just as fatally.
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let channels = Int(buffer.format.channelCount)
            guard channels > 0 else { return }
            withUnsafeTemporaryAllocation(
                of: UnsafePointer<Float>.self, capacity: channels
            ) { pointers in
                for channel in 0..<channels {
                    pointers[channel] = UnsafePointer(channelData[channel])
                }
                meter.record(
                    planar: UnsafeBufferPointer(start: pointers.baseAddress!, count: channels),
                    frameCount: frames
                )
            }
        }
        isOutputTapInstalled = true
    }

    /// Point the output unit at the device the user has actually selected in Sound settings.
    ///
    /// `AVAudioEngine` picks the default output device when its output unit is first created, and
    /// then keeps it: an engine instance that outlived a device change would go on rendering into
    /// the device the user has stopped listening to. `SignalDeckController` rebuilds the whole
    /// chain when the default changes, but that relies on a fresh engine resolving the *current*
    /// default, so state it outright instead of inheriting whatever the unit was born with.
    ///
    /// Setting the device is best-effort. Failing to set it is not worth refusing to play over —
    /// the unit keeps whatever device it had, which is usually the right one anyway.
    private func pinOutputToDefaultDevice() {
        guard var deviceID = ProcessTapCapture.defaultOutputDeviceID() else { return }
        let status = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("SignalDeck: could not pin output to device \(deviceID) (OSStatus \(status))")
        }
    }

    func start() throws {
        guard !isRunning else { return }
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }

    func teardown() {
        stop()
        // A restore left in flight would otherwise reach into a graph that no longer exists.
        pendingGainRestore?.cancel()
        pendingGainRestore = nil
        if isOutputTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            isOutputTapInstalled = false
        }
        outputMeter.reset()
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }
        for slot in rack.slots where engine.attachedNodes.contains(slot.unit) {
            engine.disconnectNodeOutput(slot.unit)
            engine.detach(slot.unit)
        }
        renderFormat = nil
    }

    // MARK: - Graph patching

    /// Re-patch after the rack's topology changed, with a short gain dip over the splice.
    private func repatch() {
        guard sourceNode != nil, renderFormat != nil else { return }

        // Dip, re-patch, and only restore once the new chain has had time to fill. Restoring the
        // gain synchronously here (as an earlier version did via `applyOutputGain`) cancels the
        // dip outright and you hear the click it was meant to hide.
        //
        // Drag-reordering fires topology changes faster than 15 ms apart, so the previous restore
        // has to be cancelled first — otherwise it unmutes the mixer in the middle of the next
        // splice and lets exactly that click through.
        pendingGainRestore?.cancel()
        engine.mainMixerNode.outputVolume = 0
        buildConnections()

        // ~15 ms is long enough for in-flight buffers to drain through the new chain.
        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingGainRestore = nil
            self.applyOutputGain()
        }
        pendingGainRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: restore)
    }

    private func buildConnections() {
        guard let source = sourceNode, let format = renderFormat else { return }

        // Detach units that are no longer in the rack.
        let liveUnits = Set(rack.slots.map { ObjectIdentifier($0.unit) })
        for node in engine.attachedNodes {
            guard let unit = node as? AVAudioUnit else { continue }
            if !liveUnits.contains(ObjectIdentifier(unit)) {
                engine.disconnectNodeOutput(unit)
                engine.detach(unit)
            }
        }

        // Attach newcomers.
        for slot in rack.slots where !engine.attachedNodes.contains(slot.unit) {
            engine.attach(slot.unit)
        }

        // Break existing links, then relink in rack order.
        engine.disconnectNodeOutput(source)
        for slot in rack.slots { engine.disconnectNodeOutput(slot.unit) }

        var previous: AVAudioNode = source
        for slot in rack.slots {
            engine.connect(previous, to: slot.unit, format: format)
            previous = slot.unit
        }
        // mainMixerNode rather than outputNode, so the engine inserts sample-rate conversion
        // when the tap's rate differs from the output device's.
        engine.connect(previous, to: engine.mainMixerNode, format: format)
    }

    // MARK: - Output trim

    private var linearOutputGain: Float { pow(10, rack.outputGainDB / 20) }

    func applyOutputGain() {
        engine.mainMixerNode.outputVolume = linearOutputGain
    }

    // MARK: - Metering

    /// Gain reduction from the first dynamics processor in the rack, if there is one.
    /// Returns 0 when the user's chain has no compressor — the meter just sits still.
    var gainReductionDB: Float {
        guard let dynamicsUnit = rack.slots.first(where: {
            $0.unit.audioComponentDescription.componentSubType == kAudioUnitSubType_DynamicsProcessor
                && !$0.isBypassed
        })?.unit else { return 0 }

        var value: AudioUnitParameterValue = 0
        let status = AudioUnitGetParameter(
            dynamicsUnit.audioUnit, kDynamicsProcessorParam_CompressionAmount,
            kAudioUnitScope_Global, 0, &value
        )
        return status == noErr ? value : 0
    }

    /// Total added latency of the rack in milliseconds — worth surfacing, since A/V sync with
    /// Plex's video is the thing users will notice if they stack up latent plugins.
    var rackLatencyMilliseconds: Double {
        rack.slots.reduce(0) { $0 + $1.unit.auAudioUnit.latency } * 1000
    }
}
