import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut. Stored with Carbon key code and modifiers.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    static let defaultCombo = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_L),
        carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
        keyLabel: "L")

    /// Builds a combo from a key press; requires ⌘, ⌥ or ⌃ so plain typing never triggers it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        keyCode = UInt32(event.keyCode)
        carbonModifiers = mods
        keyLabel = HotKeyCombo.label(for: event)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// Key equivalent string for showing the shortcut next to a menu item.
    var menuKeyEquivalent: String {
        keyLabel.count == 1 ? keyLabel.lowercased() : ""
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Пробел", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    private static func label(for event: NSEvent) -> String {
        label(keyCode: event.keyCode) ?? {
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? "?"
            return chars.isEmpty ? "?" : chars
        }()
    }

    /// Label for a physical key from the Latin (ASCII-capable) layout, so ⌃⌥⌘L shows "L"
    /// even when the Russian layout is active at the moment of recording.
    static func label(keyCode: UInt16) -> String? {
        if let special = specialKeys[Int(keyCode)] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                base, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let label = String(utf16CodeUnits: chars, count: length).uppercased()
        return label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
    }

    /// Recomputes the label from the key code (fixes labels recorded under a non-Latin layout).
    func normalized() -> HotKeyCombo {
        var copy = self
        if let label = HotKeyCombo.label(keyCode: UInt16(keyCode)) { copy.keyLabel = label }
        return copy
    }
}

/// Registers one global shortcut through Carbon. No Accessibility permission is needed for this.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var current: HotKeyCombo?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handlerRef)
    }

    /// Returns false if the system refused the combination.
    @discardableResult
    func register(_ combo: HotKeyCombo?) -> Bool {
        unregister()
        current = combo
        guard let combo else { return true }
        let id = EventHotKeyID(signature: OSType(0x5045_474C), id: 1) // "PEGL"
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            Log.system.error("Hot key registration failed: \(status)")
            hotKeyRef = nil
            return false
        }
        return true
    }

    /// Temporarily releases the shortcut, e.g. while the user records a new one.
    func suspend() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    func resume() { register(current) }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    fileprivate func fire() { action?() }
}

nonisolated private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { HotKeyCenter.shared.fire() }
    return noErr
}
