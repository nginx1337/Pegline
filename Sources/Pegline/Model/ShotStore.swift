import AppKit
import PeglineCore

/// The photos on the line. Holds references to files only; never copies or deletes on its own.
final class ShotStore {
    enum RemovalReason {
        /// The user took it off the line; the file stays where it is.
        case unpinned
        /// The user moved the file to the Trash.
        case trashed
        /// The file was deleted or moved to the Trash outside Pegline.
        case fileGone
        /// The line is full; the oldest photo is forgotten (file untouched).
        case overflow
    }

    enum Change {
        case inserted(ShotRecord)
        case removed(ShotRecord, RemovalReason)
        /// The file moved, was renamed, or its contents changed.
        case updated(ShotRecord, contentChanged: Bool)
        case reset
    }

    private(set) var collection: ShotCollection
    var shots: [ShotRecord] { collection.items }

    private var observers: [UUID: (Change) -> Void] = [:]
    private let archiveURL: URL
    private var saveTask: Task<Void, Never>?

    init(capacity: Int) {
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pegline", isDirectory: true)
        #if DEBUG
        // Lets the self-test run beside a real instance without touching its line.
        if let dir = ProcessInfo.processInfo.environment["PEGLINE_STORE_DIR"] { support = URL(fileURLWithPath: dir) }
        #endif
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        archiveURL = support.appendingPathComponent("line.json")
        collection = ShotCollection(capacity: capacity)
        load()
    }

    @discardableResult
    func observe(_ handler: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    private func notify(_ change: Change) {
        for handler in observers.values { handler(change) }
    }

    func record(id: UUID) -> ShotRecord? { shots.first { $0.id == id } }
    func isTracked(path: String) -> Bool { collection.contains(path: path) }
    func isTracked(identity: FileIdentity?) -> Bool { collection.contains(identity: identity) }

    /// The user took this file off the line earlier in this session.
    func wasDismissed(path: String?, identity: FileIdentity?) -> Bool {
        collection.wasDismissed(path: path, identity: identity)
    }

    // MARK: Changes

    @discardableResult
    func add(_ record: ShotRecord) -> Bool {
        let before = shots
        guard collection.insert(record) else { return false }
        Log.store.info("Added \(record.fileName, privacy: .public)")
        notify(.inserted(record))
        // Anything that fell off the end because of capacity (the file itself is untouched).
        let keep = Set(shots.map(\.id))
        for old in before where !keep.contains(old.id) { notify(.removed(old, .overflow)) }
        scheduleSave()
        return true
    }

    func remove(id: UUID, reason: RemovalReason) {
        guard let removed = collection.remove(id: id, dismiss: reason == .unpinned) else { return }
        Log.store.info("Removed \(removed.fileName, privacy: .public)")
        notify(.removed(removed, reason))
        scheduleSave()
    }

    func removeAll() {
        collection.removeAll()
        notify(.reset)
        scheduleSave()
    }

    func setCapacity(_ value: Int) {
        let before = shots
        collection.setCapacity(value)
        let keep = Set(shots.map(\.id))
        for record in before where !keep.contains(record.id) { notify(.removed(record, .overflow)) }
        scheduleSave()
    }

    /// Moves the file to the Trash (recoverable) and takes it off the line.
    func trash(id: UUID) throws {
        guard let record = record(id: id) else { return }
        try FileManager.default.trashItem(at: record.url, resultingItemURL: nil)
        remove(id: id, reason: .trashed)
    }

    // MARK: Following files

    /// Re-checks one tracked file after a file system event on its path.
    func refresh(path: String, contentMayHaveChanged: Bool) {
        guard let record = collection.record(path: path) else { return }
        reconcile(record, contentMayHaveChanged: contentMayHaveChanged)
    }

    /// Re-checks every file, e.g. at launch or after waking from sleep.
    func reconcileAll() {
        for record in shots { reconcile(record, contentMayHaveChanged: false) }
    }

    private func reconcile(_ record: ShotRecord, contentMayHaveChanged: Bool) {
        if let probe = FileProbe.read(path: record.path) {
            // Same name still exists. If the inode changed the file was replaced (e.g. saved by an editor).
            var updated = record
            let replaced = record.identity != nil && record.identity != probe.identity
            if replaced {
                updated.identity = probe.identity
                updated.bookmark = Self.bookmark(for: record.url)
            }
            if replaced || contentMayHaveChanged {
                if let size = ImageInfo.pixelSize(path: record.path) {
                    updated.pixelWidth = size.width
                    updated.pixelHeight = size.height
                }
                collection.update(updated)
                notify(.updated(updated, contentChanged: true))
                scheduleSave()
            }
            return
        }
        // The name is gone: follow the bookmark to see whether it was renamed or moved.
        if let moved = Self.resolve(record), !FileLocations.isInTrash(moved.path) {
            var updated = record
            updated.path = moved.path
            updated.bookmark = Self.bookmark(for: moved) ?? record.bookmark
            if collection.contains(path: updated.path) {
                // Another record already points there; drop this one.
                remove(id: record.id, reason: .fileGone)
                return
            }
            collection.update(updated)
            Log.store.info("Followed rename to \(updated.fileName, privacy: .public)")
            notify(.updated(updated, contentChanged: false))
            scheduleSave()
        } else {
            remove(id: record.id, reason: .fileGone)
        }
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func resolve(_ record: ShotRecord) -> URL? {
        guard let data = record.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: archiveURL) else { return }
        do {
            let archive = try LineArchive.decode(data)
            collection = ShotCollection(items: archive.shots, capacity: collection.capacity)
            Log.store.info("Loaded \(archive.shots.count) shots")
        } catch {
            Log.store.error("Could not read line.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try LineArchive(shots: shots).encoded().write(to: archiveURL, options: .atomic)
        } catch {
            Log.store.error("Could not save line.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
