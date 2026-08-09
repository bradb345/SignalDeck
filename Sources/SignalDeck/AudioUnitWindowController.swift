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

    func show(_ slot: EffectSlot) {
        if let existing = windows[slot.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        slot.unit.auAudioUnit.requestViewController { [weak self] viewController in
            MainActor.assumeIsolated {
                guard let self else { return }
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
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(slot.id) }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close an effect's editor when it's removed from the rack.
    func close(_ slotID: UUID) {
        windows[slotID]?.close()
        forget(slotID)
    }

    func closeAll() {
        for id in Array(windows.keys) { close(id) }
    }

    private func forget(_ slotID: UUID) {
        if let observer = closeObservers.removeValue(forKey: slotID) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows[slotID] = nil
    }
}
