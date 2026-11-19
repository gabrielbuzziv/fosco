import CoreGraphics
import Testing
@testable import FoscoCore

@Suite struct FragmentStitching {
    /// A fragment on a 20px-tall line starting at `x`, `width` wide, on the row at `y`.
    private func box(_ x: CGFloat, _ width: CGFloat, y: CGFloat = 100) -> CGRect {
        CGRect(x: x, y: y, width: width, height: 20)
    }

    private func indices(_ runs: [[(index: Int, isGlued: Bool)]]) -> [[Int]] {
        runs.map { $0.map(\.index) }
    }

    @Test func gluesAnAddressSplitInsideAWord() {
        // "Linha 6 cliente6@empresa6" + ".com.br": the second box even overlaps the first.
        let runs = fragmentRuns([box(16, 369), box(380, 105)])
        #expect(indices(runs) == [[0, 1]])
        #expect(runs[0].map(\.isGlued) == [false, true])
        #expect(joinFragments([("cliente6@empresa6", false), (".com.br", true)]).text == "cliente6@empresa6.com.br")
    }

    @Test func joinsPiecesOfANumberWithASpace() {
        // "(47)" "9" "0888-7777", separated by ordinary word spaces, given out of order.
        let runs = fragmentRuns([box(70, 80), box(10, 30), box(48, 12)])
        #expect(indices(runs) == [[1, 2, 0]])
        #expect(runs[0].map(\.isGlued) == [false, false, false])
        let line = joinFragments([("(47)", false), ("9", false), ("0888-7777", false)])
        #expect(line.text == "(47) 9 0888-7777")
        #expect(line.offsets == [0, 5, 7])
    }

    @Test func keepsDistantColumnsApart() {
        #expect(indices(fragmentRuns([box(10, 100), box(160, 100)])) == [[0], [1]])
    }

    @Test func keepsDifferentLinesApart() {
        #expect(indices(fragmentRuns([box(10, 100), box(112, 100, y: 124)])) == [[0], [1]])
    }

    @Test func attachesToTheNearestFragmentOnTheLine() {
        // Two rows; the third fragment continues the second row.
        #expect(indices(fragmentRuns([box(10, 100), box(10, 100, y: 130), box(114, 60, y: 130)])) == [[0], [1, 2]])
    }
}

@Suite struct Tiling {
    @Test func usesOneTileWhenTheImageFits() {
        let spans = tileSpans(length: 900, tile: 1024, overlap: 512)
        #expect(spans.count == 1)
        #expect(spans[0].start == 0 && spans[0].length == 900)
    }

    @Test(arguments: [(2560.0, 1024.0, 512.0), (3440.0, 1024.0, 512.0), (1440.0, 1024.0, 96.0), (12000.0, 1024.0, 96.0), (1025.0, 1024.0, 512.0)])
    func coversTheWholeLengthWithTheRequestedOverlap(length: CGFloat, tile: CGFloat, overlap: CGFloat) {
        let spans = tileSpans(length: length, tile: tile, overlap: overlap)
        #expect(spans.first?.start == 0)
        #expect(spans.allSatisfy { $0.length <= tile })
        #expect(spans.last.map { $0.start + $0.length } == length)
        for (previous, next) in zip(spans, spans.dropFirst()) {
            #expect(previous.start + previous.length - next.start >= overlap - 1)
        }
    }

    @Test func enlargesCapturesFromStandardDisplaysOnly() {
        #expect(TileLayout.standard(pixelsPerPoint: 1).map(\.scale) == [2, 0.5])
        #expect(TileLayout.standard(pixelsPerPoint: 2).map(\.scale) == [1, 0.25])
    }
}

@Suite struct RegionMerging {
    @Test func collapsesTheSameTextFoundTwice() {
        let merged = mergeRegions([
            SensitiveRegion(kind: .email, rect: CGRect(x: 100, y: 50, width: 200, height: 16)),
            SensitiveRegion(kind: .email, rect: CGRect(x: 104, y: 51, width: 198, height: 15)),
        ])
        #expect(merged == [SensitiveRegion(kind: .email, rect: CGRect(x: 100, y: 50, width: 202, height: 16))])
    }

    @Test func keepsNeighboursOnTheSameRowSeparate() {
        let regions = [
            SensitiveRegion(kind: .email, rect: CGRect(x: 100, y: 50, width: 200, height: 16)),
            SensitiveRegion(kind: .phone, rect: CGRect(x: 340, y: 50, width: 110, height: 16)),
        ]
        #expect(mergeRegions(regions) == regions)
    }

    @Test func absorbsChainsOfOverlaps() {
        // The middle piece bridges two that do not touch each other.
        let merged = mergeRegions([
            SensitiveRegion(kind: .phone, rect: CGRect(x: 0, y: 0, width: 100, height: 20)),
            SensitiveRegion(kind: .phone, rect: CGRect(x: 160, y: 0, width: 100, height: 20)),
            SensitiveRegion(kind: .phone, rect: CGRect(x: 60, y: 0, width: 140, height: 20)),
        ])
        #expect(merged.map(\.rect) == [CGRect(x: 0, y: 0, width: 260, height: 20)])
    }
}
