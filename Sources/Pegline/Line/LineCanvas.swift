import AppKit
import QuartzCore
import PeglineCore

enum ShotAction {
    case copy, openInPreview, markup, revealInFinder, saveCopy, unpin, moveToTrash
}

protocol LineCanvasDelegate: AnyObject {
    @discardableResult
    func canvas(_ canvas: LineCanvas, perform action: ShotAction, on record: ShotRecord, sourceFrame: NSRect, image: CGImage?) -> Bool
    func canvas(_ canvas: LineCanvas, menuFor record: ShotRecord, sourceFrame: NSRect) -> NSMenu
    func canvasInteractionBegan(_ canvas: LineCanvas)
    func canvasInteractionEnded(_ canvas: LineCanvas)
}

/// Draws the rope and photos with Core Animation and handles clicks, drags and scrolling.
final class LineCanvas: NSView, NSDraggingSource, NSMenuDelegate {
    enum Exit { case lift, fall }

    weak var delegate: LineCanvasDelegate?
    weak var overlay: LineView?
    let thumbnails: ThumbnailLoader

    private(set) var metrics: LineMetrics
    var visibleCount: Int { didSet { if oldValue != visibleCount { layoutLine(animated: false) } } }
    var motion: MotionStyle { didSet { if oldValue != motion { motionChanged() } } }

    private(set) var nodes: [PhotoNode] = []
    private(set) var palette = LinePalette.make(dark: false)
    private let ropeGroup = CALayer()
    private let ropeLayer = CAShapeLayer()
    private let twistLayer = CAShapeLayer()
    private let leftHook = CAShapeLayer()
    private let rightHook = CAShapeLayer()
    private let photosLayer = CALayer()
    private(set) var rope = RopeGeometry(startX: 0, endX: 300, anchorDepth: 12, sag: 8)
    private(set) var scrollOffset: CGFloat = 0
    private(set) var isOnScreen = false
    private var nextPinIndex = 0
    private var placed: Set<UUID> = []
    private var pushCounter = 0

    private var hovered: PhotoNode?
    private var pressed: PhotoNode?
    private var downPoint: NSPoint = .zero
    private var longPressTask: Task<Void, Never>?
    private var longPressFired = false
    private var dragStarted = false
    private var draggingNode: PhotoNode?
    private var scrollVelocity: CGFloat = 0
    private var accessibilityCache: [UUID: PhotoAccessibilityElement] = [:]

