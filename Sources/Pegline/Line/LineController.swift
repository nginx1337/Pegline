import AppKit
import PeglineCore

/// Decides when and where the line is visible, and routes actions from it.
final class LineController: LineCanvasDelegate {
    enum Reason: Int, Comparable {
        /// Revealed by holding the pointer at the top edge; hides when the pointer leaves.
        case hover = 0
        /// Shown because a screenshot arrived; hides after a few seconds.
        case newShot = 1
        /// Shown from the menu or shortcut; stays until hidden the same way.
        case pinned = 2
        static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }
    }

    let panel = LinePanel()
    let lineView: LineView
    private let store: ShotStore
    private let prefs: Preferences
    private let actions: ShotActions
    private let thumbnails: ThumbnailLoader

    private(set) var isVisible = false
    private(set) var reason: Reason = .pinned
    private var screen: NSScreen?
    private var hideTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var pointerInside = false
    private var lastPointer = NSPoint.zero
    private var interactions = 0

    var onVisibilityChanged: ((Bool) -> Void)?

    init(store: ShotStore, prefs: Preferences, actions: ShotActions, thumbnails: ThumbnailLoader) {
        self.store = store
        self.prefs = prefs
        self.actions = actions
        self.thumbnails = thumbnails
        lineView = LineView(
            thumbnails: thumbnails, metrics: LineMetrics(maxCardWidth: prefs.thumbnailSize.maxWidth),
            visibleCount: prefs.visibleCount, motion: prefs.effectiveMotion)
        panel.contentView = lineView
        lineView.canvas.delegate = self
        lineView.canvas.reload(store.shots)

        store.observe { [weak self] change in self?.apply(change) }

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        center.addObserver(forName: .peglinePreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
        workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        installMonitors()
    }

    // MARK: Public

    func toggle() {
        if isVisible { hide() } else { show(reason: .pinned) }
    }

    func show(reason: Reason, on target: NSScreen? = nil) {
        hideTask?.cancel()
        dwellTask?.cancel()
        dwellTask = nil
        let target = target ?? screenUnderPointer() ?? NSScreen.main
        guard let target else { return }
        if isVisible {
            if reason > self.reason { self.reason = reason }
            if target != screen { place(on: target) }
            scheduleHideIfNeeded(afterShow: true)
            return
        }
        self.reason = reason
        place(on: target)
        lineView.prepareForShow()
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        isVisible = true
        lineView.canvas.animateIn()
        pointerInside = false
        updatePointer(NSEvent.mouseLocation)
        scheduleHideIfNeeded(afterShow: true)
        onVisibilityChanged?(true)
        Log.line.info("Shown (\(String(describing: reason), privacy: .public))")
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        hideTask?.cancel()
        panel.ignoresMouseEvents = true
        lineView.prepareForHide()
        lineView.canvas.animateOut { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.lineView.canvas.resetTransientAnimations()
        }
        onVisibilityChanged?(false)
    }

    // MARK: Store changes

    private func apply(_ change: ShotStore.Change) {
        let canvas = lineView.canvas
        switch change {
        case .inserted(let record):
            canvas.insert(record, animated: isVisible)
            if prefs.showOnNewShot {
                show(reason: .newShot)
            }
        case .removed(let record, let why):
            canvas.remove(id: record.id, exit: why == .unpinned ? .lift : .fall, animated: isVisible)
        case .updated(let record, let contentChanged):
            canvas.update(record, contentChanged: contentChanged)
        case .reset:
            canvas.reload(store.shots)
        }
    }

    // MARK: Placement

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Just under the menu bar (or the camera housing), centred on the screen.
    private func place(on target: NSScreen) {
        screen = target
        let metrics = LineMetrics(maxCardWidth: prefs.thumbnailSize.maxWidth)
        lineView.canvas.updateMetrics(metrics)
        let frame = target.frame
        var top = target.visibleFrame.maxY
        let notch = target.safeAreaInsets.top
        if notch > 0 { top = min(top, frame.maxY - notch) }
        let viewport = RopeLayout.viewportWidth(
            visibleCount: prefs.visibleCount, maxCardWidth: metrics.maxCardWidth, spacing: metrics.spacing,
            available: frame.width - 2 * metrics.sideMargin)
        let width = min(frame.width, viewport + 2 * metrics.sideMargin)
        let height = metrics.panelHeight
        let rect = NSRect(x: (frame.midX - width / 2).rounded(), y: top - height, width: width, height: height)
        panel.setFrame(rect, display: false)
    }

    private func screensChanged() {
        guard isVisible else { return }
        if let screen, NSScreen.screens.contains(screen) {
            place(on: screen)
        } else if let replacement = screenUnderPointer() ?? NSScreen.main {
            place(on: replacement)
        }
    }

    private func spaceChanged() {
        // Entering or leaving a full-screen Space can show or hide the menu bar.
        guard isVisible, let screen else { return }
        place(on: screen)
    }

    private func preferencesChanged() {
        let canvas = lineView.canvas
        canvas.motion = prefs.effectiveMotion
        canvas.visibleCount = prefs.visibleCount
        if store.collection.capacity != prefs.lineCapacity { store.setCapacity(prefs.lineCapacity) }
        if isVisible, let screen {
            place(on: screen)
        } else {
            canvas.updateMetrics(LineMetrics(maxCardWidth: prefs.thumbnailSize.maxWidth))
        }
    }

    // MARK: Pointer

    private func installMonitors() {
        // Global mouse monitors do not need Accessibility permission (only keyboard monitors do).
        let move: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: move, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer(NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: move, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointer(NSEvent.mouseLocation) }
            return event
        }) { monitors.append(local) }
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedElsewhere() }
        }) { monitors.append(clicks) }
    }

    func updatePointer(_ point: NSPoint) {
        let deltaX = point.x - lastPointer.x
        lastPointer = point
        guard isVisible else {
            checkReveal(point)
            return
        }
        // Fast path: far from the panel nothing can be hovered, so skip all geometry work.
        if !panel.frame.insetBy(dx: -60, dy: -60).contains(point), interactions == 0 {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            if pointerInside {
                pointerInside = false
                lineView.canvas.pointerMoved(to: NSPoint(x: -10_000, y: -10_000), deltaX: deltaX)
                scheduleHideIfNeeded(afterShow: false)
            }
            return
        }
        let local = lineView.convert(panel.convertPoint(fromScreen: point), from: nil)
        let interactive = lineView.isInteractive(at: local)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        lineView.canvas.pointerMoved(to: local, deltaX: deltaX)

        let attention = panel.convertToScreen(lineView.convert(lineView.attentionRect, to: nil)).insetBy(dx: -36, dy: -28)
        let inside = attention.contains(point)
        if inside != pointerInside {
            pointerInside = inside
            if inside { hideTask?.cancel() } else { scheduleHideIfNeeded(afterShow: false) }
        }
    }

    /// Holding the pointer against the top edge, in the middle of the screen, reveals the line.
    private func checkReveal(_ point: NSPoint) {
        guard prefs.revealOnEdge, !store.shots.isEmpty,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
        else {
            dwellTask?.cancel()
            dwellTask = nil
            return
        }
        if inRevealZone(point, screen) {
            guard dwellTask == nil else { return }
            let delay = prefs.revealDelay.seconds
            dwellTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.dwellTask = nil
                let now = NSEvent.mouseLocation
                guard !self.isVisible, NSEvent.pressedMouseButtons == 0, self.inRevealZone(now, screen) else { return }
                self.show(reason: .hover, on: screen)
            }
        } else {
            dwellTask?.cancel()
            dwellTask = nil
        }
    }

    private func inRevealZone(_ point: NSPoint, _ screen: NSScreen) -> Bool {
        let metrics = LineMetrics(maxCardWidth: prefs.thumbnailSize.maxWidth)
        let viewport = RopeLayout.viewportWidth(
            visibleCount: prefs.visibleCount, maxCardWidth: metrics.maxCardWidth, spacing: metrics.spacing,
            available: screen.frame.width - 2 * metrics.sideMargin)
        // A narrow centre zone: the empty middle of the menu bar (or the camera housing).
        let halfWidth = min(viewport / 2, screen.frame.width * 0.22)
        return point.y >= screen.frame.maxY - 3 && abs(point.x - screen.frame.midX) <= halfWidth
    }

    private func clickedElsewhere() {
        guard isVisible, reason != .pinned, interactions == 0 else { return }
        hide()
    }

    private func scheduleHideIfNeeded(afterShow: Bool) {
        hideTask?.cancel()
        guard isVisible, reason != .pinned, interactions == 0, !pointerInside else { return }
        let delay: Double
        switch reason {
        case .hover: delay = afterShow ? 1.6 : 0.7
        case .newShot:
            guard prefs.autoHide else { return }
            delay = afterShow ? prefs.autoHideDelay : 1.4
        case .pinned: return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.pointerInside, self.interactions == 0 else { return }
            self.hide()
        }
    }

    // MARK: LineCanvasDelegate

    func canvas(_ canvas: LineCanvas, perform action: ShotAction, on record: ShotRecord, sourceFrame: NSRect, image: CGImage?) -> Bool {
        switch action {
        case .copy: return actions.copy(record)
        case .openInPreview: actions.openInPreview(record)
        case .markup: actions.openMarkup(record, sourceFrame: sourceFrame, window: panel, image: image)
        case .revealInFinder: actions.revealInFinder(record)
        case .saveCopy: withInteraction { actions.saveCopy(record) }
        case .unpin: actions.unpin(record)
        case .moveToTrash: withInteraction { actions.moveToTrash(record) }
        }
        return true
    }

    func canvas(_ canvas: LineCanvas, menuFor record: ShotRecord, sourceFrame: NSRect) -> NSMenu {
        ShotMenuBuilder.contextMenu(for: record) { [weak self] action in
            guard let self else { return }
            _ = self.canvas(canvas, perform: action, on: record, sourceFrame: sourceFrame, image: nil)
        } share: { [weak self] in
            self?.actions.shareMenuItem(for: record)
        }
    }

    func canvasInteractionBegan(_ canvas: LineCanvas) {
        interactions += 1
        hideTask?.cancel()
    }

    func canvasInteractionEnded(_ canvas: LineCanvas) {
        interactions = max(0, interactions - 1)
        updatePointer(NSEvent.mouseLocation)
        if !pointerInside { scheduleHideIfNeeded(afterShow: false) }
    }

    /// Modal panels (save, confirm) must not race with auto-hide.
    private func withInteraction(_ body: () -> Void) {
        interactions += 1
        body()
        interactions = max(0, interactions - 1)
        scheduleHideIfNeeded(afterShow: false)
    }
}
