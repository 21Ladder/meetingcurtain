import AppKit
@preconcurrency import EventKit
import MeetingCurtainCore

/// Reads events from macOS Calendar, which syncs the Google account set up in Internet Accounts.
@MainActor
final class CalendarService {
    struct Account: Equatable {
        var title: String
        var calendars: Int
    }

    let store = EKEventStore()
    /// Join links by occurrence and calendar, reused while the event is unmodified: scanning notes is the
    /// most expensive part of a refresh.
    private var linkCache: [String: (modified: Date, link: URL?)] = [:]

    var authorization: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    var hasAccess: Bool { authorization == .fullAccess }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            log.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Event occurrences in `calendars` overlapping the range, soonest first. Cancelled events are left
    /// out, and an event that appears in several calendars (e.g. your own and a shared one) is listed once.
    func meetings(from start: Date, to end: Date, in calendars: [EKCalendar]) -> [Meeting] {
        // Never pass an empty list: `nil` means every calendar.
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let localCalendar = Calendar.current
        var cache: [String: (modified: Date, link: URL?)] = [:]
        var copies: [(meeting: Meeting, isOwnCopy: Bool)] = []
        for event in store.events(matching: predicate) {
            guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { continue }
            let isAllDay = event.isAllDay || Meeting.coversWholeDays(start: start, end: end, calendar: localCalendar)
            let id = Meeting.occurrenceID(eventID: Self.stableID(of: event), start: start, isAllDay: isAllDay,
                                          calendar: localCalendar)
            // Per calendar: copies of one event in several calendars can carry different notes.
            let cacheKey = "\(id)|\(event.calendar?.calendarIdentifier ?? "")"
            let link: URL?
            if let modified = event.lastModifiedDate, let cached = linkCache[cacheKey], cached.modified == modified {
                link = cached.link
            } else {
                link = MeetingLinks.joinURL(url: event.url, location: event.location, notes: event.notes)
            }
            if let modified = event.lastModifiedDate { cache[cacheKey] = (modified, link) }
            // `isCurrentUser` only matches in the account that got the invitation.
            let me = event.attendees?.first(where: \.isCurrentUser)
            let meeting = Meeting(event: event, id: id, start: start, end: end, isAllDay: isAllDay,
                                  isDeclined: me?.participantStatus == .declined, joinURL: link)
            copies.append((meeting, me != nil))
        }
        linkCache = cache
        return Meeting.merged(copies)
    }

    /// The server's identifier survives syncs and calendar moves; `eventIdentifier` can change then.
    static func stableID(of event: EKEvent) -> String {
        if let id = event.calendarItemExternalIdentifier, !id.isEmpty { return id }
        if let id = event.eventIdentifier, !id.isEmpty { return id }
        return event.calendarItemIdentifier
    }

    func eventCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    /// Online accounts (Google, Exchange, other CalDAV) with their number of event calendars. iCloud and
    /// on-my-Mac calendars are not counted, so an empty result means the Google account is not connected.
    static func onlineAccounts(in calendars: [EKCalendar]) -> [Account] {
        var counts: [String: Int] = [:]
        for calendar in calendars {
            guard let source = calendar.source else { continue }
            let online = source.sourceType == .exchange
                || (source.sourceType == .calDAV && source.title.caseInsensitiveCompare("iCloud") != .orderedSame)
            if online { counts[source.title, default: 0] += 1 }
        }
        return counts.map { Account(title: $0.key, calendars: $0.value) }.sorted { $0.title < $1.title }
    }

    /// Asks macOS to sync remote calendars now instead of waiting for its next scheduled fetch.
    /// Changes arrive later through `.EKEventStoreChanged`.
    func requestSync() {
        guard hasAccess else { return }
        store.refreshSourcesIfNecessary()
    }

    /// Drops cached calendar data. Needed if access was granted while the store already existed.
    func reset() {
        store.reset()
    }
}

extension Meeting {
    init(event: EKEvent, id: String, start: Date, end: Date, isAllDay: Bool, isDeclined: Bool, joinURL: URL?) {
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            id: id,
            title: title.isEmpty ? "Untitled event" : title,
            start: start,
            end: end,
            isAllDay: isAllDay,
            isDeclined: isDeclined,
            calendarTitle: event.calendar?.title ?? "",
            color: CalendarColor(event.calendar?.color),
            location: location.isEmpty ? nil : location,
            joinURL: joinURL
        )
    }
}

extension CalendarColor {
    init(_ color: NSColor?) {
        guard let color = color?.usingColorSpace(.sRGB) else {
            self = .fallback
            return
        }
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }
}

extension CalendarInfo {
    init(_ calendar: EKCalendar) {
        self.init(id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "",
                  isFeed: calendar.type == .subscription || calendar.type == .birthday,
                  isSubscribed: calendar.isSubscribed, isWritable: calendar.allowsContentModifications,
                  isDelegate: calendar.source?.isDelegate ?? false)
    }
}

extension CalendarSelection {
    func includes(_ calendar: EKCalendar) -> Bool { includes(CalendarInfo(calendar)) }
}
