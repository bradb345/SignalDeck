import AudioToolbox
import Foundation

/// Starting points. These are ordinary racks — once loaded, every parameter is editable in the
/// AU's own editor and can be re-saved as a user rack.
///
/// **Reading the dynamics settings:** `AUDynamicsProcessor` has no compression *ratio*
/// parameter. Its compressor is defined by `Threshold` + `HeadRoom`: material above the
/// threshold is squeezed so peaks land roughly `HeadRoom` dB above it, which means a *smaller*
/// head room is *harder* compression. Don't go looking for a ratio knob in the editor.
///
/// `ExpansionRatio` is a separate downward expander (a soft gate) and its stock default of 2:1
/// pushes quiet dialogue further down — the exact opposite of what we want. Every factory rack
/// pins it to 1.0.
enum FactoryRacks {

    private static let dynamics = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0
    )
    private static let limiter = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0
    )
    private static let graphicEQ = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_GraphicEQ,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0
    )

    private static func dynamicsSnapshot(
        name: String, threshold: Float, headRoom: Float,
        attack: Float, release: Float, gain: Float
    ) -> EffectSnapshot {
        EffectSnapshot(
            componentDescription: dynamics,
            displayName: name,
            parameterOverrides: [
                String(kDynamicsProcessorParam_Threshold): threshold,
                String(kDynamicsProcessorParam_HeadRoom): headRoom,
                String(kDynamicsProcessorParam_ExpansionRatio): 1.0,
                String(kDynamicsProcessorParam_ExpansionThreshold): -100,
                String(kDynamicsProcessorParam_AttackTime): attack,
                String(kDynamicsProcessorParam_ReleaseTime): release,
                // Historically `MasterGain`; Swift only exposes the current spelling.
                String(kDynamicsProcessorParam_OverallGain): gain
            ]
        )
    }

    /// A brickwall catch after the make-up gain. `OverallGain` is applied post-compression with
    /// no ceiling, so transients the attack missed will clip without this.
    private static var limiterSnapshot: EffectSnapshot {
        EffectSnapshot(
            componentDescription: limiter,
            displayName: "Peak Limiter",
            parameterOverrides: [
                String(kLimiterParam_AttackTime): 0.001,
                String(kLimiterParam_DecayTime): 0.050,
                String(kLimiterParam_PreGain): 0
            ]
        )
    }

    /// Late-night: clamp explosions hard, then lift the whole mix so whispered dialogue is
    /// audible at low system volume. Slowish attack keeps gunshots and door slams from sounding
    /// lifeless; long release avoids audible pumping under score.
    static var nightMode: RackSnapshot {
        RackSnapshot(name: "Night Mode", effects: [
            dynamicsSnapshot(name: "Night Compressor", threshold: -32, headRoom: 6,
                             attack: 0.004, release: 0.220, gain: 9),
            limiterSnapshot
        ])
    }

    /// Speech-forward: engages earlier, recovers faster, more make-up gain. The graphic EQ is
    /// added bypassed as a starting point for carving the 2–4 kHz presence range by ear.
    static var dialogueBoost: RackSnapshot {
        RackSnapshot(name: "Dialogue Boost", effects: [
            dynamicsSnapshot(name: "Dialogue Compressor", threshold: -26, headRoom: 4,
                             attack: 0.002, release: 0.120, gain: 12),
            EffectSnapshot(componentDescription: graphicEQ, displayName: "Presence EQ", isBypassed: true),
            limiterSnapshot
        ])
    }

    /// Light levelling that keeps most of the original dynamics.
    static var smooth: RackSnapshot {
        RackSnapshot(name: "Smooth", effects: [
            dynamicsSnapshot(name: "Gentle Compressor", threshold: -24, headRoom: 12,
                             attack: 0.010, release: 0.300, gain: 4),
            limiterSnapshot
        ])
    }

    /// Routing only — useful for A/B-ing against the untouched stream.
    static var passthrough: RackSnapshot {
        RackSnapshot(name: "Passthrough", effects: [])
    }

    static var all: [RackSnapshot] { [nightMode, dialogueBoost, smooth, passthrough] }
}
