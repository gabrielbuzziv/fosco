import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import FoscoCore

/// End-to-end checks on rendered screens. They run real OCR, so they are serialized and take a
/// few seconds each.
@Suite(.serialized) struct Redaction {
    /// The one thing these screens show that is not caught: a number wrapped onto two lines keeps
    /// the three digits that fall on the second line. Tracked here so a regression is not hidden.
    static let knownGaps: Set<String> = ["+351 912 345 678"]

    @Test(arguments: ["dashboard-light-1x", "dashboard-dark-1x", "dashboard-small-1x", "dashboard-light-2x"])
    func hidesEveryAddressAndNumberOnADashboard(name: String) throws {
        let fixture = try Fixture(name)
        let redacted = try #require(redactSensitiveContent(in: fixture.decoded.image, pixelsPerPoint: fixture.pixelsPerPoint))
        let result = coverage(of: fixture, by: redacted.regions)

        #expect(Set(result.exposed.map(\.text)).subtracting(Self.knownGaps).isEmpty, "still readable: \(result.exposed)")
        #expect(result.exposed.allSatisfy { $0.hidden > 0.7 }, "a known gap got worse: \(result.exposed)")
        #expect(result.blurredDecoys.isEmpty, "blurred although harmless: \(result.blurredDecoys)")
        #expect(redacted.image.width == fixture.decoded.image.width && redacted.image.height == fixture.decoded.image.height)
    }

    @Test func leavesNothingToFindInItsOwnOutput() throws {
        let fixture = try Fixture("dashboard-dark-1x")
        let redacted = try #require(redactSensitiveContent(in: fixture.decoded.image, pixelsPerPoint: 1))
        // Reading the blurred image again must not find any of the hidden text.
        let leftovers = locateSensitiveRegions(in: redacted.image, layouts: TileLayout.standard(pixelsPerPoint: 1), kinds: Set(SensitiveKind.allCases))
        #expect(leftovers.isEmpty, "found again after blurring: \(leftovers)")
    }

    @Test func hidesAScreenPackedWithSmallText() {
        let fixture = Fixture.denseGrid(width: 2560, height: 1440, fontSize: 12)
        let regions = redactSensitiveContent(in: fixture.decoded.image)?.regions ?? []
        #expect(coverage(of: fixture, by: regions).exposed.isEmpty)
    }

    @Test func hidesAVeryTallScrollingCapture() {
        let fixture = Fixture.denseGrid(width: 1200, height: 3600, fontSize: 11, dark: true)
        let regions = redactSensitiveContent(in: fixture.decoded.image)?.regions ?? []
        #expect(coverage(of: fixture, by: regions).exposed.isEmpty)
    }

    @Test func hidesHeadlineTextWiderThanATile() {
        // 2x enlarged, this address is wider than a whole fine tile, so only the coarse sweep sees it whole.
        let secret = "contato.financeiro@construtoraexemplo.com.br"
        let fixture = Fixture.headline("Fale com \(secret) hoje", secret: secret, kind: "email", fontSize: 56, width: 2560, height: 400)
        #expect(fixture.targets[0].frames[0].width > 1100)
        let regions = redactSensitiveContent(in: fixture.decoded.image)?.regions ?? []
        #expect(coverage(of: fixture, by: regions).exposed.isEmpty)
    }

    @Test func leavesAHarmlessScreenAlone() {
        let fixture = Fixture.harmlessText(width: 900, height: 300)
        #expect(redactSensitiveContent(in: fixture.decoded.image) == nil)
    }

    @Test func blursOnlyTheRequestedKinds() throws {
        let fixture = Fixture.denseGrid(width: 1100, height: 300, fontSize: 13)
        let redacted = try #require(redactSensitiveContent(in: fixture.decoded.image, kinds: [.phone]))
        #expect(Set(redacted.regions.map(\.kind)) == [.phone])
        #expect(redactSensitiveContent(in: fixture.decoded.image, kinds: []) == nil)
    }

    @Test func changesPixelsOnlyInsideTheBlurredRegions() throws {
        let fixture = Fixture.denseGrid(width: 1100, height: 300, fontSize: 13)
        let original = fixture.decoded.image
        let redacted = try #require(redactSensitiveContent(in: original))
        let before = try #require(pixels(of: original)), after = try #require(pixels(of: redacted.image))
        var changedOutside = 0, changedInside = 0
        for y in 0..<original.height {
            for x in 0..<original.width where before[(y * original.width + x) * 4..<(y * original.width + x) * 4 + 3] != after[(y * original.width + x) * 4..<(y * original.width + x) * 4 + 3] {
                if redacted.regions.contains(where: { $0.rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) }) {
                    changedInside += 1
                } else {
                    changedOutside += 1
                }
            }
        }
        #expect(changedOutside == 0)
        #expect(changedInside > 1000)
    }

    /// RGBA bytes, top row first.
    private func pixels(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }
}

