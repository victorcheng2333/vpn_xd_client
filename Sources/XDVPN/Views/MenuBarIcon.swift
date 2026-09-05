import AppKit
import SwiftUI

/// Template (monochrome) menu bar glyphs drawn from the brand shield.
enum MenuBarIcon {
    enum Variant: Hashable { case outline, outlineDot, filledCheck, alert }

    static let size = NSSize(width: 18, height: 18)
    private static var cache: [Variant: NSImage] = [:]

    static func image(for status: VPNManager.Status, blink: Bool) -> NSImage {
        image(variant(for: status, blink: blink))
    }

    static func variant(for status: VPNManager.Status, blink: Bool) -> Variant {
        switch status {
        case .setupRequired, .disconnected: return .outline
        case .connected: return .filledCheck
        case .failed: return .alert
        case .connecting, .recovering, .disconnecting, .waitingToReconnect: return blink ? .outlineDot : .outline
        }
    }

    static func image(_ variant: Variant) -> NSImage {
        if let cached = cache[variant] { return cached }
        let image = NSImage(size: size, flipped: true) { rect in
            draw(variant, in: rect)
            return true
        }
        image.isTemplate = true
        cache[variant] = image
        return image
    }

    /// Shield occupies 14×16.5pt centred in the 18pt canvas.
    private static func draw(_ variant: Variant, in canvas: NSRect) {
        let w: CGFloat = 14, h: CGFloat = 16.5
        let rect = CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2 + 0.25, width: w, height: h)
        let stroke: CGFloat = 1.6
        let shield = NSBezierPath(cgPath: ShieldShape().path(in: rect).cgPath)
        NSColor.black.set()

        switch variant {
        case .outline, .outlineDot:
            let inner = NSBezierPath(cgPath: ShieldShape().path(in: rect.insetBy(dx: stroke / 2, dy: stroke / 2)).cgPath)
            inner.lineWidth = stroke
            inner.lineJoinStyle = .round
            inner.stroke()
            if variant == .outlineDot {
                let d: CGFloat = 4.2
                NSBezierPath(ovalIn: CGRect(x: rect.midX - d / 2, y: rect.minY + rect.height * 0.47 - d / 2, width: d, height: d)).fill()
            }
        case .filledCheck:
            shield.fill()
            let check = NSBezierPath(cgPath: CheckShape().path(in: rect.insetBy(dx: 1.2, dy: 1.6)).cgPath)
            check.lineWidth = 1.9
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            check.stroke()
        case .alert:
            shield.fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let bar = NSBezierPath(roundedRect: CGRect(x: rect.midX - 0.9, y: rect.minY + 4.2, width: 1.8, height: 5.2), xRadius: 0.9, yRadius: 0.9)
            bar.fill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - 1.05, y: rect.minY + 11, width: 2.1, height: 2.1)).fill()
        }
    }
}

/// Live menu bar label; blinks softly while a transition is in progress.
struct MenuBarLabel: View {
    private let vpn = VPNManager.shared

    var body: some View {
        if vpn.status.isBusy {
            TimelineView(.periodic(from: .now, by: 0.6)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                Image(nsImage: MenuBarIcon.image(for: vpn.status, blink: on))
            }
        } else {
            Image(nsImage: MenuBarIcon.image(for: vpn.status, blink: false))
        }
    }
}
