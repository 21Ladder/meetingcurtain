import AppKit
import CoreGraphics

/// Wake, unlock, clock and display changes: each one is a moment to re-check the calendar.
@MainActor
final class SystemEvents {
    enum Event {
        case didWake, screensDidWake, locked, unlocked, sessionActive, clockChanged, screensChanged
    }

    private(set) var isScreenLocked: Bool
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(handler: @escaping @MainActor (Event) -> Void) {
        isScreenLocked = Self.readLockState()

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let observed: [(NotificationCenter, Notification.Name, Event)] = [
            (workspace, NSWorkspace.didWakeNotification, .didWake),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
            (.default, .NSSystemClockDidChange, .clockChanged),
            (.default, .NSSystemTimeZoneDidChange, .clockChanged),
            (.default, NSApplication.didChangeScreenParametersNotification, .screensChanged),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlocked),
        ]
        for (center, name, event) in observed {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch event {
                    case .locked: self.isScreenLocked = true
                    case .unlocked: self.isScreenLocked = false
                    default: break
                    }
                    handler(event)
                }
            }
            tokens.append((center, token))
        }
    }

    private static func readLockState() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
