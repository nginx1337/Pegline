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

    public func record(path: String) -> ShotRecord? { items.first { $0.path == path } }

    /// Inserts at the front. Returns false if the same file (by path or identity) is already present.
    /// Records beyond capacity are only forgotten by the line; files are never touched.
    @discardableResult
    public mutating func insert(_ record: ShotRecord) -> Bool {
        if contains(path: record.path) || contains(identity: record.identity) { return false }
        items.insert(record, at: 0)
        if items.count > capacity { items.removeLast(items.count - capacity) }
        return true
    }

    @discardableResult
    public mutating func remove(id: UUID) -> ShotRecord? {
        guard let index = index(of: id) else { return nil }
        return items.remove(at: index)
    }

    public mutating func update(_ record: ShotRecord) {
        guard let index = index(of: record.id) else { return }
        items[index] = record
    }

    public mutating func removeAll() { items.removeAll() }

    public mutating func setCapacity(_ value: Int) {
        capacity = max(1, value)
        if items.count > capacity { items.removeLast(items.count - capacity) }
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
