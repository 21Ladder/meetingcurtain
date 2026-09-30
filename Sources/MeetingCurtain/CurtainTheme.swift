import SwiftUI

enum CurtainTheme: String, CaseIterable, Identifiable {
    case standard, orange

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .orange: "Orange"
        }
    }

    var palette: CurtainPalette {
        switch self {
        case .standard: .standard
        case .orange: .orange
        }
    }
}

struct CurtainPalette {
    var background: Color
    var colorScheme: ColorScheme
    var showsCalendarGlow: Bool
    var showsCalendarDot: Bool
    var usesThirds: Bool
    var countdownSize: CGFloat
    var text: Color
    var minimumSecondaryOpacity: Double
    var started: Color
    var joinFill: Color?
    var joinText: Color
    var buttonFill: Color
    var buttonText: Color
    var buttonStroke: Color?
    var cardFill: Color
    var waves: Color?
    var smiley: Color?

    func secondary(_ opacity: Double) -> Color {
        text.opacity(max(opacity, minimumSecondaryOpacity))
    }

    static let standard = CurtainPalette(
        background: Color(red: 0.035, green: 0.035, blue: 0.05),
        colorScheme: .dark,
        showsCalendarGlow: true,
        showsCalendarDot: true,
        usesThirds: false,
        countdownSize: 168,
        text: .white,
        minimumSecondaryOpacity: 0,
        started: Color(red: 1, green: 0.45, blue: 0.40),
        joinFill: nil,
        joinText: .white,
        buttonFill: .white.opacity(0.14),
        buttonText: .white,
        buttonStroke: nil,
        cardFill: .white.opacity(0.07),
        waves: nil,
        smiley: nil
    )

    private static let brown = Color(red: 0x2E / 255, green: 0x1A / 255, blue: 0)
    private static let cream = Color(red: 1, green: 0xE6 / 255, blue: 0xC6 / 255)

    static let orange = CurtainPalette(
        background: Color(red: 0xEE / 255, green: 0xA2 / 255, blue: 0x1B / 255),
        colorScheme: .light,
        showsCalendarGlow: false,
        showsCalendarDot: false,
        usesThirds: true,
        countdownSize: 132,
        text: brown,
        minimumSecondaryOpacity: 0.8,
        started: Color(red: 0x7A / 255, green: 0x15 / 255, blue: 0),
        joinFill: brown,
        joinText: cream,
        buttonFill: .clear,
        buttonText: brown,
        buttonStroke: brown.opacity(0.55),
        cardFill: cream.opacity(0.55),
        waves: cream.opacity(0.6),
        smiley: cream
    )
}

struct WaveLines: Shape {
    var count = 14

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        for i in 0..<count {
            let t = Double(i) / Double(count - 1) - 0.5
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * (0.84 + t * 0.14)))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + h * (0.76 + t * 0.04)),
                control1: CGPoint(x: rect.minX + w * 0.30, y: rect.minY + h * (0.68 + t * 0.10)),
                control2: CGPoint(x: rect.minX + w * 0.58, y: rect.minY + h * (0.94 + t * 0.07))
            )
        }
        return path
    }
}
