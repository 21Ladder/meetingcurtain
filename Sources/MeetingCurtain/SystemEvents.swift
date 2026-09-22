import AppKit
import CoreGraphics
import IOKit

/// Wake, unlock, clock and display changes: each one is a moment to re-check the calendar.
@MainActor
final class SystemEvents {
    enum AlertReadiness: Equatable {
        case ready
        /// Timers run but there is no display and no sound (lid closed, Power Nap, or idle sleep).
        case darkWake(lidOpen: Bool)
        /// Another user has the screen (Fast User Switching).
        case otherUser
    }

    enum Event {
        case willSleep, didWake, screensDidWake, screensDidSleep, locked, unlocked, sessionActive, clockChanged, screensChanged
    }

    private(set) var isScreenLocked: Bool
    private(set) var areScreensAsleep = false
    /// From going to sleep until the next full wake, i.e. also during dark wakes (lid closed, Power Nap),
    /// when timers run but there is no display and no sound.
    private(set) var isSystemAsleep = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(handler: @escaping @MainActor (Event) -> Void) {
        isScreenLocked = Self.readLockState()

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let observed: [(NotificationCenter, Notification.Name, Event)] = [
            (workspace, NSWorkspace.willSleepNotification, .willSleep),
            (workspace, NSWorkspace.didWakeNotification, .didWake),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensDidWake),
            (workspace, NSWorkspace.screensDidSleepNotification, .screensDidSleep),
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
                    case .willSleep: self.isSystemAsleep = true
                    case .locked: self.isScreenLocked = true
                    case .unlocked: self.isScreenLocked = false; self.isSystemAsleep = false
                    case .screensDidSleep: self.areScreensAsleep = true
                    case .screensDidWake, .didWake: self.areScreensAsleep = false; self.isSystemAsleep = false
                    case .sessionActive: self.isSystemAsleep = false
                    default: break
                    }
                    handler(event)
                }
            }
            tokens.append((center, token))
        }
    }

    /// Whether an alert now would reach the user.
    func alertReadiness() -> AlertReadiness {
        if isSystemAsleep {
            // A missed wake notification must never silence curtains for good: recent input means the
            // Mac is in use. (There is no input during a dark wake.)
            let anyInput = CGEventType(rawValue: ~0)!
            guard CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < 30 else {
                return .darkWake(lidOpen: !Self.isLidClosed)
            }
            isSystemAsleep = false
        }
        return Self.sessionFlag(kCGSessionOnConsoleKey) ?? true ? .ready : .otherUser
    }

    /// When unknown, the lid counts as closed, so a MacBook in a bag is never woken up.
    private static var isLidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return true }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool ?? true
    }

    private static func readLockState() -> Bool {
        sessionFlag("CGSSessionScreenIsLocked") ?? false
    }

    private static func sessionFlag(_ key: String) -> Bool? {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?[key] as? Bool
    }
}
