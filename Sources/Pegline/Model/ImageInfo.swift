import AppKit
import ImageIO
import PeglineCore

/// Image reading helpers. All of them are safe to call from any thread.
enum ImageInfo {
    struct PixelSize: Sendable {
        var width: Int
        var height: Int
    }

    /// Pixel size accounting for EXIF orientation. Nil if the file is not a complete, readable image.
    nonisolated static func pixelSize(path: String) -> PixelSize? {
        let url = URL(fileURLWithPath: path) as CFURL
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }

    /// Pixel size of image data (for example from the clipboard), read from its header only.
    nonisolated static func pixelSize(data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return pixelSize(source: source)
    }

    nonisolated private static func pixelSize(source: CGImageSource) -> PixelSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    /// Downsampled image for the line. Decodes only as many pixels as needed.
    nonisolated static func thumbnail(path: String, maxPixel: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// PNG data for the clipboard when the original is in a format other apps may not read.
    nonisolated static func pngData(path: String) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return pngData(source: source)
    }

    /// PNG data from image data in any format ImageIO reads (TIFF, JPEG, HEIC…).
    nonisolated static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pngData(source: source)
    }

    nonisolated private static func pngData(source: CGImageSource) -> Data? {
        // Check the size from the header before decoding, so a huge image cannot exhaust memory.
        guard let size = pixelSize(source: source), ImageLimits.allows(width: size.width, height: size.height),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// Small in-memory cache of downsampled images.
final class ThumbnailLoader {
    private let cache = NSCache<NSString, CGImageBox>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    init() {
        cache.countLimit = 90
    }

    private func key(_ id: UUID, _ maxPixel: Int) -> String { "\(id.uuidString)-\(maxPixel)" }

    func cached(id: UUID, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(id, maxPixel) as NSString)?.image
    }

    func thumbnail(id: UUID, path: String, maxPixel: Int) async -> CGImage? {
        let key = key(id, maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) {
            ImageInfo.thumbnail(path: path, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(CGImageBox(image), forKey: key as NSString) }
        return image
    }

    func invalidate(id: UUID) {
        // NSCache cannot enumerate keys; clear entries for the sizes we use.
        for size in [64, 96, 128] + ThumbnailSize.allCases.flatMap({ [Int($0.maxWidth), Int($0.maxWidth * 2), Int($0.maxWidth * 3)] }) {
            cache.removeObject(forKey: key(id, size) as NSString)
        }
    }
}

final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
