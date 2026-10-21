import Foundation
import CoreServices

/// Watches one folder with FSEvents. Costs nothing while the folder is quiet.
final class FolderWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags

        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        var isRemovedOrRenamed: Bool { has(kFSEventStreamEventFlagItemRemoved) || has(kFSEventStreamEventFlagItemRenamed) }
        var isContentChange: Bool {
            has(kFSEventStreamEventFlagItemModified) || has(kFSEventStreamEventFlagItemInodeMetaMod)
                || has(kFSEventStreamEventFlagItemXattrMod)
        }
        var isRootChange: Bool { has(kFSEventStreamEventFlagRootChanged) }
        var mustRescan: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) }
    }

    let folder: URL
    /// Real path (symlinks resolved), as FSEvents reports it.
    let canonicalPath: String
    private var stream: FSEventStreamRef?
    var handler: (([Event]) -> Void)?

    init(folder: URL) {
        self.folder = folder
        // realpath, not resolvingSymlinksInPath: Foundation turns /private/tmp into /tmp,
        // while FSEvents always reports the real path.
        if let real = realpath(folder.path, nil) {
            canonicalPath = String(cString: real)
            free(real)
        } else {
            canonicalPath = folder.standardizedFileURL.path
        }
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, folderEventsCallback, &context, [canonicalPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.08, flags)
        else {
            Log.detection.error("FSEventStreamCreate failed for \(self.canonicalPath, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
        Log.detection.info("Watching \(self.canonicalPath, privacy: .public)")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(_ events: [Event]) { handler?(events) }

    isolated deinit { stop() }
}

nonisolated private func folderEventsCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
    var events: [FolderWatcher.Event] = []
    events.reserveCapacity(count)
    for index in 0..<count {
        guard let path = array[index] as? String else { continue }
        events.append(FolderWatcher.Event(path: path, flags: flags[index]))
    }
    let address = UInt(bitPattern: info)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(pointer).takeUnretainedValue()
        watcher.deliver(events)
    }
}
