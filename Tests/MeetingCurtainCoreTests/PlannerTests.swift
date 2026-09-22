import Foundation
import Testing
@testable import MeetingCurtainCore

private let base = Date(timeIntervalSince1970: 1_790_000_000)
private func zone(_ id: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: id)!
    return calendar
}
private let utc = zone("UTC")

private func meeting(
    _ id: String,
    startsIn minutes: Double,
    length: Double = 30,
    allDay: Bool = false,
    declined: Bool = false
) -> Meeting {
    let start = base.addingTimeInterval(minutes * 60)
    return Meeting(
        id: id,
        title: id,
        start: start,
        end: start.addingTimeInterval(length * 60),
        isAllDay: allDay,
        isDeclined: declined
    )
}

private func plan(_ meetings: [Meeting], at offsetMinutes: Double = 0, policy: CurtainPolicy = .init(), state: ReminderState = .init()) -> Plan {
    Planner.plan(for: meetings, now: base.addingTimeInterval(offsetMinutes * 60), policy: policy, state: state, calendar: utc)
}

@Suite struct PlannerTests {
    @Test func notDueBeforeLeadTime() {
        let result = plan([meeting("a", startsIn: 10)])
        #expect(result.due.isEmpty)
        #expect(result.next?.meeting.id == "a")
        #expect(result.next?.date == base.addingTimeInterval(8 * 60))
    }

    @Test func dueInsideLeadTime() {
        let result = plan([meeting("a", startsIn: 2)])
        #expect(result.due.map(\.id) == ["a"])
        #expect(result.next == nil)
    }

    @Test func dueExactlyAtOpening() {
        #expect(plan([meeting("a", startsIn: 2)], at: 0).due.count == 1)
        #expect(plan([meeting("a", startsIn: 2)], at: -0.01).due.isEmpty)
    }

    @Test func leadTimeIsConfigurable() {
        let policy = CurtainPolicy(leadTime: 5 * 60)
        #expect(plan([meeting("a", startsIn: 4)], policy: policy).due.count == 1)
        #expect(plan([meeting("a", startsIn: 6)], policy: policy).next?.date == base.addingTimeInterval(60))
    }

    @Test func zeroLeadTimeShowsAtStart() {
        let policy = CurtainPolicy(leadTime: 0)
        #expect(plan([meeting("a", startsIn: 1)], policy: policy).due.isEmpty)
        #expect(plan([meeting("a", startsIn: 0)], policy: policy).due.count == 1)
    }

    @Test func stillAnnouncedAfterStart() {
        // e.g. the lid was opened twelve minutes into an hour-long meeting.
        #expect(plan([meeting("a", startsIn: -12, length: 60)]).due.count == 1)
    }

    @Test func notAnnouncedLongAfterStart() {
        let result = plan([meeting("a", startsIn: -31, length: 60)])
        #expect(result.due.isEmpty)
        #expect(result.next == nil)
    }

    @Test func shortMeetingStopsAtItsEnd() {
        #expect(plan([meeting("a", startsIn: -6, length: 5)]).due.isEmpty)
    }

    @Test func dismissedMeetingIsNeverShown() {
        let a = meeting("a", startsIn: 1)
        var state = ReminderState()
        state.dismiss(a)
        let result = plan([a], state: state)
        #expect(result.due.isEmpty)
        #expect(result.next == nil)
    }

    @Test func snoozedMeetingReturnsAfterSnooze() {
        let a = meeting("a", startsIn: 1)
        var state = ReminderState()
        state.snooze(a, until: base.addingTimeInterval(60))
        let now = plan([a], state: state)
        #expect(now.due.isEmpty)
        #expect(now.next?.date == base.addingTimeInterval(60))
        #expect(plan([a], at: 1, state: state).due.count == 1)
    }

    @Test func snoozeWorksPastLateGrace() {
        let a = meeting("a", startsIn: -29, length: 60)
        var state = ReminderState()
        state.snooze(a, until: base.addingTimeInterval(60))
        #expect(plan([a], at: 1.5, state: state).due.count == 1)
    }

    @Test func overlappingMeetingsAreAllDueSoonestFirst() {
        let result = plan([meeting("later", startsIn: 2), meeting("sooner", startsIn: 1), meeting("far", startsIn: 30)])
        #expect(result.due.map(\.id) == ["sooner", "later"])
        #expect(result.next?.meeting.id == "far")
    }

    @Test func nextPicksEarliestOpening() {
        let result = plan([meeting("c", startsIn: 60), meeting("b", startsIn: 20), meeting("d", startsIn: 40)])
        #expect(result.next?.meeting.id == "b")
    }

