import Foundation

/// User racks on disk: `~/Library/Application Support/SignalDeck/Racks/*.signaldeckrack`
///
/// Each file is JSON, and each effect inside carries the AU's opaque `fullState`, so a saved
/// rack round-trips third-party plugin editors completely.
@MainActor
@Observable
final class RackStore {

    private(set) var userRacks: [RackSnapshot] = []

    private let directory: URL
    private let lastRackFile: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SignalDeck", isDirectory: true)
        self.directory = support.appendingPathComponent("Racks", isDirectory: true)
        self.lastRackFile = support.appendingPathComponent("CurrentRack.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        userRacks = files
            .filter { $0.pathExtension == "signaldeckrack" }
            .compactMap { url -> RackSnapshot? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(RackSnapshot.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ snapshot: RackSnapshot) throws {
        let safeName = snapshot.name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeName).signaldeckrack")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        reload()
    }

    func delete(_ snapshot: RackSnapshot) {
        let safeName = snapshot.name.replacingOccurrences(of: "/", with: "-")
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(safeName).signaldeckrack")
        )
        reload()
    }

    // MARK: - Session restore

    /// The exact rack that was live when the app last quit, including unsaved tweaks.
    func persistCurrent(_ snapshot: RackSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: lastRackFile, options: .atomic)
    }

    func loadCurrent() -> RackSnapshot? {
        guard let data = try? Data(contentsOf: lastRackFile) else { return nil }
        return try? JSONDecoder().decode(RackSnapshot.self, from: data)
    }
}
