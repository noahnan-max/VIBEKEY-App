import AppKit
import SwiftUI

/// Shared Talkflow-inspired visual system for every VIBEKEY surface.
/// Light colors follow the observed 0.8.2 reference; dark colors are our own
/// accessible adaptation. Accent text and white-on-purple controls are distinct.
enum VIFLOWTheme {
    static let accentNSColor = adaptive("accent", light: 0x594BDD, dark: 0xB3A9FF)
    static let filledNSColor = adaptive("filled", light: 0x5146CD, dark: 0x7160DF)
    static let accentSoftNSColor = adaptive("accentSoft", light: 0xF6F6FC, dark: 0x2B2641)
    static let filledHoverNSColor = adaptive("filledHover", light: 0x493EC2, dark: 0x6655D4)
    static let filledPressedNSColor = adaptive("filledPressed", light: 0x4036AF, dark: 0x5B4BC4)
    static let canvasNSColor = adaptive("canvas", light: 0xFFFFFF, dark: 0x18181B)
    static let surfaceNSColor = adaptive("surface", light: 0xFFFFFF, dark: 0x212125)
    static let mutedNSColor = adaptive("muted", light: 0xF7F7F9, dark: 0x29292F)
    static let inkNSColor = adaptive("ink", light: 0x29292C, dark: 0xF5F5F7)
    static let secondaryNSColor = adaptive("secondary", light: 0x6E6E75, dark: 0xBFBFC8)
    static let borderNSColor = adaptive("border", light: 0xEEEEF2, dark: 0x383840)
    static let controlBorderNSColor = adaptive("controlBorder", light: 0xDCDCE5, dark: 0x50505A)
    static let errorNSColor = adaptive("error", light: 0xE5484D, dark: 0xFB7185)
    static let errorInkNSColor = adaptive("errorInk", light: 0xB42318, dark: 0xFB7185)
    static let errorSoftNSColor = adaptive("errorSoft", light: 0xFDECEC, dark: 0x4A1720)
    static let filledInkNSColor = adaptive("filledInk", light: 0xFFFFFF, dark: 0xFFFFFF)

    static var accent: Color { Color(nsColor: accentNSColor) }
    static var filled: Color { Color(nsColor: filledNSColor) }
    static var accentSoft: Color { Color(nsColor: accentSoftNSColor) }
    static var filledHover: Color { Color(nsColor: filledHoverNSColor) }
    static var filledPressed: Color { Color(nsColor: filledPressedNSColor) }
    static var canvas: Color { Color(nsColor: canvasNSColor) }
    static var surface: Color { Color(nsColor: surfaceNSColor) }
    static var muted: Color { Color(nsColor: mutedNSColor) }
    static var ink: Color { Color(nsColor: inkNSColor) }
    static var secondary: Color { Color(nsColor: secondaryNSColor) }
    static var border: Color { Color(nsColor: borderNSColor) }
    static var controlBorder: Color { Color(nsColor: controlBorderNSColor) }
    static var error: Color { Color(nsColor: errorNSColor) }
    static var errorInk: Color { Color(nsColor: errorInkNSColor) }
    static var errorSoft: Color { Color(nsColor: errorSoftNSColor) }
    static var filledInk: Color { Color(nsColor: filledInkNSColor) }

    static let controlRadius: CGFloat = 6
    static let panelRadius: CGFloat = 12
    // VIBEKEY's longer wordmark and device selector need more room than Talkflow.
    static let sidebarWidth: CGFloat = 224
    static var body: Font { font(13) }
    static var caption: Font { font(11.5) }
    static var title: Font { font(18, weight: .semibold) }
    static var subheading: Font { font(13, weight: .semibold) }

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: NSColor.Name("VIFLOW.\(name)")) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
