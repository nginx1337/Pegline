import Foundation
import Darwin

/// A cheap snapshot of a file used to tell whether it is still being written.
public struct FileProbe: Equatable, Sendable {
    public var size: Int64
    public var modified: TimeInterval
    public var created: TimeInterval
    public var inode: UInt64
    public var device: Int32

    public init(size: Int64, modified: TimeInterval, created: TimeInterval, inode: UInt64, device: Int32) {
        self.size = size
        self.modified = modified
        self.created = created
        self.inode = inode
        self.device = device
    }

    /// Reads the file with a single `stat` call. Returns nil for missing files and non-regular files.
    public static func read(path: String) -> FileProbe? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileProbe(
            size: Int64(info.st_size),
            modified: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9,
            created: TimeInterval(info.st_birthtimespec.tv_sec) + TimeInterval(info.st_birthtimespec.tv_nsec) / 1e9,
            inode: UInt64(info.st_ino),
            device: info.st_dev
        )
    }

    public var identity: FileIdentity { FileIdentity(device: device, inode: inode) }
}

/// Identifies a file independent of its name, so renames are not mistaken for new captures.
public struct FileIdentity: Hashable, Codable, Sendable {
    public var device: Int32
    public var inode: UInt64
    public init(device: Int32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// What to do with a candidate after looking at it again.
public enum StabilityVerdict: Equatable, Sendable {
    /// Size and date have not changed since the last look: the file is complete.
    case stable
    /// Still growing or not checked before: look again later.
    case wait
    /// The file disappeared.
    case gone
}

public enum StabilityCheck {
    /// Compares two snapshots taken a short time apart.
    public static func verdict(previous: FileProbe?, current: FileProbe?) -> StabilityVerdict {
        guard let current else { return .gone }
        guard let previous, current.size > 0 else { return .wait }
        if previous.size == current.size, previous.modified == current.modified, previous.inode == current.inode {
            return .stable
        }
        return .wait
    }

    /// Delay before the next look; grows so big or slow writes do not cause busy polling.
    public static func retryDelay(attempt: Int) -> TimeInterval {
        min(0.15 * pow(1.5, Double(attempt)), 2.0)
    }

    /// After this many attempts (roughly 30 seconds) we stop waiting for a file.
    public static let maxAttempts = 24
}
