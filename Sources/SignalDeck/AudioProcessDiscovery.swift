import AudioToolbox
import CoreAudio
import Foundation
import AppKit

/// A running application that Core Audio knows about as one or more `AudioObjectID`s.
///
/// Note the plural: Electron/Chromium apps (Plex Desktop, Plex HTPC) render audio from a
/// *helper* process, not the main app process. Translating only the main PID gives you a
/// process object that never produces a sample. We therefore group every audio process
/// object that belongs to the same bundle and tap all of them together.
struct AudioProcess: Identifiable, Hashable {
    var id: pid_t { pid }
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    /// Every Core Audio process object associated with this app (main + helpers).
    let objectIDs: [AudioObjectID]
    /// Every distinct bundle ID Core Audio reports for those objects — the main app's plus any
    /// helper bundle IDs. Fed to `CATapDescription.bundleIDs` on macOS 26+ so the tap can be
    /// restored automatically when the app relaunches.
    let bundleIDs: [String]
    /// True if at least one of the objects is currently pushing audio to a device.
    let isPlayingAudio: Bool

    static func == (a: AudioProcess, b: AudioProcess) -> Bool { a.pid == b.pid }
    func hash(into h: inout Hasher) { h.combine(pid) }
}

enum AudioProcessDiscovery {

    /// Apps that are candidates for tapping, newest-audio-first.
    ///
    /// We start from `NSWorkspace` (so we get names + icons + only user-facing apps), then
    /// fold in every Core Audio process object whose PID belongs to that app *or* to a child
    /// process of that app.
    static func runningAudioApps() -> [AudioProcess] {
        let coreAudioProcesses = allProcessObjects()

        // pid -> (objectID, isRunningOutput)
        var byPID: [pid_t: [(id: AudioObjectID, active: Bool)]] = [:]
        for objectID in coreAudioProcesses {
            guard let pid: pid_t = processProperty(objectID, kAudioProcessPropertyPID) else { continue }
            let active: UInt32 = processProperty(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0
            byPID[pid, default: []].append((objectID, active != 0))
        }

        // Map helper PIDs back to their owning app bundle via the bundle ID Core Audio reports.
        var byBundleID: [String: [(id: AudioObjectID, active: Bool)]] = [:]
        for objectID in coreAudioProcesses {
            guard let bundleID: String = processStringProperty(objectID, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty else { continue }
            let active: UInt32 = processProperty(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0
            byBundleID[bundleID, default: []].append((objectID, active != 0))
        }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }

        var result: [AudioProcess] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }

            // Union of "objects whose PID is this app" and "objects reporting this bundle ID".
            var objects = byPID[app.processIdentifier] ?? []
            objects.append(contentsOf: byBundleID[bundleID] ?? [])
            let unique = Dictionary(grouping: objects, by: \.id)
                .map { (id: $0.key, active: $0.value.contains { $0.active }) }

            guard !unique.isEmpty else { continue }

            let reportedBundleIDs = Set(unique.compactMap {
                processStringProperty($0.id, kAudioProcessPropertyBundleID)
            }.filter { !$0.isEmpty })

            result.append(AudioProcess(
                pid: app.processIdentifier,
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                icon: app.icon,
                objectIDs: unique.map(\.id),
                bundleIDs: Array(reportedBundleIDs.union([bundleID])).sorted(),
                isPlayingAudio: unique.contains { $0.active }
            ))
        }

        return result.sorted {
            if $0.isPlayingAudio != $1.isPlayingAudio { return $0.isPlayingAudio }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Convenience for the primary use case. Matches Plex Desktop, Plex HTPC and Plex Media Player.
    static func findPlex() -> AudioProcess? {
        let candidates = runningAudioApps()
        return candidates.first {
            $0.bundleID.lowercased().contains("plex") || $0.name.localizedCaseInsensitiveContains("plex")
        }
    }

    // MARK: - Core Audio plumbing

    private static func allProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                &dataSize, buffer.baseAddress!
            )
        }
        return status == noErr ? ids : []
    }

    private static func processProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func processStringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
