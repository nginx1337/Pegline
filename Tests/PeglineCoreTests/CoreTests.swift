import Testing
import Foundation
@testable import PeglineCore

@Suite("Screenshot classification")
struct ClassifierTests {
    let classifier = ScreenshotClassifier()

    @Test func acceptsSystemNames() {
        #expect(classifier.nameLooksLikeScreenshot("Снимок экрана — 2026-10-11 в 15.12.02.png"))
        #expect(classifier.nameLooksLikeScreenshot("Screenshot 2026-10-11 at 15.12.02.png"))
        #expect(!classifier.nameLooksLikeScreenshot("holiday.png"))
    }

    @Test func rejectsHiddenAndTemporaryFiles() {
        #expect(!classifier.isImageCandidate(fileName: ".Снимок экрана 2026.png"))
        #expect(!classifier.isImageCandidate(fileName: "~draft.png"))
        #expect(!classifier.isImageCandidate(fileName: "Screen Recording.mov"))
        #expect(classifier.isImageCandidate(fileName: "a.HEIC"))
    }

    @Test func customPrefixWins() {
        let custom = ScreenshotClassifier(customPrefix: "Shot")
        #expect(custom.nameLooksLikeScreenshot("Shot 1.png"))
    }

    @Test func attributeIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("plain.png")
        try Data([0x89, 0x50]).write(to: file)
        #expect(!classifier.accepts(path: file.path, policy: .screenshotsOnly))
        #expect(classifier.accepts(path: file.path, policy: .allImages))
        let value: [UInt8] = [1]
        let result = setxattr(file.path, ScreenshotClassifier.screenCaptureAttribute, value, value.count, 0, 0)
        #expect(result == 0)
        #expect(classifier.accepts(path: file.path, policy: .screenshotsOnly))
    }
}

@Suite("Collection")
struct CollectionTests {
    func record(_ path: String, inode: UInt64? = nil) -> ShotRecord {
        ShotRecord(
            path: path, bookmark: nil, identity: inode.map { FileIdentity(device: 1, inode: $0) },
            addedAt: Date(), pixelWidth: 100, pixelHeight: 50)
    }

    @Test func refusesDuplicatesByPathAndIdentity() {
        var collection = ShotCollection()
        let first = collection.insert(record("/a.png", inode: 1))
        let samePath = collection.insert(record("/a.png", inode: 2))
        let sameFile = collection.insert(record("/renamed.png", inode: 1))
        #expect(first)
        #expect(!samePath)
        #expect(!sameFile)
        #expect(collection.items.count == 1)
    }

    @Test func newestFirstAndCapacity() {
        var collection = ShotCollection(capacity: 2)
        collection.insert(record("/1.png"))
        collection.insert(record("/2.png"))
        collection.insert(record("/3.png"))
        #expect(collection.items.map(\.path) == ["/3.png", "/2.png"])
    }

    @Test func archiveRoundTrip() throws {
        let items = [record("/x.png", inode: 9)]
        let data = try LineArchive(shots: items).encoded()
        let decoded = try LineArchive.decode(data)
        #expect(decoded.shots.map(\.path) == ["/x.png"])
        #expect(decoded.shots.first?.identity?.inode == 9)
    }
}

@Suite("File stability")
struct StabilityTests {
    let base = FileProbe(size: 100, modified: 1, created: 1, inode: 5, device: 1)

    @Test func verdicts() {
        #expect(StabilityCheck.verdict(previous: nil, current: base) == .wait)
        #expect(StabilityCheck.verdict(previous: base, current: base) == .stable)
        var grown = base
        grown.size = 200
        #expect(StabilityCheck.verdict(previous: base, current: grown) == .wait)
        #expect(StabilityCheck.verdict(previous: base, current: nil) == .gone)
        var empty = base
        empty.size = 0
        #expect(StabilityCheck.verdict(previous: empty, current: empty) == .wait)
    }

    @Test func backoffIsBounded() {
        #expect(StabilityCheck.retryDelay(attempt: 0) > 0)
        #expect(StabilityCheck.retryDelay(attempt: 100) <= 2.0)
    }
}

@Suite("Rope layout")
struct LayoutTests {
    @Test func cardsKeepAspectInsideBox() {
        let wide = RopeLayout.cardSize(pixelWidth: 2880, pixelHeight: 1800, maxWidth: 160)
        #expect(wide.width == 160)
        #expect(wide.height == 100)
        let tall = RopeLayout.cardSize(pixelWidth: 800, pixelHeight: 1600, maxWidth: 160)
        #expect(tall.height == 120)
        #expect(tall.width == (160 * 0.42).rounded())
        let sliver = RopeLayout.cardSize(pixelWidth: 3000, pixelHeight: 20, maxWidth: 160)
        #expect(sliver.height >= 160 * 0.28)
    }

