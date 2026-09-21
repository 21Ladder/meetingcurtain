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
    public let isDeclined: Bool
    public let calendarTitle: String
    public let color: CalendarColor
    public let location: String?
    public let joinURL: URL?

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

    public static func occurrenceID(eventID: String, start: Date) -> String {
        "\(eventID)@\(Int64(start.timeIntervalSince1970.rounded()))"
    }
}
