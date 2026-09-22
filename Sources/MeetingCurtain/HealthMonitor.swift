import AppKit
import EventKit
import Observation
import ServiceManagement
import UserNotifications
import MeetingCurtainCore

enum HealthStatus: Int, Comparable {
    case ok, info, warning, critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

struct HealthCheck: Identifiable, Equatable {
    enum Kind: String {
        case calendarAccess, googleCalendar, schedule, launchAtLogin, installLocation, notifications, sound
    }

    enum Fix: Equatable {
        case requestCalendarAccess, openCalendarPrivacy, openInternetAccounts
        case enableLaunchAtLogin, openLoginItems
        case requestNotifications, openNotificationSettings

        var label: String {
            switch self {
            case .requestCalendarAccess: "Allow Access…"
            case .openCalendarPrivacy: "Open Privacy Settings…"
            case .openInternetAccounts: "Open Internet Accounts…"
            case .enableLaunchAtLogin: "Turn On"
            case .openLoginItems: "Open Login Items…"
            case .requestNotifications: "Allow Notifications…"
            case .openNotificationSettings: "Open Notification Settings…"
            }
        }
    }

    let kind: Kind
    let status: HealthStatus
    let title: String
    let detail: String
    var fix: Fix?

    var id: Kind { kind }
}

/// The self-check routine: verifies that everything the curtain depends on is in place.
/// `MeetingMonitor` runs it at launch, after wake, every 15 minutes, and on demand.
@MainActor @Observable
final class HealthMonitor {
    struct Inputs {
        var calendarAuthorization: EKAuthorizationStatus
        var calendarCount: Int
        var onlineAccounts: [CalendarService.Account]
        var wantsLaunchAtLogin: Bool
        var loginItemStatus: SMAppService.Status
        var installedInApplications: Bool
        var wantsLockScreenAlerts: Bool
        var notificationStatus: UNAuthorizationStatus
        var wantsSound: Bool
        var soundName: String
    }

    private(set) var checks: [HealthCheck] = []
    private(set) var lastRun: Date?
    @ObservationIgnored private var scheduleCheck = HealthCheck(
        kind: .schedule, status: .ok, title: "Watching your calendar", detail: "No meetings in the next 24 hours."
    )

    var overall: HealthStatus { checks.map(\.status).max() ?? .ok }
    var problems: [HealthCheck] { checks.filter { $0.status >= .warning } }

    func evaluate(_ inputs: Inputs) {
        var result = [calendarAccess(inputs)]
        if inputs.calendarAuthorization == .fullAccess {
            result.append(googleCalendar(inputs))
            result.append(scheduleCheck)
        }
        result.append(launchAtLogin(inputs))
        result.append(installLocation(inputs))
        if inputs.wantsLockScreenAlerts { result.append(notifications(inputs)) }
        if inputs.wantsSound { result.append(sound(inputs)) }

        if result != checks {
            for check in result where check.status >= .warning {
                log.notice("Self-check: \(check.title, privacy: .public) — \(check.detail, privacy: .public)")
            }
        }
        checks = result
        lastRun = Date()
    }

    private func calendarAccess(_ inputs: Inputs) -> HealthCheck {
        switch inputs.calendarAuthorization {
        case .fullAccess:
            return HealthCheck(kind: .calendarAccess, status: .ok, title: "Calendar access granted",
                               detail: "MeetingCurtain can read your events.")
        case .notDetermined:
            return HealthCheck(kind: .calendarAccess, status: .critical, title: "Calendar access needed",
                               detail: "Without it no curtain can be shown.", fix: .requestCalendarAccess)
        default:
            return HealthCheck(kind: .calendarAccess, status: .critical, title: "No calendar access",
                               detail: "Allow MeetingCurtain under Privacy & Security → Calendars (Full Access).",
                               fix: .openCalendarPrivacy)
        }
    }

