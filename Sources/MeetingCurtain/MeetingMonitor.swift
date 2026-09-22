import AppKit
@preconcurrency import EventKit
import ServiceManagement
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
    /// Start of the last fetch window; a meeting on screen that ended before it is over, not deleted.
    private var fetchedFrom = Date.distantPast
    private(set) var plan = Plan()
    private var state: ReminderState
    private var testMeeting: Meeting?
    private var announced: Set<String> = []
    /// Meetings that already got the second alert at their start time.
    private var chimed: Set<String> = []
    private var preflighted: Set<String> = []
    private var hasRunFirstCheck = false
    private var confirmingCritical = false
    private var lastLoginStatus: SMAppService.Status?
    /// Throttles use the monotonic clock, so setting the wall clock back can't stall or skip them.
    private var lastSelfCheck: ContinuousClock.Instant?
    private var lastNotificationCheck: ContinuousClock.Instant?
    /// How many calendars the last refresh read, for the self-check.
    private var watchedCalendarCount = 0
    /// `start()` runs the first self-check; until then nothing else should trigger one.
    private var nextRoutine = Date().addingTimeInterval(MeetingMonitor.routineInterval)
    private var lastAuthorization: EKAuthorizationStatus = .notDetermined
    private let timer = WallClockTimer()
    private var systemEvents: SystemEvents?
    private var calendarObserver: NSObjectProtocol?
    private var pendingRefresh: DispatchWorkItem?
    private var napActivity: NSObjectProtocol?
    private var knownCalendars: Set<String> = []

    /// Called after every evaluation, e.g. so the menu bar icon can follow the health state.
    var onChange: (() -> Void)?
    /// Called when the self-check newly finds that curtains can't work (e.g. calendar access was revoked),
    /// because the menu bar icon alone is easy to miss.
    var onCritical: (() -> Void)?

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

        if calendar.authorization == .notDetermined {
            // Arm the routine wake-up and show "Calendar access needed" while the prompt waits.
            checkNow()
            let granted = await calendar.requestAccess()
            log.notice("Calendar access \(granted ? "granted" : "denied", privacy: .public)")
        }
        await runSelfCheck()
        // Not awaited before the first check: an unanswered notification prompt must not hold up startup.
        if prefs.lockScreenAlerts, attention.notificationStatus == .notDetermined {
            Task {
                await attention.requestNotificationPermission()
                await runSelfCheck()
            }
        }
    }

    /// Eligible meetings that haven't ended yet, for the menu.
    var upcoming: [Meeting] {
        let now = Date()
        let policy = prefs.policy
        return meetings.filter { $0.end > now && Planner.isEligible($0, policy: policy) }
    }

    // MARK: Refresh and evaluation

    /// Fetches the meetings of the watched calendars. Callers that just read the calendars pass them in,
    /// so EventKit is asked once per pass.
    func refresh(reason: String, calendars known: [EKCalendar]? = nil) {
        let selection = prefs.calendarSelection
        let watched = (known ?? currentCalendars()).filter { selection.includes($0) }
        watchedCalendarCount = watched.count
        let now = Date()
        // Look back as far as a meeting can still be announced late.
        fetchedFrom = now.addingTimeInterval(-prefs.policy.lateGrace)
        meetings = calendar.meetings(from: fetchedFrom, to: now.addingTimeInterval(Self.horizon), in: watched)
        log.info("Refreshed (\(reason, privacy: .public)): \(self.meetings.count) events in the next 24 h")
        evaluate(now: now)
    }

    /// Recomputes what should be on screen and re-arms the timer. Cheap: no calendar access.
    func evaluate(now: Date = Date()) {
        if state.prune(now: now) { saveDismissed() }
        var candidates = meetings
        if let testMeeting { candidates.append(testMeeting) }
        plan = Planner.plan(for: candidates, now: now, policy: prefs.policy, state: state)

        // A curtain stays up until the user acts, even past the late-grace period or the meeting's end,
        // but a meeting that was deleted, moved, or excluded by a settings change disappears from it.
        let policy = prefs.policy
        var shown = plan.due
        let dueIDs = Set(shown.map(\.id))
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for meeting in curtain.meetings where !dueIDs.contains(meeting.id) && !state.isDismissed(meeting.id) {
            if let current = byID[meeting.id] {
                if Planner.isEligible(current, policy: policy) { shown.append(current) }
            } else if max(meeting.start, meeting.end) <= fetchedFrom {
                shown.append(meeting)
            }
        }
        shown.sort { $0.start < $1.start }

        let fresh = shown.filter { !announced.contains($0.id) }
        let freshIDs = Set(fresh.map(\.id))
        // Second alert when a meeting starts while its curtain is still up, e.g. you were away from the desk.
        let startAlerts = Planner.startAlerts(onScreen: shown, now: now, policy: policy)
            .filter { !chimed.contains($0.id) && !freshIDs.contains($0.id) }
        // Whether an alert would reach the user is asked once, and only when there is one.
        let readiness = fresh.isEmpty && startAlerts.isEmpty ? .ready : systemEvents?.alertReadiness() ?? .ready
        if readiness == .ready {
            present(shown, fresh: fresh, now: now)
            if !startAlerts.isEmpty {
                chimed.formUnion(startAlerts.map(\.id))
                attention.chime(prefs: prefs)
            }
        } else {
            // Dark wake (no display, no sound) or another user at the screen: an alert now would go unseen and
            // be used up. The full wake or session switch re-evaluates. With the lid open (e.g. idle sleep at
            // the desk), wake the Mac so the curtain can appear now.
            if fresh.isEmpty { present(shown, fresh: [], now: now) }
            if readiness == .darkWake(lidOpen: true) { attention.wakeDisplay() }
        }

        // Meetings still on screen count as live even when they are no longer fetched, so they
        // aren't announced again on the next evaluation.
        let live = Set(byID.keys).union(shown.map(\.id))
        announced.formIntersection(live)
        chimed.formIntersection(live)
        preflighted.formIntersection(live)
        armTimer(now: now)
        health.updateSchedule(next: realNext(), upcomingCount: upcoming.count)
        onChange?()
    }

    /// Puts `meetings` on the curtain (or takes it down) and announces the `fresh` ones.
    private func present(_ meetings: [Meeting], fresh: [Meeting], now: Date) {
        guard !meetings.isEmpty else {
            if curtain.isVisible { curtain.hide() }
            return
        }
        curtain.show(meetings, bringToFront: !fresh.isEmpty)
        guard !fresh.isEmpty else { return }
        announced.formUnion(fresh.map(\.id))
        // Announced at or after its start: this alert already covers the start.
        chimed.formUnion(fresh.filter { $0.start <= now }.map(\.id))
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
        if let start = Planner.nextStart(onScreen: curtain.meetings, now: now) {
            wakes.append((start, 0.5))
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
        var syncRequested = false
        if let next = plan.next, !preflighted.contains(next.meeting.id),
           now >= next.date.addingTimeInterval(-Self.preflightLead - 5) {
            preflighted.insert(next.meeting.id)
            // Pull the latest from Google so a meeting moved or cancelled at the last minute is caught.
            // What it brings arrives through `.EKEventStoreChanged`.
            calendar.requestSync()
            syncRequested = true
        }
        if now >= nextRoutine.addingTimeInterval(-Self.routineLeeway) {
            requestSelfCheck()
        } else if syncRequested {
            evaluate(now: now)
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
                // Also keeps the Mac from idle-sleeping in these few minutes; closing the lid still sleeps.
                options: .userInitiated, reason: "Meeting curtain due soon"
            )
        } else if !imminent, let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    // MARK: Self-check routine

    /// Runs the self-check unless one just ran: waking, unlocking and an overdue routine timer often
    /// arrive together, and one check covers them all. Otherwise it only re-evaluates.
    func requestSelfCheck(force: Bool = false) {
        guard force || Self.hasElapsed(.seconds(10), since: lastSelfCheck) else {
            evaluate()
            return
        }
        lastSelfCheck = .now
        nextRoutine = Date().addingTimeInterval(Self.routineInterval)
        Task { await runSelfCheck() }
    }

    private static func hasElapsed(_ duration: Duration, since instant: ContinuousClock.Instant?) -> Bool {
        instant.map { ContinuousClock.now - $0 > duration } ?? true
    }

    /// Re-verifies everything the curtain depends on, repairs what it can, and refreshes the calendar.
    /// Only the notification permission is read asynchronously, before the check; the check itself is
    /// synchronous, so an older result can never overwrite a newer one.
    func runSelfCheck() async {
        // Notification permission rarely changes; re-read it hourly, or sooner when invalidated.
        if prefs.lockScreenAlerts, Self.hasElapsed(.seconds(3600), since: lastNotificationCheck) {
            lastNotificationCheck = .now
            await attention.refreshNotificationStatus()
        }
        checkNow()
    }

    /// One self-check run. Each system service (calendar permission, calendars, login item) is queried once.
    private func checkNow() {
        lastSelfCheck = .now
        nextRoutine = Date().addingTimeInterval(Self.routineInterval)

        let authorization = calendar.authorization
        if authorization != lastAuthorization {
            // Access was granted or revoked; drop anything the store cached.
            log.notice("Calendar authorization changed to \(authorization.rawValue)")
            lastAuthorization = authorization
            calendar.reset()
        }
        var calendars = authorization == .fullAccess ? calendar.eventCalendars() : []
        if authorization == .fullAccess, calendars.isEmpty {
            // Self-heal a store that came up empty, e.g. created before access was granted.
            calendar.reset()
            calendars = calendar.eventCalendars()
        }
        knownCalendars = Set(calendars.map(\.calendarIdentifier))

        let loginStatus = checkLoginItem()
        refresh(reason: "self-check", calendars: calendars)

        let before = health.overall
        health.evaluate(HealthMonitor.Inputs(
            calendarAuthorization: authorization,
            calendarCount: calendars.count,
            watchedCalendars: watchedCalendarCount,
            onlineAccounts: CalendarService.onlineAccounts(in: calendars),
            wantsLaunchAtLogin: prefs.launchAtLogin,
            loginItemStatus: loginStatus,
            installedInApplications: LoginItem.isInstalledInApplications,
            wantsLockScreenAlerts: prefs.lockScreenAlerts,
            notificationStatus: attention.notificationStatus,
            wantsSound: prefs.playSound,
            soundName: prefs.soundName
        ))
        health.updateSchedule(next: realNext(), upcomingCount: upcoming.count)
        onChange?()
        if hasRunFirstCheck, before < .critical, health.overall == .critical { confirmCritical() }
        hasRunFirstCheck = true
    }

    /// Re-registers a login item that went missing, but respects one the user removed in System Settings
    /// while the app was running. Only the installed copy registers itself, so a build-folder copy never
    /// leaves a stray login item.
    private func checkLoginItem() -> SMAppService.Status {
        var status = LoginItem.status
        defer { lastLoginStatus = status }
        guard prefs.launchAtLogin, LoginItem.isInstalledInApplications else { return status }
        if lastLoginStatus == .enabled, status == .notRegistered {
            log.notice("Login item removed in System Settings; turning launch at login off")
            prefs.launchAtLogin = false
        } else if status == .notRegistered || status == .notFound {
            LoginItem.apply(enabled: true)
            status = LoginItem.status
        }
        return status
    }

    /// A single empty calendar read (e.g. right after wake or login, or while the calendar daemon restarts)
    /// must not pop up Settings; only a problem that is still there 20 s later does.
    func confirmCritical() {
        guard !confirmingCritical else { return }
        confirmingCritical = true
        Task {
            try? await Task.sleep(for: .seconds(20))
            confirmingCritical = false
            checkNow()
            if health.overall == .critical { onCritical?() }
        }
    }

    /// Makes the next self-check re-read notification permission, e.g. after the user may have changed it.
    func invalidateNotificationStatus() {
        lastNotificationCheck = nil
    }

    /// Picks up calendar access granted or revoked in System Settings right away (also used by the menu).
    @discardableResult
    func checkAuthorizationChange() -> EKAuthorizationStatus {
        let authorization = calendar.authorization
        if authorization != lastAuthorization { requestSelfCheck(force: true) }
        return authorization
    }

    private func currentCalendars() -> [EKCalendar] {
        checkAuthorizationChange() == .fullAccess ? calendar.eventCalendars() : []
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
            invalidateNotificationStatus()
            Task {
                await attention.requestNotificationPermission()
                await runSelfCheck()
            }
        case .openNotificationSettings:
            let id = Bundle.main.bundleIdentifier ?? appID
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
            invalidateNotificationStatus()
            updateCurtainLiveness()
            requestSelfCheck()
            // The network is often not back yet right after wake, so ask once more a bit later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                MainActor.assumeIsolated { self?.calendar.requestSync() }
            }
        case .unlocked, .sessionActive, .screensDidWake:
            // Calendar changes keep arriving while locked, so the data is current; no fetch needed.
            updateCurtainLiveness()
            evaluate()
        case .screensDidSleep:
            updateCurtainLiveness()
        case .locked:
            updateCurtainLiveness()
            // The screen locked while a curtain was up (e.g. you walked away): put it on the lock screen too.
            if curtain.isVisible, prefs.lockScreenAlerts { attention.notify(curtain.meetings) }
        case .willSleep:
            break
        case .clockChanged:
            // After the clock is set back, the routine check must not wait for the old wall-clock time.
            nextRoutine = min(nextRoutine, Date().addingTimeInterval(Self.routineInterval))
            scheduleRefresh()
        case .screensChanged:
            curtain.rebuildForCurrentScreens()
        }
    }

    private func updateCurtainLiveness() {
        curtain.setLive(!(systemEvents.map { $0.isScreenLocked || $0.areScreensAsleep } ?? false))
    }

    /// Calendar syncs often post several change notifications in a burst; handle them once.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.calendarStoreChanged() }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Accounts or calendars added, removed or re-enabled show up only here; re-run the self-check for
    /// those right away instead of at the next routine run.
    private func calendarStoreChanged() {
        let calendars = currentCalendars()
        if Set(calendars.map(\.calendarIdentifier)) != knownCalendars {
            requestSelfCheck(force: true)
        } else {
            refresh(reason: "calendar changed", calendars: calendars)
        }
    }

    func preferencesChanged(_ key: Preferences.Key) {
        switch key {
        case .calendarChoices:
            requestSelfCheck(force: true)
        case .leadMinutes, .includeAllDay, .skipDeclined:
            evaluate()
        case .playSound, .soundName:
            if prefs.playSound { attention.play(prefs.soundName) }
            requestSelfCheck(force: true)
        case .lockScreenAlerts:
            invalidateNotificationStatus()
            Task {
                if prefs.lockScreenAlerts { await attention.requestNotificationPermission() }
                await runSelfCheck()
            }
        case .launchAtLogin:
            // A copy in a build folder never registers itself; unregistering is always fine.
            if !prefs.launchAtLogin || LoginItem.isInstalledInApplications {
                LoginItem.apply(enabled: prefs.launchAtLogin)
            }
            requestSelfCheck(force: true)
        }
    }

    // MARK: Curtain actions

    /// Opens the call and closes the curtain. Other meetings that were on the curtain come back at their
    /// own start time instead of being dismissed along with it.
    func join(_ meeting: Meeting) {
        if let url = meeting.joinURL { NSWorkspace.shared.open(url) }
        let now = Date()
        for other in curtain.meetings where other.id != meeting.id {
            state.snooze(other, until: max(other.start, now.addingTimeInterval(Self.snoozeDuration)))
            announced.remove(other.id)
        }
        close(dismissing: [meeting])
    }

    /// Opens the call from the menu. Shortly before or during the meeting that counts as joining, so its
    /// curtain doesn't cover the call; opening a link hours ahead leaves the reminder in place.
    func openFromMenu(_ meeting: Meeting) {
        guard let url = meeting.joinURL else { return }
        guard meeting.start.timeIntervalSinceNow <= max(prefs.policy.leadTime, 15 * 60) else {
            NSWorkspace.shared.open(url)
            return
        }
        if curtain.meetings.contains(where: { $0.id == meeting.id }) {
            join(meeting)
        } else {
            NSWorkspace.shared.open(url)
            state.dismiss(meeting)
            saveDismissed()
            evaluate()
        }
    }

    func snoozeVisible() {
        let visible = curtain.meetings
        let until = Date().addingTimeInterval(Self.snoozeDuration)
        for meeting in visible {
            state.snooze(meeting, until: until)
            announced.remove(meeting.id)
        }
        close(dismissing: [])
    }

    func dismissVisible() {
        close(dismissing: curtain.meetings)
    }

    private func close(dismissing dismissed: [Meeting]) {
        for meeting in dismissed where meeting.id != testMeeting?.id {
            state.dismiss(meeting)
        }
        if let test = testMeeting, dismissed.contains(where: { $0.id == test.id }) { testMeeting = nil }
        saveDismissed()
        attention.clearNotifications(for: curtain.meetings.map(\.id))
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
        // Tolerate a stray non-number value instead of losing every dismissal.
        let raw = UserDefaults.standard.dictionary(forKey: dismissedKey) ?? [:]
        return raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func saveDismissed() {
        UserDefaults.standard.set(state.dismissed.mapValues(\.timeIntervalSince1970), forKey: Self.dismissedKey)
    }
}
