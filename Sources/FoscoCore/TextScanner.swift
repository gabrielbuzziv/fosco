import CoreGraphics
import Foundation
import os
import Vision

public struct SensitiveRegion: Equatable, Sendable {
    public let kind: SensitiveKind
    /// Pixel rectangle in the image, origin at the top-left corner.
    public let rect: CGRect

    public init(kind: SensitiveKind, rect: CGRect) {
        self.kind = kind
        self.rect = rect
    }
}

/// Locates e-mail addresses and phone numbers shown in the image.
func locateSensitiveRegions(
    in image: CGImage,
    layouts: [TileLayout],
    kinds: Set<SensitiveKind>,
    maxConcurrentTiles: Int = defaultConcurrentTiles
) -> [SensitiveRegion] {
    guard !kinds.isEmpty else { return [] }
    let size = CGSize(width: image.width, height: image.height)
    let found = OSAllocatedUnfairLock(initialState: [SensitiveRegion]())

    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = maxConcurrentTiles
    for layout in layouts {
        for rect in tileRects(for: size, layout: layout) {
            queue.addOperation {
                let regions = scanTile(of: image, sourceRect: rect, layout: layout, kinds: kinds)
                found.withLock { $0.append(contentsOf: regions) }
            }
        }
    }
    queue.waitUntilAllOperationsAreFinished()
    return mergeRegions(found.withLock { $0 })
}

/// Vision is parallel inside one request, so more tiles at once buys little and costs memory.
let defaultConcurrentTiles = 3

/// A match and its box inside a tile (unit square, bottom-left origin, as Vision reports it).
private typealias BoxedMatch = (kind: SensitiveKind, box: CGRect)

private func scanTile(of image: CGImage, sourceRect: CGRect, layout: TileLayout, kinds: Set<SensitiveKind>) -> [SensitiveRegion] {
    guard let tile = renderTile(of: image, sourceRect: sourceRect, scale: layout.scale) else { return [] }
    let tileSize = CGSize(width: tile.width, height: tile.height)
    let observations = recognizeText(in: tile)
    let found = matchesAcrossFragments(of: observations, tileSize: tileSize, kinds: kinds)
        + matchesInAlternateReadings(of: observations, kinds: kinds)
    return found.compactMap { kind, box in
        guard box.height * tileSize.height >= layout.minimumTextHeight else { return nil }
        return SensitiveRegion(kind: kind, rect: sourceRect.denormalized(box))
    }
}

private func recognizeText(in tile: CGImage) -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Correction "fixes" addresses and numbers into dictionary words.
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["pt-BR", "en-US"]
    do {
        try VNImageRequestHandler(cgImage: tile).perform([request])
    } catch {
        logger.error("OCR failed on a tile: \(error.localizedDescription, privacy: .public)")
    }
    return request.results ?? []
}

/// Vision often breaks one line into several observations, sometimes in the middle of an address
/// ("ana@acme" + ".com.br") or a number ("(47)" + "9" + "8888-7777"). This reads each run of
/// neighbouring fragments as the single line it is.
private func matchesAcrossFragments(
    of observations: [VNRecognizedTextObservation],
    tileSize: CGSize,
    kinds: Set<SensitiveKind>
) -> [BoxedMatch] {
    let fragments = observations.compactMap { observation in
        observation.topCandidates(1).first.map { Fragment(text: $0, box: observation.boundingBox) }
    }
    var found: [BoxedMatch] = []
    for run in fragmentRuns(fragments.map { $0.box.scaled(to: tileSize) }) {
        let line = joinFragments(run.map { (fragments[$0.index].text.string, $0.isGlued) })
        for match in findSensitiveMatches(in: line.text, kinds: kinds) {
            let characters = line.text.distance(from: line.text.startIndex, to: match.range.lowerBound)
                ..< line.text.distance(from: line.text.startIndex, to: match.range.upperBound)
            let box = zip(run, line.offsets).reduce(CGRect.null) { union, member in
                union.union(fragments[member.0.index].box(of: characters, whenStartingAt: member.1))
            }
            if !box.isNull { found.append((match.kind, box)) }
        }
    }
    return found
}

