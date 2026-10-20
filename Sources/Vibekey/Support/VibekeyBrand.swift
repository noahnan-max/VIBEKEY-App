import AppKit

/// Shared geometry for the app icon, sidebar and compact menu-bar mark.
enum VibekeyBrand {
    enum Variant { case primary, dots }

    static let primaryColor = NSColor(srgbRed: 89 / 255, green: 75 / 255, blue: 221 / 255, alpha: 1)
    static let symbol = image(size: 128, variant: .primary, color: .black, template: true)
    static let menuBarIdle = image(size: 18, variant: .dots, color: .black, template: true)

    static func path(in bounds: NSRect, variant: Variant) -> NSBezierPath {
        let side = min(bounds.width, bounds.height)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dotRadius = side * 0.126
        // A 3% optical margin; the eight circles occupy 94% of the canvas.
        let ringRadius = (side * 0.47 - dotRadius) / cos(.pi / 8)
        let path = NSBezierPath()
        for index in 0..<8 {
            let angle = .pi / 8 + CGFloat(index) * .pi / 4
            let dotCenter = NSPoint(x: center.x + cos(angle) * ringRadius,
                                    y: center.y + sin(angle) * ringRadius)
            path.appendOval(in: NSRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2))
        }
        switch variant {
        case .primary:
            let waveformScale: CGFloat = 1.2
            let barWidth = side * 0.034 * waveformScale
            let barStep = side * 0.046 * waveformScale
            for (index, height) in [0.07, 0.14, 0.212, 0.14, 0.07].enumerated() {
                let rect = NSRect(x: center.x + CGFloat(index - 2) * barStep - barWidth / 2,
                                  y: center.y - side * height * waveformScale / 2,
                                  width: barWidth, height: side * height * waveformScale)
                path.appendRoundedRect(rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            }
        case .dots:
            break
        }
        return path
    }

    static func image(size: CGFloat, variant: Variant, color: NSColor, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            color.setFill()
            path(in: bounds, variant: variant).fill()
            return true
        }
        image.isTemplate = template
        return image
    }
}
