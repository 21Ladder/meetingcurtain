import Foundation
import Testing
@testable import MeetingCurtainCore

@Suite struct CalendarSelectionTests {
    let own = CalendarInfo(id: "1", title: "me@example.com", account: "Google")
    let colleague = CalendarInfo(id: "2", title: "Alex", account: "Google", isWritable: false)
    let holidays = CalendarInfo(id: "3", title: "Holidays in Austria", account: "Google", isWritable: false)
    let webcal = CalendarInfo(id: "4", title: "F1", account: "Subscribed", isFeed: true, isSubscribed: true, isWritable: false)
    let birthdays = CalendarInfo(id: "5", title: "Birthdays", account: "Other", isFeed: true, isWritable: false)
    let delegated = CalendarInfo(id: "6", title: "Boss", account: "boss@example.com", isDelegate: true)

    @Test func defaultsToYourOwnCalendars() {
        let selection = CalendarSelection()
        #expect(selection.includes(own))
        for other in [colleague, holidays, webcal, birthdays, delegated] { #expect(!selection.includes(other)) }
    }

    @Test func choicesOverrideDefaults() {
        var selection = CalendarSelection()
        selection.set(true, for: colleague)
        selection.set(false, for: own)
        #expect(selection.includes(colleague))
        #expect(!selection.includes(own))
    }

    @Test func choiceSurvivesNewCalendarIdentifier() {
        var selection = CalendarSelection()
        selection.set(false, for: own)
        var resynced = own
        resynced.id = "1-after-full-sync"
        #expect(!selection.includes(resynced))
    }
}
