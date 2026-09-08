import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let background = NSBezierPath(roundedRect: NSRect(x: p * 0.08, y: p * 0.08, width: p * 0.84, height: p * 0.84), xRadius: p * 0.2, yRadius: p * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.63, blue: 0.56, alpha: 1), ending: NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.4, alpha: 1))!.draw(in: background, angle: -60)
        let frame = NSBezierPath()
        for (x, y, sx, sy) in [(0.3, 0.7, 1.0, -1.0), (0.7, 0.7, -1.0, -1.0), (0.3, 0.3, 1.0, 1.0), (0.7, 0.3, -1.0, 1.0)] {
            frame.move(to: NSPoint(x: (x + sx * 0.13) * p, y: y * p))
            frame.line(to: NSPoint(x: x * p, y: y * p))
            frame.line(to: NSPoint(x: x * p, y: (y + sy * 0.13) * p))
        }
        frame.lineWidth = p * 0.055
        frame.lineCapStyle = .round
        frame.lineJoinStyle = .round
        NSColor.white.setStroke()
        frame.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
