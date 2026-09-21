import AppKit
@preconcurrency import EventKit
import MeetingCurtainCore

/// Keeps the upcoming meetings current, shows the curtain when one is due, and runs the self-check routine.
///
/// While idle the app holds exactly one wall-clock timer (next curtain, pre-meeting sync, or routine check,
/// whichever comes first) and otherwise only reacts to system events: calendar changes, wake, unlock,
/// clock changes. There is no polling loop.
@MainActor
final class MeetingMonitor {
    static let horizon: TimeInterval = 24 * 3600
    static let routineInterval: TimeInterval = 15 * 60
    static let routineLeeway: TimeInterval = 90
    /// How long before a curtain macOS is asked to sync Google, to catch last-minute changes.
    static let preflightLead: TimeInterval = 3 * 60
    static let snoozeDuration: TimeInterval = 60
    private static let dismissedKey = "dismissedOccurrences"

    let prefs: Preferences
    let calendar = CalendarService()
    let health = HealthMonitor()
    let attention = Attention()
    let curtain = CurtainController()

    private(set) var meetings: [Meeting] = []
    private(set) var plan = Plan()
    private var state: ReminderState
    private var testMeeting: Meeting?
    private var announced: Set<String> = []
    private var preflighted: Set<String> = []
    /// `start()` runs the first self-check; until then nothing else should trigger one.
    private var nextRoutine = Date().addingTimeInterval(MeetingMonitor.routineInterval)
    private var lastAuthorization: EKAuthorizationStatus = .notDetermined
    private let timer = WallClockTimer()
    private var systemEvents: SystemEvents?
    private var calendarObserver: NSObjectProtocol?
    private var pendingRefresh: DispatchWorkItem?
    private var napActivity: NSObjectProtocol?

    /// Called after every evaluation, e.g. so the menu bar icon can follow the health state.
    var onChange: (() -> Void)?

    init(prefs: Preferences) {
        self.prefs = prefs
        state = ReminderState(dismissed: Self.loadDismissed())
        timer.onFire = { [weak self] in self?.timerFired() }
        curtain.model.onJoin = { [weak self] in self?.join($0) }
        curtain.model.onSnooze = { [weak self] in self?.snoozeVisible() }
        curtain.model.onDismiss = { [weak self] in self?.dismissVisible() }
    }

    func start() async {
        systemEvents = SystemEvents { [weak self] in self?.handle($0) }
        calendarObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: calendar.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }

        if prefs.launchAtLogin, LoginItem.isInstalledInApplications { LoginItem.apply(enabled: true) }

