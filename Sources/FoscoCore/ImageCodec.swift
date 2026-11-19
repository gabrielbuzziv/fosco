import CoreGraphics
import Foundation
import ImageIO

public struct DecodedImage: Sendable {
    public let image: CGImage
    /// Uniform type identifier of the container the image came in ("public.png", …).
    public let typeIdentifier: String
    public let dpi: CGFloat?
    public let orientation: Int?

    /// Screen pixels per point the capture was taken at: 1 on a standard display, 2 on Retina.
    public var pixelsPerPoint: CGFloat {
        guard let dpi, dpi > 0 else { return 1 }
        return max(1, (dpi / 72).rounded())
    }
}

public func decodeImage(_ data: Data) -> DecodedImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let typeIdentifier = CGImageSourceGetType(source) as String?,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return DecodedImage(
        image: image,
        typeIdentifier: typeIdentifier,
        dpi: (properties?[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat($0.doubleValue) },
        orientation: (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    )
}

/// Encodes the image, carrying over the density and orientation of the original so it pastes and
/// previews at the same size.
public func encodeImage(_ image: CGImage, as typeIdentifier: String, like original: DecodedImage) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, typeIdentifier as CFString, 1, nil) else { return nil }
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
    if let dpi = original.dpi {
        properties[kCGImagePropertyDPIWidth] = dpi
        properties[kCGImagePropertyDPIHeight] = dpi
    }
    if let orientation = original.orientation {
        properties[kCGImagePropertyOrientation] = orientation
    }
    if typeIdentifier == "public.tiff" {
        // LZW (5): a screen capture as uncompressed TIFF is tens of megabytes.
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
}
