import Foundation

/// A calendar colour in sRGB, stored as plain numbers so `Meeting` stays `Sendable`.
public struct CalendarColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let fallback = CalendarColor(red: 0.30, green: 0.47, blue: 0.96)

    /// True when dark text reads better than white text on this colour (WCAG relative luminance).
    public var prefersDarkText: Bool {
        func linear(_ c: Double) -> Double {
            c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance > 0.45
    }
}

/// One occurrence of a calendar event, reduced to what the curtain needs.
public struct Meeting: Sendable, Hashable, Identifiable {
    /// Unique per occurrence. Recurring events share one event identifier, so the start time is part of it,
    /// which also means a moved meeting counts as a new occurrence and is announced again.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public var isDeclined: Bool
    public let calendarTitle: String
    public let color: CalendarColor
    public let location: String?
    public var joinURL: URL?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        isDeclined: Bool = false,
        calendarTitle: String = "",
        color: CalendarColor = .fallback,
        location: String? = nil,
        joinURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isDeclined = isDeclined
        self.calendarTitle = calendarTitle
        self.color = color
        self.location = location
        self.joinURL = joinURL
    }

    /// All-day starts are "local midnight", which moves when the Mac's time zone changes, so all-day
    /// occurrences are keyed by their calendar day to keep a dismissal across travel.
    public static func occurrenceID(eventID: String, start: Date, isAllDay: Bool = false, calendar: Calendar = .current) -> String {
        guard isAllDay else { return "\(eventID)@\(Int64(start.timeIntervalSince1970.rounded()))" }
        return "\(eventID)@\(start.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()))"
    }

    /// One meeting per id when the same event appears in several calendars or accounts. The copy from the
    /// account that got the invitation wins, since only there does "declined" reflect your answer, and a
    /// "declined" and a join link from any copy are kept. Soonest first.
    public static func merged(_ copies: [(meeting: Meeting, isOwnCopy: Bool)]) -> [Meeting] {
        var byID: [String: (meeting: Meeting, isOwnCopy: Bool)] = [:]
        for copy in copies {
            guard let existing = byID[copy.meeting.id] else {
                byID[copy.meeting.id] = copy
                continue
            }
            var keep = copy.isOwnCopy && !existing.isOwnCopy ? copy.meeting : existing.meeting
            keep.isDeclined = existing.meeting.isDeclined || copy.meeting.isDeclined
            // A copy from a free/busy-only calendar has no notes, so no link; take it from another copy.
            keep.joinURL = keep.joinURL ?? existing.meeting.joinURL ?? copy.meeting.joinURL
            byID[copy.meeting.id] = (keep, existing.isOwnCopy || copy.isOwnCopy)
        }
        return byID.values.map(\.meeting).sorted { $0.start < $1.start }
    }

    /// A timed event that covers whole days, e.g. Google "Out of office" (which can't be all-day, so a
    /// day off arrives as 00:00 to 00:00). Treated like an all-day event instead of a meeting at midnight.
    public static func coversWholeDays(start: Date, end: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: start)
        guard start == day, let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return end >= next.addingTimeInterval(-60)   // also 00:00 to 23:59
    }
}
