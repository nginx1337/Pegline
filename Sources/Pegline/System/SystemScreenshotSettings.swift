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
    private let defaults: UserDefaults
    private let domain: CFString

    /// The domain and defaults can be swapped for a scratch pair in the self-test.
    init(domain: CFString = SystemScreenshotPrefs.domain, defaults: UserDefaults = .standard) {
        self.domain = domain
        self.defaults = defaults
    }
    private let originalsKey = "screencaptureOriginals"
    private let appliedKey = "screencaptureApplied"
    private static let absentMarker = "__pegline_absent__"

    /// Saved original values: key → value (or the absent marker).
    private var originals: [String: Any] {
        get { defaults.dictionary(forKey: originalsKey) ?? [:] }
        set { store(newValue, originalsKey) }
    }

    /// Values Pegline itself wrote, to tell them apart from later changes the user made in ⇧⌘5.
    private var applied: [String: Any] {
        get { defaults.dictionary(forKey: appliedKey) ?? [:] }
        set { store(newValue, appliedKey) }
    }

    private func store(_ value: [String: Any], _ key: String) {
        if value.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
    }

    var hasChanges: Bool { !originals.isEmpty }

    /// Applies the options the user turned on in Pegline. If the user has since changed one of
    /// those settings in the system tool, their choice wins and Pegline stops managing it.
    func applyManaged(_ prefs: Preferences) {
        var dropThumbnail = false, dropLocation = false
        if prefs.manageFloatingThumbnail {
            dropThumbnail = !set("show-thumbnail", false as CFPropertyList)
        } else {
            restore("show-thumbnail")
        }
        if prefs.manageLocation, let path = prefs.managedLocationPath {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            dropLocation = !set("location", path as CFPropertyList)
        } else {
            restore("location")
        }
        updateSuddenTermination()
        // Changed after the work above, since these posts re-enter applyManaged.
        if dropThumbnail { prefs.manageFloatingThumbnail = false }
        if dropLocation { prefs.manageLocation = false }
    }

    /// Puts every value Pegline changed back as it was, unless the user changed it since.
    func restoreAll() {
        for key in originals.keys { restore(key) }
        updateSuddenTermination()
    }

    private func current(_ key: String) -> CFPropertyList? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private static func same(_ a: CFPropertyList?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b as CFTypeRef)
        default: return false
        }
    }

    /// Writes Pegline's value. Returns false (and writes nothing) when the user changed the
    /// setting outside Pegline after Pegline last wrote it.
    func set(_ key: String, _ value: CFPropertyList) -> Bool {
        let now = current(key)
        var savedOriginals = originals, savedApplied = applied
        if savedOriginals[key] != nil, let ours = savedApplied[key], !Self.same(now, ours) {
            savedOriginals[key] = nil
            savedApplied[key] = nil
            originals = savedOriginals
            applied = savedApplied
            Log.system.info("User changed screencapture \(key, privacy: .public) outside Pegline; keeping their value")
            return false
        }
        if savedOriginals[key] == nil {
            // Remember the original only once, so a crash never makes our value look "original".
            savedOriginals[key] = now ?? Self.absentMarker as CFPropertyList
            originals = savedOriginals
            Log.system.info("Saved original screencapture \(key, privacy: .public)")
        }
        CFPreferencesSetAppValue(key as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
        savedApplied[key] = value
        applied = savedApplied
        return true
    }

    func restore(_ key: String) {
        var savedOriginals = originals, savedApplied = applied
        guard let original = savedOriginals[key] else { return }
        if let ours = savedApplied[key], !Self.same(current(key), ours) {
            // The user picked something else in the system tool since; do not undo that.
            Log.system.info("Not restoring screencapture \(key, privacy: .public): changed by the user")
        } else {
            let value: CFPropertyList? = (original as? String) == Self.absentMarker ? nil : original as CFPropertyList
            CFPreferencesSetAppValue(key as CFString, value, domain)
            CFPreferencesAppSynchronize(domain)
            Log.system.info("Restored screencapture \(key, privacy: .public)")
        }
        savedOriginals[key] = nil
        savedApplied[key] = nil
        originals = savedOriginals
        applied = savedApplied
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