@Suite struct Pipeline {
    @Test func tellsCleanRedactedAndUnreadableApart() async throws {
        let pipeline = RedactionPipeline()
        func png(_ fixture: Fixture) throws -> Data { try #require(encodeImage(fixture.decoded.image, as: "public.png", like: fixture.decoded)) }

        guard case .clean = await pipeline.outcome(for: try png(.harmlessText(width: 900, height: 300))) else {
            Issue.record("a harmless capture was not reported clean"); return
        }
        guard case .unreadable = await pipeline.outcome(for: Data("not an image".utf8)) else {
            Issue.record("garbage was not reported unreadable"); return
        }
        guard case .redacted(let capture) = await pipeline.outcome(for: try png(.denseGrid(width: 1100, height: 300, fontSize: 13))) else {
            Issue.record("a capture with secrets was not redacted"); return
        }
        #expect(!capture.redacted.regions.isEmpty)
        let jpeg = try #require(capture.encoded(as: "public.jpeg").flatMap(decodeImage))
        #expect(jpeg.typeIdentifier == "public.jpeg" && jpeg.image.width == 1100)
    }

    @Test func doesNotReadAPictureItIsToldIsSettled() async throws {
        let pipeline = RedactionPipeline()
        let secrets = Fixture.denseGrid(width: 1100, height: 300, fontSize: 13).decoded
        let known = try #require(encodeImage(secrets.image, as: "public.png", like: secrets))
        func png(_ image: CGImage) throws -> Data {
            try #require(encodeImage(image, as: "public.png", like: DecodedImage(image: image, typeIdentifier: "public.png", dpi: 144, orientation: nil)))
        }

        // Read on its own this picture would be blurred; listed as settled, in whatever encoding, it is left alone.
        guard case .clean = await pipeline.outcome(for: try png(try #require(redrawn(secrets.image))), settled: [known]) else {
            Issue.record("a settled picture was read again"); return
        }
        let other = Fixture.denseGrid(width: 1100, height: 300, fontSize: 12).decoded.image
        guard case .redacted = await pipeline.outcome(for: try png(other), settled: [known]) else {
            Issue.record("another picture of the same size was taken for the settled one"); return
        }
    }

    @Test func warmsUpWithACaptureThatGoesThroughTheWholePath() throws {
        // If the sample showed nothing to hide, warming up would skip the blur.
        let sample = try #require(sampleCapture())
        let redacted = try #require(redactSensitiveContent(in: sample))
        #expect(redacted.regions.map(\.kind) == [.email])
    }

    @Test func readsACaptureRequestedTwiceAtOnceOnlyOnce() async throws {
        let pipeline = RedactionPipeline()
        let fixture = Fixture.denseGrid(width: 1100, height: 300, fontSize: 13)
        let data = try #require(encodeImage(fixture.decoded.image, as: "public.png", like: fixture.decoded))
        async let first = pipeline.outcome(for: data)
        async let second = pipeline.outcome(for: data)
        guard case .redacted(let a) = await first, case .redacted(let b) = await second else {
            Issue.record("expected both requests to be redacted"); return
        }
        // The same read served both: the blurred image is one object, not two equal ones.
        #expect(a.redacted.image === b.redacted.image)
    }
}

@Suite struct ImageCoding {
    private func encoded(dpi: CGFloat?, type: String = "public.png") throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let original = DecodedImage(image: image, typeIdentifier: type, dpi: dpi, orientation: nil)
        return try #require(encodeImage(image, as: type, like: original))
    }

    @Test func keepsRetinaDensityThroughARoundTrip() throws {
        let decoded = try #require(decodeImage(try encoded(dpi: 144)))
        #expect(decoded.typeIdentifier == "public.png")
        #expect(decoded.dpi == 144)
        #expect(decoded.pixelsPerPoint == 2)
        #expect(decoded.image.width == 40 && decoded.image.height == 20)
    }

    @Test func treatsUnknownDensityAsAStandardDisplay() throws {
        #expect(try #require(decodeImage(try encoded(dpi: nil))).pixelsPerPoint == 1)
        #expect(try #require(decodeImage(try encoded(dpi: 72))).pixelsPerPoint == 1)
    }

    @Test(arguments: ["public.jpeg", "public.tiff", "public.heic"])
    func encodesTheFormatsScreenshotsComeIn(type: String) throws {
        #expect(try #require(decodeImage(try encoded(dpi: 144, type: type))).typeIdentifier == type)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(decodeImage(Data("not an image".utf8)) == nil)
        #expect(decodeImage(Data()) == nil)
    }
}
