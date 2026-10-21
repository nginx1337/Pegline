import Foundation

/// One screenshot hanging on the line. Only a reference to the file is stored, never a copy.
public struct ShotRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    /// Bookmark lets us follow the file after it is renamed or moved, even between launches.
    public var bookmark: Data?
    public var identity: FileIdentity?
    public var addedAt: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Where the photo came from: nil for a screenshot file, "clipboard" or "copiedFile".
    public var origin: String?

    public init(
        id: UUID = UUID(), path: String, bookmark: Data?, identity: FileIdentity?,
        addedAt: Date, pixelWidth: Int, pixelHeight: Int, origin: String? = nil
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.identity = identity
        self.addedAt = addedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.origin = origin
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { (path as NSString).lastPathComponent }
}

/// Ordered collection (newest first) that refuses duplicates.
public struct ShotCollection: Equatable, Sendable {
    public private(set) var items: [ShotRecord] = []
    public var capacity: Int
    /// Files the user took off the line (or that fell off the end) during this session.
    /// Detection checks these so a later rename, tag or metadata change does not hang them again.
    public private(set) var dismissedPaths: Set<String> = []
    public private(set) var dismissedIdentities: Set<FileIdentity> = []

    public init(items: [ShotRecord] = [], capacity: Int = 100) {
        self.capacity = max(1, capacity)
        self.items = []
        for item in items.reversed() { _ = insert(item) }
    }

    public func contains(path: String) -> Bool { items.contains { $0.path == path } }

    public func contains(identity: FileIdentity?) -> Bool {
        guard let identity else { return false }
        return items.contains { $0.identity == identity }
    }

    public func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    public func wasDismissed(path: String?, identity: FileIdentity?) -> Bool {
        if let path, dismissedPaths.contains(path) { return true }
        if let identity, dismissedIdentities.contains(identity) { return true }
        return false
    }

    private mutating func dismiss(_ record: ShotRecord) {
        dismissedPaths.insert(record.path)
        if let identity = record.identity { dismissedIdentities.insert(identity) }
    }

    private mutating func undismiss(_ record: ShotRecord) {
        dismissedPaths.remove(record.path)
        if let identity = record.identity { dismissedIdentities.remove(identity) }
    }

    public func record(path: String) -> ShotRecord? { items.first { $0.path == path } }

    /// Inserts at the front. Returns false if the same file (by path or identity) is already present.
    /// Records beyond capacity are only forgotten by the line; files are never touched.
    @discardableResult
    public mutating func insert(_ record: ShotRecord) -> Bool {
        if contains(path: record.path) || contains(identity: record.identity) { return false }
        // Hanging a file again on purpose (for example copying it) lifts the dismissal.
        undismiss(record)
        items.insert(record, at: 0)
        trimToCapacity()
        return true
    }

    /// Removes a record. `dismiss` remembers it so detection will not hang it again this session.
    @discardableResult
    public mutating func remove(id: UUID, dismiss shouldDismiss: Bool = false) -> ShotRecord? {
        guard let index = index(of: id) else { return nil }
        let record = items.remove(at: index)
        if shouldDismiss { dismiss(record) }
        return record
    }

    public mutating func update(_ record: ShotRecord) {
        guard let index = index(of: record.id) else { return }
        items[index] = record
    }

    public mutating func removeAll() {
        for record in items { dismiss(record) }
        items.removeAll()
    }

    public mutating func setCapacity(_ value: Int) {
        capacity = max(1, value)
        trimToCapacity()
    }

    private mutating func trimToCapacity() {
        while items.count > capacity { dismiss(items.removeLast()) }
    }
}

/// On-disk format of the line. Versioned so future changes can migrate.
public struct LineArchive: Codable, Sendable {
    public var version: Int
    public var shots: [ShotRecord]

    public init(shots: [ShotRecord]) {
        version = 1
        self.shots = shots
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LineArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LineArchive.self, from: data)
    }
}

public enum FileLocations {
    /// True for any Trash: the home one (~/.Trash) and per-volume ones (/Volumes/X/.Trashes/501).
    public static func isInTrash(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}
