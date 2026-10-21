// Draws the Pegline app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
let iconset = URL(fileURLWithPath: output).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Apple-style continuous rounded square (superellipse), in a 1024 canvas.
func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n: CGFloat = 5.0
    let a = rect.width / 2, b = rect.height / 2
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = c.x + a * (cosT >= 0 ? 1 : -1) * pow(abs(cosT), 2 / n)
        let y = c.y + b * (sinT >= 0 ? 1 : -1) * pow(abs(sinT), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    ctx.interpolationQuality = .high

    // Body: macOS icon grid, 824 × 824 centred, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(color(0xEFE9DF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Warm linen, a little lighter at the top like daylight on a wall.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0xF6F2EB), color(0xE6DED1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Rope.
    let ropeY: CGFloat = 742, sag: CGFloat = 78
    func ropeDepth(_ x: CGFloat) -> CGFloat {
        let t = (x - 60) / (964 - 60)
        return ropeY - sag * 4 * t * (1 - t)
    }
    let rope = CGMutablePath()
    rope.move(to: CGPoint(x: 60, y: ropeY))
    rope.addQuadCurve(to: CGPoint(x: 964, y: ropeY), control: CGPoint(x: 512, y: ropeY - sag * 2))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 5, color: color(0x000000, 0.22))
    ctx.addPath(rope)
    ctx.setStrokeColor(color(0x7C7064))
    ctx.setLineWidth(15)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(rope)
    ctx.setStrokeColor(color(0xFFFFFF, 0.32))
    ctx.setLineWidth(6)
    ctx.setLineDash(phase: 0, lengths: [7, 15])
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    func photo(centerX: CGFloat, width: CGFloat, height: CGFloat, angle: CGFloat, screen: UInt32, window: UInt32, pin: UInt32) {
        let pivot = CGPoint(x: centerX, y: ropeDepth(centerX))
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: angle)
        let card = CGRect(x: -width / 2, y: -height - 22, width: width, height: height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 34, color: color(0x3A2E22, 0.30))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(color(0xFCFBF8))
        ctx.fillPath()
        ctx.restoreGState()
        let inner = card.insetBy(dx: 16, dy: 16)
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(color(screen))
        ctx.fillPath()
        // A small window inside the screenshot.
        let win = CGRect(x: inner.minX + inner.width * 0.14, y: inner.minY + inner.height * 0.14,
                         width: inner.width * 0.72, height: inner.height * 0.66)
        ctx.addPath(CGPath(roundedRect: win, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.setFillColor(color(window))
        ctx.fillPath()
        for i in 0..<3 {
            let d = CGRect(x: win.minX + 20 + CGFloat(i) * 26, y: win.maxY - 34, width: 16, height: 16)
            ctx.addEllipse(in: d)
            ctx.setFillColor(color(0x000000, 0.16))
            ctx.fillPath()
        }
        for (i, w) in [0.62, 0.44].enumerated() {
            let line = CGRect(x: win.minX + 22, y: win.maxY - 78 - CGFloat(i) * 34, width: win.width * w, height: 14)
            ctx.addPath(CGPath(roundedRect: line, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setFillColor(color(0x000000, 0.10))
            ctx.fillPath()
        }
        // The peg.
        let peg = CGRect(x: -24, y: -78, width: 48, height: 128)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 3, height: -6), blur: 8, color: color(0x000000, 0.30))
        ctx.addPath(CGPath(roundedRect: peg, cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.setFillColor(color(pin))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: CGRect(x: peg.minX + 9, y: peg.minY + 14, width: 7, height: peg.height - 28),
                           cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, 0.30))
        ctx.fillPath()
        let spring = CGRect(x: -34, y: -11, width: 68, height: 22)
        ctx.addPath(CGPath(roundedRect: spring, cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.setFillColor(color(0xB7BABF))
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: spring, cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.setStrokeColor(color(0x000000, 0.2))
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
    }

    photo(centerX: 880, width: 300, height: 236, angle: 0.07, screen: 0xD9C08A, window: 0xFAF6EE, pin: 0x9DB09A)
    photo(centerX: 470, width: 470, height: 352, angle: -0.06, screen: 0x3F5670, window: 0xE7EBF1, pin: 0xCB8A66)
    ctx.restoreGState()

    // Hairline edge so the icon reads on light backgrounds.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0x000000, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()
    return ctx.makeImage()!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in sizes {
    let rep = NSBitmapImageRep(cgImage: drawIcon(size: px))
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("wrote \(iconset.path)")
