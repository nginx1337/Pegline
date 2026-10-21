import Foundation
import CoreGraphics

/// Geometry of the rope and the photos hanging from it.
/// Coordinates: x grows to the right, `depth` is the distance down from the top edge of the panel.
public struct RopeGeometry: Equatable, Sendable {
    /// Left and right ends of the rope.
    public var startX: CGFloat
    public var endX: CGFloat
    /// Depth of the rope ends below the top edge.
    public var anchorDepth: CGFloat
    /// How far the middle of the rope hangs below the ends.
    public var sag: CGFloat

    public init(startX: CGFloat, endX: CGFloat, anchorDepth: CGFloat, sag: CGFloat) {
        self.startX = startX
        self.endX = endX
        self.anchorDepth = anchorDepth
        self.sag = sag
    }

    public var length: CGFloat { max(1, endX - startX) }

    /// Depth of the rope at `x`. A parabola is visually indistinguishable from a catenary here.
    public func depth(atX x: CGFloat) -> CGFloat {
        let t = min(max((x - startX) / length, 0), 1)
        return anchorDepth + sag * 4 * t * (1 - t)
    }

    /// Angle of the rope at `x` in radians (positive = going down to the right, in screen terms).
    public func slopeAngle(atX x: CGFloat) -> CGFloat {
        let t = min(max((x - startX) / length, 0), 1)
        let dDepthDx = sag * 4 * (1 - 2 * t) / length
        return atan(dDepthDx)
    }

    /// Control point for drawing the rope as one quadratic Bézier curve (depth coordinates).
    public var controlPoint: CGPoint {
        CGPoint(x: (startX + endX) / 2, y: anchorDepth + sag * 2)
    }
}

public enum RopeLayout {
    /// Size of a photo card for an image, keeping its aspect ratio inside a box of
    /// `maxWidth` × `maxWidth * 0.75`. Very tall or very wide images are clamped so they stay legible.
    public static func cardSize(pixelWidth: Int, pixelHeight: Int, maxWidth: CGFloat) -> CGSize {
        let maxHeight = (maxWidth * 0.75).rounded()
        guard pixelWidth > 0, pixelHeight > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let aspect = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        var width = maxWidth
        var height = width / aspect
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        // Keep slivers clickable: a very tall capture still gets a reasonable card.
        width = max(width, maxWidth * 0.42)
        height = max(height, maxWidth * 0.28)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Width of the viewport (the visible part of the line) for a given number of photos.
    public static func viewportWidth(
        visibleCount: Int, maxCardWidth: CGFloat, spacing: CGFloat, available: CGFloat
    ) -> CGFloat {
        let wanted = CGFloat(max(1, visibleCount)) * (maxCardWidth + spacing) - spacing
        return min(wanted, available)
    }

    /// Total width of all cards placed side by side.
    public static func contentWidth(cardWidths: [CGFloat], spacing: CGFloat) -> CGFloat {
        guard !cardWidths.isEmpty else { return 0 }
        return cardWidths.reduce(0, +) + spacing * CGFloat(cardWidths.count - 1)
    }

    public static func maxScrollOffset(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - viewportWidth)
    }

    /// Centre x of every card. Content narrower than the viewport is centred in it;
    /// wider content starts at the viewport's left edge and is shifted by `offset`.
    public static func centers(
        cardWidths: [CGFloat], spacing: CGFloat, viewportMinX: CGFloat, viewportWidth: CGFloat, offset: CGFloat
    ) -> [CGFloat] {
        let content = contentWidth(cardWidths: cardWidths, spacing: spacing)
        var x: CGFloat
        if content <= viewportWidth {
            x = viewportMinX + (viewportWidth - content) / 2
        } else {
            let clamped = min(max(offset, 0), content - viewportWidth)
            x = viewportMinX - clamped
        }
        var result: [CGFloat] = []
        result.reserveCapacity(cardWidths.count)
        for width in cardWidths {
            result.append(x + width / 2)
            x += width + spacing
        }
        return result
    }

    /// 1 inside the viewport, fading to 0 over `fade` points outside it.
    public static func visibility(
        cardMinX: CGFloat, cardMaxX: CGFloat, viewportMinX: CGFloat, viewportMaxX: CGFloat, fade: CGFloat
    ) -> CGFloat {
        let overflowLeft = max(0, viewportMinX - cardMinX)
        let overflowRight = max(0, cardMaxX - viewportMaxX)
        let overflow = max(overflowLeft, overflowRight)
        guard fade > 0 else { return overflow > 0 ? 0 : 1 }
        return max(0, 1 - overflow / fade)
    }

    /// Rope hangs a bit lower when it is longer and carries more photos.
    public static func sag(length: CGFloat, photoCount: Int) -> CGFloat {
        let base = min(max(length * 0.018, 5), 16)
        return base + min(CGFloat(photoCount), 10) * 0.5
    }

    /// Offset that brings the card at `index` fully into view with the least movement.
    public static func offsetRevealing(
        index: Int, cardWidths: [CGFloat], spacing: CGFloat, viewportWidth: CGFloat, currentOffset: CGFloat
    ) -> CGFloat {
        guard cardWidths.indices.contains(index) else { return currentOffset }
        let start = cardWidths[..<index].reduce(0, +) + spacing * CGFloat(index)
        let end = start + cardWidths[index]
        let maxOffset = maxScrollOffset(
            contentWidth: contentWidth(cardWidths: cardWidths, spacing: spacing), viewportWidth: viewportWidth)
        var offset = currentOffset
        if start < offset { offset = start }
        if end > offset + viewportWidth { offset = end - viewportWidth }
        return min(max(offset, 0), maxOffset)
    }
}