/// A lower-ranked reading sometimes gets right the character the best one got wrong.
private func matchesInAlternateReadings(of observations: [VNRecognizedTextObservation], kinds: Set<SensitiveKind>) -> [BoxedMatch] {
    observations.flatMap { observation in
        observation.topCandidates(3).dropFirst().flatMap { reading in
            findSensitiveMatches(in: reading.string, kinds: kinds).map { match in
                (match.kind, (try? reading.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox)
            }
        }
    }
}

private struct Fragment {
    let text: VNRecognizedText
    let box: CGRect

    /// Box of the part of this fragment inside `characters`, a range of the joined line in which
    /// this fragment starts at `start`. Null when the range lies elsewhere on the line.
    func box(of characters: Range<Int>, whenStartingAt start: Int) -> CGRect {
        let string = text.string
        let local = characters.clamped(to: start..<(start + string.count))
        guard !local.isEmpty else { return .null }
        let range = string.index(string.startIndex, offsetBy: local.lowerBound - start)
            ..< string.index(string.startIndex, offsetBy: local.upperBound - start)
        // Without a box for the match itself, hide the whole fragment rather than nothing.
        guard let matchBox = (try? text.boundingBox(for: range))?.boundingBox else { return box }
        // The match's own box can be shorter than the glyphs; the line's box spans their full height.
        return CGRect(x: matchBox.minX, y: min(matchBox.minY, box.minY), width: matchBox.width,
                      height: max(matchBox.maxY, box.maxY) - min(matchBox.minY, box.minY))
    }
}

/// Crops and resamples one tile onto an opaque white sRGB bitmap, whatever the source format is.
private func renderTile(of image: CGImage, sourceRect: CGRect, scale: CGFloat) -> CGImage? {
    guard let crop = image.cropping(to: sourceRect) else { return nil }
    let width = Int((sourceRect.width * scale).rounded()), height = Int((sourceRect.height * scale).rounded())
    guard width > 0, height > 0, let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(bounds)
    context.interpolationQuality = .high
    context.draw(crop, in: bounds)
    return context.makeImage()
}

private extension CGRect {
    /// A unit-square box in pixels of an image of the given size.
    func scaled(to size: CGSize) -> CGRect {
        CGRect(x: minX * size.width, y: minY * size.height, width: width * size.width, height: height * size.height)
    }

    /// Maps a Vision box (unit square, bottom-left origin) inside this tile to image pixels.
    func denormalized(_ box: CGRect) -> CGRect {
        CGRect(x: minX + box.minX * width, y: minY + (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
    }
}

// MARK: - Merging

/// The same text is found by several tiles, sweeps and readings; collapse those into one region.
func mergeRegions(_ regions: [SensitiveRegion]) -> [SensitiveRegion] {
    var merged: [SensitiveRegion] = []
    for region in regions {
        var current = region
        // A union can newly overlap a region accepted earlier, so keep absorbing until stable.
        while let index = merged.firstIndex(where: { $0.rect.overlapsSubstantially(current.rect) }) {
            let other = merged.remove(at: index)
            let kind = other.rect.width >= current.rect.width ? other.kind : current.kind
            current = SensitiveRegion(kind: kind, rect: other.rect.union(current.rect))
        }
        merged.append(current)
    }
    return merged.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
}

private extension CGRect {
    func overlapsSubstantially(_ other: CGRect) -> Bool {
        let overlap = intersection(other)
        guard !overlap.isNull else { return false }
        let smallerArea = min(width * height, other.width * other.height)
        return smallerArea > 0 && overlap.width * overlap.height >= 0.25 * smallerArea
    }
}

let logger = Logger(subsystem: "com.gabrielbuzzi.fosco", category: "core")
