import AppKit
import IOKit.pwr_mgt
@preconcurrency import UserNotifications
import MeetingCurtainCore

/// Everything besides the curtain that gets attention: a sound, waking the display, and a
/// notification when the screen is locked (the lock screen covers the curtain).
@MainActor
final class Attention {
    private var sound: NSSound?
    private var activityAssertion: IOPMAssertionID = 0
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    private var center: UNUserNotificationCenter { .current() }

    func announce(_ meetings: [Meeting], prefs: Preferences, screenLocked: Bool) {
        wakeDisplay()
        if prefs.playSound { play(prefs.soundName) }
        if screenLocked && prefs.lockScreenAlerts { notify(meetings) }
        if let first = meetings.first { speak("\(first.title). \(Self.startDescription(first))") }
    }

    /// Second alert when a meeting actually starts while its curtain is still up (e.g. you were away).
    func chime(prefs: Preferences) {
        wakeDisplay()
        if prefs.playSound { play(prefs.soundName) }
    }

    /// VoiceOver reads this even though keyboard focus stays in the app you were using.
    private func speak(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    func play(_ name: String) {
        sound?.stop()
        sound = NSSound(named: NSSound.Name(name))
        sound?.play()
    }

    static func soundExists(_ name: String) -> Bool { NSSound(named: NSSound.Name(name)) != nil }

    /// Declaring user activity turns a sleeping display on, the same as touching the trackpad.
    private func wakeDisplay() {
        let result = IOPMAssertionDeclareUserActivity(
            "MeetingCurtain meeting reminder" as CFString, kIOPMUserActiveLocal, &activityAssertion
        )
        guard result == kIOReturnSuccess else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activityAssertion != 0 else { return }
                IOPMAssertionRelease(self.activityAssertion)
                self.activityAssertion = 0
            }
        }
    }

    // MARK: Lock-screen notifications

    func refreshNotificationStatus() async {
        notificationStatus = await center.notificationSettings().authorizationStatus
    }

    func requestNotificationPermission() async {
        if notificationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshNotificationStatus()
    }

    private func notify(_ meetings: [Meeting]) {
        guard notificationStatus == .authorized || notificationStatus == .provisional else { return }
        for meeting in meetings {
            let content = UNMutableNotificationContent()
            content.title = meeting.title
            content.body = Self.startDescription(meeting)
            content.interruptionLevel = .active
            let request = UNNotificationRequest(identifier: meeting.id, content: content, trigger: nil)
            center.add(request) { error in
                if let error { log.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func clearNotifications(for ids: [String]) {
        guard !ids.isEmpty, notificationStatus != .notDetermined else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func startDescription(_ meeting: Meeting, now: Date = Date()) -> String {
        if meeting.isAllDay { return "All-day event today" }
        let time = meeting.start.formatted(date: .omitted, time: .shortened)
        let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded())
        switch minutes {
        case ..<0: return "Started at \(time)"
        case 0: return "Starts now (\(time))"
        default: return "Starts in \(minutes) min at \(time)"
        }
    }
}
