import Foundation

/// What the curtain needs to know about a calendar to decide whether its events count as "yours".
public struct CalendarInfo: Sendable {
    public var id: String
    public var title: String
    public var account: String
    /// A subscription or the Birthdays calendar, rather than a calendar of an account.
    public var isFeed: Bool
    public var isSubscribed: Bool
    public var isWritable: Bool
    public var isDelegate: Bool

    public init(id: String, title: String, account: String, isFeed: Bool = false,
                isSubscribed: Bool = false, isWritable: Bool = true, isDelegate: Bool = false) {
        self.id = id; self.title = title; self.account = account; self.isFeed = isFeed
        self.isSubscribed = isSubscribed; self.isWritable = isWritable; self.isDelegate = isDelegate
    }

    /// `calendarIdentifier` does not survive a full resync, so choices are also remembered by name.
    public var fallbackKey: String { "\(account)/\(title)" }
}

/// Which calendars produce curtains. EventKit returns every calendar, including ones hidden in
/// Calendar.app, colleagues' calendars, subscriptions and Birthdays.
public struct CalendarSelection: Sendable {
    /// Explicit choices, keyed by calendar id and by `fallbackKey`.
    public var choices: [String: Bool]

    public init(choices: [String: Bool] = [:]) { self.choices = choices }

    /// Your own calendars: ones you can write to, in your own accounts, that aren't feeds.
    public static func includedByDefault(_ calendar: CalendarInfo) -> Bool {
        !calendar.isFeed && calendar.isWritable && !calendar.isSubscribed && !calendar.isDelegate
    }

    public func includes(_ calendar: CalendarInfo) -> Bool {
        choices[calendar.id] ?? choices[calendar.fallbackKey] ?? Self.includedByDefault(calendar)
    }

    public mutating func set(_ included: Bool, for calendar: CalendarInfo) {
        choices[calendar.id] = included
        choices[calendar.fallbackKey] = included
    }
}
