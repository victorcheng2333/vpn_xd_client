// Generates AppIcon.icns: a gradient squircle with a white shield.
// Usage: swift Support/make-icon.swift Support/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    // macOS-style rounded square inset like Apple's template.
    let inset = size * 0.085
    let square = rect.insetBy(dx: inset, dy: inset)
    let radius = square.width * 0.225
    let path = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.30, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.80, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -65)

    // Soft highlight in the top-left.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    glow.draw(fromCenter: NSPoint(x: square.minX + square.width * 0.25, y: square.maxY - square.height * 0.15),
              radius: 0,
              toCenter: NSPoint(x: square.minX + square.width * 0.25, y: square.maxY - square.height * 0.15),
              radius: square.width * 0.9,
              options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Shield symbol, tinted white.
    let symbolSize = size * 0.50
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let symbolRect = NSRect(
        x: rect.midX - symbol.size.width / 2,
        y: rect.midY - symbol.size.height / 2,
        width: symbol.size.width,
        height: symbol.size.height
    )
    let tinted = NSImage(size: symbol.size, flipped: false) { dst in
        symbol.draw(in: dst)
        NSColor.white.set()
        dst.fill(using: .sourceAtop)
        return true
    }
    let symbolShadow = NSShadow()
    symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    symbolShadow.shadowBlurRadius = size * 0.02
    symbolShadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    NSGraphicsContext.saveGraphicsState()
    symbolShadow.set()
    tinted.draw(in: symbolRect)
    NSGraphicsContext.restoreGraphicsState()
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

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
exit(iconutil.terminationStatus)
