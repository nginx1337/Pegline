#if DEBUG
import AppKit
import PeglineCore

/// `Pegline --render-preview <out.png> [light|dark] [count] image1 image2 …`
/// Renders the line offscreen so its look can be checked without screen recording permission.
enum PreviewRenderer {
    static func run(arguments: [String]) {
        guard let output = arguments.first else {
            print("usage: --render-preview out.png [light|dark] [visibleCount] images…")
            return
        }
        var rest = Array(arguments.dropFirst())
        var dark = false
        if let first = rest.first, first == "dark" || first == "light" {
            dark = first == "dark"
            rest.removeFirst()
        }
        var visible = 7
        if let first = rest.first, let n = Int(first) {
            visible = n
            rest.removeFirst()
        }
        let metrics = LineMetrics(maxCardWidth: ThumbnailSize.medium.maxWidth)
        let view = LineView(thumbnails: ThumbnailLoader(), metrics: metrics, visibleCount: visible, motion: .lively)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let viewport = RopeLayout.viewportWidth(
            visibleCount: visible, maxCardWidth: metrics.maxCardWidth, spacing: metrics.spacing, available: 3000)
        let size = NSSize(width: viewport + 2 * metrics.sideMargin, height: metrics.panelHeight)
        view.frame = NSRect(origin: .zero, size: size)
        let records: [ShotRecord] = rest.compactMap { path in
            guard let px = ImageInfo.pixelSize(path: path) else { return nil }
            return ShotRecord(path: path, bookmark: nil, identity: nil, addedAt: Date(), pixelWidth: px.width, pixelHeight: px.height)
        }
        view.canvas.reload(records)
        view.canvas.viewDidChangeEffectiveAppearance()
        for node in view.canvas.nodes {
            node.setImage(ImageInfo.thumbnail(path: node.record.path, maxPixel: Int(metrics.maxCardWidth * 2)), animated: false)
        }
        if let second = view.canvas.nodes.dropFirst().first {
            second.setHovered(true, palette: view.canvas.palette, motion: .off)
        }

        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        // A neutral backdrop standing in for the desktop.
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.scaleBy(x: scale, y: scale)
        view.canvas.layer?.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        print("wrote \(output) \(Int(size.width))×\(Int(size.height)) with \(records.count) photos")
    }
}
#endif
