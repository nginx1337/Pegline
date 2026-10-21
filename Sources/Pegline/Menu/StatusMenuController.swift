import AppKit
import PeglineCore

/// Menu bar item: the main (and usually only) interface of Pegline.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = statusItem.button {
            button.image = MenuBarIcon.make(filled: false)
            button.setAccessibilityLabel("Pegline")
            button.toolTip = "Pegline — снимки экрана на верёвке"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.behavior = []
    }

    func setLineVisible(_ visible: Bool) {
        statusItem.button?.image = MenuBarIcon.make(filled: visible)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.detector.refreshFolder()
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        let prefs = model.prefs

        let toggle = ActionMenuItem(model.line.isVisible ? "Скрыть верёвку" : "Показать верёвку",
                                    symbol: model.line.isVisible ? "eye.slash" : "eye") { [weak self] in
            self?.model.line.toggle()
        }
        if let combo = prefs.hotKey, !combo.menuKeyEquivalent.isEmpty {
            toggle.keyEquivalent = combo.menuKeyEquivalent
            toggle.keyEquivalentModifierMask = combo.cocoaModifiers
        }
        menu.addItem(toggle)

        addRecent()
        menu.addItem(.separator())
        menu.addItem(folderItem())
        menu.addItem(sizeItem())
        menu.addItem(motionItem())
        menu.addItem(behaviourItem())
        let hotKeyTitle = "Сочетание клавиш: \(prefs.hotKey?.displayString ?? "нет")…"
        menu.addItem(ActionMenuItem(hotKeyTitle, symbol: "keyboard") { [weak self] in self?.model.openSettings() })
        let login = ActionMenuItem("Открывать при входе в систему", symbol: "power",
                                   state: LoginItem.isEnabled ? .on : .off) { [weak self] in
            self?.model.setLoginItem(!LoginItem.isEnabled)
        }
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Настройки…", key: ",") { [weak self] in self?.model.openSettings() })
        menu.addItem(ActionMenuItem("Знакомство с Pegline") { [weak self] in self?.model.openOnboarding() })
        menu.addItem(ActionMenuItem("О программе Pegline") { [weak self] in self?.model.showAbout() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Выйти из Pegline", key: "q") { NSApp.terminate(nil) })
    }

    // MARK: Recent shots

    private func addRecent() {
        let shots = model.store.shots
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Недавние снимки"))
        if let problem = model.detector.accessProblem {
            let item = ActionMenuItem("Нет доступа к папке снимков", symbol: "exclamationmark.triangle") {
                PrivacyLinks.openFilesAndFolders()
            }
            item.subtitle = problem
            menu.addItem(item)
        } else if !SystemScreenshotPrefs.savesToFile, model.prefs.clipboardMode == .off {
            let item = NSMenuItem(title: "Снимки сейчас сохраняются не в файл", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            item.subtitle = "Включите «Из буфера обмена» в меню «Папка снимков»"
            item.isEnabled = false
            menu.addItem(item)
        }
        model.refreshSystemState()
        if model.clipboardDenied {
            let item = ActionMenuItem("Нет доступа к буферу обмена", symbol: "exclamationmark.triangle") {
                PrivacyLinks.openPasteboard()
            }
            item.subtitle = "Разрешите вставку для Pegline в Системных настройках"
            menu.addItem(item)
        }
        guard !shots.isEmpty else {
            let empty = NSMenuItem(title: "Пока пусто — нажмите ⇧⌘4", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for record in shots.prefix(8) {
            let item = ActionMenuItem("Скопировать снимок") { [weak self] in _ = self?.model.actions.copy(record) }
            item.subtitle = ShotFormatting.caption(record)
            item.image = thumbnail(for: record, item: item)
            item.toolTip = record.fileName
            menu.addItem(item)
            let open = ActionMenuItem("Открыть в «Просмотре»") { [weak self] in self?.model.actions.openInPreview(record) }
            open.subtitle = ShotFormatting.caption(record)
            open.image = item.image
            open.isAlternate = true
            open.keyEquivalentModifierMask = [.option]
            menu.addItem(open)
        }
        let hint = NSMenuItem(title: "Нажмите, чтобы скопировать; с ⌥ — открыть", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if shots.count > 8 {
            menu.addItem(ActionMenuItem("Все снимки на верёвке (\(shots.count))", symbol: "rectangle.stack") { [weak self] in
                self?.model.line.show(reason: .pinned)
            })
        }
        let clear = ActionMenuItem("Убрать все снимки с верёвки", symbol: "pin.slash") { [weak self] in
            self?.model.store.removeAll()
        }
        clear.subtitle = "Файлы останутся на месте"
        menu.addItem(clear)
    }

    private func thumbnail(for record: ShotRecord, item: NSMenuItem) -> NSImage? {
        let size = NSSize(width: 44, height: 28)
        let maxPixel = 128
        if let image = model.thumbnails.cached(id: record.id, maxPixel: maxPixel) {
            return MenuBarIcon.menuThumbnail(image, size: size)
        }
        Task { [weak self, weak item] in
            guard let self, let image = await self.model.thumbnails.thumbnail(id: record.id, path: record.path, maxPixel: maxPixel) else { return }
            item?.image = MenuBarIcon.menuThumbnail(image, size: size)
        }
        return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    }

    // MARK: Settings submenus

    private func submenu(_ title: String, symbol: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        item.submenu = sub
        return item
    }

    private func folderItem() -> NSMenuItem {
        let prefs = model.prefs
        return submenu("Папка снимков", symbol: "folder") { sub in
            let path = NSMenuItem(title: ShotFormatting.abbreviatedPath(model.detector.folder), action: nil, keyEquivalent: "")
            path.isEnabled = false
            path.image = NSWorkspace.shared.icon(forFile: model.detector.folder.path)
            path.image?.size = NSSize(width: 16, height: 16)
            sub.addItem(path)
            sub.addItem(.separator())
            sub.addItem(ActionMenuItem("Как в системе (⇧⌘5 → Параметры)", state: prefs.folderMode == .system ? .on : .off) { [weak self] in
                self?.model.prefs.folderMode = .system
            })
            sub.addItem(ActionMenuItem("Другая папка…", state: prefs.folderMode == .custom ? .on : .off) { [weak self] in
                self?.model.chooseCustomFolder()
            })
            sub.addItem(ActionMenuItem("Показать в Finder") { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.activateFileViewerSelecting([self.model.detector.folder])
            })
            sub.addItem(.separator())
            sub.addItem(.sectionHeader(title: "Добавлять на верёвку"))
            sub.addItem(ActionMenuItem("Только снимки экрана", state: prefs.capturePolicy == .screenshotsOnly ? .on : .off) { [weak self] in
                self?.model.prefs.capturePolicy = .screenshotsOnly
            })
            sub.addItem(ActionMenuItem("Все новые изображения в папке", state: prefs.capturePolicy == .allImages ? .on : .off) { [weak self] in
                self?.model.prefs.capturePolicy = .allImages
            })
            sub.addItem(.separator())
            sub.addItem(.sectionHeader(title: "Из буфера обмена"))
            for mode in [ClipboardMode.screenshots, .allImages, .off] {
                let item = ActionMenuItem(Preferences.title(for: mode), state: prefs.clipboardMode == mode ? .on : .off) { [weak self] in
                    self?.model.prefs.clipboardMode = mode
                }
                if mode == .screenshots { item.subtitle = "⌃⇧⌘4 и «Буфер обмена» в ⇧⌘5" }
                sub.addItem(item)
            }
            sub.addItem(ActionMenuItem("Показать сохранённые из буфера") {
                let folder = ClipboardImporter.folder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            })
        }
    }

    private func sizeItem() -> NSMenuItem {
        let prefs = model.prefs
        return submenu("Миниатюры", symbol: "photo.on.rectangle") { sub in
            for size in ThumbnailSize.allCases {
                sub.addItem(ActionMenuItem(size.title, state: prefs.thumbnailSize == size ? .on : .off) { [weak self] in
                    self?.model.prefs.thumbnailSize = size
                })
            }
            sub.addItem(.separator())
            sub.addItem(.sectionHeader(title: "Видно одновременно"))
            for count in Preferences.visibleCountChoices {
                sub.addItem(ActionMenuItem("\(count) снимков", state: prefs.visibleCount == count ? .on : .off) { [weak self] in
                    self?.model.prefs.visibleCount = count
                })
            }
        }
    }

    private func motionItem() -> NSMenuItem {
        let prefs = model.prefs
        return submenu("Анимации", symbol: "wind") { sub in
            for style in MotionStyle.allCases {
                let item = ActionMenuItem(style.title, state: prefs.motion == style ? .on : .off) { [weak self] in
                    self?.model.prefs.motion = style
                }
                item.subtitle = style.detail
                sub.addItem(item)
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                sub.addItem(.separator())
                let note = NSMenuItem(title: "В системе включено «Уменьшение движения»", action: nil, keyEquivalent: "")
                note.isEnabled = false
                sub.addItem(note)
            }
        }
    }

    private func behaviourItem() -> NSMenuItem {
        let prefs = model.prefs
        return submenu("Показ и скрытие", symbol: "rectangle.topthird.inset.filled") { sub in
            sub.addItem(ActionMenuItem("Показывать при новом снимке", state: prefs.showOnNewShot ? .on : .off) { [weak self] in
                self?.model.prefs.showOnNewShot.toggle()
            })
            sub.addItem(ActionMenuItem("Прятать через \(Int(prefs.autoHideDelay)) с", state: prefs.autoHide ? .on : .off) { [weak self] in
                self?.model.prefs.autoHide.toggle()
            })
            sub.addItem(.separator())
            let edge = ActionMenuItem("Раскрывать у верхнего края", state: prefs.revealOnEdge ? .on : .off) { [weak self] in
                self?.model.prefs.revealOnEdge.toggle()
            }
            edge.subtitle = "Задержите курсор у края посередине экрана"
            sub.addItem(edge)
            for delay in RevealDelay.allCases {
                let item = ActionMenuItem("    \(delay.title)", state: prefs.revealDelay == delay ? .on : .off) { [weak self] in
                    self?.model.prefs.revealDelay = delay
                }
                item.isEnabled = prefs.revealOnEdge
                item.indentationLevel = 1
                sub.addItem(item)
            }
        }
    }
}

enum PrivacyLinks {
    static func openPasteboard() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openFilesAndFolders() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Programmatic artwork for the menu bar: a sagging rope with two photos.
enum MenuBarIcon {
    static func make(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let rope = NSBezierPath()
            rope.move(to: NSPoint(x: 1.2, y: 14.6))
            rope.curve(to: NSPoint(x: 16.8, y: 14.6), controlPoint1: NSPoint(x: 6, y: 11.6), controlPoint2: NSPoint(x: 12, y: 11.6))
            rope.lineWidth = 1.2
            rope.lineCapStyle = .round
            rope.stroke()

            func photo(center: NSPoint, size: NSSize, angle: CGFloat, solid: Bool) {
                let transform = NSAffineTransform()
                transform.translateX(by: center.x, yBy: center.y)
                transform.rotate(byDegrees: angle)
                let rect = NSRect(x: -size.width / 2, y: -size.height, width: size.width, height: size.height)
                let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                path.transform(using: transform as AffineTransform)
                if solid {
                    path.fill()
                } else {
                    path.lineWidth = 1.1
                    path.stroke()
                }
                let pin = NSBezierPath(roundedRect: NSRect(x: -0.8, y: -1.6, width: 1.6, height: 3.4), xRadius: 0.6, yRadius: 0.6)
                pin.transform(using: transform as AffineTransform)
                pin.fill()
            }
            photo(center: NSPoint(x: 5.6, y: 12.7), size: NSSize(width: 5.6, height: 7.0), angle: 5, solid: filled)
            photo(center: NSPoint(x: 12.4, y: 12.6), size: NSSize(width: 5.6, height: 7.0), angle: -4, solid: true)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pegline"
        return image
    }

    static func menuThumbnail(_ cgImage: CGImage, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: aspectFill(CGSize(width: cgImage.width, height: cgImage.height), into: rect))
            ctx.resetClip()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
            return true
        }
    }
}
