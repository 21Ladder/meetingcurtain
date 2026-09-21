import AppKit
import SwiftUI
import MeetingCurtainCore

/// Renders the curtain to a PNG for design review: `MeetingCurtain --render-curtain out.png [variant]`,
/// where variant is `single`, `started`, `multi` or `nolink`.
@MainActor
enum CurtainSnapshot {
    static func render(to url: URL, variant: String) {
        let now = Date()
        let blue = CalendarColor(red: 0.26, green: 0.52, blue: 0.96)
        var primary = Meeting(
            id: "a", title: "Weekly product sync", start: now.addingTimeInterval(112), end: now.addingTimeInterval(1912),
            calendarTitle: "Work", color: blue, location: "Room 4.12",
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )
        var meetings: [Meeting] = []
        switch variant {
        case "started":
            primary = Meeting(id: "a", title: primary.title, start: now.addingTimeInterval(-185), end: now.addingTimeInterval(1615),
                              calendarTitle: "Work", color: blue, joinURL: primary.joinURL)
        case "nolink":
            primary = Meeting(id: "a", title: "Dentist appointment with a rather long title that wraps onto a second line",
                              start: primary.start, end: primary.end, calendarTitle: "Personal",
                              color: CalendarColor(red: 0.98, green: 0.80, blue: 0.18), location: "Main Street 12")
        case "multi":
            meetings.append(Meeting(id: "b", title: "1:1 with Alex", start: now.addingTimeInterval(170), end: now.addingTimeInterval(1970),
                                    calendarTitle: "Work", color: CalendarColor(red: 0.20, green: 0.72, blue: 0.45),
                                    joinURL: URL(string: "https://us02web.zoom.us/j/123")))
        default:
            break
        }
        let model = CurtainModel()
        model.meetings = [primary] + meetings

        let renderer = ImageRenderer(content: CurtainView(model: model).frame(width: 1512, height: 982))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Rendering failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
