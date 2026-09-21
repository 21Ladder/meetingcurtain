import AppKit
import MeetingCurtainCore

/// The menu bar icon. The menu is built only when it opens, so it costs nothing while closed and
/// relative times ("in 12 min") are always current.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let monitor: MeetingMonitor
    private let openSettings: () -> Void
    private var shownStatus: HealthStatus?

    init(monitor: MeetingMonitor, openSettings: @escaping () -> Void) {
        self.monitor = monitor
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    /// Switches to a warning icon while the self-check reports a problem.
    func updateIcon() {
        let status = monitor.health.overall
        guard status != shownStatus else { return }
        shownStatus = status
        let healthy = status < .warning
        let image = NSImage(
            systemSymbolName: healthy ? "calendar.badge.clock" : "calendar.badge.exclamationmark",
            accessibilityDescription: "MeetingCurtain"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = healthy
            ? "MeetingCurtain"
            : "MeetingCurtain: \(monitor.health.problems.first?.title ?? "needs attention")"
    }

    func menuWillOpen(_ menu: NSMenu) {
        monitor.checkAuthorizationChange()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()

        menu.addItem(.sectionHeader(title: "Upcoming"))
        let upcoming = monitor.upcoming.prefix(8)
        if upcoming.isEmpty {
            menu.addItem(disabled(monitor.calendar.hasAccess ? "No meetings in the next 24 hours" : "No calendar access"))
        }
        for meeting in upcoming {
            menu.addItem(item(for: meeting, now: now))
        }

        menu.addItem(.separator())
        menu.addItem(healthItem())
        menu.addItem(ActionItem("Run Self-Check Now") { [monitor] in Task { await monitor.runSelfCheck() } })
        menu.addItem(ActionItem("Show Test Curtain") { [monitor] in monitor.showTestCurtain() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Settings…", key: ",") { [openSettings] in openSettings() })
        menu.addItem(ActionItem("Quit MeetingCurtain", key: "q") { NSApp.terminate(nil) })
    }

    private func item(for meeting: Meeting, now: Date) -> NSMenuItem {
        let item = ActionItem(meeting.title) {
            if let url = meeting.joinURL {
                NSWorkspace.shared.open(url)
            } else if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.openApplication(at: calendarApp, configuration: .init())
            }
        }
        var parts = [meeting.isAllDay ? "All day" : meeting.start.formatted(date: .omitted, time: .shortened)]
        if !meeting.isAllDay { parts.append(Self.relative(meeting.start, now: now)) }
        if let url = meeting.joinURL { parts.append("Join \(MeetingLinks.serviceName(for: url))") }
        if meeting.isDeclined { parts.append("Declined") }
        item.subtitle = parts.joined(separator: " · ")
        item.image = Self.dot(meeting.color)
        return item
    }

    private func healthItem() -> NSMenuItem {
        let health = monitor.health
        let problems = health.problems
        let title = problems.isEmpty
            ? "Everything OK"
            : problems.count == 1 ? problems[0].title : "\(problems.count) problems need attention"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: health.overall.symbol, accessibilityDescription: nil)
        if let lastRun = health.lastRun {
            item.subtitle = "Self-check \(lastRun.formatted(date: .omitted, time: .shortened))"
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for check in health.checks {
            let row: NSMenuItem
            if let fix = check.fix {
                row = ActionItem(check.title) { [monitor] in monitor.perform(fix) }
                row.subtitle = "\(check.detail)\n→ \(fix.label)"
            } else {
                row = NSMenuItem(title: check.title, action: nil, keyEquivalent: "")
                row.subtitle = check.detail
            }
            row.image = NSImage(systemSymbolName: check.status.symbol, accessibilityDescription: nil)
            submenu.addItem(row)
        }
        item.submenu = submenu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    static func relative(_ date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        switch minutes {
        case ..<1: return "now"
        case ..<60: return "in \(minutes) min"
        default:
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
        }
    }

    private static func dot(_ color: CalendarColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        // AppKit sends menu actions on the main thread.
        let handler = self.handler
        MainActor.assumeIsolated { handler() }
    }
}