    private func googleCalendar(_ inputs: Inputs) -> HealthCheck {
        if inputs.calendarCount == 0 {
            return HealthCheck(kind: .googleCalendar, status: .critical, title: "No calendars found",
                               detail: "Add your Google account in System Settings → Internet Accounts and turn on Calendars.",
                               fix: .openInternetAccounts)
        }
        guard !inputs.onlineAccounts.isEmpty else {
            return HealthCheck(kind: .googleCalendar, status: .warning, title: "Google account not connected",
                               detail: "Only local or iCloud calendars were found. Add your Google account in Internet Accounts.",
                               fix: .openInternetAccounts)
        }
        let accounts = inputs.onlineAccounts
            .map { "\($0.title) (\($0.calendars) calendar\($0.calendars == 1 ? "" : "s"))" }
            .joined(separator: ", ")
        return HealthCheck(kind: .googleCalendar, status: .ok, title: "Google account connected", detail: accounts)
    }

    /// Keeps the "next curtain" line current; called after every evaluation, so it must stay cheap.
    func updateSchedule(next: Plan.Upcoming?, upcomingCount: Int) {
        let check: HealthCheck
        if let next {
            let today = Calendar.current.isDateInToday(next.date)
            let when = next.date.formatted(date: today ? .omitted : .abbreviated, time: .shortened)
            check = HealthCheck(kind: .schedule, status: .ok, title: "Next curtain at \(when)", detail: next.meeting.title)
        } else {
            let detail = upcomingCount == 0
                ? "No meetings in the next 24 hours."
                : "No further curtains needed in the next 24 hours."
            check = HealthCheck(kind: .schedule, status: .ok, title: "Watching your calendar", detail: detail)
        }
        scheduleCheck = check
        if let index = checks.firstIndex(where: { $0.kind == .schedule }), checks[index] != check {
            checks[index] = check
        }
    }

    private func launchAtLogin(_ inputs: Inputs) -> HealthCheck {
        guard inputs.wantsLaunchAtLogin else {
            return HealthCheck(kind: .launchAtLogin, status: .info, title: "Launch at login is off",
                               detail: "After a restart you won't get curtains until you open the app yourself.",
                               fix: .enableLaunchAtLogin)
        }
        switch inputs.loginItemStatus {
        case .enabled:
            return HealthCheck(kind: .launchAtLogin, status: .ok, title: "Starts automatically at login",
                               detail: "Listed under System Settings → General → Login Items.")
        case .requiresApproval:
            return HealthCheck(kind: .launchAtLogin, status: .warning, title: "Login item needs approval",
                               detail: "Turn MeetingCurtain on in System Settings → General → Login Items.",
                               fix: .openLoginItems)
        default:
            return HealthCheck(kind: .launchAtLogin, status: .warning, title: "Login item not registered",
                               detail: "macOS did not accept the login item. Try again or add it in Login Items.",
                               fix: .enableLaunchAtLogin)
        }
    }

    private func installLocation(_ inputs: Inputs) -> HealthCheck {
        if inputs.installedInApplications {
            return HealthCheck(kind: .installLocation, status: .ok, title: "Installed in Applications",
                               detail: Bundle.main.bundleURL.deletingLastPathComponent().path)
        }
        return HealthCheck(kind: .installLocation, status: .warning, title: "Running from a build folder",
                           detail: "Install with ./build.sh install so the login item keeps pointing at a stable copy.")
    }

    private func notifications(_ inputs: Inputs) -> HealthCheck {
        switch inputs.notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return HealthCheck(kind: .notifications, status: .ok, title: "Lock-screen notifications allowed",
                               detail: "Used when a meeting starts while the Mac is locked.")
        case .notDetermined:
            return HealthCheck(kind: .notifications, status: .warning, title: "Notifications not allowed yet",
                               detail: "Needed to alert you while the Mac is locked.", fix: .requestNotifications)
        default:
            return HealthCheck(kind: .notifications, status: .warning, title: "Notifications are off",
                               detail: "Allow them for lock-screen alerts, or turn off \"Notify on the lock screen\" in Settings.",
                               fix: .openNotificationSettings)
        }
    }

    private func sound(_ inputs: Inputs) -> HealthCheck {
        if Attention.soundExists(inputs.soundName) {
            return HealthCheck(kind: .sound, status: .ok, title: "Alert sound ready", detail: inputs.soundName)
        }
        return HealthCheck(kind: .sound, status: .warning, title: "Alert sound missing",
                           detail: "\"\(inputs.soundName)\" isn't installed. Pick another sound.")
    }
}
