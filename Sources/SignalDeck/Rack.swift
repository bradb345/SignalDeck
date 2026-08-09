import AVFoundation
import SwiftUI
import AudioToolbox
import Foundation

// MARK: - Persistence model

/// One insert in a saved rack. `stateData` is the AU's own opaque `fullState`, so third-party
/// plugins round-trip their entire editor state, not just the parameters we know about.
struct EffectSnapshot: Codable, Hashable {
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var displayName: String
    var isBypassed: Bool = false
    /// Property-list encoding of `AUAudioUnit.fullState`.
    var stateData: Data?
    /// Used by factory racks that are defined in code rather than captured from a live unit.
    var parameterOverrides: [String: Float]?

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    init(componentDescription: AudioComponentDescription,
         displayName: String,
         isBypassed: Bool = false,
         stateData: Data? = nil,
         parameterOverrides: [String: Float]? = nil) {
        self.componentType = componentDescription.componentType
        self.componentSubType = componentDescription.componentSubType
        self.componentManufacturer = componentDescription.componentManufacturer
        self.displayName = displayName
        self.isBypassed = isBypassed
        self.stateData = stateData
        self.parameterOverrides = parameterOverrides
    }
}

struct RackSnapshot: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var effects: [EffectSnapshot]
    /// Output trim in dB applied after the chain.
    var outputGainDB: Float = 0
}

// MARK: - Runtime model

/// A live insert: an instantiated `AVAudioUnit` plus the UI state around it.
@MainActor
@Observable
final class EffectSlot: Identifiable {
    let id = UUID()
    let unit: AVAudioUnit
    let displayName: String
    let manufacturer: String
    let hasCustomView: Bool

    var isBypassed: Bool {
        didSet { unit.auAudioUnit.shouldBypassEffect = isBypassed }
    }

    init(unit: AVAudioUnit, displayName: String, manufacturer: String, hasCustomView: Bool, isBypassed: Bool = false) {
        self.unit = unit
        self.displayName = displayName
        self.manufacturer = manufacturer
        self.hasCustomView = hasCustomView
        self.isBypassed = isBypassed
        unit.auAudioUnit.shouldBypassEffect = isBypassed
    }

    func snapshot() -> EffectSnapshot {
        var stateData: Data?
        if let fullState = unit.auAudioUnit.fullState {
            stateData = try? PropertyListSerialization.data(
                fromPropertyList: fullState, format: .binary, options: 0
            )
        }
        return EffectSnapshot(
            componentDescription: unit.audioComponentDescription,
            displayName: displayName,
            isBypassed: isBypassed,
            stateData: stateData
        )
    }
}

/// Ordered list of inserts. Purely a model — it knows nothing about `AVAudioEngine`;
/// `SignalDeckEngine` observes `revision` and rewires the graph.
@MainActor
@Observable
final class Rack {
    private(set) var slots: [EffectSlot] = []
    var name: String = "Untitled"
    var outputGainDB: Float = 0

    /// Bumped whenever the *topology* changes (add/remove/reorder). Bypass and parameter
    /// changes don't bump it — those are handled inside the AU and need no re-patch.
    private(set) var revision: Int = 0

    /// Set by `SignalDeckEngine`; called after any topology change.
    var onTopologyChanged: (() -> Void)?

    // MARK: Editing

    func append(_ entry: AudioUnitCatalog.Entry, options: AudioComponentInstantiationOptions) async throws {
        let unit = try await AVAudioUnit.instantiate(
            with: entry.componentDescription, options: options
        )
        slots.append(EffectSlot(
            unit: unit,
            displayName: entry.name,
            manufacturer: entry.manufacturer,
            hasCustomView: entry.hasCustomView
        ))
        topologyChanged()
    }

    func remove(_ slot: EffectSlot) {
        slots.removeAll { $0.id == slot.id }
        topologyChanged()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
        topologyChanged()
    }

    func removeAll() {
        slots.removeAll()
        topologyChanged()
    }

    private func topologyChanged() {
        revision += 1
        onTopologyChanged?()
    }

    // MARK: Snapshots

    func snapshot() -> RackSnapshot {
        RackSnapshot(name: name, effects: slots.map { $0.snapshot() }, outputGainDB: outputGainDB)
    }

    /// Rebuilds the whole chain from a snapshot. Any effect that fails to instantiate
    /// (plugin uninstalled since the rack was saved) is skipped rather than aborting the load.
    func load(_ snapshot: RackSnapshot, options: AudioComponentInstantiationOptions) async {
        var rebuilt: [EffectSlot] = []
        let catalog = AudioUnitCatalog.installedEffects()

        for effect in snapshot.effects {
            do {
                let unit = try await AVAudioUnit.instantiate(
                    with: effect.componentDescription, options: options
                )
                let match = catalog.first {
                    $0.componentDescription.componentSubType == effect.componentSubType &&
                    $0.componentDescription.componentManufacturer == effect.componentManufacturer
                }

                // Opaque state first (it may reset parameters), then explicit overrides on top.
                if let data = effect.stateData,
                   let plist = try? PropertyListSerialization.propertyList(
                        from: data, options: [], format: nil) as? [String: Any] {
                    unit.auAudioUnit.fullState = plist
                }
                if let overrides = effect.parameterOverrides {
                    for (key, value) in overrides {
                        guard let parameterID = AudioUnitParameterID(key) else { continue }
                        AudioUnitSetParameter(
                            unit.audioUnit, parameterID, kAudioUnitScope_Global, 0, value, 0
                        )
                    }
                }

                rebuilt.append(EffectSlot(
                    unit: unit,
                    displayName: match?.name ?? effect.displayName,
                    manufacturer: match?.manufacturer ?? "Unknown",
                    hasCustomView: match?.hasCustomView ?? false,
                    isBypassed: effect.isBypassed
                ))
            } catch {
                NSLog("SignalDeck: skipping missing Audio Unit '\(effect.displayName)': \(error)")
            }
        }

        slots = rebuilt
        name = snapshot.name
        outputGainDB = snapshot.outputGainDB
        topologyChanged()
    }
}
