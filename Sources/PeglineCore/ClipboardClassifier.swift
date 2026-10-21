import Foundation

/// Which clipboard images go onto the line.
public enum ClipboardMode: String, Codable, Sendable, CaseIterable {
    /// Ignore the clipboard.
    case off
    /// Only screenshots taken with "copy to clipboard" (⌃⇧⌘3, ⌃⇧⌘4, or the Clipboard option in ⇧⌘5).
    case screenshots
    /// Any copied image: screenshots, pictures from browsers and editors, image files from Finder.
    case allImages
}

/// What a clipboard change contains, decided from type identifiers only.
/// Looking at types does not read any data, so it does not trigger the system paste prompt.
public enum ClipboardContent: Equatable, Sendable {
    case nothingUseful
    /// Raw image data with nothing else attached: what the system screenshot tool puts there.
    case screenshotImage(type: String)
    /// Image data that came with other things (a web page, rich text, a file), e.g. "Copy Image" in a browser.
    case otherImage(type: String)
    /// A file was copied (for example in Finder); the file itself can go on the line.
    case imageFile
}

public enum ClipboardClassifier {
    /// Image types we can read, best first.
    public static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"]

    /// Types that reveal the image came from somewhere other than a screen capture.
    static let foreignMarkers: Set<String> = [
        "public.html", "public.url", "public.utf8-plain-text", "public.utf16-plain-text", "public.rtf",
        "com.apple.webarchive", "com.apple.flat-rtfd", "public.file-url", "com.adobe.pdf",
        "org.chromium.source-url", "org.chromium.web-custom-data", "com.apple.pasteboard.promised-file-url"
    ]

    /// Decides from the type lists of each pasteboard item.
    public static func classify(items: [[String]]) -> ClipboardContent {
        guard !items.isEmpty else { return .nothingUseful }
        let all = Set(items.flatMap { $0 })
        if all.contains("public.file-url") {
            return .imageFile
        }
        guard let type = imageTypes.first(where: { all.contains($0) }) else { return .nothingUseful }
        // A capture is a single item holding only image representations. Private system types
        // (dyn.*, com.apple.*) and legacy aliases ("Apple PNG pasteboard type") do not count.
        let extras = all.subtracting(imageTypes).filter { type in
            if foreignMarkers.contains(type) { return true }
            return !type.hasPrefix("dyn.") && !type.hasPrefix("com.apple.") && !type.hasSuffix("pasteboard type")
        }
        if items.count == 1, extras.isEmpty {
            return .screenshotImage(type: type)
        }
        return .otherImage(type: type)
    }

    /// Whether the mode wants this content.
    public static func accepts(_ content: ClipboardContent, mode: ClipboardMode) -> Bool {
        switch (mode, content) {
        case (.off, _), (_, .nothingUseful): return false
        case (.screenshots, .screenshotImage): return true
        case (.screenshots, _): return false
        case (.allImages, _): return true
        }
    }

    /// What a copied file reference is good for.
    public enum FileReference: Equatable, Sendable {
        /// A readable image in a normal place (for example copied in Finder): hang the file itself.
        case imageInPlace
        /// A readable image in a temporary or app-private place that may vanish soon: hang a copy.
        case imageToCopy
        /// The file exists but is not an image (PDF, folder…); the image data next to it is only an icon.
        case notAnImage
        /// The file cannot be read (another app's private container, deleted temp file):
        /// use the image data that came with it instead. Telegram, Messages and Photos copy like this.
        case unreadable
    }

    public static func fileReference(path: String, exists: Bool, readable: Bool, isImage: Bool) -> FileReference {
        guard exists, readable else { return .unreadable }
        guard isImage else { return .notAnImage }
        return isTemporaryLocation(path) ? .imageToCopy : .imageInPlace
    }

    /// Places where apps keep scratch copies: other apps' containers, caches and temporary folders.
    public static func isTemporaryLocation(_ path: String) -> Bool {
        let markers = ["/Library/Containers/", "/Library/Group Containers/", "/Library/Caches/",
                       "/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        return markers.contains { path.contains($0) } || path.hasPrefix(NSTemporaryDirectory())
            || FileLocations.isInTrash(path)
    }

    /// File extension to keep the original encoding where it is widely readable; TIFF becomes PNG.
    public static func fileExtension(forType type: String) -> String {
        switch type {
        case "public.jpeg": "jpg"
        case "public.heic": "heic"
        case "com.compuserve.gif": "gif"
        default: "png"
        }
    }

    /// "Снимок из буфера — 2026-10-21 в 00.15.32.png", mirroring the system naming.
    public static func fileName(for date: Date, screenshot: Bool, extension ext: String = "png", calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d в %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(screenshot ? "Снимок из буфера" : "Изображение из буфера") — \(stamp).\(ext)"
    }
}
