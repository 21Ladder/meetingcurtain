import Foundation
import Testing
@testable import MeetingCurtainCore

@Suite struct MeetingLinksTests {
    private func link(url: String? = nil, location: String? = nil, notes: String? = nil) -> String? {
        MeetingLinks.joinURL(url: url.flatMap(URL.init(string:)), location: location, notes: notes)?.absoluteString
    }

    @Test func googleMeetInGoogleDescriptionBlock() {
        let notes = """
        Agenda: roadmap

        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        Join with Google Meet: https://meet.google.com/abc-defg-hij
        Or dial: (US) +1 555-0100 PIN: 123456#
        Learn more about Meet at: https://support.google.com/a/users/answer/9282720
        """
        #expect(link(notes: notes) == "https://meet.google.com/abc-defg-hij")
    }

    @Test func meetLinkWithoutScheme() {
        #expect(link(location: "meet.google.com/abc-defg-hij")?.hasSuffix("meet.google.com/abc-defg-hij") == true)
    }

    @Test func googleRedirectIsUnwrapped() {
        let notes = "Join: https://www.google.com/url?q=https%3A%2F%2Fus02web.zoom.us%2Fj%2F123456789%3Fpwd%3Dabc&sa=D"
        #expect(link(notes: notes) == "https://us02web.zoom.us/j/123456789?pwd=abc")
    }

    @Test func zoomVariants() {
        #expect(link(notes: "https://us06web.zoom.us/j/81234567890?pwd=xyz") != nil)
        #expect(link(notes: "https://zoom.us/my/someone") != nil)
        #expect(link(notes: "Download Zoom at https://zoom.us/download") == nil)
    }

    @Test func teamsAndWebex() {
        #expect(link(notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x") != nil)
        #expect(link(notes: "https://teams.microsoft.com/meet/123456?p=abc") != nil)
        #expect(link(notes: "https://acme.webex.com/meet/jane") != nil)
        #expect(link(notes: "https://acme.webex.com/acme/j.php?MTID=m123") != nil)
    }

    @Test func urlFieldWinsOverNotes() {
        #expect(link(url: "https://meet.google.com/aaa-bbbb-ccc", notes: "https://zoom.us/j/1") == "https://meet.google.com/aaa-bbbb-ccc")
    }

    @Test func nonMeetingURLFieldFallsBackToNotes() {
        #expect(link(url: "https://docs.google.com/document/d/1", notes: "https://zoom.us/j/1") == "https://zoom.us/j/1")
    }

    @Test func locationBeforeNotes() {
        #expect(link(location: "https://zoom.us/j/2", notes: "https://meet.google.com/aaa-bbbb-ccc") == "https://zoom.us/j/2")
    }

    @Test func ignoresUnrelatedLinks() {
        #expect(link(location: "Room 4.12", notes: "Docs: https://example.com/agenda https://meet.google.com/") == nil)
        #expect(link() == nil)
    }

    @Test func serviceNames() {
        let names = [
            "https://meet.google.com/abc-defg-hij": "Google Meet",
            "https://us02web.zoom.us/j/1": "Zoom",
            "zoommtg://zoom.us/join?confno=1": "Zoom",
            "https://teams.microsoft.com/l/meetup-join/x": "Teams",
            "https://acme.webex.com/meet/jane": "Webex",
            "https://meet.jit.si/room": "Meeting",
        ]
        for (link, name) in names {
            #expect(MeetingLinks.serviceName(for: URL(string: link)!) == name)
        }
    }

    @Test func nativeSchemes() {
        #expect(link(url: "zoommtg://zoom.us/join?confno=123") == "zoommtg://zoom.us/join?confno=123")
    }
}
