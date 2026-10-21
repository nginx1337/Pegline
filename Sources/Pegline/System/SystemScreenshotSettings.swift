import AppKit

/// Read-only view of the system screenshot tool's settings (domain com.apple.screencapture).
enum SystemScreenshotPrefs {
    static var domain: CFString { "com.apple.screencapture" as CFString }

    static func value(_ key: String) -> CFPropertyList? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    /// Folder where macOS saves screenshots. Defaults to the Desktop.
    static var location: URL {
        if let raw = value("location") as? String, !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// Whether the floating thumbnail is shown (it delays saving the file by about five seconds).
    static var showsFloatingThumbnail: Bool {
        (value("show-thumbnail") as? Bool) ?? true
    }

    /// Custom file name prefix, if the user set one.
    static var namePrefix: String? { value("name") as? String }

    /// "file", "clipboard", "preview", "mail", "messages". Only "file" produces files we can see.
    static var target: String { (value("target-screenshot") as? String) ?? (value("target") as? String) ?? "file" }

    static var savesToFile: Bool { target == "file" }
}

/// Changes to the system screenshot tool that the user explicitly agreed to.
/// Original values are saved before the first change and restored when Pegline quits
/// or when the user turns an option off. Changes are re-applied on the next launch.
final class ScreenshotSystemSettings {
    private let defaults = UserDefaults.standard
    private let originalsKey = "screencaptureOriginals"
    private static let absentMarker = "__pegline_absent__"

    /// Saved original values: key → value (or the absent marker).
    private var originals: [String: Any] {
        get { defaults.dictionary(forKey: originalsKey) ?? [:] }
        set {
            if newValue.isEmpty { defaults.removeObject(forKey: originalsKey) } else { defaults.set(newValue, forKey: originalsKey) }
        }
    }

    var hasChanges: Bool { !originals.isEmpty }

    /// Applies the options the user turned on in Pegline.
    func applyManaged(_ prefs: Preferences) {
        if prefs.manageFloatingThumbnail {
            set("show-thumbnail", false as CFPropertyList)
        } else {
            restore("show-thumbnail")
        }
        if prefs.manageLocation, let path = prefs.managedLocationPath {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            set("location", path as CFPropertyList)
        } else {
            restore("location")
        }
        updateSuddenTermination()
    }

    /// Puts every changed value back exactly as it was.
    func restoreAll() {
        for key in originals.keys { restore(key) }
        updateSuddenTermination()
    }

    private func set(_ key: String, _ value: CFPropertyList) {
        var saved = originals
        if saved[key] == nil {
            // Remember the original only once, so a crash never makes our value look "original".
            let current = CFPreferencesCopyAppValue(key as CFString, SystemScreenshotPrefs.domain)
            saved[key] = current ?? Self.absentMarker as CFPropertyList
            originals = saved
            Log.system.info("Saved original screencapture \(key, privacy: .public)")
        }
        CFPreferencesSetAppValue(key as CFString, value, SystemScreenshotPrefs.domain)
        CFPreferencesAppSynchronize(SystemScreenshotPrefs.domain)
    }

    private func restore(_ key: String) {
        var saved = originals
        guard let original = saved[key] else { return }
        if let marker = original as? String, marker == Self.absentMarker {
            CFPreferencesSetAppValue(key as CFString, nil, SystemScreenshotPrefs.domain)
        } else {
            CFPreferencesSetAppValue(key as CFString, original as CFPropertyList, SystemScreenshotPrefs.domain)
        }
        CFPreferencesAppSynchronize(SystemScreenshotPrefs.domain)
        saved[key] = nil
        originals = saved
        Log.system.info("Restored screencapture \(key, privacy: .public)")
    }

    private var suddenTerminationDisabled = false

    /// While system settings are changed, macOS must let us run our clean-up on quit.
    private func updateSuddenTermination() {
        if hasChanges, !suddenTerminationDisabled {
            ProcessInfo.processInfo.disableSuddenTermination()
            suddenTerminationDisabled = true
        } else if !hasChanges, suddenTerminationDisabled {
            ProcessInfo.processInfo.enableSuddenTermination()
            suddenTerminationDisabled = false
        }
    }
}
