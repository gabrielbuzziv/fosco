import CoreGraphics
import CoreText
import CryptoKit
import Foundation

public struct RedactedCapture: Sendable {
    public let original: DecodedImage
    public let redacted: RedactedImage

    /// The blurred image in the given container, with the original's density and orientation.
    public func encoded(as typeIdentifier: String) -> Data? {
        encodeImage(redacted.image, as: typeIdentifier, like: original)
    }
}

public enum RedactionOutcome: Sendable {
    /// Nothing sensitive was found; the capture can stay as it is.
    case clean
    case redacted(RedactedCapture)
    /// Not an image, or too large to read in reasonable time.
    case unreadable
}

/// Reads captures off the main thread. A capture requested again while it is still being read
/// (Shottr copies once on capture and again on Esc) shares the first read.
public actor RedactionPipeline {
    private var inFlight: [Data: Task<RedactionOutcome, Never>] = [:]

    public init() {}

    /// Reads and blurs a throwaway image so the text models and blur shaders are loaded before the
    /// first real capture, which would otherwise take a second or two longer.
    public nonisolated func warmUp() {
        Task.detached(priority: .utility) {
            guard let sample = sampleCapture() else { return }
            _ = redactSensitiveContent(in: sample)
        }
    }

    /// `settled` are pictures known to need no reading, in any encoding: blurred copies this app
    /// made, and originals the user asked to keep.
    public func outcome(for imageData: Data, settled: [Data] = []) async -> RedactionOutcome {
        let key = digest(of: imageData)
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .userInitiated) { redact(imageData, settled: settled) }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return outcome
    }
}

public func digest(of data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

/// A scrolling capture this large takes minutes to read; leave it alone instead of stalling.
private let maximumPixelCount = 80_000_000

private func redact(_ data: Data, settled: [Data]) -> RedactionOutcome {
    guard let decoded = decodeImage(data), decoded.image.width * decoded.image.height <= maximumPixelCount else {
        return .unreadable
    }
    let isSettled = settled.contains { known in
        decodeImage(known).map { showsSamePicture(decoded.image, $0.image) } ?? false
    }
    guard !isSettled else {
        logger.notice("Recognised a picture that needs no reading")
        return .clean
    }
    guard let redacted = redactSensitiveContent(in: decoded.image, pixelsPerPoint: decoded.pixelsPerPoint) else {
        return .clean
    }
    return .redacted(RedactedCapture(original: decoded, redacted: redacted))
}

/// A small white image with one made-up address on it.
func sampleCapture() -> CGImage? {
    guard let context = CGContext(
        data: nil, width: 480, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 480, height: 80))
    let text = NSAttributedString(string: "contato: exemplo@exemplo.com.br", attributes: [
        kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 22, nil),
        kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
    ])
    context.textPosition = CGPoint(x: 20, y: 30)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    return context.makeImage()
}
