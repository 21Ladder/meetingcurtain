import Foundation

/// The user's rules for when a curtain appears.
public struct CurtainPolicy: Sendable, Equatable {
    /// How long before the start the curtain appears.
    public var leadTime: TimeInterval
    /// How long after the start a meeting is still announced, e.g. when the Mac wakes up late.
    public var lateGrace: TimeInterval
    public var includeAllDay: Bool
    public var skipDeclined: Bool
    /// All-day events have no start time, so when they are included they are announced at this hour.
    public var allDayHour: Int

    public init(
        leadTime: TimeInterval = 120,
        lateGrace: TimeInterval = 600,
        includeAllDay: Bool = false,
        skipDeclined: Bool = false,
        allDayHour: Int = 9
    ) {
        self.leadTime = leadTime
        self.lateGrace = lateGrace
        self.includeAllDay = includeAllDay
        self.skipDeclined = skipDeclined
        self.allDayHour = allDayHour
    }
}

/// What the user decided about individual meeting occurrences.
public struct ReminderState: Sendable, Equatable {
    /// Meeting id → meeting start, kept so old entries can be pruned.
    public private(set) var dismissed: [String: Date]
    public private(set) var snoozedUntil: [String: Date]

    public init(dismissed: [String: Date] = [:], snoozedUntil: [String: Date] = [:]) {
        self.dismissed = dismissed
        self.snoozedUntil = snoozedUntil
    }

    public func isDismissed(_ id: String) -> Bool { dismissed[id] != nil }

    public mutating func dismiss(_ meeting: Meeting) {
        dismissed[meeting.id] = meeting.start
        snoozedUntil[meeting.id] = nil
    }

    public mutating func snooze(_ meeting: Meeting, until date: Date) {
        snoozedUntil[meeting.id] = date
    }

    /// Drops entries for meetings that are long over. Returns whether anything was removed.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-2 * 86_400)
        let before = (dismissed.count, snoozedUntil.count)
        dismissed = dismissed.filter { $0.value > cutoff }
        snoozedUntil = snoozedUntil.filter { $0.value > cutoff }
        return before != (dismissed.count, snoozedUntil.count)
    }
}

public struct Plan: Sendable, Equatable {
    public struct Upcoming: Sendable, Equatable {
        public var meeting: Meeting
        public var date: Date
    }

    /// Meetings whose curtain should be on screen now, soonest first.
    public var due: [Meeting]
    /// The next meeting to become due, and when.
    public var next: Upcoming?

    public init(due: [Meeting] = [], next: Upcoming? = nil) {
        self.due = due
        self.next = next
    }
}

public enum Planner {
    public static func isEligible(_ meeting: Meeting, policy: CurtainPolicy) -> Bool {
        if meeting.isAllDay && !policy.includeAllDay { return false }
        if meeting.isDeclined && policy.skipDeclined { return false }
        return true
    }

    /// The span during which the meeting's curtain may be shown.
    public static func window(
        for meeting: Meeting,
        policy: CurtainPolicy,
        state: ReminderState,
        calendar: Calendar = .current
    ) -> (opens: Date, closes: Date) {
        var opens: Date
        var closes: Date
        let end: Date
        if meeting.isAllDay {
            // Announce once on the first day, from `allDayHour` until the event ends.
            let day = calendar.startOfDay(for: meeting.start)
            opens = calendar.date(byAdding: .hour, value: policy.allDayHour, to: day) ?? meeting.start
            end = meeting.end > opens ? meeting.end : opens.addingTimeInterval(policy.lateGrace)
            closes = end
        } else {
            opens = meeting.start.addingTimeInterval(-policy.leadTime)
            end = meeting.end > meeting.start ? meeting.end : meeting.start.addingTimeInterval(policy.lateGrace)
            closes = min(meeting.start.addingTimeInterval(policy.lateGrace), end)
        }
        if let snoozedUntil = state.snoozedUntil[meeting.id] {
            // A snoozed meeting keeps reminding until it ends, even past the late-grace period.
            opens = max(opens, snoozedUntil)
            closes = max(closes, end)
        }
        return (opens, closes)
    }

    public static func plan(
        for meetings: [Meeting],
        now: Date,
        policy: CurtainPolicy,
        state: ReminderState,
        calendar: Calendar = .current
    ) -> Plan {
        var due: [Meeting] = []
        var next: Plan.Upcoming?
        for meeting in meetings where isEligible(meeting, policy: policy) && !state.isDismissed(meeting.id) {
            let window = window(for: meeting, policy: policy, state: state, calendar: calendar)
            guard now < window.closes, window.opens < window.closes else { continue }
            if window.opens <= now {
                due.append(meeting)
            } else if next == nil || window.opens < next!.date {
                next = Plan.Upcoming(meeting: meeting, date: window.opens)
            }
        }
        due.sort { ($0.start, $0.title) < ($1.start, $1.title) }
        return Plan(due: due, next: next)
    }
}