        if calendar.authorization == .notDetermined {
            let granted = await calendar.requestAccess()
            log.notice("Calendar access \(granted ? "granted" : "denied", privacy: .public)")
        }
        lastAuthorization = calendar.authorization
        if prefs.lockScreenAlerts { await attention.requestNotificationPermission() }
        await runSelfCheck()
    }

    /// Eligible meetings that haven't ended yet, for the menu.
    var upcoming: [Meeting] {
        let now = Date()
        let policy = prefs.policy
        return meetings.filter { $0.end > now && Planner.isEligible($0, policy: policy) }
    }

    // MARK: Refresh and evaluation

    func refresh(reason: String) {
        let now = Date()
        meetings = calendar.meetings(from: now, to: now.addingTimeInterval(Self.horizon))
        log.info("Refreshed (\(reason, privacy: .public)): \(self.meetings.count) events in the next 24 h")
        evaluate(now: now)
    }

    /// Recomputes what should be on screen and re-arms the timer. Cheap: no calendar access.
    func evaluate(now: Date = Date()) {
        if state.prune(now: now) { saveDismissed() }
        var candidates = meetings
        if let testMeeting { candidates.append(testMeeting) }
        plan = Planner.plan(for: candidates, now: now, policy: prefs.policy, state: state)

        // A curtain stays up until the user acts, even past the late-grace period, but a meeting that
        // was deleted or moved in the calendar disappears from it.
        var shown = plan.due
        let dueIDs = Set(shown.map(\.id))
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for meeting in curtain.meetings where !dueIDs.contains(meeting.id) && !state.isDismissed(meeting.id) {
            if let current = byID[meeting.id] { shown.append(current) }
        }
        shown.sort { $0.start < $1.start }
        present(shown)

        let live = Set(byID.keys)
        announced.formIntersection(live)
        preflighted.formIntersection(live)
        armTimer(now: now)
        health.updateSchedule(next: realNext(), upcomingCount: upcoming.count)
        onChange?()
    }

    private func present(_ meetings: [Meeting]) {
        guard !meetings.isEmpty else {
            if curtain.isVisible { curtain.hide() }
            return
        }
        let fresh = meetings.filter { !announced.contains($0.id) }
        curtain.show(meetings, bringToFront: !fresh.isEmpty)
        guard !fresh.isEmpty else { return }
        announced.formUnion(fresh.map(\.id))
        attention.announce(fresh, prefs: prefs, screenLocked: systemEvents?.isScreenLocked ?? false)
        log.notice("Curtain shown for \(fresh.count) meeting(s)")
    }

    private func realNext() -> Plan.Upcoming? {
        guard let next = plan.next, next.meeting.id != testMeeting?.id else { return nil }
        return next
    }

    // MARK: Timer

    private func armTimer(now: Date) {
        var wakes: [(date: Date, leeway: TimeInterval)] = [(max(nextRoutine, now), Self.routineLeeway)]
        if let next = plan.next {
            wakes.append((next.date, 0.5))
            let preflight = next.date.addingTimeInterval(-Self.preflightLead)
            if preflight > now, !preflighted.contains(next.meeting.id) { wakes.append((preflight, 5)) }
        }
        wakes.sort { $0.date < $1.date }
        let first = wakes[0]
        // Never let a relaxed wake-up drift past a precise one that follows it.
        let slack = wakes.count > 1 ? wakes[1].date.timeIntervalSince(first.date) : .infinity
        timer.schedule(at: first.date, leeway: min(first.leeway, max(slack, 0.5)))
        updateNapActivity(now: now)
    }

    private func timerFired() {
        let now = Date()
        if let next = plan.next, !preflighted.contains(next.meeting.id),
           now >= next.date.addingTimeInterval(-Self.preflightLead - 5) {
            preflighted.insert(next.meeting.id)
            // Pull the latest from Google so a meeting moved or cancelled at the last minute is caught.
            calendar.requestSync()
        }
        if now >= nextRoutine.addingTimeInterval(-Self.routineLeeway) {
            Task { await runSelfCheck() }
        } else {
            refresh(reason: "timer")
        }
    }

    /// App Nap can delay the timers of an app without visible windows. From shortly before a curtain is due,
    /// opt out of it so the curtain appears on time. Outside that window the app naps normally.
    private func updateNapActivity(now: Date) {
        let imminent = plan.next.map { $0.date.timeIntervalSince(now) <= Self.preflightLead + 10 } ?? false
        if imminent, napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Meeting curtain due soon"
            )
        } else if !imminent, let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    // MARK: Self-check routine

    /// Re-verifies everything the curtain depends on, repairs what it can, and refreshes the calendar.
    func runSelfCheck() async {
        nextRoutine = Date().addingTimeInterval(Self.routineInterval)
        heal()
        refresh(reason: "self-check")
        if prefs.lockScreenAlerts { await attention.refreshNotificationStatus() }
        health.evaluate(healthInputs())
        health.updateSchedule(next: realNext(), upcomingCount: upcoming.count)
        onChange?()
    }

    /// Repairs that are safe to do without asking.
    private func heal() {
        // Only the installed copy registers itself, so a build-folder copy never leaves a stray login item.
        if prefs.launchAtLogin, LoginItem.isInstalledInApplications,
           LoginItem.status == .notRegistered || LoginItem.status == .notFound {
            LoginItem.apply(enabled: true)
        }
        let authorization = calendar.authorization
        if authorization != lastAuthorization {
            // Access was granted or revoked in System Settings; drop anything the store cached.
            log.notice("Calendar authorization changed to \(authorization.rawValue)")
            lastAuthorization = authorization
            calendar.reset()
        } else if calendar.hasAccess, calendar.calendarCount == 0 {
            calendar.reset()
        }
    }

    /// Cheap check for the menu: picks up calendar access granted in System Settings right away.
    func checkAuthorizationChange() {
        if calendar.authorization != lastAuthorization {
            Task { await runSelfCheck() }
        }
    }

    private func healthInputs() -> HealthMonitor.Inputs {
        HealthMonitor.Inputs(
            calendarAuthorization: calendar.authorization,
            calendarCount: calendar.calendarCount,
            onlineAccounts: calendar.onlineAccounts(),
            wantsLaunchAtLogin: prefs.launchAtLogin,
            loginItemStatus: LoginItem.status,
            installedInApplications: LoginItem.isInstalledInApplications,
            wantsLockScreenAlerts: prefs.lockScreenAlerts,
            notificationStatus: attention.notificationStatus,
            wantsSound: prefs.playSound,
            soundName: prefs.soundName
        )
    }

    func perform(_ fix: HealthCheck.Fix) {
        switch fix {
        case .requestCalendarAccess:
            Task {
                _ = await calendar.requestAccess()
                await runSelfCheck()
            }
        case .openCalendarPrivacy:
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .openInternetAccounts:
            openSettings("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
        case .enableLaunchAtLogin:
            prefs.launchAtLogin = true
        case .openLoginItems:
            LoginItem.openSystemSettings()
        case .requestNotifications:
            Task {
                await attention.requestNotificationPermission()
                await runSelfCheck()
            }
        case .openNotificationSettings:
            let id = Bundle.main.bundleIdentifier ?? ""
            openSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
        }
    }

    private func openSettings(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    // MARK: Events

    private func handle(_ event: SystemEvents.Event) {
        switch event {
        case .didWake:
            // Opening the lid: check right away, and ask macOS to sync Google now instead of on its schedule.
            calendar.requestSync()
            Task { await runSelfCheck() }
            // The network is often not back yet right after wake, so ask once more a bit later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated { self?.calendar.requestSync() }
            }
        case .unlocked, .sessionActive:
            refresh(reason: "unlock")
            if curtain.isVisible { curtain.bringToFront() }
        case .screensDidWake:
            evaluate()
        case .clockChanged:
            refresh(reason: "clock changed")
        case .screensChanged:
            curtain.rebuildForCurrentScreens()
        case .locked:
            break
        }
    }

    /// Calendar syncs often post several change notifications in a burst; handle them once.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh(reason: "calendar changed") }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func preferencesChanged(_ key: Preferences.Key) {
        switch key {
        case .leadMinutes, .includeAllDay, .skipDeclined:
            evaluate()
        case .playSound, .soundName:
            if prefs.playSound { attention.play(prefs.soundName) }
            Task { await runSelfCheck() }
        case .lockScreenAlerts:
            Task {
                if prefs.lockScreenAlerts { await attention.requestNotificationPermission() }
                await runSelfCheck()
            }
        case .launchAtLogin:
            LoginItem.apply(enabled: prefs.launchAtLogin)
            Task { await runSelfCheck() }
        }
    }

    // MARK: Curtain actions

    func join(_ meeting: Meeting) {
        if let url = meeting.joinURL { NSWorkspace.shared.open(url) }
        dismissVisible()
    }

    func snoozeVisible() {
        let visible = curtain.meetings
        let until = Date().addingTimeInterval(Self.snoozeDuration)
        for meeting in visible {
            state.snooze(meeting, until: until)
            announced.remove(meeting.id)
        }
        attention.clearNotifications(for: visible.map(\.id))
        curtain.hide()
        evaluate()
    }

    func dismissVisible() {
        let visible = curtain.meetings
        for meeting in visible where meeting.id != testMeeting?.id {
            state.dismiss(meeting)
        }
        if let test = testMeeting, visible.contains(where: { $0.id == test.id }) { testMeeting = nil }
        saveDismissed()
        attention.clearNotifications(for: visible.map(\.id))
        curtain.hide()
        evaluate()
    }

    /// Shows a sample curtain exactly as a real meeting would appear with the current settings.
    func showTestCurtain() {
        let start = Date().addingTimeInterval(prefs.policy.leadTime)
        testMeeting = Meeting(
            id: "test-\(UUID().uuidString)",
            title: "Test meeting",
            start: start,
            end: start.addingTimeInterval(30 * 60),
            calendarTitle: "MeetingCurtain",
            location: "Preview of your meeting reminder",
            joinURL: URL(string: "https://meet.google.com/")
        )
        evaluate()
    }

    // MARK: Persistence

    private static func loadDismissed() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: dismissedKey) as? [String: Double] ?? [:]
        return raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func saveDismissed() {
        UserDefaults.standard.set(state.dismissed.mapValues(\.timeIntervalSince1970), forKey: Self.dismissedKey)
    }
}
