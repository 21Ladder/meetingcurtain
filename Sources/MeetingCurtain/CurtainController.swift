import AppKit
import Carbon.HIToolbox
import SwiftUI
import MeetingCurtainCore

/// Shows the curtain on every display. Windows exist only while the curtain is up; hiding releases them.
@MainActor
final class CurtainController {
    /// Keys and clicks are ignored this long after the curtain appears, so a keystroke or click meant for
    /// the app you were typing in can't snooze, dismiss or join by accident.
    static let inputGuard: TimeInterval = 0.8

    let model = CurtainModel()
    private var windows: [CurtainPanel] = []
    /// Hidden windows are released on the next run-loop pass, not in the middle of the click that hid them.
    private var retiredWindows: [CurtainPanel] = []
    private var guardGeneration = 0

    /// Based on the model, not the windows: while displays are reconfigured there can briefly be no screen
    /// and no window, but the curtain is still up.
    var isVisible: Bool { !model.meetings.isEmpty }
    /// The meetings currently on screen.
    var meetings: [Meeting] { model.meetings }

    func show(_ meetings: [Meeting], bringToFront: Bool) {
        // Assigning an equal value would still re-render every full-screen view.
        if model.meetings != meetings { model.meetings = meetings }
        if windows.isEmpty {
            createWindows()
        } else if bringToFront {
            self.bringToFront()
        }
    }

    func hide() {
        retire(windows)
        windows.removeAll()
        model.meetings = []
    }

    /// While nobody can see the curtain (display asleep, screen locked) its countdown stops and it ignores
    /// input. When it can be seen again it is raised with a fresh input guard, so the key or click that
    /// woke the display can't act on it.
    func setLive(_ live: Bool) {
        guard model.isLive != live else { return }
        model.isLive = live
        guard isVisible else { return }
        if live { bringToFront() } else { suspendInput() }
    }

    private func suspendInput() {
        guardGeneration += 1
        model.acceptsInput = false
    }

    private func retire(_ closing: [CurtainPanel]) {
        for window in closing { window.orderOut(nil) }
        retiredWindows.append(contentsOf: closing)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // AppKit can keep ordered-out windows alive until the next event arrives; detaching the
                // view stops its countdown right away even if nobody touches the Mac.
                for window in self.retiredWindows {
                    window.contentView = nil
                    window.close()
                }
                self.retiredWindows.removeAll()
            }
        }
    }

    /// Raises the curtain and takes keyboard focus without activating the app, so the app you were in
    /// stays active underneath and gets its focus back as soon as the curtain closes.
    func bringToFront() {
        startInputGuard()
        for window in windows { window.orderFrontRegardless() }
        let screenWithMouse = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        let key = windows.first { $0.screen == screenWithMouse } ?? windows.first
        key?.makeKey()
    }

    /// Displays were added, removed or rearranged: cover the new layout.
    func rebuildForCurrentScreens() {
        guard isVisible else { return }
        retire(windows)
        windows.removeAll()
        createWindows(animated: false)
    }

    private func createWindows(animated: Bool = true) {
        for screen in NSScreen.screens {
            let window = CurtainPanel(screen: screen)
            window.contentView = FirstClickHostingView(rootView: CurtainView(model: model))
            window.onSnoozeKey = { [model] in if model.acceptsInput { model.onSnooze() } }
            window.alphaValue = animated ? 0 : 1
            windows.append(window)
        }
        bringToFront()
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            for window in windows { window.animator().alphaValue = 1 }
        }
    }

    private func startInputGuard() {
        suspendInput()
        let generation = guardGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inputGuard) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.guardGeneration == generation else { return }
                self.model.acceptsInput = true
            }
        }
    }
}

/// A borderless panel covering one whole display, above full-screen apps, the menu bar and the Dock.
/// Non-activating: it receives keys without taking activation away from the app you are using.
final class CurtainPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = true
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Best effort to keep the curtain out of screen shares while you are presenting.
        sharingType = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Borderless windows are otherwise pushed below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Swallow keys nothing handles (e.g. typing during the input guard) instead of beeping.
    override func noResponder(for eventSelector: Selector) {}

    /// The physical S key on layouts where it doesn't type "s" (e.g. Russian, Greek), which SwiftUI's
    /// "s" shortcut doesn't match.
    var onSnoozeKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let typesNonLatin = event.charactersIgnoringModifiers?.unicodeScalars.contains { !$0.isASCII } ?? false
        if event.keyCode == UInt16(kVK_ANSI_S), typesNonLatin,
           event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) {
            onSnoozeKey?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Buttons respond to the first click even while another app is active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
