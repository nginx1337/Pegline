import AppKit
import Observation
import PeglineCore

/// Wires the parts together and holds the state the settings and onboarding windows show.
@Observable
final class AppModel {
    let prefs = Preferences.shared
    @ObservationIgnored let store: ShotStore
    @ObservationIgnored let thumbnails = ThumbnailLoader()
    @ObservationIgnored let actions: ShotActions
    @ObservationIgnored let detector: ScreenshotDetector
    @ObservationIgnored let systemSettings = ScreenshotSystemSettings()
    @ObservationIgnored let clipboard = ClipboardWatcher()
    @ObservationIgnored private(set) var line: LineController!
    @ObservationIgnored private var statusMenu: StatusMenuController!
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var lastFolderKeys: [String] = []

    // Observable state for SwiftUI.
    var folderPath = ""
    var accessProblem: String?
    var hotKeyProblem: String?
    var loginItemEnabled = LoginItem.isEnabled
    var loginItemMessage: String?
    var systemSettingsChanged = false
    var shotsAddedThisSession = 0
    var floatingThumbnailShown = SystemScreenshotPrefs.showsFloatingThumbnail
    var savesToFile = SystemScreenshotPrefs.savesToFile
    var clipboardDenied = false

    init() {
        store = ShotStore(capacity: Preferences.shared.lineCapacity)
        actions = ShotActions(store: store)
        detector = ScreenshotDetector(store: store, prefs: Preferences.shared)
    }

