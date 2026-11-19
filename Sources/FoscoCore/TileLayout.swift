import CoreGraphics

/// One OCR sweep: how the capture is resampled and cut into tiles before Vision reads it.
///
/// Vision shrinks its input to a fixed working size, so small text on a large capture is lost
/// unless the capture is cut into tiles first, and text from a 1x display reads far better
/// enlarged. Measured on dense test screens, tiles up to about 4 megapixels never dropped text,
/// while 8 megapixel ones occasionally lost a third of it. Sizes are in resampled pixels.
struct TileLayout: Equatable, Sendable {
    var scale: CGFloat
    var tileSide: CGFloat
    /// Text wider than this can be cut by a tile edge without being whole in the next tile.
    var horizontalOverlap: CGFloat
    /// Only has to cover one line of text.
    var verticalOverlap: CGFloat
    /// Matches on shorter text are ignored; lets a sweep leave small print to a finer one.
    var minimumTextHeight: CGFloat = 0

    /// The fine sweep puts text at about two pixels per point, where Vision reads body text best,
    /// with tiles overlapping by half so most text is read twice from different crops. The coarse
    /// one is a cheap look at the capture shrunk four times as much, for headline-sized text that
    /// is wider than a fine tile's overlap. On anything smaller it loses the spaces between words
    /// and would blur the neighbours too, so there it stays out of the way.
    static func standard(pixelsPerPoint: CGFloat) -> [TileLayout] {
        let density = max(pixelsPerPoint, 1)
        return [
            TileLayout(scale: 2 / density, tileSide: 2048, horizontalOverlap: 1024, verticalOverlap: 192),
            TileLayout(scale: 0.5 / density, tileSide: 2880, horizontalOverlap: 1440, verticalOverlap: 384, minimumTextHeight: 22),
        ]
    }
}

/// Source-pixel rectangles (top-left origin) covering the image, sized so every tile is at most
/// `tileSide` after resampling.
func tileRects(for size: CGSize, layout: TileLayout) -> [CGRect] {
    let columns = tileSpans(length: size.width, tile: layout.tileSide / layout.scale, overlap: layout.horizontalOverlap / layout.scale)
    let rows = tileSpans(length: size.height, tile: layout.tileSide / layout.scale, overlap: layout.verticalOverlap / layout.scale)
    return rows.flatMap { row in
        columns.map { column in CGRect(x: column.start, y: row.start, width: column.length, height: row.length) }
    }
}

/// Evenly spread spans of equal length that cover `length` and overlap their neighbour by at least `overlap`.
func tileSpans(length: CGFloat, tile: CGFloat, overlap: CGFloat) -> [(start: CGFloat, length: CGFloat)] {
    guard length > tile, tile > overlap else { return [(0, length)] }
    let count = ((length - overlap) / (tile - overlap)).rounded(.up)
    let span = ((length + (count - 1) * overlap) / count).rounded(.up)
    let step = (length - span) / (count - 1)
    return (0..<Int(count)).map { index in ((CGFloat(index) * step).rounded(.down), span) }
}
