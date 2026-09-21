import AppKit
import SwiftUI
import MeetingCurtainCore

/// Shows the curtain on every display. Windows exist only while the curtain is up; hiding releases them.
@MainActor
final class CurtainController {
    let model = CurtainModel()
    private var windows: [CurtainWindow] = []
    /// Hidden windows are released on the next run-loop pass, not in the middle of the click that hid them.
    private var retiredWindows: [CurtainWindow] = []

    var isVisible: Bool { !windows.isEmpty }
    /// The meetings currently on screen.
    var meetings: [Meeting] { isVisible ? model.meetings : [] }

    func show(_ meetings: [Meeting], bringToFront: Bool) {
        model.meetings = meetings
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

    private func retire(_ closing: [CurtainWindow]) {
        for window in closing { window.orderOut(nil) }
        retiredWindows.append(contentsOf: closing)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.retiredWindows.removeAll() }
        }
    }

    func bringToFront() {
        NSApp.activate()
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
            let window = CurtainWindow(screen: screen)
            window.contentView = FirstClickHostingView(rootView: CurtainView(model: model))
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
}

/// A borderless window covering one whole display, above full-screen apps, the menu bar and the Dock.
final class CurtainWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
}

/// Buttons respond to the first click even while another app is active.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
