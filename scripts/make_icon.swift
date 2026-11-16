// Draws the placeholder app icon: a round table seen from above with three seats,
// on a warm gradient. Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let background = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [
        NSColor(red: 0.98, green: 0.62, blue: 0.29, alpha: 1),
        NSColor(red: 0.84, green: 0.27, blue: 0.27, alpha: 1),
    ])?.draw(in: background, angle: -90)

    let center = NSPoint(x: size / 2, y: size / 2)
    // Seats around the table.
    NSColor.white.withAlphaComponent(0.9).setFill()
    for index in 0..<3 {
        let angle = CGFloat(index) * 2 * .pi / 3 + .pi / 2
        let radius: CGFloat = 270 * s
        let seat = NSRect(
            x: center.x + cos(angle) * radius - 62 * s, y: center.y + sin(angle) * radius - 62 * s,
            width: 124 * s, height: 124 * s
        )
        NSBezierPath(ovalIn: seat).fill()
    }
    // The table.
    let table = NSRect(x: center.x - 165 * s, y: center.y - 165 * s, width: 330 * s, height: 330 * s)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: table).fill()
    // A small waveform on the table.
    let wave = NSBezierPath()
    wave.lineWidth = 18 * s
    wave.lineCapStyle = .round
    let heights: [CGFloat] = [40, 90, 140, 90, 120, 60, 30]
    for (i, h) in heights.enumerated() {
        let x = center.x + (CGFloat(i) - 3) * 38 * s
        wave.move(to: NSPoint(x: x, y: center.y - h * s / 2))
        wave.line(to: NSPoint(x: x, y: center.y + h * s / 2))
    }
    NSColor(red: 0.84, green: 0.33, blue: 0.27, alpha: 1).setStroke()
    wave.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = draw(size: CGFloat(base * scale)) {
            try data.write(to: output.appendingPathComponent(name))
        }
    }
}
