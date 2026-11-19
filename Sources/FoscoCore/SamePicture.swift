import CoreGraphics
import Foundation

/// Whether two images show the same picture, give or take the rounding an app introduces when it
/// decodes an image and encodes it again.
///
/// Shottr, once its editor shows the blurred copy, copies that back in its own encoding when the
/// editor is closed: other bytes, the same pixels. Recognising them spares a second read, during
/// which nothing could be pasted.
func showsSamePicture(_ first: CGImage, _ second: CGImage) -> Bool {
    guard first.width == second.width, first.height == second.height,
          first.width * first.height <= comparablePixelCount,
          let a = premultipliedPixels(of: first), let b = premultipliedPixels(of: second) else { return false }
    if a == b { return true }
    return a.withUnsafeBytes { a in
        b.withUnsafeBytes { b in
            for index in 0..<a.count where abs(Int(a[index]) - Int(b[index])) > roundingTolerance { return false }
            return true
        }
    }
}

/// Both images are held uncompressed while they are compared; beyond this, reading is the cheaper way.
private let comparablePixelCount = 16_000_000
/// How many levels out of 255 a channel may be off by. Text anyone could read is off by far more.
private let roundingTolerance = 3

/// RGBA bytes in sRGB, colour multiplied by opacity: a nearly transparent pixel can hold any
/// colour, and what counts is what it looks like.
private func premultipliedPixels(of image: CGImage) -> Data? {
    var bytes = Data(count: image.width * image.height * 4)
    let isDrawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return isDrawn ? bytes : nil
}
