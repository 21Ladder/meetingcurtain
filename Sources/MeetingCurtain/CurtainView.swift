import SwiftUI
import MeetingCurtainCore

@MainActor @Observable
final class CurtainModel {
    var meetings: [Meeting] = []
    /// False for a moment after the curtain appears; see `CurtainController.inputGuard`.
    var acceptsInput = true
    /// False while the display sleeps or the screen is locked; the countdown then stops ticking.
    var isLive = true
    @ObservationIgnored var onJoin: @MainActor (Meeting) -> Void = { _ in }
    @ObservationIgnored var onSnooze: @MainActor () -> Void = {}
    @ObservationIgnored var onDismiss: @MainActor () -> Void = {}
}

/// The full-screen reminder. Everything is sized from the display height so it reads the same on a
/// 13" laptop and a large external monitor.
struct CurtainView: View {
    let model: CurtainModel

    var body: some View {
        GeometryReader { proxy in
            let scale = min(max(min(proxy.size.height / 1000, proxy.size.width / 1500), 0.6), 1.6)
            if let primary = model.meetings.first {
                CurtainContent(primary: primary, others: Array(model.meetings.dropFirst()), model: model, scale: scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .background(Color(red: 0.035, green: 0.035, blue: 0.05))
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

private struct CurtainContent: View {
    let primary: Meeting
    let others: [Meeting]
    let model: CurtainModel
    let scale: CGFloat

    private var accent: Color { Color(primary.color) }

    var body: some View {
        ZStack {
            EllipticalGradient(
                colors: [accent.opacity(0.55), accent.opacity(0.12), .clear],
                center: .top, startRadiusFraction: 0, endRadiusFraction: 0.85
            )
            VStack(spacing: 0) {
                accent.frame(height: 6 * scale)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                header
                Text(primary.title)
                    .font(.system(size: 76 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 20 * scale)
                details
                    .padding(.top, 18 * scale)
                Countdown(meeting: primary, isLive: model.isLive, scale: scale)
                    .padding(.top, 40 * scale)
                actions
                    .padding(.top, 48 * scale)
                    .disabled(!model.acceptsInput)
                if !others.isEmpty {
                    othersList
                        .padding(.top, 44 * scale)
                        .disabled(!model.acceptsInput)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 64 * scale)
            .padding(.vertical, 48 * scale)
            .frame(maxWidth: 1300 * scale)
        }
    }

    private var header: some View {
        HStack(spacing: 10 * scale) {
            Circle().fill(accent).frame(width: 12 * scale, height: 12 * scale)
            Text(primary.calendarTitle.isEmpty ? "MEETING" : primary.calendarTitle.uppercased())
        }
        .font(.system(size: 17 * scale, weight: .semibold))
        .tracking(3 * scale)
        .foregroundStyle(.white.opacity(0.7))
    }

    private var details: some View {
        HStack(spacing: 28 * scale) {
            Label(timeRange(primary), systemImage: "clock")
            if let location = displayLocation(primary) {
                Label(location, systemImage: "mappin.and.ellipse").lineLimit(1)
            }
            if others.count > 0 {
                Label("+\(others.count) more", systemImage: "calendar")
            }
        }
        .font(.system(size: 22 * scale, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
    }

    private var actions: some View {
        HStack(spacing: 18 * scale) {
            if let url = primary.joinURL {
                Button { model.onJoin(primary) } label: {
                    ButtonLabel(title: "Join \(MeetingLinks.serviceName(for: url))", symbol: "video.fill", key: "return", scale: scale)
                }
                .buttonStyle(CurtainButtonStyle(fill: accent, darkText: primary.color.prefersDarkText, scale: scale))
                .keyboardShortcut(.defaultAction)
            }
            Button { model.onSnooze() } label: {
                ButtonLabel(title: "Snooze 1 min", symbol: "clock.arrow.circlepath", key: "S", scale: scale)
            }
            .buttonStyle(CurtainButtonStyle(fill: .white.opacity(0.14), darkText: false, scale: scale))
            .keyboardShortcut("s", modifiers: [])
            Button { model.onDismiss() } label: {
                ButtonLabel(title: others.isEmpty ? "Dismiss" : "Dismiss all", symbol: "xmark", key: "esc", scale: scale)
            }
            .buttonStyle(CurtainButtonStyle(fill: .white.opacity(0.14), darkText: false, scale: scale))
            .keyboardShortcut(.cancelAction)
        }
    }

    private var othersList: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            Text("ALSO STARTING SOON")
                .font(.system(size: 14 * scale, weight: .semibold))
                .tracking(2.5 * scale)
                .foregroundStyle(.white.opacity(0.55))
            ForEach(others.prefix(3)) { meeting in
                HStack(spacing: 14 * scale) {
                    Circle().fill(Color(meeting.color)).frame(width: 10 * scale, height: 10 * scale)
                    Text(meeting.title)
                        .font(.system(size: 22 * scale, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 12 * scale)
                    Text(timeRange(meeting))
                        .font(.system(size: 18 * scale, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                    if let url = meeting.joinURL {
                        Button("Join \(MeetingLinks.serviceName(for: url))") { model.onJoin(meeting) }
                            .buttonStyle(CurtainButtonStyle(fill: Color(meeting.color), darkText: meeting.color.prefersDarkText,
                                                            scale: scale * 0.7))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20 * scale)
                .padding(.vertical, 14 * scale)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16 * scale))
            }
        }
        .frame(maxWidth: 820 * scale)
    }

    private func timeRange(_ meeting: Meeting) -> String {
        if meeting.isAllDay { return "All day" }
        let start = meeting.start.formatted(date: .omitted, time: .shortened)
        let end = meeting.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    /// The location, unless it only repeats the video link.
    private func displayLocation(_ meeting: Meeting) -> String? {
        guard let location = meeting.location, !location.contains("://") else { return nil }
        if let host = meeting.joinURL?.host, location.contains(host) { return nil }
        return location
    }
}

/// "Starts in 1:52" counting down, then "Started +0:12" counting up. The system updates the digits
/// itself; the body is re-evaluated only once, when the meeting starts.
private struct Countdown: View {
    let meeting: Meeting
    let isLive: Bool
    let scale: CGFloat
    @State private var reachedStartID: String?

    var body: some View {
        let now = Date()
        let started = reachedStartID == meeting.id || meeting.start <= now
        VStack(spacing: 4 * scale) {
            Text(meeting.isAllDay ? "ALL-DAY EVENT" : started ? "STARTED" : "STARTS IN")
                .font(.system(size: 18 * scale, weight: .semibold))
                .tracking(4 * scale)
                .foregroundStyle(.white.opacity(0.6))
            Group {
                if meeting.isAllDay {
                    Text("Today")
                } else if started {
                    // Stops at the meeting's end, so a curtain left up while you're away doesn't tick forever.
                    HStack(spacing: 0) {
                        Text("+")
                        Text(timerInterval: meeting.start...meeting.start.addingTimeInterval(86_400),
                             pauseTime: isLive ? max(meeting.end, now) : now, countsDown: false)
                    }
                } else {
                    Text(timerInterval: now...meeting.start, pauseTime: isLive ? nil : now, countsDown: true)
                }
            }
            .font(.system(size: 168 * scale, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(started && !meeting.isAllDay ? Color(red: 1, green: 0.45, blue: 0.40) : .white)
        }
        .task(id: meeting.id) {
            let wait = meeting.start.timeIntervalSinceNow
            guard wait > 0 else { return }
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { reachedStartID = meeting.id }
        }
    }
}

private struct ButtonLabel: View {
    let title: String
    let symbol: String
    let key: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 12 * scale) {
            Image(systemName: symbol)
            Text(title)
            Text(key)
                .font(.system(size: 13 * scale, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7 * scale)
                .padding(.vertical, 3 * scale)
                .overlay(RoundedRectangle(cornerRadius: 5 * scale).stroke(lineWidth: 1).opacity(0.5))
                .opacity(0.75)
        }
    }
}

private struct CurtainButtonStyle: ButtonStyle {
    let fill: Color
    let darkText: Bool
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22 * scale, weight: .semibold))
            .foregroundStyle(darkText ? Color.black : Color.white)
            .padding(.horizontal, 30 * scale)
            .padding(.vertical, 18 * scale)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

extension Color {
    init(_ rgb: CalendarColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
