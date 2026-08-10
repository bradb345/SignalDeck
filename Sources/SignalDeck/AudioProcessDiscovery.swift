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

extension NSImage {
    /// `NSRunningApplication.icon` reports a 512pt size. A `Picker` lays its closed row out from
    /// the image's *intrinsic* size — `.resizable().frame(…)` on the SwiftUI side is honoured in
    /// the open menu but not there, so the app icon blew the row open and got clipped. Setting
    /// the size on a copy fixes the layout at the source; the multi-resolution representations
    /// are untouched, so AppKit still picks the crisp one to draw.
    func fittedToMenuRow(side: CGFloat = 16) -> NSImage {
        guard let copy = self.copy() as? NSImage else { return self }
        copy.size = NSSize(width: side, height: side)
        return copy
    }
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
        let appPIDs = Set(apps.map(\.processIdentifier))

        // Fold each audio process object up to the top-most ancestor that is a user-facing app.
        // Chromium/Electron apps (Plex Desktop, Plex HTPC) render audio from a helper process
        // whose bundle ID is the *helper's* — matching on the app's own bundle ID alone finds
        // nothing, and tapping only the main PID taps a process that never emits a sample.
        var byOwningPID: [pid_t: [(id: AudioObjectID, active: Bool)]] = [:]
        for (pid, objects) in byPID {
            guard let owner = owningAppPID(for: pid, appPIDs: appPIDs) else { continue }
            byOwningPID[owner, default: []].append(contentsOf: objects)
        }

        var result: [AudioProcess] = []
        for app in apps {
            guard let bundleID = app.bundleIdentifier else { continue }

            // Union of "objects owned by this app's process tree" and "objects reporting this
            // bundle ID".
            var objects = byOwningPID[app.processIdentifier] ?? []
            objects.append(contentsOf: byBundleID[bundleID] ?? [])
            let unique = Dictionary(grouping: objects, by: \.id)
                .map { (id: $0.key, active: $0.value.contains { $0.active }) }
                .sorted { $0.id < $1.id }   // stable order: callers diff these arrays

            guard !unique.isEmpty else { continue }

            let reportedBundleIDs = Set(unique.compactMap {
                processStringProperty($0.id, kAudioProcessPropertyBundleID)
            }.filter { !$0.isEmpty })

            result.append(AudioProcess(
                pid: app.processIdentifier,
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                icon: app.icon?.fittedToMenuRow(),
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

    // MARK: - Process tree

    /// Walks up the parent chain from `pid` until it reaches a PID that belongs to a running
    /// user-facing application, so helper processes are attributed to the app that spawned them.
    /// Returns nil if no ancestor is an app (daemons, coreaudiod itself, and so on).
    private static func owningAppPID(for pid: pid_t, appPIDs: Set<pid_t>, maxDepth: Int = 8) -> pid_t? {
        var current = pid
        for _ in 0..<maxDepth {
            if appPIDs.contains(current) { return current }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
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
