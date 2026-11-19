import CoreGraphics
import Foundation

/// A window Shottr has on screen.
public struct ShottrWindow: Equatable, Sendable {
    public var number: Int
    /// 0 for an ordinary window such as the editor; the preview thumbnail floats far above.
    public var layer: Int
    public var size: CGSize

    public init(number: Int, layer: Int, size: CGSize) {
        self.number = number
        self.layer = layer
        self.size = size
    }
}

/// How Shottr shows a capture. Either way it keeps the original, there to be dragged out.
public enum ShottrView: Equatable, Sendable {
    /// In its editor, whose picture Shottr replaces when asked to load the clipboard.
    case editor
    /// As a small preview floating above everything. Shottr offers no way to replace or dismiss
    /// it: it keeps its picture until the user drags it, opens it or closes it.
    case thumbnail
}

/// How Shottr is showing the capture that was just blurred on the clipboard, if it is.
///
/// - The editor is reused from one capture to the next, so it counts only when Shottr is in front,
///   or was until the capture was copied: one left open behind another app holds something else.
/// - The thumbnail comes up a moment after the capture is copied, so it counts when it was not on
///   screen before. Shottr does not come to the front for it.
public func shottrView(
    of windows: [ShottrWindow], onScreenBefore: Set<Int>, isFrontmost: Bool, lastDeactivated: Date?, copiedAt: Date
) -> ShottrView? {
    let editorIsOpen = windows.contains { $0.layer == 0 }
    // The read takes a second or two, time enough to click elsewhere.
    let wasInFront = isFrontmost || lastDeactivated.map { $0 >= copiedAt.addingTimeInterval(-1) } == true
    if editorIsOpen && wasInFront { return .editor }
    let thumbnailCameUp = windows.contains { window in
        window.layer >= thumbnailLayer && max(window.size.width, window.size.height) <= largestThumbnailSide
            && !onScreenBefore.contains(window.number)
    }
    return thumbnailCameUp ? .thumbnail : nil
}

/// Where Shottr puts its thumbnail: the level of screen savers. Its confirmation banner sits lower,
/// and the overlay it draws while an area is selected is as large as the screen.
private let thumbnailLayer = 1000
private let largestThumbnailSide: CGFloat = 600