    @Test func narrowContentIsCentred() {
        let centers = RopeLayout.centers(
            cardWidths: [100, 100], spacing: 20, viewportMinX: 0, viewportWidth: 1000, offset: 0)
        #expect(centers == [440, 560])
    }

    @Test func wideContentScrollsAndClamps() {
        let widths = Array(repeating: CGFloat(100), count: 10)
        let a = RopeLayout.centers(cardWidths: widths, spacing: 20, viewportMinX: 0, viewportWidth: 340, offset: 0)
        #expect(a.first == 50)
        let b = RopeLayout.centers(cardWidths: widths, spacing: 20, viewportMinX: 0, viewportWidth: 340, offset: 10_000)
        // Last card's right edge sits exactly at the viewport's right edge.
        #expect(b.last! + 50 == 340)
    }

    @Test func ropeDepthIsDeepestInTheMiddle() {
        let rope = RopeGeometry(startX: 0, endX: 200, anchorDepth: 4, sag: 10)
        #expect(rope.depth(atX: 0) == 4)
        #expect(rope.depth(atX: 100) == 14)
        #expect(rope.depth(atX: 200) == 4)
        #expect(abs(rope.slopeAngle(atX: 100)) < 0.0001)
        #expect(rope.slopeAngle(atX: 10) > 0)
    }

    @Test func visibilityFadesOutsideViewport() {
        #expect(RopeLayout.visibility(cardMinX: 10, cardMaxX: 90, viewportMinX: 0, viewportMaxX: 100, fade: 50) == 1)
        #expect(RopeLayout.visibility(cardMinX: 80, cardMaxX: 125, viewportMinX: 0, viewportMaxX: 100, fade: 50) == 0.5)
        #expect(RopeLayout.visibility(cardMinX: 200, cardMaxX: 300, viewportMinX: 0, viewportMaxX: 100, fade: 50) == 0)
    }

    @Test func revealOffset() {
        let widths = Array(repeating: CGFloat(100), count: 10)
        let offset = RopeLayout.offsetRevealing(
            index: 5, cardWidths: widths, spacing: 20, viewportWidth: 340, currentOffset: 0)
        // Card 5 spans 600...700, so the viewport must end at 700.
        #expect(offset == 360)
    }
}

@Suite("Clipboard")
struct ClipboardTests {
    @Test func screenshotIsOnlyImageData() {
        #expect(ClipboardClassifier.classify(items: [["public.png"]]) == .screenshotImage(type: "public.png"))
        #expect(ClipboardClassifier.classify(items: [["public.tiff", "NeXT TIFF v4.0 pasteboard type", "dyn.ah62d4rv4gu8y"]])
            == .screenshotImage(type: "public.tiff"))
    }

    @Test func browserImageIsNotAScreenshot() {
        let browser = [["public.tiff", "public.html", "public.url"]]
        #expect(ClipboardClassifier.classify(items: browser) == .otherImage(type: "public.tiff"))
        #expect(!ClipboardClassifier.accepts(.otherImage(type: "public.tiff"), mode: .screenshots))
        #expect(ClipboardClassifier.accepts(.otherImage(type: "public.tiff"), mode: .allImages))
    }

    @Test func finderCopyIsAFile() {
        #expect(ClipboardClassifier.classify(items: [["public.file-url"], ["public.tiff"]]) == .imageFile)
        #expect(!ClipboardClassifier.accepts(.imageFile, mode: .screenshots))
    }

    @Test func textIsIgnored() {
        #expect(ClipboardClassifier.classify(items: [["public.utf8-plain-text"]]) == .nothingUseful)
        #expect(ClipboardClassifier.classify(items: []) == .nothingUseful)
        #expect(!ClipboardClassifier.accepts(.screenshotImage(type: "public.png"), mode: .off))
    }

    @Test func fileNameFollowsSystemStyle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_792_540_532) // 2026-10-20 23:55:32 UTC
        #expect(ClipboardClassifier.fileName(for: date, screenshot: true, calendar: calendar)
            == "Снимок из буфера — 2026-10-20 в 23.55.32.png")
    }
}

@Suite("Copied file references")
struct FileReferenceTests {
    @Test func telegramStyleUnreadableFileFallsBackToImageData() {
        let path = "/Users/me/Library/Containers/ru.keepcoder.Telegram/Data/tmp/telegram-cloud-photo.jpg"
        #expect(ClipboardClassifier.fileReference(path: path, exists: true, readable: false, isImage: false) == .unreadable)
        #expect(ClipboardClassifier.fileReference(path: path, exists: false, readable: false, isImage: false) == .unreadable)
    }

