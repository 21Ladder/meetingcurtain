// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)

    // macOS icon grid: the rounded square fills about 80% of the canvas.
    let tile = NSRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
    let shape = NSBezierPath(roundedRect: tile, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(colors: [
        NSColor(srgbRed: 0.36, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.16, blue: 0.42, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Two curtain drapes, tied back to the sides, and a valance across the top.
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    for mirrored in [false, true] {
        let drape = NSBezierPath()
        let x0 = tile.minX, top = tile.maxY, bottom = tile.minY
        let tieY = tile.minY + tile.height * 0.42
        drape.move(to: NSPoint(x: x0, y: top))
        drape.line(to: NSPoint(x: tile.midX - size * 0.04, y: top))
        drape.curve(to: NSPoint(x: x0 + size * 0.13, y: tieY),
                    controlPoint1: NSPoint(x: tile.midX - size * 0.10, y: top - size * 0.22),
                    controlPoint2: NSPoint(x: x0 + size * 0.16, y: tieY + size * 0.14))
        drape.curve(to: NSPoint(x: x0 + size * 0.17, y: bottom),
                    controlPoint1: NSPoint(x: x0 + size * 0.10, y: tieY - size * 0.08),
                    controlPoint2: NSPoint(x: x0 + size * 0.16, y: bottom + size * 0.10))
        drape.line(to: NSPoint(x: x0, y: bottom))
        drape.close()
        if mirrored {
            var flip = AffineTransform(translationByX: size, byY: 0)
            flip.scale(x: -1, y: 1)
            drape.transform(using: flip)
        }
        NSColor(srgbRed: 0.93, green: 0.30, blue: 0.36, alpha: 1).setFill()
        drape.fill()
    }
    NSColor(srgbRed: 0.72, green: 0.16, blue: 0.24, alpha: 1).setFill()
    NSRect(x: tile.minX, y: tile.maxY - size * 0.09, width: tile.width, height: size * 0.09).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Clock face in the gap between the drapes.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.26, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let clock = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = clock.size
        clock.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - size * 0.02, width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
