import CoreGraphics
import CoreImage

/// Returns a copy of the image with every rectangle (pixels, top-left origin) blurred.
///
/// A plain blur of text can be matched back to the letters that produced it. So each patch is
/// first averaged into a coarse mosaic on a randomly placed grid, about one cell per letter, and
/// only then smoothed: what is left is a soft smear that no longer holds the letter shapes. A faint
/// neutral tint on top makes the patch read as deliberate on both light and dark screens.
func blurRegions(_ rects: [CGRect], in image: CGImage) -> CGImage? {
    let width = image.width, height = image.height
    let colorSpace = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let canvas = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    canvas.draw(image, in: bounds)

    let source = CIImage(cgImage: image)
    for rect in rects {
        // Core Graphics and Core Image both put the origin at the bottom-left.
        let frame = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
            .integral.intersection(bounds)
        guard !frame.isEmpty else { continue }
        let cell = max(4, frame.height * 0.45)
        let gridOrigin = CIVector(x: frame.minX + .random(in: 0..<cell), y: frame.minY + .random(in: 0..<cell))
        let smear = source.cropped(to: frame).clampedToExtent()
            // Pixellate samples single points; averaging first makes each cell stand for its area.
            .applyingGaussianBlur(sigma: cell * 0.5)
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: cell, kCIInputCenterKey: gridOrigin])
            .applyingGaussianBlur(sigma: cell * 0.9)
            .cropped(to: frame)
        guard let patch = renderer.createCGImage(smear, from: frame, format: .RGBA8, colorSpace: colorSpace) else { return nil }
        let radius = min(frame.height * 0.28, frame.width / 2)
        canvas.saveGState()
        canvas.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        canvas.clip()
        canvas.draw(patch, in: frame)
        canvas.setFillColor(CGColor(gray: 0.5, alpha: 0.1))
        canvas.fill(frame)
        canvas.restoreGState()
    }
    return canvas.makeImage()
}

/// Room around the recognized text. Vision's boxes already carry a few pixels of slack sideways, so
/// more would smear the neighbouring words; this only guards against a clipped first or last glyph.
func blurFrame(for textRect: CGRect) -> CGRect {
    textRect.insetBy(dx: -max(2, textRect.height * 0.12), dy: -max(1, textRect.height * 0.1))
}

/// CIContext is documented as thread-safe; creating one is expensive, so it is shared.
private let renderer = CIContext()
