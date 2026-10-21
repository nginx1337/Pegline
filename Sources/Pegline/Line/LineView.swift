import AppKit
import PeglineCore

/// Content of the panel: the canvas plus small Liquid Glass overlays
/// (caption under the hovered photo, arrows when there are more photos than fit).
final class LineView: NSView {
    let canvas: LineCanvas
    private let info = GlassPill()
    private let emptyHint = GlassPill()
    private let leftArrow = GlassArrow(direction: -1)
    private let rightArrow = GlassArrow(direction: 1)
    private var infoHideTask: Task<Void, Never>?
    private var feedbackUntil: Date = .distantPast
    private weak var infoNode: PhotoNode?

    init(thumbnails: ThumbnailLoader, metrics: LineMetrics, visibleCount: Int, motion: MotionStyle) {
        canvas = LineCanvas(thumbnails: thumbnails, metrics: metrics, visibleCount: visibleCount, motion: motion)
        super.init(frame: .zero)
        wantsLayer = true
        canvas.overlay = self
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        for pill in [info, emptyHint] {
            pill.alphaValue = 0
            addSubview(pill)
        }
        emptyHint.set(text: "Новые снимки экрана появятся здесь · ⇧⌘4", symbol: "camera.viewfinder")
        for arrow in [leftArrow, rightArrow] {
            arrow.isHidden = true
            arrow.onPress = { [weak self] direction in self?.canvas.page(direction) }
            addSubview(arrow)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        canvas.frame = bounds
        canvasDidLayout()
    }

    /// Area that must receive mouse events (photos and arrows). Everything else passes through.
    func isInteractive(at point: NSPoint) -> Bool {
        if canvas.isInteracting { return true }
        if let rect = canvas.interactiveRect, rect.contains(point) { return true }
        for arrow in [leftArrow, rightArrow] where !arrow.isHidden && arrow.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return true
        }
        return false
    }

    /// Rect that keeps an automatically shown line from hiding while the pointer is near it.
    var attentionRect: NSRect {
        var rect = canvas.interactiveRect ?? NSRect(x: bounds.midX - 160, y: bounds.maxY - 60, width: 320, height: 60)
        for arrow in [leftArrow, rightArrow] where !arrow.isHidden { rect = rect.union(arrow.frame) }
        rect = rect.union(NSRect(x: rect.minX, y: bounds.maxY - 8, width: rect.width, height: 8))
        return rect
    }

    func canvasDidLayout() {
        let counts = canvas.hiddenCounts
        let overflow = canvas.maxScrollOffset > 0
        let cardMid = bounds.maxY - canvas.metrics.anchorDepth - canvas.metrics.maxSag / 2 - canvas.metrics.maxCardHeight / 2
        let size = NSSize(width: 34, height: 34)
        let vpMin = canvas.viewportMinX, vpMax = vpMin + canvas.viewportWidth
        leftArrow.frame = NSRect(x: vpMin - size.width - 14, y: cardMid - size.height / 2, width: size.width, height: size.height)
        rightArrow.frame = NSRect(x: vpMax + 14, y: cardMid - size.height / 2, width: size.width, height: size.height)
        leftArrow.setCount(counts.left)
        rightArrow.setCount(counts.right)
        leftArrow.isHidden = !overflow || canvas.scrollOffset <= 0.5
        rightArrow.isHidden = !overflow || canvas.scrollOffset >= canvas.maxScrollOffset - 0.5
        let empty = canvas.nodes.isEmpty
        let hintSize = emptyHint.fittingSize
        emptyHint.frame = NSRect(
            x: (bounds.midX - hintSize.width / 2).rounded(), y: bounds.maxY - canvas.metrics.anchorDepth - 30 - hintSize.height,
            width: hintSize.width, height: hintSize.height)
        emptyHint.animator().alphaValue = empty ? 1 : 0
        if let node = infoNode, !canvas.nodes.contains(where: { $0 === node }) { hideInfo() }
        if let node = infoNode { position(info, under: node) }
    }

    // MARK: Caption

    func showInfo(for node: PhotoNode) {
        guard Date() > feedbackUntil else { return }
        infoHideTask?.cancel()
        infoNode = node
        info.set(text: ShotFormatting.caption(node.record), symbol: nil)
        position(info, under: node)
        fade(info, to: 1)
    }

    func hideInfo() {
        infoHideTask?.cancel()
        infoNode = nil
        fade(info, to: 0)
    }

    /// Short confirmation under a photo ("Скопировано").
    func showFeedback(_ text: String, symbol: String, for node: PhotoNode) {
        infoHideTask?.cancel()
        infoNode = node
        info.set(text: text, symbol: symbol)
        position(info, under: node)
        fade(info, to: 1)
        feedbackUntil = Date().addingTimeInterval(1.2)
        infoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled, let self else { return }
            self.feedbackUntil = .distantPast
            if let node = self.infoNode, node.isHovered {
                self.showInfo(for: node)
            } else {
                self.hideInfo()
            }
        }
    }

    private func position(_ pill: GlassPill, under node: PhotoNode) {
        let size = pill.fittingSize
        let card = node.cardFrame
        var x = (card.midX - size.width / 2).rounded()
        x = min(max(x, 4), bounds.width - size.width - 4)
        pill.frame = NSRect(x: x, y: max(2, card.minY - size.height - 10), width: size.width, height: size.height)
    }

    private func fade(_ view: NSView, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.14 : 0.2
            view.animator().alphaValue = alpha
        }
    }

    func prepareForHide() {
        hideInfo()
        emptyHint.animator().alphaValue = 0
    }

    func prepareForShow() {
        emptyHint.alphaValue = canvas.nodes.isEmpty ? 1 : 0
    }
}

/// Small rounded Liquid Glass label with an optional symbol.
final class GlassPill: NSView {
    private let glass = NSGlassEffectView()
    private let stack = NSStackView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 12
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 11)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)
        glass.contentView = stack
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(text: String, symbol: String?) {
        label.stringValue = text
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            icon.image = image
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
    }

    override var fittingSize: NSSize {
        let text = label.intrinsicContentSize.width
        let iconWidth: CGFloat = icon.isHidden ? 0 : 14 + stack.spacing
        return NSSize(width: ceil(text + iconWidth + 21), height: 24)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        glass.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Round glass button with a chevron and the number of photos hidden on that side.
final class GlassArrow: NSView {
    let direction: Int
    var onPress: ((Int) -> Void)?
    private let glass = NSGlassEffectView()
    private let button = NSButton()

    init(direction: Int) {
        self.direction = direction
        super.init(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 17
        glass.effectIsInteractive = true
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: direction < 0 ? "chevron.left" : "chevron.right",
            accessibilityDescription: direction < 0 ? "Более новые снимки" : "Более старые снимки")
        button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        button.contentTintColor = .labelColor
        button.target = self
        button.action = #selector(pressed)
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        glass.contentView = button
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        glass.frame = bounds
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCount(_ count: Int) {
        button.toolTip = count > 0 ? "Ещё \(count)" : nil
        button.setAccessibilityLabel(direction < 0 ? "Более новые снимки: \(count)" : "Более старые снимки: \(count)")
    }

    @objc private func pressed() { onPress?(direction) }
}
