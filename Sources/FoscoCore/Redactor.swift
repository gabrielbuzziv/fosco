import CoreGraphics

public struct RedactedImage: Sendable {
    public let image: CGImage
    /// What was blurred, in pixels with a top-left origin.
    public let regions: [SensitiveRegion]
}

/// Blurs every e-mail address and phone number visible in the image.
/// Returns nil when there is nothing to hide, so callers can leave the original untouched.
public func redactSensitiveContent(
    in image: CGImage,
    pixelsPerPoint: CGFloat = 1,
    kinds: Set<SensitiveKind> = Set(SensitiveKind.allCases)
) -> RedactedImage? {
    let found = locateSensitiveRegions(in: image, layouts: TileLayout.standard(pixelsPerPoint: pixelsPerPoint), kinds: kinds)
    guard !found.isEmpty else { return nil }
    // Padding can make neighbours touch; merge again so no area is blurred twice.
    let regions = mergeRegions(found.map { SensitiveRegion(kind: $0.kind, rect: blurFrame(for: $0.rect)) })
    guard let blurred = blurRegions(regions.map(\.rect), in: image) else { return nil }
    return RedactedImage(image: blurred, regions: regions)
}
