import CoreGraphics
import Foundation
import Testing
@testable import FoscoCore

/// Not a regression test: prints accuracy and latency for several scan plans so the defaults in
/// `TileLayout.standard` can be chosen from evidence. Run with `FOSCO_BENCH=1 swift test --filter ScanBenchmark`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FOSCO_BENCH"] != nil), .serialized)
struct ScanBenchmark {
    static func fixtures() throws -> [Fixture] {
        try ["dashboard-light-1x", "dashboard-dark-1x", "dashboard-small-1x", "dashboard-light-2x"].map(Fixture.init) + [
            .denseGrid(width: 2560, height: 1440, fontSize: 12),
            .denseGrid(width: 3440, height: 1440, fontSize: 13, dark: true),
            .denseGrid(width: 2560, height: 1440, fontSize: 20),
            .denseGrid(width: 2560, height: 1440, fontSize: 30),
            .denseGrid(width: 2560, height: 1440, fontSize: 44, dark: true),
            .denseGrid(width: 2560, height: 1440, fontSize: 64),
            .denseGrid(width: 1400, height: 6000, fontSize: 11, dark: true),
            .denseGrid(width: 1100, height: 700, fontSize: 13),
        ]
    }

    static func plans(density: CGFloat) -> [(String, [TileLayout], Int)] {
        let standard = TileLayout.standard(pixelsPerPoint: density)
        return [
            ("standard", standard, defaultConcurrentTiles),
            ("fine sweep only", [standard[0]], defaultConcurrentTiles),
            ("coarse sweep only", [standard[1]], defaultConcurrentTiles),
        ]
    }

    @Test func comparePlans() throws {
        let fixtures = try Self.fixtures()
        let allKinds = Set(SensitiveKind.allCases)
        _ = locateSensitiveRegions(in: fixtures[0].decoded.image, layouts: TileLayout.standard(pixelsPerPoint: 2), kinds: allKinds) // load the models
        for fixture in fixtures {
            let image = fixture.decoded.image
            print("\n== \(fixture.name) (\(image.width)x\(image.height), \(fixture.targets.count) targets, \(fixture.decoys.count) decoys)")
            for (label, layouts, concurrency) in Self.plans(density: fixture.pixelsPerPoint) {
                let tiles = layouts.map { tileRects(for: CGSize(width: image.width, height: image.height), layout: $0).count }
                var timings: [Int] = []
                var result = Coverage()
                for _ in 0..<3 {
                    let start = Date()
                    let found = locateSensitiveRegions(in: image, layouts: layouts, kinds: allKinds, maxConcurrentTiles: concurrency)
                    timings.append(Int(Date().timeIntervalSince(start) * 1000))
                    result = coverage(of: fixture, by: mergeRegions(found.map { SensitiveRegion(kind: $0.kind, rect: blurFrame(for: $0.rect)) }))
                }
                let label = label.padding(toLength: 24, withPad: " ", startingAt: 0)
                print("  \(label) tiles \(tiles)  exposed \(result.exposed.count)  decoys hit \(result.blurredDecoys.count)  median \(timings.sorted()[1]) ms")
                for miss in result.exposed.prefix(4) { print("      exposed: \(miss.text)  (\(Int(miss.hidden * 100))% hidden)") }
                for decoy in result.blurredDecoys.prefix(3) { print("      decoy: \(decoy)") }
            }
        }
    }
}
