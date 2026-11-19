import CoreGraphics
import Foundation
import Testing
@testable import FoscoCore

/// The picture as another app would hand it back: drawn again, a channel off by one level here and
/// there. `drawing` adds something on top, for when it is no longer the same picture.
func redrawn(_ image: CGImage, drawing: (CGContext) -> Void = { _ in }) -> CGImage? {
    let count = image.width * image.height * 4
    guard let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let data = context.data else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = data.bindMemory(to: UInt8.self, capacity: count)
    for index in stride(from: 0, to: count, by: 28) where bytes[index] > 5 && bytes[index] < 250 { bytes[index] += 1 }
    drawing(context)
    return context.makeImage()
}

@Suite struct SamePicture {
    private let picture = Fixture.denseGrid(width: 600, height: 200, fontSize: 13).decoded.image

    @Test func recognisesAPictureThatWasEncodedAgain() throws {
        let again = try #require(redrawn(picture))
        let decoded = DecodedImage(image: again, typeIdentifier: "public.png", dpi: 144, orientation: nil)
        let fromTIFF = try #require(encodeImage(again, as: "public.tiff", like: decoded).flatMap(decodeImage))
        #expect(showsSamePicture(picture, again))
        #expect(showsSamePicture(picture, fromTIFF.image))
    }

    @Test func tellsApartAPictureWithSomethingAdded() throws {
        // A few dark pixels on a white margin, as one more word would leave.
        let changed = try #require(redrawn(picture) { context in
            context.setFillColor(CGColor(gray: 0.1, alpha: 1))
            context.fill(CGRect(x: 2, y: 2, width: 9, height: 2))
        })
        #expect(!showsSamePicture(picture, changed))
    }

    @Test func tellsApartPicturesOfDifferentSizes() {
        #expect(!showsSamePicture(picture, Fixture.denseGrid(width: 600, height: 220, fontSize: 13).decoded.image))
    }
}
