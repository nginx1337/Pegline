import AppKit
import Observation
import PeglineCore

enum ThumbnailSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    /// Maximum card width in points.
    var maxWidth: CGFloat {
        switch self {
        case .small: 116
        case .medium: 152
        case .large: 200
        }
    }

    var title: String {
        switch self {
        case .small: "Маленькие"
        case .medium: "Средние"
        case .large: "Крупные"
        }
    }
}

enum MotionStyle: String, CaseIterable, Identifiable {
    /// Gentle idle sway plus reactions.
    case lively
    /// Photos move only when something happens: a new shot, the cursor brushing past.
    case calm
    /// Fades only.
    case off
    var id: String { rawValue }

    var title: String {
        switch self {
        case .lively: "Живые"
        case .calm: "Спокойные"
        case .off: "Без движения"
        }
    }

    var detail: String {
        switch self {
        case .lively: "Фотографии чуть покачиваются, пока верёвка на экране"
        case .calm: "Движение только при появлении снимка и касании курсором"
        case .off: "Только плавное появление и исчезновение"
        }
    }
}

enum RevealDelay: String, CaseIterable, Identifiable {
    case quick, normal, relaxed
    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .quick: 0.15
        case .normal: 0.4
        case .relaxed: 0.9
        }
    }

    var title: String {
        switch self {
        case .quick: "Быстро"
        case .normal: "Обычно"
        case .relaxed: "С паузой"
        }
    }
}

enum FolderMode: String {
    /// Follow wherever macOS saves screenshots (and follow changes).
    case system
    /// A folder the user picked.
    case custom
}

extension Notification.Name {
    static let peglinePreferencesChanged = Notification.Name("PeglinePreferencesChanged")
}

/// User settings, stored in the app's own defaults. Nothing here touches system settings.
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var thumbnailSize: ThumbnailSize { didSet { store(thumbnailSize.rawValue, "thumbnailSize") } }
    var visibleCount: Int { didSet { store(visibleCount, "visibleCount") } }
    var motion: MotionStyle { didSet { store(motion.rawValue, "motion") } }
    var revealOnEdge: Bool { didSet { store(revealOnEdge, "revealOnEdge") } }
    var revealDelay: RevealDelay { didSet { store(revealDelay.rawValue, "revealDelay") } }
    var autoHide: Bool { didSet { store(autoHide, "autoHide") } }
    var showOnNewShot: Bool { didSet { store(showOnNewShot, "showOnNewShot") } }
    var autoHideDelay: Double { didSet { store(autoHideDelay, "autoHideDelay") } }
    var folderMode: FolderMode { didSet { store(folderMode.rawValue, "folderMode") } }
    var customFolderPath: String? { didSet { store(customFolderPath, "customFolderPath") } }
    var capturePolicy: CapturePolicy { didSet { store(capturePolicy.rawValue, "capturePolicy") } }
    var useSpotlight: Bool { didSet { store(useSpotlight, "useSpotlight") } }
    var clipboardMode: ClipboardMode { didSet { store(clipboardMode.rawValue, "clipboardMode") } }
    var lineCapacity: Int { didSet { store(lineCapacity, "lineCapacity") } }
    var hotKey: HotKeyCombo? {
        didSet {
            let data = hotKey.flatMap { try? JSONEncoder().encode($0) }
            store(data, "hotKey")
        }
    }
    var onboardingCompleted: Bool { didSet { store(onboardingCompleted, "onboardingCompleted") } }

    // Consent-based changes to the system screenshot tool (applied only while Pegline runs).
    var manageFloatingThumbnail: Bool { didSet { store(manageFloatingThumbnail, "manageFloatingThumbnail") } }
    var manageLocation: Bool { didSet { store(manageLocation, "manageLocation") } }
    var managedLocationPath: String? { didSet { store(managedLocationPath, "managedLocationPath") } }

    private init() {
        let d = UserDefaults.standard
        thumbnailSize = ThumbnailSize(rawValue: d.string(forKey: "thumbnailSize") ?? "") ?? .medium
        visibleCount = d.object(forKey: "visibleCount") as? Int ?? 7
        motion = MotionStyle(rawValue: d.string(forKey: "motion") ?? "") ?? .lively
        revealOnEdge = d.object(forKey: "revealOnEdge") as? Bool ?? true
        revealDelay = RevealDelay(rawValue: d.string(forKey: "revealDelay") ?? "") ?? .normal
        autoHide = d.object(forKey: "autoHide") as? Bool ?? true
        showOnNewShot = d.object(forKey: "showOnNewShot") as? Bool ?? true
        autoHideDelay = d.object(forKey: "autoHideDelay") as? Double ?? 6
        folderMode = FolderMode(rawValue: d.string(forKey: "folderMode") ?? "") ?? .system
        customFolderPath = d.string(forKey: "customFolderPath")
        capturePolicy = CapturePolicy(rawValue: d.string(forKey: "capturePolicy") ?? "") ?? .screenshotsOnly
        useSpotlight = d.object(forKey: "useSpotlight") as? Bool ?? true
        clipboardMode = ClipboardMode(rawValue: d.string(forKey: "clipboardMode") ?? "") ?? .screenshots
        lineCapacity = d.object(forKey: "lineCapacity") as? Int ?? 60
        if let data = d.data(forKey: "hotKey") {
            hotKey = (try? JSONDecoder().decode(HotKeyCombo.self, from: data))?.normalized()
        } else {
            hotKey = d.object(forKey: "hotKeyCleared") == nil ? .defaultCombo : nil
        }
        onboardingCompleted = d.bool(forKey: "onboardingCompleted")
        manageFloatingThumbnail = d.bool(forKey: "manageFloatingThumbnail")
        manageLocation = d.bool(forKey: "manageLocation")
        managedLocationPath = d.string(forKey: "managedLocationPath")
    }

    private func store(_ value: Any?, _ key: String) {
        if key == "hotKey" {
            if value == nil { defaults.set(true, forKey: "hotKeyCleared") } else { defaults.removeObject(forKey: "hotKeyCleared") }
        }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: .peglinePreferencesChanged, object: self, userInfo: ["key": key])
    }

    /// Whether motion should play, respecting the system "Reduce motion" setting.
    var effectiveMotion: MotionStyle {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .off : motion
    }

    static let visibleCountChoices = [4, 5, 6, 7, 8, 10, 12]

    static func title(for mode: ClipboardMode) -> String {
        switch mode {
        case .off: "Не добавлять"
        case .screenshots: "Только снимки экрана"
        case .allImages: "Любые скопированные изображения"
        }
    }
}