    @Test func declinedMeetingsIncludedByDefault() {
        let declined = meeting("a", startsIn: 1, declined: true)
        #expect(plan([declined]).due.count == 1)
        #expect(plan([declined], policy: CurtainPolicy(skipDeclined: true)).due.isEmpty)
    }

    @Test func allDayEventsExcludedByDefault() {
        let day = utc.startOfDay(for: base)
        let holiday = Meeting(id: "h", title: "Holiday", start: day, end: day.addingTimeInterval(86_400), isAllDay: true)
        let nine = day.addingTimeInterval(9 * 3600)
        let excluded = Planner.plan(for: [holiday], now: nine, policy: .init(), state: .init(), calendar: utc)
        #expect(excluded.due.isEmpty && excluded.next == nil)
    }

    @Test func includedAllDayEventsAnnouncedAtNine() {
        let day = utc.startOfDay(for: base)
        let holiday = Meeting(id: "h", title: "Holiday", start: day, end: day.addingTimeInterval(86_400), isAllDay: true)
        let policy = CurtainPolicy(includeAllDay: true)
        let early = Planner.plan(for: [holiday], now: day.addingTimeInterval(3600), policy: policy, state: .init(), calendar: utc)
        #expect(early.due.isEmpty)
        #expect(early.next?.date == day.addingTimeInterval(9 * 3600))
        let afternoon = Planner.plan(for: [holiday], now: day.addingTimeInterval(15 * 3600), policy: policy, state: .init(), calendar: utc)
        #expect(afternoon.due.count == 1)
    }

    @Test func dismissedMultiDayEventStaysDismissed() {
        let day = utc.startOfDay(for: base)
        let vacation = Meeting(id: "v", title: "Vacation", start: day, end: day.addingTimeInterval(5 * 86_400), isAllDay: true)
        var state = ReminderState()
        state.dismiss(vacation)
        let dayThree = day.addingTimeInterval(3 * 86_400 + 10 * 3600)
        state.prune(now: dayThree)
        let result = Planner.plan(for: [vacation], now: dayThree, policy: CurtainPolicy(includeAllDay: true), state: state, calendar: utc)
        #expect(result.due.isEmpty)
    }

    @Test func allDayHourIsClockTimeOnDaylightSavingDays() {
        let vienna = zone("Europe/Vienna")
        for date in ["2026-03-29", "2026-10-25"] {
            let day = vienna.date(from: DateComponents(year: Int(date.prefix(4)), month: Int(date.dropFirst(5).prefix(2)), day: Int(date.suffix(2))))!
            let event = Meeting(id: date, title: "DST", start: day, end: vienna.date(byAdding: .day, value: 1, to: day)!, isAllDay: true)
            let opens = Planner.window(for: event, policy: CurtainPolicy(includeAllDay: true), state: .init(), calendar: vienna).opens
            #expect(vienna.component(.hour, from: opens) == 9)
        }
    }

    @Test func zeroLengthEventsStillAnnounced() {
        #expect(plan([meeting("a", startsIn: 1, length: 0)]).due.count == 1)
        #expect(plan([meeting("a", startsIn: -3, length: 0)]).due.count == 1)
    }

    @Test func pruneDropsOldEntries() {
        var state = ReminderState()
        state.dismiss(meeting("old", startsIn: -3 * 24 * 60))
        state.dismiss(meeting("recent", startsIn: -60))
        let removed = state.prune(now: base)
        #expect(removed)
        #expect(state.dismissed.keys.sorted() == ["recent"])
        let removedAgain = state.prune(now: base)
        #expect(!removedAgain)
    }

    @Test func dismissClearsSnooze() {
        let a = meeting("a", startsIn: 1)
        var state = ReminderState()
        state.snooze(a, until: base.addingTimeInterval(60))
        state.dismiss(a)
        #expect(state.snoozedUntil.isEmpty)
    }

    @Test func occurrenceIDSeparatesRecurrences() {
        let first = Meeting.occurrenceID(eventID: "E", start: base)
        let second = Meeting.occurrenceID(eventID: "E", start: base.addingTimeInterval(86_400))
        #expect(first != second)
        #expect(first == Meeting.occurrenceID(eventID: "E", start: base.addingTimeInterval(0.2)))
    }
}

@Suite struct ColorTests {
    @Test func textContrast() {
        #expect(CalendarColor(red: 1, green: 0.85, blue: 0.2).prefersDarkText)
        #expect(!CalendarColor(red: 0.2, green: 0.3, blue: 0.8).prefersDarkText)
        #expect(!CalendarColor.fallback.prefersDarkText)
    }
}

