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

    /// Only flipped false once a tap attempt actually fails with a TCC denial, so the
    /// "Open Privacy Settings…" button doesn't appear next to unrelated errors.
    private(set) var hasAudioCapturePermission = true

    /// What the tap is delivering (before the rack) and what the mixer is playing (after it).
    /// Peaks decay smoothly so the bars fall like a hardware meter instead of flickering.
    private(set) var inputLevels = AudioLevels()
    private(set) var outputLevels = AudioLevels()

    /// True while audio is measurably moving through the tap.
    var isSignalPresent: Bool { inputLevels.hasSignal }

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
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var pendingProcessListRefresh: Task<Void, Never>?

    /// Meter refresh rate. Fast enough that the bars track speech, cheap enough to leave running.
    private static let meterHz = 30.0

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

    /// Re-enumerates running audio apps. Driven by the Refresh button and, while processing, by
    /// the process-object-list listener — nothing rescans on a timer.
    func refreshApps() {
        let apps = AudioProcessDiscovery.runningAudioApps()
        availableApps = apps

        guard let selected = selectedApp else { return }

        if let updated = apps.first(where: { $0.pid == selected.pid }) {
            // Compare as sets: `objectIDs` is assembled from a Dictionary, whose iteration order
            // is not stable between calls. Comparing the arrays directly reported a change on
            // nearly every rescan and tore the tap down and back up each time, which is heard as
            // a dropout.
            let changed = Set(updated.objectIDs) != Set(selected.objectIDs)
            selectedApp = updated
            if changed, isActive {
                // Helper processes came or went (Plex spawning its renderer). Re-tap so the
                // new audio process is included.
                stop()
                start()
            }
        } else if isActive {
            // On macOS 26 the tap restores itself by bundle ID, so a quit isn't fatal.
            statusMessage = "Waiting for \(selected.name) to relaunch…"
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
            let format: AVAudioFormat
            do {
                format = try capture.start(processObjectIDs: app.objectIDs, bundleIDs: app.bundleIDs)
            } catch ProcessTapError.staleProcessObjects {
                // The app re-spun its audio between the last discovery poll and this toggle, so
                // the object IDs we cached are dead. Re-resolve and take one more run at it rather
                // than making the user hit a toggle that would have worked a second later.
                refreshApps()
                guard let refreshed = availableApps.first(where: { $0.pid == app.pid }) else {
                    throw ProcessTapError.staleProcessObjects
                }
                format = try capture.start(processObjectIDs: refreshed.objectIDs,
                                           bundleIDs: refreshed.bundleIDs)
            }

            let engine = SignalDeckEngine(ringBuffer: capture.ringBuffer, rack: rack)
            engine.onConfigurationChanged = { [weak self] in
                self?.restartForDeviceChange(reason: "Audio configuration changed…")
            }
            try engine.prepare(sourceFormat: format)
            engine.applyOutputGain()
            try engine.start()

            self.capture = capture
            self.engine = engine
            self.isActive = true
            self.hasAudioCapturePermission = true
            self.statusMessage = "Processing \(app.name) · \(Int(format.sampleRate / 1000)) kHz"
            startMetering()
            let observing = installProcessListListener()
            // The object IDs the tap was built from were snapshotted before the listener existed,
            // and a helper that appeared before that snapshot has already sent its notification.
            // Nothing would ever rebuild the tap around it, so reconcile once now that we are
            // observing — via the debounced path, so this can't re-enter start().
            scheduleProcessListRefresh()
            if !observing {
                // Nothing about the running stream is broken — what's lost is the automatic
                // re-tap when a helper appears, which the Refresh button still covers. Tearing
                // down working audio over a failed notification registration would be the worse
                // trade, so say what degraded and let the next start() try again.
                self.statusMessage += " · rescan manually"
            }
        } catch {
            capture.stop()
            if case ProcessTapError.permissionDenied = error { hasAudioCapturePermission = false }
            errorMessage = error.localizedDescription
            statusMessage = "Failed to start"
        }
    }

    func stop(reason: String = "Idle") {
        meterTimer?.invalidate(); meterTimer = nil
        removeProcessListListener()
        engine?.teardown(); engine = nil
        capture?.stop(); capture = nil
        gainReductionDB = 0
        inputLevels = .silent
        outputLevels = .silent
        isActive = false
        statusMessage = reason
    }

    /// The aggregate device is pinned to a specific output UID, so switching from speakers to
    /// headphones requires a full rebuild. The rack survives — only the plumbing is recreated.
    func restartForDeviceChange(reason: String = "Output device changed…") {
        guard isActive else { return }
        stop(reason: reason)
        start()
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func quit() {
        persistCurrentRack()
        stop()
        removeDefaultDeviceListener()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Timers & listeners

    /// Timers are added to `.common` explicitly. A `MenuBarExtra` panel puts the run loop into
    /// event-tracking mode while it's open, and a default-mode timer stops firing there — which
    /// is exactly when the user is looking at the meters.
    private func schedule(every interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Every assignment here notifies `@Observable`, which re-evaluates the meter views whether or
    /// not the value moved. At 30 Hz that is a redraw storm while the pipeline sits silent, so
    /// each write is gated on an actual change.
    private func startMetering() {
        meterTimer = schedule(every: 1.0 / Self.meterHz) { [weak self] in
            guard let self else { return }
            self.updateLevels()
            guard let engine = self.engine else { return }
            let reduction = engine.gainReductionDB
            if reduction != self.gainReductionDB { self.gainReductionDB = reduction }
            let latency = engine.rackLatencyMilliseconds
            if latency != self.rackLatencyMilliseconds { self.rackLatencyMilliseconds = latency }
        }
    }

    /// Peak-hold with a ~20 dB/s fall-off, RMS with light smoothing. Without the hold, a 30 Hz
    /// sample of a speech signal spends most frames near zero and the bar looks broken.
    private func updateLevels() {
        guard let capture, let engine else { return }
        let input = Self.blend(previous: inputLevels, latest: capture.inputMeter.drain())
        if input != inputLevels { inputLevels = input }
        let output = Self.blend(previous: outputLevels, latest: engine.drainOutputLevels())
        if output != outputLevels { outputLevels = output }
    }

    /// The documented 20 dB/s fall-off, as a per-frame amplitude factor at `meterHz`. Hard-coding
    /// this (it was 0.78) put the real decay at ~65 dB/s, which drops a peak from 0 to the -60
    /// floor inside a second — a hold short enough that there is barely a hold.
    private static let peakDecayPerFrame = pow(Float(10), -20 / (20 * Float(meterHz)))

    private static func blend(previous: AudioLevels, latest: AudioLevels) -> AudioLevels {
        let decay = peakDecayPerFrame
        let smoothing: Float = 0.5  // RMS attack/release blend
        func hold(_ old: Float, _ new: Float) -> Float { max(new, old * decay) }
        func average(_ old: Float, _ new: Float) -> Float { old + (new - old) * smoothing }
        return AudioLevels(
            peakLeft: hold(previous.peakLeft, latest.peakLeft),
            peakRight: hold(previous.peakRight, latest.peakRight),
            rmsLeft: average(previous.rmsLeft, latest.rmsLeft),
            rmsRight: average(previous.rmsRight, latest.rmsRight)
        )
    }

    /// Core Audio tells us when process objects come and go, so the app list never has to be
    /// polled. This is installed only while processing, and only for tap correctness: an
    /// Electron app (Plex) can spawn its renderer *after* the tap is up, and that helper's
    /// audio is missed until the tap is rebuilt around it. While idle nothing listens — the
    /// Refresh button is what repopulates the picker.
    ///
    /// Returns whether the listener is registered, so `start()` can tell the user that automatic
    /// re-tapping is off rather than silently pretending to observe.
    @discardableResult
    private func installProcessListListener() -> Bool {
        guard processListListener == nil else { return true }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.scheduleProcessListRefresh() }
        }
        // Store the block only once Core Audio has taken it. Storing first would make a failed
        // registration look installed: the next start() would skip re-registering, and teardown
        // would try to remove a listener that was never added.
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        guard status == noErr else { return false }
        processListListener = listener
        return true
    }

    private func removeProcessListListener() {
        pendingProcessListRefresh?.cancel(); pendingProcessListRefresh = nil
        guard let listener = processListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        // Keep the block on a failed removal: it is still registered, so forgetting it would let
        // the next start() add a second listener on top of the live one and double every refresh.
        guard status == noErr else { return }
        processListListener = nil
    }

    /// One app launching adds several process objects, each with its own notification. Coalesce
    /// the burst so it costs at most one re-tap instead of a stop/start per notification, which
    /// would be heard as a stutter.
    ///
    /// Both the entry and the far side of the delay are gated on `isActive`: a notification
    /// already queued on the main queue when `stop()` runs still lands afterwards, and rescanning
    /// then would be exactly the idle background work this listener exists to avoid.
    private func scheduleProcessListRefresh() {
        guard isActive else { return }
        pendingProcessListRefresh?.cancel()
        pendingProcessListRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.refreshApps()
        }
    }

    private func installDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.restartForDeviceChange() }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
    }

    private func removeDefaultDeviceListener() {
        guard let listener = deviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        deviceListener = nil
    }
}
