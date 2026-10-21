import Foundation
import PeglineCore

/// Turns raw file system activity into "a new screenshot is ready".
///
/// Pipeline: FSEvents / Spotlight report a path → wait a moment → check the file is new, looks like a
/// screenshot, has stopped growing and decodes as a complete image → add it to the store once.
final class ScreenshotDetector {
    enum Source { case folder, spotlight }

    private struct Pending {
        var attempts = 0
        var lastProbe: FileProbe?
        var source: Source
        var task: Task<Void, Never>?
    }

    private let store: ShotStore
    private let prefs: Preferences
    private var watcher: FolderWatcher?
    private let spotlight = SpotlightWatcher()
    /// Files created before this moment are never added, so launching does not flood the line.
    let sessionStart = Date()
    private var pending: [String: Pending] = [:]
    private var classifier = ScreenshotClassifier()

    private(set) var folder: URL
    /// Set when the folder cannot be read (for example access was denied in Privacy settings).
    private(set) var accessProblem: String?

    var onShotAdded: ((ShotRecord) -> Void)?
    var onStateChanged: (() -> Void)?

    init(store: ShotStore, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
        folder = Self.resolveFolder(prefs)
    }

    static func resolveFolder(_ prefs: Preferences) -> URL {
        if prefs.folderMode == .custom, let path = prefs.customFolderPath {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return SystemScreenshotPrefs.location
    }

    func start() {
        classifier = ScreenshotClassifier(customPrefix: SystemScreenshotPrefs.namePrefix)
        restartWatcher()
        spotlight.onFound = { [weak self] paths in
            for path in paths { self?.consider(path: path, source: .spotlight) }
        }
        updateSpotlight()
    }

    func updateSpotlight() {
        if prefs.useSpotlight { spotlight.start(since: sessionStart) } else { spotlight.stop() }
    }

    /// Re-reads where screenshots go; switches the watcher if it changed.
    func refreshFolder() {
        classifier = ScreenshotClassifier(customPrefix: SystemScreenshotPrefs.namePrefix)
        let resolved = Self.resolveFolder(prefs)
        if resolved.standardizedFileURL.path != folder.standardizedFileURL.path {
            Log.detection.info("Screenshot folder is now \(resolved.path, privacy: .public)")
            folder = resolved
            restartWatcher()
        } else {
            checkAccess()
        }
        onStateChanged?()
    }

    private func restartWatcher() {
        watcher?.stop()
        let watcher = FolderWatcher(folder: folder)
        watcher.handler = { [weak self] events in self?.handle(events) }
        watcher.start()
        self.watcher = watcher
        checkAccess()
    }

    /// Reading the folder once is also what makes macOS ask for access to Desktop/Documents/Downloads.
    @discardableResult
    func checkAccess() -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            accessProblem = nil
        } catch {
            accessProblem = "Нет доступа к папке «\(folder.lastPathComponent)». Разрешите доступ в Системных настройках → Конфиденциальность и безопасность → Файлы и папки."
            Log.detection.error("No access to \(self.folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        onStateChanged?()
        return accessProblem == nil
    }

    // MARK: Events

    private func handle(_ events: [FolderWatcher.Event]) {
        guard let watcher else { return }
        for event in events {
            if event.isRootChange {
                // The watched folder itself was moved or deleted.
                refreshFolder()
                continue
            }
            if event.mustRescan {
                store.reconcileAll()
                continue
            }
            let path = event.path
            if store.isTracked(path: path) {
                if event.isRemovedOrRenamed || event.isContentChange {
                    store.refresh(path: path, contentMayHaveChanged: event.isContentChange)
                }
                continue
            }
            // Only files directly inside the folder; ignore busy subfolders.
            guard (path as NSString).deletingLastPathComponent == watcher.canonicalPath else { continue }
            consider(path: path, source: .folder)
        }
    }

    private func consider(path: String, source: Source) {
        let name = (path as NSString).lastPathComponent
        guard classifier.isImageCandidate(fileName: name) else { return }
        guard pending[path] == nil, !store.isTracked(path: path) else { return }
        pending[path] = Pending(source: source)
        schedule(path, after: 0.06)
    }

    private func schedule(_ path: String, after delay: TimeInterval) {
        pending[path]?.task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.check(path)
        }
    }

    private func finish(_ path: String, _ reason: StaticString) {
        pending[path] = nil
    }

    private func retry(_ path: String, _ state: Pending) {
        pending[path] = state
        if state.attempts >= StabilityCheck.maxAttempts {
            Log.detection.info("Gave up waiting for \((path as NSString).lastPathComponent, privacy: .public)")
            finish(path, "timeout")
            return
        }
        schedule(path, after: StabilityCheck.retryDelay(attempt: state.attempts))
    }

    private func check(_ path: String) async {
        guard var state = pending[path] else { return }
        state.attempts += 1

        guard let probe = FileProbe.read(path: path) else {
            // Temporary files vanish after being renamed; the final name gets its own event.
            return finish(path, "gone")
        }
        if probe.created < sessionStart.timeIntervalSince1970 - 2 {
            return finish(path, "pre-existing")
        }
        if store.isTracked(identity: probe.identity) || store.isTracked(path: path) {
            return finish(path, "duplicate")
        }
        let policy: CapturePolicy = state.source == .spotlight ? .screenshotsOnly : prefs.capturePolicy
        if !classifier.accepts(path: path, policy: policy) {
            // The screenshot attribute may land a moment after the file; look a few more times.
            if state.attempts < 4 { return retry(path, state) }
            return finish(path, "not a screenshot")
        }

        switch StabilityCheck.verdict(previous: state.lastProbe, current: probe) {
        case .gone:
            finish(path, "gone")
        case .wait:
            state.lastProbe = probe
            retry(path, state)
        case .stable:
            let size = await Task.detached(priority: .userInitiated) { ImageInfo.pixelSize(path: path) }.value
            guard pending[path] != nil else { return }
            guard let size else {
                // Not decodable yet: still being written, or not an image at all.
                state.lastProbe = probe
                return retry(path, state)
            }
            accept(path: path, probe: probe, size: size, source: state.source)
        }
    }

    private func accept(path: String, probe: FileProbe, size: ImageInfo.PixelSize, source: Source) {
        finish(path, "accepted")
        let url = URL(fileURLWithPath: path)
        let record = ShotRecord(
            path: path, bookmark: ShotStore.bookmark(for: url), identity: probe.identity,
            addedAt: Date(), pixelWidth: size.width, pixelHeight: size.height)
        guard store.add(record) else { return }
        Log.detection.info("New screenshot \(record.fileName, privacy: .public) via \(source == .folder ? "folder" : "spotlight", privacy: .public)")
        onShotAdded?(record)
        if source == .spotlight, prefs.folderMode == .system,
           (path as NSString).deletingLastPathComponent != watcher?.canonicalPath {
            // A capture landed somewhere else: the user may have changed the save location.
            refreshFolder()
        }
    }
}
