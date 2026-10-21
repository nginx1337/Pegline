import AppKit
import PeglineCore

/// NSMenuItem that runs a closure. Keeps menu code short and avoids selector plumbing.
nonisolated final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         state: NSControl.StateValue = .off, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        self.state = state
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        let handler = self.handler
        MainActor.assumeIsolated { handler() }
    }
}

enum ShotMenuBuilder {
    /// Right-click menu for one photo.
    static func contextMenu(
        for record: ShotRecord, perform: @escaping (ShotAction) -> Void, share: () -> NSMenuItem?
    ) -> NSMenu {
        let menu = NSMenu(title: record.fileName)
        menu.autoenablesItems = false
        let header = NSMenuItem.sectionHeader(title: ShotFormatting.caption(record))
        menu.addItem(header)
        menu.addItem(ActionMenuItem("Скопировать", symbol: "doc.on.doc") { perform(.copy) })
        menu.addItem(ActionMenuItem("Открыть в «Просмотре»", symbol: "eye") { perform(.openInPreview) })
        menu.addItem(ActionMenuItem("Открыть в «Разметке»", symbol: "pencil.tip.crop.circle") { perform(.markup) })
        menu.addItem(ActionMenuItem("Показать в Finder", symbol: "folder") { perform(.revealInFinder) })
        menu.addItem(.separator())
        if let shareItem = share() { menu.addItem(shareItem) }
        menu.addItem(ActionMenuItem("Сохранить копию…", symbol: "square.and.arrow.down") { perform(.saveCopy) })
        menu.addItem(.separator())
        let unpin = ActionMenuItem("Убрать с верёвки", symbol: "pin.slash") { perform(.unpin) }
        unpin.subtitle = "Файл останется на месте"
        menu.addItem(unpin)
        let trash = ActionMenuItem("Переместить в Корзину…", symbol: "trash") { perform(.moveToTrash) }
        trash.subtitle = "Файл можно будет восстановить"
        menu.addItem(trash)
        return menu
    }
}