    func start() {
        // Files may have been renamed, moved or deleted while Pegline was not running.
        store.reconcileAll()
        // Re-apply only the system changes the user agreed to earlier (originals are kept safe).
        #if DEBUG
        let isolated = ProcessInfo.processInfo.environment["PEGLINE_STORE_DIR"] != nil
        #else
        let isolated = false
        #endif
        if !isolated { systemSettings.applyManaged(prefs) }
        refreshSystemState()

        line = LineController(store: store, prefs: prefs, actions: actions, thumbnails: thumbnails)
        statusMenu = StatusMenuController(model: self)
        line.onVisibilityChanged = { [weak self] visible in self?.statusMenu.setLineVisible(visible) }

        detector.onStateChanged = { [weak self] in self?.refreshDetectorState() }
        detector.onShotAdded = { [weak self] _ in self?.shotsAddedThisSession += 1 }
        detector.start()
        refreshDetectorState()
        startClipboard()

        HotKeyCenter.shared.action = { [weak self] in self?.line.toggle() }
        registerHotKey()

        NotificationCenter.default.addObserver(forName: .peglinePreferencesChanged, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? ""
            MainActor.assumeIsolated { self?.preferenceChanged(key) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.reconcileAll()
                self?.detector.refreshFolder()
            }
        }

        if !prefs.onboardingCompleted { openOnboarding() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["PEGLINE_SELFTEST"] != nil { SelfTest.run(self) }
        #endif
    }

    func shutdown() {
        store.saveNow()
        #if DEBUG
        // An isolated self-test instance must not undo what the real instance applied.
        if ProcessInfo.processInfo.environment["PEGLINE_STORE_DIR"] != nil { return }
        #endif
        // Leave the system screenshot tool exactly as we found it.
        systemSettings.restoreAll()
    }

    private func preferenceChanged(_ key: String) {
        switch key {
        case "folderMode", "customFolderPath":
            detector.refreshFolder()
        case "useSpotlight":
            detector.updateSpotlight()
        case "clipboardMode":
            clipboard.mode = prefs.clipboardMode
            refreshSystemState()
        case "hotKey":
            registerHotKey()
        case "manageFloatingThumbnail", "manageLocation", "managedLocationPath":
            systemSettings.applyManaged(prefs)
            detector.refreshFolder()
            refreshSystemState()
        default:
            break
        }
    }

    private func registerHotKey() {
        let ok = HotKeyCenter.shared.register(prefs.hotKey)
        hotKeyProblem = ok ? nil : "Это сочетание уже занято системой или другой программой."
    }

    private func refreshDetectorState() {
        folderPath = ShotFormatting.abbreviatedPath(detector.folder)
        accessProblem = detector.accessProblem
        refreshSystemState()
    }

    func refreshSystemState() {
        systemSettingsChanged = systemSettings.hasChanges
        floatingThumbnailShown = SystemScreenshotPrefs.showsFloatingThumbnail
        savesToFile = SystemScreenshotPrefs.savesToFile
        clipboardDenied = prefs.clipboardMode != .off && clipboard.isDenied
    }

    // MARK: Clipboard

    private func startClipboard() {
        actions.onDidWritePasteboard = { [weak self] in self?.clipboard.ignoreOwnChange() }
        clipboard.onCapture = { [weak self] capture in self?.hangClipboardImage(capture) }
        clipboard.onFiles = { [weak self] urls in self?.hangCopiedFiles(urls) }
        clipboard.mode = prefs.clipboardMode
    }

    private func hangClipboardImage(_ capture: ClipboardWatcher.Capture) {
        guard let url = ClipboardImporter.save(capture),
              let probe = FileProbe.read(path: url.path),
              let size = ImageInfo.pixelSize(path: url.path)
        else { return }
        let record = ShotRecord(
            path: url.path, bookmark: ShotStore.bookmark(for: url), identity: probe.identity,
            addedAt: Date(), pixelWidth: size.width, pixelHeight: size.height, origin: "clipboard")
        if store.add(record) {
            shotsAddedThisSession += 1
            Log.detection.info("Clipboard image saved as \(url.lastPathComponent, privacy: .private)")
        }
    }

    /// Image files copied in Finder go on the line as they are; nothing is duplicated.
    private func hangCopiedFiles(_ urls: [URL]) {
        let classifier = ScreenshotClassifier()
        for url in urls.reversed() where classifier.isImageCandidate(fileName: url.lastPathComponent) {
            guard let probe = FileProbe.read(path: url.path), let size = ImageInfo.pixelSize(path: url.path) else { continue }
            let record = ShotRecord(
                path: url.path, bookmark: ShotStore.bookmark(for: url), identity: probe.identity,
                addedAt: Date(), pixelWidth: size.width, pixelHeight: size.height, origin: "copiedFile")
            if store.add(record) { shotsAddedThisSession += 1 }
        }
    }

    // MARK: Consent-based system changes

    /// Turns the floating thumbnail off only after the user confirms in a dialog.
    func setFloatingThumbnailManaged(_ enabled: Bool) {
        if enabled {
            let confirmed = confirm(
                title: "Сохранять снимок сразу?",
                message: "Pegline отключит плавающую миниатюру в системном инструменте «Снимок экрана» — тогда файл сохраняется сразу и почти мгновенно появляется на верёвке.\n\nИсходное значение сохранено. Оно вернётся, когда вы выключите этот параметр или выйдете из Pegline.",
                button: "Отключить миниатюру")
            guard confirmed else { return }
        }
        prefs.manageFloatingThumbnail = enabled
    }

    /// Points the system screenshot tool to another folder, only after confirmation.
    func setLocationManaged(_ enabled: Bool) {
        if enabled {
            guard let folder = pickFolder(
                title: "Куда сохранять снимки экрана",
                message: "Пока Pegline работает, системный инструмент будет сохранять снимки в эту папку.",
                start: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first)
            else { return }
            let confirmed = confirm(
                title: "Сохранять снимки в «\(folder.lastPathComponent)»?",
                message: "Pegline изменит папку сохранения в системном инструменте «Снимок экрана» на \(ShotFormatting.abbreviatedPath(folder)).\n\nПрежняя папка сохранена и вернётся, когда вы выключите этот параметр или выйдете из Pegline.",
                button: "Изменить папку")
            guard confirmed else { return }
            prefs.managedLocationPath = folder.path
            prefs.manageLocation = true
        } else {
            prefs.manageLocation = false
        }
    }

    func restoreSystemSettingsNow() {
        prefs.manageFloatingThumbnail = false
        prefs.manageLocation = false
        systemSettings.restoreAll()
        detector.refreshFolder()
        refreshSystemState()
    }

    // MARK: Other commands

    func chooseCustomFolder() {
        guard let folder = pickFolder(
            title: "Папка для слежения",
            message: "Pegline будет добавлять на верёвку новые снимки из этой папки.",
            start: detector.folder)
        else { return }
        prefs.customFolderPath = folder.path
        prefs.folderMode = .custom
    }

    func setLoginItem(_ enabled: Bool) {
        loginItemMessage = LoginItem.set(enabled)
        loginItemEnabled = LoginItem.isEnabled
    }

    /// Asks macOS for access (the first read shows the system prompt). If access was already
    /// refused, macOS will not ask again, so open the Privacy pane where it can be turned on.
    func requestFolderAccess() {
        let granted = detector.checkAccess()
        refreshDetectorState()
        if !granted { PrivacyLinks.openFilesAndFolders() }
    }

    func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(model: self)
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindow.make(model: self) { [weak self] in
                self?.prefs.onboardingCompleted = true
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        }
        NSApp.activate()
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    func showAbout() {
        NSApp.activate()
        let credits = NSMutableAttributedString(
            string: "Снимки экрана на бельевой верёвке.\nВсё хранится только на этом Mac: без сети, аналитики и учётных записей.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Pegline"])
    }

    // MARK: Dialog helpers

    private func confirm(title: String, message: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Отменить")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func pickFolder(title: String, message: String, start: URL?) -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Выбрать"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}
