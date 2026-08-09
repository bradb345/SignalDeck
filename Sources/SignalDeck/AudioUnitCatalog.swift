import AVFoundation
import AudioToolbox
import Foundation

/// Everything installed on this machine that we can drop into the rack.
@MainActor
enum AudioUnitCatalog {

    struct Entry: Identifiable, Hashable {
        var id: String { "\(manufacturer)/\(name)/\(componentSubType)" }
        let name: String
        let manufacturer: String
        let componentDescription: AudioComponentDescription
        let hasCustomView: Bool
        let isAppleBuiltIn: Bool
        var componentSubType: UInt32 { componentDescription.componentSubType }

        // AudioComponentDescription is a plain C struct with no Hashable conformance,
        // so identity is derived from `id` (manufacturer + name + subtype).
        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Effect-type Audio Units, grouped by manufacturer with Apple first.
    ///
    /// We include `kAudioUnitType_Effect` and `kAudioUnitType_MusicEffect`. We deliberately
    /// exclude generators, instruments and mixers — they don't make sense as inserts on a
    /// playback stream.
    static func installedEffects() -> [Entry] {
        let manager = AVAudioUnitComponentManager.shared()
        var entries: [Entry] = []

        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let matching = AudioComponentDescription(
                componentType: type,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            for component in manager.components(matching: matching) {
                entries.append(Entry(
                    name: component.name,
                    manufacturer: component.manufacturerName,
                    componentDescription: component.audioComponentDescription,
                    hasCustomView: component.hasCustomView,
                    isAppleBuiltIn: component.manufacturerName == "Apple"
                ))
            }
        }

        return entries.sorted { lhs, rhs in
            if lhs.isAppleBuiltIn != rhs.isAppleBuiltIn { return lhs.isAppleBuiltIn }
            if lhs.manufacturer != rhs.manufacturer {
                return lhs.manufacturer.localizedStandardCompare(rhs.manufacturer) == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func groupedByManufacturer() -> [(manufacturer: String, entries: [Entry])] {
        let grouped = Dictionary(grouping: installedEffects(), by: \.manufacturer)
        return grouped
            .map { (manufacturer: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                if (lhs.manufacturer == "Apple") != (rhs.manufacturer == "Apple") {
                    return lhs.manufacturer == "Apple"
                }
                return lhs.manufacturer.localizedStandardCompare(rhs.manufacturer) == .orderedAscending
            }
    }

    /// Human-readable four-char-code, handy for debugging persisted racks.
    static func fourCharCode(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }
}
