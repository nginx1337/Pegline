import AppKit
import ImageIO
import UniformTypeIdentifiers
import PeglineCore

/// Notices images copied to the clipboard, including screenshots taken with ⌃⇧⌘3 / ⌃⇧⌘4,
/// which never become files.
///
/// macOS has no notification for clipboard changes, so the change counter is checked a few times
/// a second (a single integer, no data is read). Only when the types show an image that the
/// current mode wants is the data itself read. That read may show the system "paste" prompt
/// the first time; the user can allow it permanently in System Settings.
final class ClipboardWatcher {
    struct Capture {
        var data: Data
        var type: String
        var isScreenshot: Bool
    }

    /// More files than this in one copy are ignored.
    static let maxCopiedFiles = 8

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChange: Int
    private var ownChange = -1
    private var lastDigest: Int?

    var mode: ClipboardMode = .screenshots {
        didSet { mode == .off ? stop() : start() }
    }
    var onCapture: ((Capture) -> Void)?
    var onFiles: (([URL]) -> Void)?

    init() {
        lastChange = pasteboard.changeCount
    }

    /// Whether macOS currently refuses Pegline access to the clipboard.
    var isDenied: Bool { pasteboard.accessBehavior == .alwaysDeny }

    func start() {
        guard timer == nil, mode != .off else { return }
        lastChange = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called right after Pegline itself writes to the clipboard, so our own copies are not re-added.
    func ignoreOwnChange() {
        ownChange = pasteboard.changeCount
        lastChange = ownChange
    }

    /// Copied files: hang readable images, copy ones from temporary places, and for files we may not
    /// read (Telegram, Messages, Photos keep them in private containers) use the image data that came along.
    private func handleFileReferences(items: [[String]]) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Copying a big Finder selection is file management, not "hang these": skip it before
        // touching any file, so the line is not flooded and older photos are not pushed off.
        guard urls.count <= Self.maxCopiedFiles else {
            Log.detection.info("Skipped clipboard with \(urls.count) files (limit \(Self.maxCopiedFiles))")
            return
        }
        var inPlace: [URL] = []
        var copied = false
        var unreadable = false
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            let readable = exists && FileManager.default.isReadableFile(atPath: url.path)
            let imageType = readable && !isDir.boolValue ? Self.imageType(of: url) : nil
            // A folder is never a picture; the image next to it is just its icon.
            let reference: ClipboardClassifier.FileReference = exists && isDir.boolValue
                ? .notAnImage
                : ClipboardClassifier.fileReference(path: url.path, exists: exists, readable: readable, isImage: imageType != nil)
            Log.detection.info("Copied file \(url.lastPathComponent, privacy: .private): \(String(describing: reference), privacy: .public)")
            switch reference {
            case .imageInPlace:
                inPlace.append(url)
            case .imageToCopy:
                let size = FileProbe.read(path: url.path)?.size ?? -1
                if ImageLimits.allows(bytes: size), let data = try? Data(contentsOf: url), let imageType {
                    deliver(Capture(data: data, type: imageType, isScreenshot: false))
                    copied = true
                }
            case .unreadable:
                unreadable = true
            case .notAnImage:
                break
            }
        }
        if !inPlace.isEmpty { onFiles?(inPlace) }
        guard inPlace.isEmpty, !copied, unreadable else { return }
        let all = Set(items.flatMap { $0 })
        if let type = ClipboardClassifier.imageTypes.first(where: { all.contains($0) }) {
            captureImageData(type: type, isScreenshot: false)
        }
    }

    private func captureImageData(type: String, isScreenshot: Bool) {
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) else {
            Log.detection.error("Clipboard image could not be read (access denied?)")
            return
        }
        guard ImageLimits.allows(bytes: Int64(data.count)) else {
            Log.detection.info("Skipped clipboard image: \(data.count) bytes is over the limit")
            return
        }
        deliver(Capture(data: data, type: type, isScreenshot: isScreenshot))
    }

    /// The same picture copied twice in a row hangs only once.
    private func deliver(_ capture: Capture) {
        var hasher = Hasher()
        hasher.combine(capture.data)
        let digest = hasher.finalize()
        guard digest != lastDigest else { return }
        lastDigest = digest
        onCapture?(capture)
    }

    private static func imageType(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true
        else { return nil }
        return type
    }

    private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        guard count != ownChange, mode != .off else { return }

        let items = (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        let content = ClipboardClassifier.classify(items: items)
        Log.detection.info("Clipboard changed: \(items.description, privacy: .public)")
        guard ClipboardClassifier.accepts(content, mode: mode) else { return }

        switch content {
        case .imageFile:
            handleFileReferences(items: items)
        case .screenshotImage(let type):
            captureImageData(type: type, isScreenshot: true)
        case .otherImage(let type):
            captureImageData(type: type, isScreenshot: false)
        case .nothingUseful:
            break
        }
    }
}

/// Turns clipboard images into files so they can be dragged, opened and marked up like any screenshot.
enum ClipboardImporter {
    /// ~/Pictures/Pegline — outside protected folders, so no extra permission is needed.
    static var folder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pegline", isDirectory: true)
    }

    static func save(_ capture: ClipboardWatcher.Capture, date: Date = Date()) -> URL? {
        let folder = folder
        do {
            // Only the user can open this folder: copied images may be private.
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch {
            Log.detection.error("Cannot create \(folder.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Only real, reasonably sized images are written; anything else is dropped unseen.
        guard let pixels = ImageInfo.pixelSize(data: capture.data),
              ImageLimits.allows(width: pixels.width, height: pixels.height)
        else {
            Log.detection.info("Skipped clipboard data that is not a usable image")
            return nil
        }
        let ext = ClipboardClassifier.fileExtension(forType: capture.type)
        let keepsOriginal = ["public.png", "public.jpeg", "public.heic", "com.compuserve.gif"].contains(capture.type)
        let encoded = keepsOriginal ? capture.data : ImageInfo.pngData(from: capture.data)
        guard let png = encoded else { return nil }
        let name = ClipboardClassifier.fileName(for: date, screenshot: capture.isScreenshot, extension: ext)
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent((name as NSString).deletingPathExtension + " (\(n)).\(ext)")
            n += 1
        }
        do {
            try png.write(to: url, options: .withoutOverwriting)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if capture.isScreenshot {
                // Mark it like the system tool does, so it is recognised as a screenshot everywhere.
                let flag: [UInt8] = [1]
                setxattr(url.path, ScreenshotClassifier.screenCaptureAttribute, flag, flag.count, 0, 0)
            }
            return url
        } catch {
            Log.detection.error("Cannot save clipboard image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