    @Test func finderImageHangsInPlace() {
        #expect(ClipboardClassifier.fileReference(path: "/Users/me/Pictures/cat.jpg", exists: true, readable: true, isImage: true) == .imageInPlace)
    }

    @Test func temporaryImageIsCopied() {
        #expect(ClipboardClassifier.fileReference(path: "/private/var/folders/x/T/img.png", exists: true, readable: true, isImage: true) == .imageToCopy)
        #expect(ClipboardClassifier.fileReference(path: "/Users/me/Library/Caches/app/img.png", exists: true, readable: true, isImage: true) == .imageToCopy)
    }

    @Test func nonImageFileIsIgnored() {
        #expect(ClipboardClassifier.fileReference(path: "/Users/me/Documents/report.pdf", exists: true, readable: true, isImage: false) == .notAnImage)
    }

    @Test func extensionsKeepEncoding() {
        #expect(ClipboardClassifier.fileExtension(forType: "public.jpeg") == "jpg")
        #expect(ClipboardClassifier.fileExtension(forType: "public.tiff") == "png")
    }
}

@Suite("Dismissed shots and Trash")
struct DismissTests {
    func record(_ path: String, inode: UInt64) -> ShotRecord {
        ShotRecord(path: path, bookmark: nil, identity: FileIdentity(device: 1, inode: inode),
                   addedAt: Date(), pixelWidth: 10, pixelHeight: 10)
    }

    @Test func unpinnedShotIsRememberedByPathAndIdentity() {
        var collection = ShotCollection()
        let shot = record("/a.png", inode: 7)
        collection.insert(shot)
        collection.remove(id: shot.id, dismiss: true)
        #expect(collection.wasDismissed(path: "/a.png", identity: nil))
        // Renamed later: same file, new name.
        #expect(collection.wasDismissed(path: "/renamed.png", identity: FileIdentity(device: 1, inode: 7)))
    }

    @Test func goneFilesAreNotDismissed() {
        var collection = ShotCollection()
        let shot = record("/a.png", inode: 7)
        collection.insert(shot)
        collection.remove(id: shot.id)
        #expect(!collection.wasDismissed(path: "/a.png", identity: nil))
    }

    @Test func overflowAndClearAllDismiss() {
        var collection = ShotCollection(capacity: 1)
        collection.insert(record("/1.png", inode: 1))
        collection.insert(record("/2.png", inode: 2))
        #expect(collection.wasDismissed(path: "/1.png", identity: nil))
        collection.removeAll()
        #expect(collection.wasDismissed(path: "/2.png", identity: nil))
    }

    @Test func hangingAgainLiftsDismissal() {
        var collection = ShotCollection()
        let shot = record("/a.png", inode: 7)
        collection.insert(shot)
        collection.remove(id: shot.id, dismiss: true)
        collection.insert(record("/a.png", inode: 7))
        #expect(!collection.wasDismissed(path: "/a.png", identity: nil))
    }

    @Test func trashOnAnyVolume() {
        #expect(FileLocations.isInTrash("/Users/me/.Trash/shot.png"))
        #expect(FileLocations.isInTrash("/Volumes/Ext/.Trashes/501/shot.png"))
        #expect(!FileLocations.isInTrash("/Users/me/Desktop/.Trashy/shot.png"))
        #expect(ClipboardClassifier.isTemporaryLocation("/Volumes/Ext/.Trashes/501/shot.png"))
    }
}

@Suite("Safety")
struct SafetyTests {
    @Test func concealedClipboardIsIgnored() {
        let secret = [["public.png", "org.nspasteboard.ConcealedType"]]
        #expect(ClipboardPrivacy.isPrivate(items: secret))
        #expect(ClipboardClassifier.classify(items: secret) == .nothingUseful)
        let transient = [["public.tiff"], ["org.nspasteboard.TransientType"]]
        #expect(ClipboardClassifier.classify(items: transient) == .nothingUseful)
        #expect(!ClipboardPrivacy.isPrivate(items: [["public.png"]]))
    }

    @Test func imageLimits() {
        #expect(ImageLimits.allows(width: 6016 * 3, height: 3384))
        #expect(!ImageLimits.allows(width: 100_000, height: 100_000))
        #expect(!ImageLimits.allows(width: 0, height: 10))
        #expect(ImageLimits.allows(bytes: 40 * 1024 * 1024))
        #expect(!ImageLimits.allows(bytes: 2 * 1024 * 1024 * 1024))
    }
}
