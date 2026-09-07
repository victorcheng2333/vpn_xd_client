import AppKit

// Same shield and power mark as scripts/icon.swift; iOS applies its own icon mask.
let target = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
func icon(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: s, y: s)
    let body = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSColor(srgbRed: 0.098, green: 0.176, blue: 0.153, alpha: 1).setFill(); body.fill()
    let mint = NSColor(srgbRed: 0.72, green: 0.9, blue: 0.79, alpha: 1)
    for radius in [280.0, 360.0] {
        mint.withAlphaComponent(0.12).setStroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: 512-radius, y: 512-radius, width: radius*2, height: radius*2))
        circle.lineWidth = 2; circle.stroke()
    }
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 760))
    shield.curve(to: NSPoint(x: 705, y: 682), controlPoint1: NSPoint(x: 565, y: 722), controlPoint2: NSPoint(x: 650, y: 690))
    shield.line(to: NSPoint(x: 705, y: 501))
    shield.curve(to: NSPoint(x: 512, y: 284), controlPoint1: NSPoint(x: 705, y: 388), controlPoint2: NSPoint(x: 583, y: 307))
    shield.curve(to: NSPoint(x: 319, y: 501), controlPoint1: NSPoint(x: 441, y: 307), controlPoint2: NSPoint(x: 319, y: 388))
    shield.line(to: NSPoint(x: 319, y: 682))
    shield.curve(to: NSPoint(x: 512, y: 760), controlPoint1: NSPoint(x: 374, y: 690), controlPoint2: NSPoint(x: 459, y: 722))
    shield.close(); mint.setStroke(); shield.lineWidth = 26; shield.lineJoinStyle = .round; shield.stroke()
    let arch = NSBezierPath()
    arch.appendArc(withCenter: NSPoint(x: 512, y: 529), radius: 94, startAngle: 135, endAngle: 405, clockwise: false)
    arch.lineWidth = 25; arch.lineCapStyle = .round; arch.stroke()
    let stem = NSBezierPath(); stem.move(to: NSPoint(x: 512, y: 662)); stem.line(to: NSPoint(x: 512, y: 546)); stem.lineWidth = 25; stem.lineCapStyle = .round; stem.stroke()
    NSGraphicsContext.restoreGraphicsState()
    // Flatten to an RGB image without an alpha channel for the App Store icon.
    let rgb = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    rgb.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: size, height: size))
    return NSBitmapImageRep(cgImage: rgb.makeImage()!).representation(using: .png, properties: [:])!
}
try icon(1024).write(to: URL(fileURLWithPath: "\(target)/AppIcon.png"))
