import AppKit

/// Transparent, borderless panel for the line.
/// - never becomes key or main, never activates Pegline, so the app you work in keeps focus;
/// - joins every Space and appears over full-screen apps;
/// - is skipped by ⌘` window cycling and hidden in Mission Control.
final class LinePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        setAccessibilityLabel("Pegline")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
