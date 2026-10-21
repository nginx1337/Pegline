import AppKit
import QuartzCore
import PeglineCore

/// Fixed proportions of a hanging photo, derived from the card width setting.
struct LineMetrics: Equatable {
    var maxCardWidth: CGFloat

    var maxCardHeight: CGFloat { (maxCardWidth * 0.75).rounded() }
    var spacing: CGFloat { max(16, (maxCardWidth * 0.13).rounded()) }
    /// Depth of the rope ends below the top edge of the panel.
    var anchorDepth: CGFloat { 12 }
    /// Rope continues this far past the outermost photo.
    var ropeOverhang: CGFloat { 30 }
    /// Gap between the rope and the top edge of a card.
    var cardGap: CGFloat { 4 }
    /// Pin extends this far above the rope.
    var pinAbove: CGFloat { 8 }
    /// Pin extends this far below the rope (overlapping the card).
    var pinBelow: CGFloat { 13 }
    var maxSag: CGFloat { 22 }
    /// Room under the cards for the caption pill and shadows.
    var bottomSpace: CGFloat { 46 }

    var panelHeight: CGFloat { anchorDepth + maxSag + cardGap + maxCardHeight + bottomSpace }
    /// Space reserved at each side for rope ends and overflow buttons.
    var sideMargin: CGFloat { ropeOverhang + 46 }
}

/// One photo: a pivot layer hanging from the rope, holding the card (paper + image) and the pin.
/// The pivot sits exactly where the pin grips the rope, so rotations look like real swinging.
final class PhotoNode {
    let id: UUID
    var record: ShotRecord
    let pinIndex: Int

    /// Pivot: position = point on the rope; all sway animations run on this layer.
    let hanger = CALayer()
    let card = CALayer()
    let image = CALayer()
    let flash = CALayer()
    let pin = CALayer()
    private let pinBody = CAShapeLayer()
    private let pinHighlight = CAShapeLayer()
    private let pinSpring = CAShapeLayer()

    private(set) var cardSize: CGSize = .zero
    private var metrics: LineMetrics
    var hasImage = false
    var isLoadingImage = false
    var visibility: CGFloat = 1
    var isHovered = false
    var isPressed = false
    var isLifted = false
    var lastNudge: CFTimeInterval = 0

    init(record: ShotRecord, metrics: LineMetrics, pinIndex: Int) {
        id = record.id
        self.record = record
        self.metrics = metrics
        self.pinIndex = pinIndex

        hanger.masksToBounds = false
        card.masksToBounds = false
        card.cornerRadius = 2.5
        card.borderWidth = 0.5
        card.shadowRadius = 5
        card.shadowOffset = CGSize(width: 0, height: -2.5)
        image.masksToBounds = true
        image.cornerRadius = 1.2
        image.contentsGravity = .resizeAspectFill
        image.minificationFilter = .trilinear
        flash.backgroundColor = CGColor(gray: 1, alpha: 1)
        flash.opacity = 0
        image.addSublayer(flash)
        card.addSublayer(image)
        hanger.addSublayer(card)

        pinBody.shadowRadius = 1
        pinBody.shadowOffset = CGSize(width: 0.5, height: -1)
        pin.addSublayer(pinBody)
        pin.addSublayer(pinHighlight)
        pin.addSublayer(pinSpring)
        hanger.addSublayer(pin)

        // Avoid implicit animations for geometry we set ourselves.
        let none: [String: CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "anchorPoint": NSNull(),
            "contents": NSNull(), "path": NSNull(), "shadowPath": NSNull(), "hidden": NSNull()
        ]
        for layer in [hanger, card, image, pin, pinBody, pinHighlight, pinSpring] { layer.actions = none }

        updateGeometry(metrics: metrics)
    }

    func updateGeometry(metrics: LineMetrics) {
        self.metrics = metrics
        cardSize = RopeLayout.cardSize(
            pixelWidth: record.pixelWidth, pixelHeight: record.pixelHeight, maxWidth: metrics.maxCardWidth)
        let w = cardSize.width, h = cardSize.height
        let pivotY = h + metrics.cardGap
        let totalHeight = pivotY + metrics.pinAbove
        hanger.bounds = CGRect(x: 0, y: 0, width: w, height: totalHeight)
        hanger.anchorPoint = CGPoint(x: 0.5, y: pivotY / totalHeight)

        card.frame = CGRect(x: 0, y: 0, width: w, height: h)
        card.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        let border = max(2.5, (w * 0.022).rounded(.toNearestOrEven))
        image.frame = card.bounds.insetBy(dx: border, dy: border)
        flash.frame = image.bounds

        // Pin: a small wooden peg with a metal spring at the rope.
        let pinWidth: CGFloat = 6.5, springWidth: CGFloat = 9
        let pinHeight = metrics.pinAbove + metrics.pinBelow
        pin.bounds = CGRect(x: 0, y: 0, width: springWidth, height: pinHeight)
        pin.anchorPoint = CGPoint(x: 0.5, y: metrics.pinBelow / pinHeight)
        pin.position = CGPoint(x: w / 2, y: pivotY)
        let bodyRect = CGRect(x: (springWidth - pinWidth) / 2, y: 0, width: pinWidth, height: pinHeight)
        pinBody.path = CGPath(roundedRect: bodyRect, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil)
        pinBody.shadowPath = pinBody.path
        let highlight = CGMutablePath()
        highlight.move(to: CGPoint(x: bodyRect.minX + 1.5, y: 2.5))
        highlight.addLine(to: CGPoint(x: bodyRect.minX + 1.5, y: pinHeight - 2.5))
        pinHighlight.path = highlight
        pinHighlight.lineWidth = 0.9
        pinHighlight.lineCap = .round
        pinHighlight.fillColor = nil
        let springRect = CGRect(x: 0, y: metrics.pinBelow - 1.6, width: springWidth, height: 3.2)
        pinSpring.path = CGPath(roundedRect: springRect, cornerWidth: 1.6, cornerHeight: 1.6, transform: nil)
        pinSpring.lineWidth = 0.5
    }

