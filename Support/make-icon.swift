// Generates AppIcon.icns: deep-blue squircle, layered brand shield, check mark.
// Usage: swift Support/make-icon.swift Support/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Brand shield in y-up coordinates (same geometry as ShieldShape in the app).
func shieldPath(_ rect: NSRect) -> NSBezierPath {
    let p = NSBezierPath()
    let w = rect.width, h = rect.height
    let top = rect.maxY, bottom = rect.minY, left = rect.minX, right = rect.maxX, midX = rect.midX
    let r = w * 0.16
    p.move(to: NSPoint(x: left + r, y: top))
    p.line(to: NSPoint(x: right - r, y: top))
    p.curve(to: NSPoint(x: right, y: top - r), controlPoint1: NSPoint(x: right, y: top), controlPoint2: NSPoint(x: right, y: top))
    p.line(to: NSPoint(x: right, y: top - h * 0.50))
    p.curve(to: NSPoint(x: midX, y: bottom),
            controlPoint1: NSPoint(x: right, y: top - h * 0.80),
            controlPoint2: NSPoint(x: midX + w * 0.24, y: bottom + h * 0.05))
    p.curve(to: NSPoint(x: left, y: top - h * 0.50),
            controlPoint1: NSPoint(x: midX - w * 0.24, y: bottom + h * 0.05),
            controlPoint2: NSPoint(x: left, y: top - h * 0.80))
    p.line(to: NSPoint(x: left, y: top - r))
    p.curve(to: NSPoint(x: left + r, y: top), controlPoint1: NSPoint(x: left, y: top), controlPoint2: NSPoint(x: left, y: top))
    p.close()
    return p
}

func withShadow(color: NSColor, blur: CGFloat, offset: NSSize, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func clipped(to path: NSBezierPath, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func draw(size: CGFloat) {
    let k = size / 1024
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    // Squircle (Apple's 824pt grid inside the 1024 canvas): light, glassy.
    let square = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let squircle = NSBezierPath(roundedRect: square, xRadius: 184 * k, yRadius: 184 * k)

    withShadow(color: NSColor.black.withAlphaComponent(0.22), blur: 24 * k, offset: NSSize(width: 0, height: -10 * k)) {
        NSColor.white.setFill()
        squircle.fill()
    }
    NSGradient(colorsAndLocations:
        (rgb(0xFFFFFF), 0.0), (rgb(0xF4F6FA), 0.55), (rgb(0xE3E8F0), 1.0))!
        .draw(in: squircle, angle: -90)
    clipped(to: squircle) {
        // Soft light from the top-left and a faint cool wash at the bottom.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: NSPoint(x: 330 * k, y: 840 * k), radius: 0,
                  toCenter: NSPoint(x: 330 * k, y: 840 * k), radius: 640 * k, options: [])
        NSGradient(colors: [rgb(0x9FB6DA, 0.28), rgb(0x9FB6DA, 0)])!
            .draw(in: NSRect(x: square.minX, y: square.minY, width: square.width, height: square.height * 0.42), angle: 90)
    }
    // Hairline edge for definition on light backgrounds.
    let edge = NSBezierPath(roundedRect: square.insetBy(dx: 1.5 * k, dy: 1.5 * k), xRadius: 182 * k, yRadius: 182 * k)
    edge.lineWidth = 3 * k
    NSColor.black.withAlphaComponent(0.06).setStroke()
    edge.stroke()

    // Shield: blue gradient, glossy top, soft blue shadow.
    let shield = NSRect(x: 262 * k, y: 206 * k, width: 500 * k, height: 590 * k)
    let shieldPathOuter = shieldPath(shield)
    withShadow(color: rgb(0x1A4FD6, 0.35), blur: 36 * k, offset: NSSize(width: 0, height: -18 * k)) {
        rgb(0x2A6BF2).setFill()
        shieldPathOuter.fill()
    }
    NSGradient(colorsAndLocations: (rgb(0x62A8FF), 0.0), (rgb(0x2E71F5), 0.55), (rgb(0x1B4FD8), 1.0))!
        .draw(in: shieldPathOuter, angle: -90)
    clipped(to: shieldPathOuter) {
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])!
            .draw(in: NSRect(x: shield.minX, y: shield.maxY - shield.height * 0.48, width: shield.width, height: shield.height * 0.48), angle: -90)
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.16), NSColor.black.withAlphaComponent(0)])!
            .draw(in: NSRect(x: shield.minX, y: shield.minY, width: shield.width, height: shield.height * 0.4), angle: 90)
        // Inner rim highlight.
        let rim = shieldPath(shield.insetBy(dx: 5 * k, dy: 5 * k))
        rim.lineWidth = 8 * k
        NSColor.white.withAlphaComponent(0.22).setStroke()
        rim.stroke()
    }

    // Check mark.
    let box = NSRect(x: shield.minX + shield.width * 0.17, y: shield.minY + shield.height * 0.30,
                     width: shield.width * 0.66, height: shield.height * 0.48)
    let check = NSBezierPath()
    check.move(to: NSPoint(x: box.minX + box.width * 0.12, y: box.minY + box.height * 0.50))
    check.line(to: NSPoint(x: box.minX + box.width * 0.40, y: box.minY + box.height * 0.22))
    check.line(to: NSPoint(x: box.minX + box.width * 0.90, y: box.minY + box.height * 0.80))
    check.lineWidth = 54 * k
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    withShadow(color: rgb(0x0B2F8A, 0.35), blur: 12 * k, offset: NSSize(width: 0, height: -6 * k)) {
        NSColor.white.setStroke()
        check.stroke()
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    try png(pixels: pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}
// Keep a 256px preview next to the icns for quick inspection.
try png(pixels: 256).write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
exit(iconutil.terminationStatus)