@Suite struct TimeShapeTests {
    let vienna = zone("Europe/Vienna")
    var monday: Date { vienna.date(from: DateComponents(year: 2026, month: 9, day: 28))! }

    @Test func timedOutOfOfficeCoveringDaysCountsAsAllDay() {
        #expect(Meeting.coversWholeDays(start: monday, end: monday.addingTimeInterval(5 * 86_400), calendar: vienna))
        #expect(Meeting.coversWholeDays(start: monday, end: monday.addingTimeInterval(86_400 - 60), calendar: vienna))
        // Spring-forward day has 23 hours.
        let dst = vienna.date(from: DateComponents(year: 2026, month: 3, day: 29))!
        #expect(Meeting.coversWholeDays(start: dst, end: vienna.date(byAdding: .day, value: 1, to: dst)!, calendar: vienna))
    }

    @Test func realMeetingsAroundMidnightStayMeetings() {
        #expect(!Meeting.coversWholeDays(start: monday, end: monday.addingTimeInterval(30 * 60), calendar: vienna))
        #expect(!Meeting.coversWholeDays(start: monday.addingTimeInterval(-3600), end: monday.addingTimeInterval(3600), calendar: vienna))
        #expect(!Meeting.coversWholeDays(start: monday.addingTimeInterval(9 * 3600), end: monday.addingTimeInterval(3 * 86_400), calendar: vienna))
    }

    @Test func noMidnightCurtainForTimedOutOfOffice() {
        let end = monday.addingTimeInterval(5 * 86_400)
        let ooo = Meeting(id: "ooo", title: "Out of office", start: monday, end: end,
                          isAllDay: Meeting.coversWholeDays(start: monday, end: end, calendar: vienna))
        let sunday2358 = monday.addingTimeInterval(-120)
        let plan = Planner.plan(for: [ooo], now: sunday2358, policy: .init(), state: .init(), calendar: vienna)
        #expect(plan.due.isEmpty && plan.next == nil)
        let included = Planner.plan(for: [ooo], now: sunday2358, policy: CurtainPolicy(includeAllDay: true), state: .init(), calendar: vienna)
        #expect(included.next?.date == monday.addingTimeInterval(9 * 3600))
    }

    @Test func allDayIDSurvivesTimeZoneChange() {
        let newYork = zone("America/New_York")
        let inVienna = vienna.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let inNewYork = newYork.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let before = Meeting.occurrenceID(eventID: "VAC", start: inVienna, isAllDay: true, calendar: vienna)
        let after = Meeting.occurrenceID(eventID: "VAC", start: inNewYork, isAllDay: true, calendar: newYork)
        #expect(before == after)
        #expect(Meeting.occurrenceID(eventID: "E", start: inVienna) != Meeting.occurrenceID(eventID: "E", start: inNewYork))
    }

    @Test func mergedPrefersTheInvitedAccountAndKeepsDeclined() {
        let start = base.addingTimeInterval(600)
        let shared = Meeting(id: "m", title: "Sync", start: start, end: start.addingTimeInterval(1800), calendarTitle: "Team")
        var invited = Meeting(id: "m", title: "Sync", start: start, end: start.addingTimeInterval(1800), calendarTitle: "Me")
        invited.isDeclined = false
        var declinedCopy = shared
        declinedCopy.isDeclined = true
        declinedCopy.joinURL = URL(string: "https://meet.google.com/abc-defg-hij")
        let merged = Meeting.merged([(declinedCopy, false), (invited, true)])
        #expect(merged.count == 1)
        #expect(merged[0].calendarTitle == "Me")
        #expect(merged[0].isDeclined)
        #expect(merged[0].joinURL != nil)
    }

    @Test func mergedSortsAndKeepsDistinctMeetings() {
        let later = meeting("later", startsIn: 20), sooner = meeting("sooner", startsIn: 5)
        #expect(Meeting.merged([(later, false), (sooner, false)]).map(\.id) == ["sooner", "later"])
    }

    @Test func startAlertsOnlyForTimedMeetingsNotLongOver() {
        let policy = CurtainPolicy()
        let justStarted = meeting("now", startsIn: -1), upcoming = meeting("soon", startsIn: 1)
        let yesterday = meeting("old", startsIn: -24 * 60)
        let day = utc.startOfDay(for: base)
        let holiday = Meeting(id: "h", title: "Holiday", start: day, end: day.addingTimeInterval(86_400), isAllDay: true)
        let due = Planner.startAlerts(onScreen: [justStarted, upcoming, yesterday, holiday], now: base, policy: policy)
        #expect(due.map(\.id) == ["now"])
        #expect(Planner.nextStart(onScreen: [justStarted, upcoming, holiday], now: base) == upcoming.start)
    }
}
