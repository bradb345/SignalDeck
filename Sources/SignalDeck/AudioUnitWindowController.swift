import AppKit
import AVFoundation
import CoreAudioKit
import SwiftUI

/// Opens each Audio Unit's own editor in its own window, the way SoundSource, Logic and every
/// other host does it.
///
/// Two paths:
///   • `AUAudioUnit.requestViewController` — AUv3, and AUv2s that ship a Cocoa view. Preferred.
///   • `AUGenericView` — CoreAudioKit's auto-generated knobs-and-sliders view, built from the
///     unit's parameter tree. This is the fallback for AUv2s with no custom UI, and it's why
///     every installed effect is usable even without a bespoke editor.
@MainActor
final class AudioUnitWindowController {

    static let shared = AudioUnitWindowController()

    private var windows: [UUID: NSWindow] = [:]
    private var closeObservers: [UUID: NSObjectProtocol] = [:]

    /// The presentation each slot is currently waiting on. `requestViewController` is async, so two
    /// clicks on the same effect can both get past the `windows` check and each build a window —
    /// the second then overwrites the first's bookkeeping and orphans it, observer and all. A
    /// callback that no longer owns its slot's token drops itself instead.
    private var presentationTokens: [UUID: Int] = [:]
    private var nextToken = 0

    func show(_ slot: EffectSlot) {
        if let existing = windows[slot.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        nextToken += 1
        let token = nextToken
        presentationTokens[slot.id] = token

        slot.unit.auAudioUnit.requestViewController { [weak self] viewController in
            // The AU calls this back on a queue of its own choosing, so we have to *hop* to the
            // main actor. `MainActor.assumeIsolated` (as an earlier version did) is a precondition,
            // not a hop, and traps outright when the unit answers off the main thread.
            Task { @MainActor in
                guard let self, self.presentationTokens[slot.id] == token else { return }
                let contentView: NSView
                if let viewController, viewController.view.frame.width > 0 {
                    contentView = viewController.view
                } else {
                    contentView = AUGenericView(audioUnit: slot.unit.audioUnit)
                    contentView.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
                }
                self.present(contentView, for: slot, retaining: viewController)
            }
        }
    }

    private func present(_ contentView: NSView, for slot: EffectSlot, retaining viewController: NSViewController?) {
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "\(slot.displayName) — \(slot.manufacturer)"
        window.isReleasedWhenClosed = false
        if let viewController {
            // Setting `contentViewController` replaces `contentView`, so it has to be one or the
            // other — and it's what keeps the AU's view controller alive while the window is up.
            window.contentViewController = viewController
        } else {
            window.contentView = contentView
        }
        window.setContentSize(contentView.frame.size)
        window.center()

        windows[slot.id] = window
        closeObservers[slot.id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            // Posted on the main thread by AppKit, so the assumption holds here.
            MainActor.assumeIsolated { self?.forget(slot.id, ifShowing: window) }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close an effect's editor when it's removed from the rack.
    func close(_ slotID: UUID) {
        presentationTokens[slotID] = nil
        let window = windows[slotID]
        forget(slotID, ifShowing: window)
        window?.close()
    }

    func closeAll() {
        for id in Array(windows.keys) { close(id) }
    }

    /// Drops the slot's bookkeeping, but only if `window` is still the one on screen for it —
    /// a stale close notification must not take a newer window's entry down with it.
    private func forget(_ slotID: UUID, ifShowing window: NSWindow?) {
        guard let window, windows[slotID] === window else { return }
        if let observer = closeObservers.removeValue(forKey: slotID) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows[slotID] = nil
        presentationTokens[slotID] = nil
    }
}
