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

    /// Event occurrences overlapping the range, soonest first. Cancelled events are left out.
    func meetings(from start: Date, to end: Date) -> [Meeting] {
        guard hasAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .compactMap(Meeting.init(event:))
            .sorted { $0.start < $1.start }
    }

    var calendarCount: Int { hasAccess ? store.calendars(for: .event).count : 0 }

    /// Online accounts (Google, Exchange, other CalDAV) with their number of event calendars. iCloud and
    /// on-my-Mac calendars are not counted, so an empty result means the Google account is not synced.
    func onlineAccounts() -> [Account] {
        guard hasAccess else { return [] }
        var counts: [String: Int] = [:]
        for calendar in store.calendars(for: .event) {
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
    init?(event: EKEvent) {
        guard event.status != .canceled, let start = event.startDate, let end = event.endDate else { return nil }
        let eventID = event.eventIdentifier ?? event.calendarItemIdentifier
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        self.init(
            id: Meeting.occurrenceID(eventID: eventID, start: start),
            title: title.isEmpty ? "Untitled event" : title,
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            isDeclined: declined,
            calendarTitle: event.calendar?.title ?? "",
            color: CalendarColor(event.calendar?.color),
            location: location.isEmpty ? nil : location,
            joinURL: MeetingLinks.joinURL(url: event.url, location: event.location, notes: event.notes)
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
