import AppKit

/// Colours of the line. Core Animation layers do not follow appearance changes on their own,
/// so the canvas asks for a new palette whenever the system switches between light and dark.
struct LinePalette {
    var paper: CGColor
    var cardBorder: CGColor
    var placeholder: CGColor
    var rope: CGColor
    var ropeTwist: CGColor
    var hook: CGColor
    var hookRim: CGColor
    var spring: CGColor
    var springEdge: CGColor
    var pinHighlight: CGColor
    var pins: [CGColor]
    var cardShadowOpacity: Float
    var pinShadowOpacity: Float

    static func make(dark: Bool) -> LinePalette {
        func c(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        if dark {
            return LinePalette(
                paper: c(0xD9D5CF), cardBorder: c(0xFFFFFF, 0.08), placeholder: c(0x3A3836),
                rope: c(0xA59C92), ropeTwist: c(0x2A2724, 0.55),
                hook: c(0x8D857D), hookRim: c(0x000000, 0.35),
                spring: c(0x9A9DA3), springEdge: c(0x000000, 0.35), pinHighlight: c(0xFFFFFF, 0.22),
                pins: [c(0x7F957B), c(0xB47A5D), c(0xBFA670), c(0x768DA3), c(0xA98897)],
                cardShadowOpacity: 0.55, pinShadowOpacity: 0.5)
        }
        return LinePalette(
            paper: c(0xFBFAF7), cardBorder: c(0x000000, 0.07), placeholder: c(0xE9E6E1),
            rope: c(0x8C8176), ropeTwist: c(0xFFFFFF, 0.5),
            hook: c(0x7A726A), hookRim: c(0x000000, 0.18),
            spring: c(0xB9BCC1), springEdge: c(0x000000, 0.22), pinHighlight: c(0xFFFFFF, 0.4),
            pins: [c(0x9DB09A), c(0xD29A7A), c(0xD9C089), c(0x8EA4B8), c(0xC7A4B4)],
            cardShadowOpacity: 0.22, pinShadowOpacity: 0.28)
    }

    static func current(for appearance: NSAppearance) -> LinePalette {
        make(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}