    func apply(_ palette: LinePalette) {
        card.backgroundColor = palette.paper
        card.borderColor = palette.cardBorder
        card.shadowOpacity = palette.cardShadowOpacity * (isHovered ? 1.25 : 1)
        if !hasImage { image.backgroundColor = palette.placeholder }
        pinBody.fillColor = palette.pins[pinIndex % palette.pins.count]
        pinBody.shadowOpacity = palette.pinShadowOpacity
        pinHighlight.strokeColor = palette.pinHighlight
        pinSpring.fillColor = palette.spring
        pinSpring.strokeColor = palette.springEdge
    }

    func setImage(_ cgImage: CGImage?, animated: Bool) {
        guard let cgImage else { return }
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            image.add(fade, forKey: "contents")
        }
        image.contents = cgImage
        image.backgroundColor = nil
        hasImage = true
    }

    /// Model frame of the card in the canvas (ignores the small sway rotation, which keeps clicking predictable).
    var cardFrame: CGRect {
        let pivot = hanger.position
        let w = cardSize.width, h = cardSize.height
        return CGRect(x: pivot.x - w / 2, y: pivot.y - metrics.cardGap - h, width: w, height: h)
    }

    /// Card plus pin: everything that should react to the pointer.
    var hitFrame: CGRect {
        let card = cardFrame
        return CGRect(x: card.minX, y: card.minY, width: card.width, height: card.height + metrics.cardGap + metrics.pinAbove)
    }

    var isVisibleOnLine: Bool { visibility > 0.5 && !hanger.isHidden }

    // MARK: Interaction looks

    func setHovered(_ hovered: Bool, palette: LinePalette, motion: MotionStyle) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        updateLift(palette: palette, motion: motion)
    }

    func setPressed(_ pressed: Bool, palette: LinePalette, motion: MotionStyle) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        updateLift(palette: palette, motion: motion)
    }

    private func updateLift(palette: LinePalette, motion: MotionStyle) {
        let scale: CGFloat = isPressed ? 0.97 : (isHovered ? 1.045 : 1)
        let target = CATransform3DMakeScale(scale, scale, 1)
        if motion == .off {
            card.removeAnimation(forKey: "lift")
            CATransaction.withoutActions { card.transform = target }
        } else {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = card.presentation()?.transform ?? card.transform
            spring.toValue = target
            spring.damping = 18
            spring.stiffness = 320
            spring.mass = 0.8
            spring.duration = spring.settlingDuration
            CATransaction.withoutActions { card.transform = target }
            card.add(spring, forKey: "lift")
        }
        let shadow = CABasicAnimation(keyPath: "shadowRadius")
        shadow.fromValue = card.presentation()?.shadowRadius ?? card.shadowRadius
        let radius: CGFloat = isHovered && !isPressed ? 10 : 5
        shadow.toValue = radius
        shadow.duration = 0.2
        CATransaction.withoutActions {
            card.shadowRadius = radius
            card.shadowOpacity = palette.cardShadowOpacity * (isHovered && !isPressed ? 1.25 : 1)
            card.shadowOffset = CGSize(width: 0, height: isHovered && !isPressed ? -5 : -2.5)
        }
        card.add(shadow, forKey: "shadowRadius")
    }

    /// Quick white flash on the image, used as copy feedback.
    func flashImage() {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 0.55, 0]
        anim.keyTimes = [0, 0.25, 1]
        anim.duration = 0.45
        flash.add(anim, forKey: "flash")
    }

    func setLifted(_ lifted: Bool) {
        isLifted = lifted
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = hanger.presentation()?.opacity ?? hanger.opacity
        let target: Float = lifted ? 0.35 : Float(visibility)
        anim.toValue = target
        anim.duration = 0.18
        CATransaction.withoutActions { hanger.opacity = target }
        hanger.add(anim, forKey: "liftOpacity")
    }

    /// Tilts the pin to follow the rope's slope.
    func setPinTilt(_ angle: CGFloat) {
        CATransaction.withoutActions { pin.transform = CATransform3DMakeRotation(angle, 0, 0, 1) }
    }

    /// The card as an image, used while dragging.
    func dragImage(palette: LinePalette) -> NSImage {
        let size = cardSize
        let contents = image.contents
        let border = image.frame.minX
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(palette.paper)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            ctx.fillPath()
            if let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let cg = contents as! CGImage
                let inner = rect.insetBy(dx: border, dy: border)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
                ctx.clip()
                ctx.draw(cg, in: aspectFill(CGSize(width: cg.width, height: cg.height), into: inner))
                ctx.restoreGState()
            }
            return true
        }
    }
}

func aspectFill(_ size: CGSize, into rect: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return rect }
    let scale = max(rect.width / size.width, rect.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
}

extension CATransaction {
    static func withoutActions(_ body: () -> Void) {
        begin()
        setDisableActions(true)
        body()
        commit()
    }
}
