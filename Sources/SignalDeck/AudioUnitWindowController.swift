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
///
/// **An editor window is built once per slot and then kept.** Closing it hides it; it is only
/// destroyed when the effect leaves the rack. That is not tidiness, it is the only lifecycle the
/// Apple AUs survive:
///
///   * `requestViewController` answers **once per AU instance**. Ask AUGraphicEQ,
///     AUDynamicsProcessor or AUPeakLimiter a second time and the callback gets `nil`, so an
///     editor that was rebuilt on every open showed the real interface the first time and the
///     generic sliders ever after.
///   * Caching just the view controller and rebuilding the window fixes the display for the
///     compressor and the limiter, and *crashes* on the graphic EQ:
///     `-[CAAppleAUCustomViewBase cleanup]` runs as the old window's frame view deallocates and
///     messages the freed view.
///   * Keeping the window alive avoids both. The controller stays owned by the window it was
///     installed in, and nothing is torn down until the effect is removed — at which point the
///     window and the controller go together, which is the one teardown order that is safe.
@MainActor
final class AudioUnitWindowController {

    static let shared = AudioUnitWindowController()

    /// One window per slot, kept for the lifetime of the slot. Also retains the AU's view
    /// controller, via `contentViewController`.
    private var windows: [UUID: NSWindow] = [:]

    /// The request each slot currently has in flight, if any. `requestViewController` is async, so
    /// this doubles as a re-entrancy guard and as a way for a stale callback to notice it no longer
    /// owns its slot.
    private var presentationTokens: [UUID: Int] = [:]
    private var nextToken = 0

    func show(_ slot: EffectSlot) {
        // Re-showing a hidden window, rather than building a new one, is what keeps the AU's own
        // editor on screen for the second and every later open.
        if let existing = windows[slot.id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // One request at a time, per slot. Two clicks before the first callback lands used to
        // issue two requests — and since the unit only answers once, the second came back nil,
        // won the token, and put the generic sliders up *on the first open*. Dropping the extra
        // click is right anyway: the answer is already on its way.
        guard presentationTokens[slot.id] == nil else { return }

        nextToken += 1
        let token = nextToken
        presentationTokens[slot.id] = token

        slot.unit.auAudioUnit.requestViewController { [weak self] viewController in
            // The AU calls this back on a queue of its own choosing, so we have to *hop* to the
            // main actor. `MainActor.assumeIsolated` (as an earlier version did) is a precondition,
            // not a hop, and traps outright when the unit answers off the main thread.
            Task { @MainActor in
                // A token that no longer matches means the slot was closed, or its rack swapped,
                // while the unit was answering — presenting now would open an editor for an
                // effect the user has already discarded.
                guard let self, self.presentationTokens[slot.id] == token else { return }
                self.presentationTokens[slot.id] = nil
                self.present(viewController, for: slot)
            }
        }
    }

    /// `viewController` is the unit's own editor, or `nil` for a unit that ships none.
    ///
    /// A non-`nil` controller is always used. An earlier version also required
    /// `view.frame.width > 0` and fell back to the generic view otherwise — but a freshly vended
    /// controller may not have been laid out yet, and its size says nothing about whether the
    /// editor is real. `nil` is the only honest signal that there is no custom UI. (That version
    /// also built an `AUGenericView`, then discarded it unused, because `present` preferred any
    /// non-`nil` controller regardless.)
    private func present(_ viewController: NSViewController?, for slot: EffectSlot) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "\(slot.displayName) — \(slot.manufacturer)"
        // The window outlives its closing; we hold the only strong reference.
        window.isReleasedWhenClosed = false

        let contentSize: NSSize
        if let viewController {
            // Setting `contentViewController` replaces `contentView`, and is what keeps the AU's
            // view controller alive for as long as the window is.
            window.contentViewController = viewController
            contentSize = Self.size(of: viewController.view)
        } else {
            let generic = AUGenericView(audioUnit: slot.unit.audioUnit)
            generic.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
            window.contentView = generic
            contentSize = generic.frame.size
        }
        window.setContentSize(contentSize)
        window.center()

        windows[slot.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Prefer the view's own frame, which is what an AU's nib-loaded editor arrives with. Fall
    /// back to its fitting size for a controller that hasn't been laid out, and to a workable
    /// default rather than a zero-sized window if neither says anything.
    private static func size(of view: NSView) -> NSSize {
        if view.frame.width > 0, view.frame.height > 0 { return view.frame.size }
        let fitting = view.fittingSize
        if fitting.width > 0, fitting.height > 0 { return fitting }
        return NSSize(width: 560, height: 360)
    }

    /// Close an effect's editor for good — the effect is leaving the rack, so the window and the
    /// AU's view controller are released together. That order is deliberate: releasing the window
    /// while something else still holds the controller is what crashes CoreAudioKit's teardown.
    func close(_ slotID: UUID) {
        presentationTokens[slotID] = nil
        guard let window = windows.removeValue(forKey: slotID) else { return }
        // Dropping the dictionary's reference releases the window, and the window releases the
        // controller with it. Detaching the controller first would leave the window briefly
        // holding a stripped content view, which is the arrangement CoreAudioKit trips over.
        window.close()
    }

    /// A slot whose `requestViewController` hasn't answered yet exists only in
    /// `presentationTokens`, so closing by window alone leaves it armed — and it would then open
    /// an editor for an effect belonging to a rack the user has already swapped out.
    func closeAll() {
        for id in Set(windows.keys).union(presentationTokens.keys) { close(id) }
    }
}