    init(thumbnails: ThumbnailLoader, metrics: LineMetrics, visibleCount: Int, motion: MotionStyle) {
        self.thumbnails = thumbnails
        self.metrics = metrics
        self.visibleCount = visibleCount
        self.motion = motion
        super.init(frame: .zero)

        let root = CALayer()
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        for shape in [ropeLayer, twistLayer] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineWidth = 1.6
        }
        twistLayer.lineDashPattern = [1.3, 2.4]
        twistLayer.lineWidth = 1.1
        ropeLayer.shadowOpacity = 0.22
        ropeLayer.shadowRadius = 1
        ropeLayer.shadowOffset = CGSize(width: 0, height: -1)
        for hook in [leftHook, rightHook] {
            hook.path = CGPath(ellipseIn: CGRect(x: -3, y: -3, width: 6, height: 6), transform: nil)
            hook.lineWidth = 0.5
            hook.shadowOpacity = 0.25
            hook.shadowRadius = 0.8
            hook.shadowOffset = CGSize(width: 0, height: -0.6)
        }
        let none: [String: CAAction] = ["position": NSNull(), "path": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        for l in [ropeGroup, ropeLayer, twistLayer, leftHook, rightHook, photosLayer] { l.actions = none }
        ropeGroup.addSublayer(ropeLayer)
        ropeGroup.addSublayer(twistLayer)
        ropeGroup.addSublayer(leftHook)
        ropeGroup.addSublayer(rightHook)
        root.addSublayer(ropeGroup)
        root.addSublayer(photosLayer)
        applyPalette()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.withoutActions {
            ropeGroup.frame = bounds
            photosLayer.frame = bounds
        }
        layoutLine(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [ropeLayer, twistLayer, leftHook, rightHook] { l.contentsScale = scale }
    }

    private func applyPalette() {
        palette = LinePalette.current(for: effectiveAppearance)
        CATransaction.withoutActions {
            ropeLayer.strokeColor = palette.rope
            twistLayer.strokeColor = palette.ropeTwist
            for hook in [leftHook, rightHook] {
                hook.fillColor = palette.hook
                hook.strokeColor = palette.hookRim
            }
            for node in nodes { node.apply(palette) }
        }
    }

    func updateMetrics(_ new: LineMetrics) {
        guard new != metrics else { return }
        metrics = new
        for node in nodes {
            node.updateGeometry(metrics: new)
            node.apply(palette)
            node.hasImage = false
        }
        layoutLine(animated: false)
    }

    // MARK: Geometry

    var viewportWidth: CGFloat {
        RopeLayout.viewportWidth(
            visibleCount: visibleCount, maxCardWidth: metrics.maxCardWidth, spacing: metrics.spacing,
            available: max(120, bounds.width - 2 * metrics.sideMargin))
    }

    var viewportMinX: CGFloat { ((bounds.width - viewportWidth) / 2).rounded() }

    private var cardWidths: [CGFloat] { nodes.map(\.cardSize.width) }

    var maxScrollOffset: CGFloat {
        RopeLayout.maxScrollOffset(
            contentWidth: RopeLayout.contentWidth(cardWidths: cardWidths, spacing: metrics.spacing),
            viewportWidth: viewportWidth)
    }

    /// Photos hidden beyond the left and right edges of the viewport.
    var hiddenCounts: (left: Int, right: Int) {
        let mid = viewportMinX + viewportWidth / 2
        var left = 0, right = 0
        for node in nodes where node.visibility < 0.5 {
            if node.hanger.position.x < mid { left += 1 } else { right += 1 }
        }
        return (left, right)
    }

    /// Area that should receive the pointer: the band of visible photos.
    var interactiveRect: CGRect? {
        let frames = nodes.filter(\.isVisibleOnLine).map(\.hitFrame)
        guard var rect = frames.first else { return nil }
        for frame in frames.dropFirst() { rect = rect.union(frame) }
        return rect.insetBy(dx: -8, dy: -6)
    }

    var isInteracting: Bool { pressed != nil || draggingNode != nil }

    func node(at point: NSPoint) -> PhotoNode? {
        nodes.first { $0.isVisibleOnLine && $0.hitFrame.insetBy(dx: -2, dy: -2).contains(point) }
    }

    func screenFrame(of node: PhotoNode) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(node.cardFrame, to: nil))
    }

    func screenFrame(id: UUID) -> NSRect {
        guard let node = nodes.first(where: { $0.id == id }) else { return .zero }
        return screenFrame(of: node)
    }

    private func ropePath(_ geometry: RopeGeometry) -> CGPath {
        let h = bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: geometry.startX, y: h - geometry.anchorDepth))
        let control = geometry.controlPoint
        path.addQuadCurve(
            to: CGPoint(x: geometry.endX, y: h - geometry.anchorDepth), control: CGPoint(x: control.x, y: h - control.y))
        return path
    }

    // MARK: Layout

    func layoutLine(animated: Bool) {
        guard bounds.width > 0 else { return }
        let widths = cardWidths
        let vpWidth = viewportWidth, vpMin = viewportMinX
        let content = RopeLayout.contentWidth(cardWidths: widths, spacing: metrics.spacing)
        scrollOffset = min(max(scrollOffset, 0), maxScrollOffset)
        let centers = RopeLayout.centers(
            cardWidths: widths, spacing: metrics.spacing, viewportMinX: vpMin, viewportWidth: vpWidth, offset: scrollOffset)

        var start: CGFloat, end: CGFloat
        if nodes.isEmpty {
            start = bounds.midX - 150
            end = bounds.midX + 150
        } else if content <= vpWidth {
            start = centers[0] - widths[0] / 2 - metrics.ropeOverhang
            end = centers[centers.count - 1] + widths[widths.count - 1] / 2 + metrics.ropeOverhang
        } else {
            start = vpMin - metrics.ropeOverhang
            end = vpMin + vpWidth + metrics.ropeOverhang
        }
        if end - start < 260 {
            let mid = (start + end) / 2
            start = mid - 130
            end = mid + 130
        }
        let sag = min(metrics.maxSag, RopeLayout.sag(length: end - start, photoCount: nodes.count))
        let geometry = RopeGeometry(startX: start, endX: end, anchorDepth: metrics.anchorDepth, sag: sag)
        setRope(geometry, animated: animated)

        for (index, node) in nodes.enumerated() {
            let x = centers[index]
            let position = CGPoint(x: x, y: bounds.height - geometry.depth(atX: x))
            let visibility = RopeLayout.visibility(
                cardMinX: x - widths[index] / 2, cardMaxX: x + widths[index] / 2,
                viewportMinX: vpMin, viewportMaxX: vpMin + vpWidth, fade: 80)
            move(node, to: position, visibility: visibility, animated: animated)
            node.setPinTilt(-geometry.slopeAngle(atX: x))
            // Decode only photos that are visible or one viewport away, so long lines stay cheap.
            let near = x > vpMin - vpWidth && x < vpMin + 2 * vpWidth
            if near, !node.hasImage, !node.isLoadingImage { loadImage(for: node, animated: false) }
        }
        overlay?.canvasDidLayout()
    }

    private func setRope(_ geometry: RopeGeometry, animated: Bool) {
        let path = ropePath(geometry)
        let h = bounds.height
        let left = CGPoint(x: geometry.startX, y: h - geometry.anchorDepth)
        let right = CGPoint(x: geometry.endX, y: h - geometry.anchorDepth)
        if animated, motion != .off, isOnScreen, rope != geometry {
            for shape in [ropeLayer, twistLayer] {
                let anim = CABasicAnimation(keyPath: "path")
                anim.fromValue = shape.presentation()?.path ?? shape.path
                anim.toValue = path
                anim.duration = 0.55
                anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                shape.add(anim, forKey: "path")
            }
            for (hook, target) in [(leftHook, left), (rightHook, right)] {
                let anim = CABasicAnimation(keyPath: "position")
                anim.fromValue = NSValue(point: hook.presentation()?.position ?? hook.position)
                anim.toValue = NSValue(point: target)
                anim.duration = 0.55
                anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                hook.add(anim, forKey: "position")
            }
        }
        CATransaction.withoutActions {
            ropeLayer.path = path
            ropeLayer.shadowPath = path.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 1)
            twistLayer.path = path
            leftHook.position = left
            rightHook.position = right
        }
        rope = geometry
    }

    private func move(_ node: PhotoNode, to position: CGPoint, visibility: CGFloat, animated: Bool) {
        let first = !placed.contains(node.id)
        let old = node.hanger.presentation()?.position ?? node.hanger.position
        let oldOpacity = node.hanger.presentation()?.opacity ?? node.hanger.opacity
        let wasHidden = node.hanger.isHidden
        let opacity: Float = node.isLifted ? 0.35 : Float(visibility)
        CATransaction.withoutActions {
            node.hanger.position = position
            node.hanger.opacity = opacity
            node.hanger.isHidden = visibility <= 0.001
        }
        node.visibility = visibility
        placed.insert(node.id)
        guard animated, !first, !wasHidden, isOnScreen, motion != .off else { return }
        if hypot(old.x - position.x, old.y - position.y) > 0.5 {
            node.hanger.add(
                Motion.spring(keyPath: "position", from: NSValue(point: old), to: NSValue(point: position), damping: 17, stiffness: 160),
                forKey: "move")
            let dx = position.x - old.x
            if abs(dx) > 6, !node.isHovered {
                // The bottom of the photo lags behind when it slides along the rope.
                push(node, amplitude: max(-0.05, min(0.05, -dx * 0.0007)))
            }
        }
        if abs(oldOpacity - opacity) > 0.01 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldOpacity
            fade.toValue = opacity
            fade.duration = 0.25
            node.hanger.add(fade, forKey: "opacity")
        }
    }

    // MARK: Content

    func reload(_ records: [ShotRecord]) {
        for node in nodes { node.hanger.removeFromSuperlayer() }
        nodes.removeAll()
        placed.removeAll()
        accessibilityCache.removeAll()
        hovered = nil
        for record in records {
            let node = makeNode(record)
            nodes.append(node)
            photosLayer.addSublayer(node.hanger)
        }
        scrollOffset = 0
        layoutLine(animated: false)
        if isOnScreen { for node in nodes { startIdle(node) } }
    }

    private func makeNode(_ record: ShotRecord) -> PhotoNode {
        let node = PhotoNode(record: record, metrics: metrics, pinIndex: nextPinIndex)
        nextPinIndex += 1
        node.apply(palette)
        let scale = window?.backingScaleFactor ?? 2
        for layer in [node.hanger, node.card, node.image, node.pin] { layer.contentsScale = scale }
        return node
    }

    func insert(_ record: ShotRecord, animated: Bool) {
        guard !nodes.contains(where: { $0.id == record.id }) else { return }
        let node = makeNode(record)
        nodes.insert(node, at: 0)
        photosLayer.addSublayer(node.hanger)
        scrollOffset = 0
        layoutLine(animated: animated)
        if animated, isOnScreen {
            entrance(node, delay: 0.02)
            startIdle(node, delay: 1.4)
        }
    }

    func remove(id: UUID, exit: Exit, animated: Bool) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        let node = nodes.remove(at: index)
        placed.remove(id)
        accessibilityCache[id] = nil
        if hovered === node {
            hovered = nil
            overlay?.hideInfo()
        }
        if pressed === node { pressed = nil }
        if animated, isOnScreen, motion != .off, node.isVisibleOnLine {
            animateExit(node, exit)
        } else {
            node.hanger.removeFromSuperlayer()
        }
        layoutLine(animated: animated)
    }

    func update(_ record: ShotRecord, contentChanged: Bool) {
        guard let node = nodes.first(where: { $0.id == record.id }) else { return }
        let sizeChanged = node.record.pixelWidth != record.pixelWidth || node.record.pixelHeight != record.pixelHeight
        node.record = record
        if sizeChanged {
            node.updateGeometry(metrics: metrics)
            layoutLine(animated: true)
        }
        if contentChanged {
            thumbnails.invalidate(id: record.id)
            loadImage(for: node, animated: true)
        }
        if hovered === node { overlay?.showInfo(for: node) }
    }

    private var thumbnailPixels: Int {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        return Int(metrics.maxCardWidth * scale)
    }

    private func loadImage(for node: PhotoNode, animated: Bool) {
        let maxPixel = thumbnailPixels
        if let cached = thumbnails.cached(id: node.id, maxPixel: maxPixel) {
            node.setImage(cached, animated: false)
            return
        }
        let id = node.id, path = node.record.path
        node.isLoadingImage = true
        Task { [weak self, weak node] in
            guard let self else { return }
            let image = await self.thumbnails.thumbnail(id: id, path: path, maxPixel: maxPixel)
            node?.isLoadingImage = false
            node?.setImage(image, animated: animated || self.isOnScreen)
        }
    }

    // MARK: Motion

    private func push(_ node: PhotoNode, amplitude: CGFloat, delay: Double = 0) {
        guard motion != .off, isOnScreen, abs(amplitude) > 0.002 else { return }
        pushCounter += 1
        node.hanger.add(Motion.push(amplitude: amplitude, delay: delay), forKey: "rot.push.\(pushCounter % 6)")
        node.lastNudge = CACurrentMediaTime()
    }

    private func startIdle(_ node: PhotoNode, delay: Double = 0) {
        guard motion == .lively, isOnScreen, !node.isHovered, node.hanger.animation(forKey: "rot.idle") == nil else { return }
        let sway = Motion.idleSway(amplitude: CGFloat.random(in: 0.011...0.019))
        sway.beginTime += delay
        node.hanger.add(sway, forKey: "rot.idle")
    }

    private func stopSwing(_ node: PhotoNode) {
        let current = Motion.currentRotation(of: node.hanger)
        Motion.removeRotations(from: node.hanger)
        if abs(current) > 0.0005, motion != .off {
            node.hanger.add(Motion.settle(from: current), forKey: "rot.settle")
        }
    }

    private func motionChanged() {
        for node in nodes {
            Motion.removeRotations(from: node.hanger)
            startIdle(node)
        }
    }

    private func entrance(_ node: PhotoNode, delay: Double) {
        let begin = CACurrentMediaTime() + delay
        let target = node.hanger.opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = target
        fade.duration = motion == .off ? 0.22 : 0.16
        fade.beginTime = begin
        fade.fillMode = .backwards
        node.hanger.add(fade, forKey: "fadeIn")
        guard motion != .off else { return }

        // Drops in from under the menu bar, overshoots a little and settles.
        let y = node.hanger.position.y
        let lift = bounds.height - y + node.cardSize.height + 20
        let drop = Motion.spring(keyPath: "position.y", from: y + lift, to: y, damping: 14, stiffness: 190)
        drop.beginTime = begin
        drop.fillMode = .backwards
        node.hanger.add(drop, forKey: "drop")
        push(node, amplitude: (Bool.random() ? 1 : -1) * CGFloat.random(in: 0.05...0.08), delay: delay + 0.22)
        // The peg clips onto the rope just after the photo arrives.
        let clip = Motion.spring(keyPath: "position.y", from: 7, to: 0, damping: 10, stiffness: 320)
        clip.isAdditive = true
        clip.beginTime = begin + 0.2
        clip.fillMode = .backwards
        node.pin.add(clip, forKey: "clip")
    }

    private func animateExit(_ node: PhotoNode, _ exit: Exit) {
        let layer = node.hanger
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let move = CABasicAnimation(keyPath: "position.y")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let group = CAAnimationGroup()
        switch exit {
        case .lift:
            move.byValue = bounds.height - layer.position.y + node.cardSize.height + 20
            group.duration = 0.3
            group.animations = [move, fade]
        case .fall:
            move.byValue = -40
            let spin = CABasicAnimation(keyPath: Motion.rotation)
            spin.byValue = (Bool.random() ? 1 : -1) * 0.22
            spin.isAdditive = true
            group.duration = 0.34
            group.animations = [move, fade, spin]
        }
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "exit")
        CATransaction.commit()
    }

    /// Plays when the panel appears.
    func animateIn() {
        isOnScreen = true
        resetTransientAnimations()
        guard let root = layer else { return }
        if motion == .off {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            root.add(fade, forKey: "fadeIn")
            return
        }
        let ropeIn = CABasicAnimation(keyPath: "opacity")
        ropeIn.fromValue = 0
        ropeIn.toValue = 1
        ropeIn.duration = 0.22
        ropeGroup.add(ropeIn, forKey: "fadeIn")
        let ropeDrop = Motion.spring(keyPath: "position.y", from: 10, to: 0, damping: 14, stiffness: 220)
        ropeDrop.isAdditive = true
        ropeGroup.add(ropeDrop, forKey: "drop")
        var delay = 0.06
        for node in nodes where node.isVisibleOnLine {
            entrance(node, delay: delay)
            delay += 0.035
        }
        for node in nodes { startIdle(node, delay: 1.0) }
    }

    /// Plays before the panel is removed from the screen.
    func animateOut(completion: @escaping () -> Void) {
        isOnScreen = false
        longPressTask?.cancel()
        if let hovered {
            hovered.setHovered(false, palette: palette, motion: motion)
            self.hovered = nil
        }
        overlay?.hideInfo()
        guard let root = layer else { return completion() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        if motion == .off {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            fade.duration = 0.15
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            root.add(fade, forKey: "exit.fade")
        } else {
            var delay = 0.0
            for node in nodes where node.isVisibleOnLine {
                let rise = CABasicAnimation(keyPath: "position.y")
                rise.byValue = bounds.height - node.hanger.position.y + node.cardSize.height + 24
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [rise, fade]
                group.duration = 0.26
                group.beginTime = CACurrentMediaTime() + delay
                group.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.6)
                group.fillMode = .both
                group.isRemovedOnCompletion = false
                node.hanger.add(group, forKey: "exit.rise")
                delay += 0.018
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            fade.duration = 0.2
            fade.beginTime = CACurrentMediaTime() + 0.08 + delay / 2
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            ropeGroup.add(fade, forKey: "exit.fade")
        }
        CATransaction.commit()
    }

    /// Stops everything once the panel is off screen, so nothing keeps rendering.
    func resetTransientAnimations() {
        layer?.removeAllAnimations()
        ropeGroup.removeAllAnimations()
        ropeLayer.removeAllAnimations()
        twistLayer.removeAllAnimations()
        leftHook.removeAllAnimations()
        rightHook.removeAllAnimations()
        for node in nodes {
            node.hanger.removeAllAnimations()
            node.pin.removeAllAnimations()
        }
    }

    // MARK: Pointer

    /// Called by the controller for every mouse move while the line is visible.
    func pointerMoved(to point: NSPoint, deltaX: CGFloat) {
        guard isOnScreen, draggingNode == nil else { return }
        let target = pressed ?? node(at: point)
        guard target !== hovered else { return }
        if let old = hovered {
            old.setHovered(false, palette: palette, motion: motion)
            // Brushing past a photo gives it a tiny push in the direction of the pointer.
            if abs(deltaX) > 1.5, CACurrentMediaTime() - old.lastNudge > 0.3 {
                push(old, amplitude: max(-0.035, min(0.035, deltaX * 0.003)))
            }
            startIdle(old, delay: 0.6)
        }
        hovered = target
        if let new = target {
            stopSwing(new)
            new.setHovered(true, palette: palette, motion: motion)
            overlay?.showInfo(for: new)
        } else {
            overlay?.hideInfo()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let node = node(at: point) else { return }
        pressed = node
        downPoint = point
        longPressFired = false
        dragStarted = false
        if hovered !== node { pointerMoved(to: point, deltaX: 0) }
        node.setPressed(true, palette: palette, motion: motion)
        delegate?.canvasInteractionBegan(self)
        longPressTask?.cancel()
        guard event.clickCount == 1 else { return }
        longPressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            self?.firedLongPress()
        }
    }

    private func firedLongPress() {
        guard let node = pressed, !dragStarted else { return }
        longPressFired = true
        node.setPressed(false, palette: palette, motion: motion)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        overlay?.showFeedback("Открываю «Разметку»", symbol: "pencil.tip.crop.circle", for: node)
        perform(.markup, on: node)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let node = pressed, !longPressFired, !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 else { return }
        dragStarted = true
        longPressTask?.cancel()
        beginDrag(node, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        longPressTask?.cancel()
        guard let node = pressed else { return }
        pressed = nil
        node.setPressed(false, palette: palette, motion: motion)
        defer { if draggingNode == nil { delegate?.canvasInteractionEnded(self) } }
        guard !longPressFired, !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard node.hitFrame.insetBy(dx: -4, dy: -4).contains(point) else { return }
        if event.clickCount >= 2 {
            overlay?.showFeedback("Открываю в «Просмотре»", symbol: "eye", for: node)
            perform(.openInPreview, on: node)
        } else {
            performCopy(node)
        }
    }

    private func performCopy(_ node: PhotoNode) {
        if perform(.copy, on: node) {
            node.flashImage()
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            overlay?.showFeedback("Скопировано", symbol: "checkmark.circle.fill", for: node)
        }
    }

    @discardableResult
    private func perform(_ action: ShotAction, on node: PhotoNode) -> Bool {
        let image = node.image.contents.map { $0 as! CGImage }
        return delegate?.canvas(self, perform: action, on: node.record, sourceFrame: screenFrame(of: node), image: image) ?? false
    }

    func perform(_ action: ShotAction, id: UUID) -> Bool {
        guard let node = nodes.first(where: { $0.id == id }) else { return false }
        if action == .copy {
            performCopy(node)
            return true
        }
        return perform(action, on: node)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let node = node(at: point), let delegate else { return nil }
        longPressTask?.cancel()
        pressed = nil
        node.setPressed(false, palette: palette, motion: motion)
        let menu = delegate.canvas(self, menuFor: node.record, sourceFrame: screenFrame(of: node))
        menu.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { delegate?.canvasInteractionBegan(self) }
    func menuDidClose(_ menu: NSMenu) { delegate?.canvasInteractionEnded(self) }

    override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return }
        let precise = event.hasPreciseScrollingDeltas
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        var delta = abs(dx) >= abs(dy) ? dx : dy
        if !precise { delta *= 12 }
        if delta != 0 {
            scrollOffset = min(max(scrollOffset - delta, 0), maxScrollOffset)
            scrollVelocity = delta
            CATransaction.withoutActions { layoutLine(animated: false) }
        }
        let ended = event.phase == .ended || event.momentumPhase == .ended || (!precise && delta != 0)
        if ended, abs(scrollVelocity) > 2 {
            let amplitude = max(-0.04, min(0.04, scrollVelocity * 0.0025))
            for node in nodes where node.isVisibleOnLine && !node.isHovered { push(node, amplitude: amplitude) }
            scrollVelocity = 0
        }
    }

    /// Scrolls by most of a viewport, used by the arrow buttons.
    func page(_ direction: Int) {
        let target = min(max(scrollOffset + CGFloat(direction) * viewportWidth * 0.8, 0), maxScrollOffset)
        guard target != scrollOffset else { return }
        scrollOffset = target
        layoutLine(animated: true)
    }

    // MARK: Dragging

    private func beginDrag(_ node: PhotoNode, event: NSEvent) {
        guard FileManager.default.fileExists(atPath: node.record.path) else {
            NSSound.beep()
            return
        }
        let item = NSDraggingItem(pasteboardWriter: node.record.url as NSURL)
        item.setDraggingFrame(node.cardFrame, contents: node.dragImage(palette: palette))
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        draggingNode = node
        node.setLifted(true)
        overlay?.hideInfo()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Always a copy: dropping on a folder saves a copy, the original is never moved away.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let node = draggingNode else { return }
        draggingNode = nil
        node.setLifted(false)
        node.setHovered(false, palette: palette, motion: motion)
        if hovered === node { hovered = nil }
        if operation != [] { push(node, amplitude: 0.04) }
        startIdle(node, delay: 0.8)
        delegate?.canvasInteractionEnded(self)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Верёвка со снимками экрана" }

    override func accessibilityChildren() -> [Any]? {
        nodes.filter(\.isVisibleOnLine).map { node in
            if let cached = accessibilityCache[node.id] { return cached }
            let element = PhotoAccessibilityElement(id: node.id, canvas: self)
            accessibilityCache[node.id] = element
            return element
        }
    }

    func record(id: UUID) -> ShotRecord? { nodes.first { $0.id == id }?.record }
}

/// VoiceOver representation of one photo, with the same actions as the mouse.
/// AppKit calls these on the main thread, which `assumeIsolated` checks.
nonisolated final class PhotoAccessibilityElement: NSAccessibilityElement {
    let id: UUID
    weak var canvas: LineCanvas?

    init(id: UUID, canvas: LineCanvas) {
        self.id = id
        self.canvas = canvas
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityParent() -> Any? { canvas }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityFrame() -> NSRect {
        let canvas = self.canvas, id = self.id
        return MainActor.assumeIsolated { canvas?.screenFrame(id: id) ?? .zero }
    }

    override func accessibilityLabel() -> String? {
        let canvas = self.canvas, id = self.id
        return MainActor.assumeIsolated {
            guard let record = canvas?.record(id: id) else { return nil }
            return "Снимок экрана, \(ShotFormatting.relative(record.addedAt)), \(record.pixelWidth) на \(record.pixelHeight)"
        }
    }

    override func accessibilityHelp() -> String? { "Нажмите, чтобы скопировать. Другие действия — в списке действий." }

    override func accessibilityPerformPress() -> Bool {
        let canvas = self.canvas, id = self.id
        return MainActor.assumeIsolated { canvas?.perform(.copy, id: id) ?? false }
    }

    private static let customActions: [(String, ShotAction)] = [
        ("Открыть в «Просмотре»", .openInPreview), ("Открыть в «Разметке»", .markup),
        ("Показать в Finder", .revealInFinder), ("Сохранить копию…", .saveCopy),
        ("Убрать с верёвки", .unpin), ("Переместить в Корзину…", .moveToTrash)
    ]

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        Self.customActions.map { name, _ in
            NSAccessibilityCustomAction(name: name, target: self, selector: #selector(runCustomAction(_:)))
        }
    }

    @objc private func runCustomAction(_ sender: NSAccessibilityCustomAction) -> Bool {
        guard let index = Self.customActions.firstIndex(where: { $0.0 == sender.name }) else { return false }
        let canvas = self.canvas, id = self.id
        return MainActor.assumeIsolated { canvas?.perform(Self.customActions[index].1, id: id) ?? false }
    }
}
