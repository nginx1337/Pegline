import Foundation
import Darwin

/// Which files in the watched folder are allowed onto the line.
public enum CapturePolicy: String, Codable, Sendable, CaseIterable {
    /// Only files macOS marked as screenshots (or that are named like one).
    case screenshotsOnly
    /// Any supported image that appears in the folder (useful for a dedicated folder).
    case allImages
}

/// Decides whether a file looks like a screenshot we should hang on the line.
public struct ScreenshotClassifier: Sendable {
    /// Extended attribute the system screenshot tool writes on every capture.
    public static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"
    ]

    /// Default file name prefixes used by the system tool in common languages.
    public static let defaultPrefixes: [String] = [
        "Снимок экрана", "Screenshot", "Screen Shot", "Bildschirmfoto", "Capture d’écran",
        "Capture d'écran", "Captura de pantalla", "Captura de Tela", "Schermata",
        "Schermafbeelding", "Zrzut ekranu", "スクリーンショット", "截屏", "螢幕快照", "스크린샷"
    ]

    public var prefixes: [String]

    public init(customPrefix: String? = nil) {
        var all = Self.defaultPrefixes
        if let custom = customPrefix?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            all.insert(custom, at: 0)
        }
        prefixes = all
    }

    /// True for visible files with an image extension we can display.
    public func isImageCandidate(fileName name: String) -> Bool {
        guard !name.hasPrefix("."), !name.hasPrefix("~") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }

    /// True if the name follows the system screenshot naming scheme.
    public func nameLooksLikeScreenshot(_ name: String) -> Bool {
        let folded = name.precomposedStringWithCanonicalMapping
        return prefixes.contains { folded.hasPrefix($0.precomposedStringWithCanonicalMapping) }
    }

    /// Full decision for a file that already exists on disk.
    public func accepts(path: String, policy: CapturePolicy) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard isImageCandidate(fileName: name) else { return false }
        switch policy {
        case .allImages:
            return true
        case .screenshotsOnly:
            return Self.hasScreenCaptureAttribute(atPath: path) || nameLooksLikeScreenshot(name)
        }
    }

    public static func hasScreenCaptureAttribute(atPath path: String) -> Bool {
        getxattr(path, screenCaptureAttribute, nil, 0, 0, 0) >= 0
    }
}
