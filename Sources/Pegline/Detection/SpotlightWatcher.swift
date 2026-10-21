import Foundation

/// Secondary detector: asks Spotlight for files macOS marked as screenshots.
/// Catches captures saved outside the watched folder (for example after the user
/// changes "Save to" in the Screenshot app). Spotlight does the work; we only get notified.
final class SpotlightWatcher {
    private let query = NSMetadataQuery()
    private var tokens: [NSObjectProtocol] = []
    var onFound: (([String]) -> Void)?

    func start(since: Date) {
        stop()
        query.predicate = NSPredicate(
            format: "kMDItemIsScreenCapture == 1 AND kMDItemContentCreationDate >= %@", since as NSDate)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 0.25
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let changed = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
            let paths = (added + changed).compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            MainActor.assumeIsolated {
                if !paths.isEmpty { self?.onFound?(paths) }
            }
        })
        tokens.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.query.disableUpdates()
                let paths = (self.query.results as? [NSMetadataItem] ?? [])
                    .compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
                self.query.enableUpdates()
                if !paths.isEmpty { self.onFound?(paths) }
            }
        })
        if !query.start() { Log.detection.error("Spotlight query did not start") }
    }

    func stop() {
        if query.isStarted { query.stop() }
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }
}
