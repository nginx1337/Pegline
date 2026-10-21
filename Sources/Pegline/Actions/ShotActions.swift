import AppKit
import UniformTypeIdentifiers
import PeglineCore

/// Everything a user can do with a photo. Shared by the line, the menu and accessibility actions.
final class ShotActions {
    private let store: ShotStore
    private let markup = MarkupPresenter()
    /// Called after Pegline writes to the clipboard, so the clipboard watcher skips that change.
    var onDidWritePasteboard: (() -> Void)?

    init(store: ShotStore) {
        self.store = store
    }

    private func existing(_ record: ShotRecord) -> URL? {
        guard FileManager.default.fileExists(atPath: record.path) else {
            store.refresh(path: record.path, contentMayHaveChanged: false)
            NSSound.beep()
            return nil
        }
        return record.url
    }

    /// Puts the image on the clipboard as both a file and image data,
    /// so Finder pastes the file and editors or messengers paste the picture.
    @discardableResult
    func copy(_ record: ShotRecord) -> Bool {
        guard let url = existing(record) else { return false }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            if type != .png, let png = ImageInfo.pngData(path: url.path) {
                item.setData(png, forType: .png)
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects([item])
        onDidWritePasteboard?()
        Log.actions.info("Copied \(record.fileName, privacy: .public): \(ok)")
        return ok
    }

    /// Opens in Preview specifically; falls back to the default app if Preview is missing.
    func openInPreview(_ record: ShotRecord) {
        guard let url = existing(record) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration) { _, error in
                if let error { Log.actions.error("Preview: \(error.localizedDescription, privacy: .public)") }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func openMarkup(_ record: ShotRecord, sourceFrame: NSRect, window: NSWindow?, image: CGImage?) {
        guard let url = existing(record) else { return }
        markup.present(url: url, sourceFrame: sourceFrame, window: window, image: image) { [weak self] in
            self?.openInPreview(record)
        } onSavedCopy: { [weak self] copyURL in
            self?.hangEditedCopy(at: copyURL)
        }
    }

    func revealInFinder(_ record: ShotRecord) {
        guard let url = existing(record) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Saves a copy anywhere; the original stays where it was.
    func saveCopy(_ record: ShotRecord) {
        guard let url = existing(record) else { return }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.title = "Сохранить копию снимка"
        panel.prompt = "Сохранить"
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard destination.standardizedFileURL != url.standardizedFileURL else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                // The panel already asked about replacing. Keep the old file recoverable.
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            presentError("Не удалось сохранить копию", error)
        }
    }

    func unpin(_ record: ShotRecord) {
        store.remove(id: record.id, reason: .unpinned)
    }

    /// Moves the file itself to the Trash after an explicit confirmation.
    func moveToTrash(_ record: ShotRecord) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Переместить снимок в Корзину?"
        alert.informativeText = "Файл «\(record.fileName)» будет перемещён в Корзину, откуда его можно восстановить. Чтобы просто убрать фото с верёвки, выберите «Убрать с верёвки» — файл тогда останется на месте."
        alert.addButton(withTitle: "Переместить в Корзину")
        alert.addButton(withTitle: "Отменить")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.trash(id: record.id)
        } catch {
            presentError("Не удалось переместить в Корзину", error)
        }
    }

    func shareMenuItem(for record: ShotRecord) -> NSMenuItem {
        NSSharingServicePicker(items: [record.url]).standardShareMenuItem
    }

    private func hangEditedCopy(at url: URL) {
        guard let probe = FileProbe.read(path: url.path), let size = ImageInfo.pixelSize(path: url.path) else { return }
        let record = ShotRecord(
            path: url.path, bookmark: ShotStore.bookmark(for: url), identity: probe.identity,
            addedAt: Date(), pixelWidth: size.width, pixelHeight: size.height)
        store.add(record)
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// Opens the system Markup editor (the same one Finder and Quick Look use).
/// If macOS does not offer it, the caller falls back to Preview, which has the same tools.
final class MarkupPresenter: NSObject, NSSharingServiceDelegate {
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")
    private var sourceFrame: NSRect = .zero
    private weak var sourceWindow: NSWindow?
    private var transitionImage: NSImage?
    private var originalURL: URL?
    private var onSavedCopy: ((URL) -> Void)?
    private var fallback: (() -> Void)?
    private var service: NSSharingService?

    static var isAvailable: Bool { NSSharingService(named: serviceName) != nil }

    func present(
        url: URL, sourceFrame: NSRect, window: NSWindow?, image: CGImage?,
        fallback: @escaping () -> Void, onSavedCopy: @escaping (URL) -> Void
    ) {
        guard let service = NSSharingService(named: Self.serviceName), service.canPerform(withItems: [url]) else {
            Log.actions.info("Markup service unavailable, opening Preview")
            fallback()
            return
        }
        self.sourceFrame = sourceFrame
        sourceWindow = window
        transitionImage = image.map { NSImage(cgImage: $0, size: sourceFrame.size) }
        originalURL = url
        self.onSavedCopy = onSavedCopy
        self.fallback = fallback
        self.service = service
        service.delegate = self
        NSApp.activate()
        service.perform(withItems: [url])
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        sourceFrame
    }

    func sharingService(
        _ sharingService: NSSharingService, transitionImageForShareItem item: Any,
        contentRect: UnsafeMutablePointer<NSRect>
    ) -> NSImage? {
        transitionImage
    }

    func sharingService(
        _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        sourceWindow
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        // Markup normally saves into the original file (we notice that through FSEvents).
        // If it hands back a separate result instead, keep it as a new file next to the original.
        for item in items {
            if let url = item as? URL, url != originalURL, FileManager.default.fileExists(atPath: url.path) {
                saveAlongside(sourceURL: url)
            } else if let image = item as? NSImage, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                writeAlongside(data: png)
            }
        }
        service = nil
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let nsError = error as NSError
        service = nil
        // Cancelling is reported as a failure; only fall back on real errors.
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError { return }
        Log.actions.error("Markup failed: \(error.localizedDescription, privacy: .public)")
        fallback?()
    }

    /// Name next to the original; the extension matches the format of the data written.
    private func editedURL(extension ext: String) -> URL? {
        guard let originalURL else { return nil }
        let base = originalURL.deletingPathExtension().lastPathComponent
        let folder = originalURL.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent("\(base) — разметка").appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) — разметка \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    private func saveAlongside(sourceURL: URL) {
        // The bytes are copied as they are, so keep the result's own extension (JPEG stays .jpg).
        let ext = sourceURL.pathExtension.isEmpty ? (originalURL?.pathExtension ?? "png") : sourceURL.pathExtension
        guard let destination = editedURL(extension: ext) else { return }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            onSavedCopy?(destination)
        } catch {
            Log.actions.error("Could not keep markup result: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `data` is always PNG here (encoded from the returned image).
    private func writeAlongside(data: Data) {
        guard let destination = editedURL(extension: "png") else { return }
        do {
            try data.write(to: destination, options: .withoutOverwriting)
            onSavedCopy?(destination)
        } catch {
            Log.actions.error("Could not write markup result: \(error.localizedDescription, privacy: .public)")
        }
    }
}
