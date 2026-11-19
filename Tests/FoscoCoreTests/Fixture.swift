import CoreGraphics
import Foundation
import Testing
@testable import FoscoCore

/// A rendered screenshot plus where its sensitive text (targets) and look-alikes (decoys) are.
struct Fixture {
    struct Item: Decodable {
        let kind: String
        let text: String
        /// One [x, y, width, height] per line the text occupies; pixels, top-left origin.
        let rects: [[CGFloat]]

        var frames: [CGRect] { rects.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } }
    }

    private struct Truth: Decodable {
        let scale: CGFloat
        let targets: [Item]
        let decoys: [Item]
    }

    let name: String
    let decoded: DecodedImage
    let pixelsPerPoint: CGFloat
    let targets: [Item]
    let decoys: [Item]

    init(name: String, decoded: DecodedImage, pixelsPerPoint: CGFloat, targets: [Item], decoys: [Item]) {
        self.name = name
        self.decoded = decoded
        self.pixelsPerPoint = pixelsPerPoint
        self.targets = targets
        self.decoys = decoys
    }

    init(_ name: String) throws {
        let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: folder.appending(path: "\(name).json")))
        self.name = name
        self.decoded = try #require(decodeImage(Data(contentsOf: folder.appending(path: "\(name).png"))))
        self.pixelsPerPoint = truth.scale
        self.targets = truth.targets
        self.decoys = truth.decoys
    }
}

struct Coverage {
    /// Targets with some part of their text still readable, with the share that is hidden.
    var exposed: [(text: String, hidden: CGFloat)] = []
    /// Decoys that got blurred although they are not sensitive.
    var blurredDecoys: [String] = []
}

func coverage(of fixture: Fixture, by regions: [SensitiveRegion]) -> Coverage {
    var result = Coverage()
    for target in fixture.targets {
        let frames = target.frames
        let hidden = frames.map { hiddenWidth(of: $0, by: regions) }.reduce(0, +) / frames.map(\.width).reduce(0, +)
        if hidden < 0.98 { result.exposed.append((target.text, hidden)) }
    }
    // A blur that merely grazes the line above or below does not count: the glyphs must be covered.
    for decoy in fixture.decoys where decoy.frames.contains(where: { hiddenWidth(of: $0, by: regions) >= 0.3 * $0.width }) {
        result.blurredDecoys.append(decoy.text)
    }
    return result
}

/// Width of the line box that lies under a region tall enough to cover the glyphs.
private func hiddenWidth(of frame: CGRect, by regions: [SensitiveRegion]) -> CGFloat {
    let glyphBand = frame.insetBy(dx: 0, dy: frame.height * 0.25)
    let spans = regions
        .filter { $0.rect.minY <= glyphBand.minY && $0.rect.maxY >= glyphBand.maxY }
        .map { (max($0.rect.minX, frame.minX), min($0.rect.maxX, frame.maxX)) }
        .filter { $0.0 < $0.1 }
        .sorted { $0.0 < $1.0 }
    var hidden: CGFloat = 0
    var cursor = frame.minX
    for (start, end) in spans where end > cursor {
        hidden += end - max(start, cursor)
        cursor = end
    }
    return hidden
}
