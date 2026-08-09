import AVFoundation
import CoreAudio
import Observation
import SwiftUI

/// Orchestrates discovery → tap → engine → rack, and owns everything the UI binds to.
@MainActor
@Observable
final class SignalDeckController {

    // MARK: - Observable state

    var availableApps: [AudioProcess] = []
    var selectedApp: AudioProcess? {
        didSet {
            guard oldValue?.pid != selectedApp?.pid else { return }
            if isActive { stop(); start() }
        }
    }

    let rack = Rack()
    let store = RackStore()

    private(set) var isActive = false
    private(set) var statusMessage = "Idle"
    private(set) var errorMessage: String?
    private(set) var gainReductionDB: Float = 0
    private(set) var rackLatencyMilliseconds: Double = 0
    private(set) var hasAudioCapturePermission = false

    var outputGainDB: Float {
        get { rack.outputGainDB }
        set { rack.outputGainDB = newValue; engine?.applyOutputGain() }
    }

    /// Bundle IDs SignalDeck should treat as "Plex" when auto-selecting a target.
    /// Covers Plex Desktop, Plex HTPC and the legacy Plex Media Player.
    static let plexBundleIDs = [
        "tv.plex.desktop", "tv.plex.plexhtpc", "com.plexapp.plex", "com.plexapp.plexmediaplayer"
    ]

    // MARK: - Private

    private var capture: ProcessTapCapture?
    private var engine: SignalDeckEngine?
    private var meterTimer: Timer?
    private var refreshTimer: Timer?

    init() {
        refreshApps()
        selectedApp = availableApps.first { Self.isPlex($0) }
            ?? availableApps.first { $0.isPlayingAudio }
        installDefaultDeviceListener()

        Task { await restoreRack() }
    }

    static func isPlex(_ app: AudioProcess) -> Bool {
        plexBundleIDs.contains(app.bundleID)
            || app.bundleID.lowercased().contains("plex")
            || app.name.localizedCaseInsensitiveContains("plex")
    }

    // MARK: - Rack

    private func restoreRack() async {
        let snapshot = store.loadCurrent() ?? FactoryRacks.nightMode
        await rack.load(snapshot, options: instantiationOptions)
    }

    func loadRack(_ snapshot: RackSnapshot) async {
        AudioUnitWindowController.shared.closeAll()
        await rack.load(snapshot, options: instantiationOptions)
        persistCurrentRack()
    }

    func addEffect(_ entry: AudioUnitCatalog.Entry) async {
        do {
            try await rack.append(entry, options: instantiationOptions)
            persistCurrentRack()
        } catch {
            errorMessage = "Couldn't load \(entry.name): \(error.localizedDescription)"
        }
    }

    func removeEffect(_ slot: EffectSlot) {
        AudioUnitWindowController.shared.close(slot.id)
        rack.remove(slot)
        persistCurrentRack()
    }

    func moveEffects(from source: IndexSet, to destination: Int) {
        rack.move(fromOffsets: source, toOffset: destination)
        persistCurrentRack()
    }

    func saveCurrentRack(as name: String) {
        var snapshot = rack.snapshot()
        snapshot.name = name
        snapshot.id = UUID()
        rack.name = name
        do { try store.save(snapshot) } catch {
            errorMessage = "Couldn't save rack: \(error.localizedDescription)"
        }
    }

    /// Captures the live rack (including unsaved parameter tweaks) for restore on next launch.
    func persistCurrentRack() {
        store.persistCurrent(rack.snapshot())
    }

    private var instantiationOptions: AudioComponentInstantiationOptions {
        engine?.instantiationOptions ?? []
    }

    // MARK: - Discovery

    func refreshApps() {
        let apps = AudioProcessDiscovery.runningAudioApps()
        availableApps = apps
        if let selected = selectedApp, let updated = apps.first(where: { $0.pid == selected.pid }) {
            if updated.objectIDs != selected.objectIDs {
                // Helper processes came or went (Plex spawning its renderer). Re-tap so the
                // new audio process is included.
                availableApps = apps
                selectedApp = updated
                if isActive { stop(); start() }
            }
        } else if selectedApp != nil, isActive {
            // On macOS 26 the tap restores itself by bundle ID, so a quit isn't fatal.
            statusMessage = "Waiting for \(selectedApp?.name ?? "target") to relaunch…"
        }
    }

    // MARK: - Transport

    func setActive(_ active: Bool) {
        active ? start() : stop(reason: "Idle")
    }

    func start() {
        guard !isActive else { return }
        guard let app = selectedApp else {
            errorMessage = "Pick an app to process first."
            return
        }
        errorMessage = nil

        let capture = ProcessTapCapture()
        do {
            try capture.start(processObjectIDs: app.objectIDs, bundleIDs: app.bundleIDs)
            guard let format = capture.tapFormat else { throw ProcessTapError.unsupportedTapFormat }

            let engine = SignalDeckEngine(ringBuffer: capture.ringBuffer, rack: rack)
            try engine.prepare(sourceFormat: format)
            engine.applyOutputGain()
            try engine.start()

            self.capture = capture
            self.engine = engine
            self.isActive = true
            self.hasAudioCapturePermission = true
            self.statusMessage = "Processing \(app.name) · \(Int(format.sampleRate / 1000)) kHz"
            startMetering()
            startAppPolling()
        } catch {
            capture.stop()
            if case ProcessTapError.permissionDenied = error { hasAudioCapturePermission = false }
            errorMessage = error.localizedDescription
            statusMessage = "Failed to start"
        }
    }

    func stop(reason: String = "Idle") {
        meterTimer?.invalidate(); meterTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        engine?.teardown(); engine = nil
        capture?.stop(); capture = nil
        gainReductionDB = 0
        isActive = false
        statusMessage = reason
    }

    /// The aggregate device is pinned to a specific output UID, so switching from speakers to
    /// headphones requires a full rebuild. The rack survives — only the plumbing is recreated.
    func restartForDeviceChange() {
        guard isActive else { return }
        stop(reason: "Output device changed…")
        start()
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func quit() {
        persistCurrentRack()
        stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Timers & listeners

    private func startMetering() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.engine else { return }
                self.gainReductionDB = engine.gainReductionDB
                self.rackLatencyMilliseconds = engine.rackLatencyMilliseconds
            }
        }
    }

    private func startAppPolling() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshApps() }
        }
    }

    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in
            Task { @MainActor [weak self] in self?.restartForDeviceChange() }
        }
    }
}
