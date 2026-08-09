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
    private let ringBuffer: AudioRingBuffer

    let rack: Rack

    private(set) var isRunning = false

    /// Third-party AUs run in-process by default: lower latency, and we're not sandboxed so
    /// there's no restriction. Flip to `.loadOutOfProcess` if a flaky plugin is crashing
    /// SignalDeck — it costs some latency but a plugin crash then takes down only the AU host.
    var instantiationOptions: AudioComponentInstantiationOptions = []

    init(ringBuffer: AudioRingBuffer, rack: Rack) {
        self.ringBuffer = ringBuffer
        self.rack = rack
        rack.onTopologyChanged = { [weak self] in self?.repatch() }
    }

    // MARK: - Lifecycle

    /// Builds the source node for the format the tap is producing.
    /// Call after `ProcessTapCapture.start`, once `tapFormat` is known.
    func prepare(sourceFormat: AVAudioFormat) throws {
        teardown()

        // The ring buffer already normalised layout, so the engine always sees planar stereo.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 2,
            interleaved: false
        ) else { throw ProcessTapError.unsupportedTapFormat }
        renderFormat = format

        let ring = ringBuffer
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
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
        engine.prepare()
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

        let restoreVolume = engine.mainMixerNode.outputVolume
        engine.mainMixerNode.outputVolume = 0
        buildConnections()
        applyOutputGain()

        // ~15 ms is long enough for in-flight buffers to drain through the new chain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self else { return }
            self.engine.mainMixerNode.outputVolume = max(restoreVolume, self.linearOutputGain)
        }
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
