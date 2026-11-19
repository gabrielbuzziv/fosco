// Turns the square artwork in Support/icon-art.png into the app icon: Support/Fosco.icns, plus
// Support/icon.png for the README. Run from the repository root: swift scripts/make-icon.swift
import AppKit
import SwiftUI

let support = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Support")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func context(side: Int) -> CGContext {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    return context
}

/// The artwork cut to the macOS icon shape, an 824 pt rounded square centred on a 1024 pt canvas,
/// sitting on the soft shadow every macOS icon has.
func drawIcon(_ artwork: CGImage) -> CGImage {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tile).cgPath

    let cut = context(side: 1024)
    cut.addPath(shape)
    cut.clip()
    cut.draw(artwork, in: tile)

    // The shadow is cast by the cut artwork itself, so no backing colour shows through at its edge.
    let icon = context(side: 1024)
    icon.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.3))
    icon.draw(cut.makeImage()!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    return icon.makeImage()!
}

func png(_ image: CGImage, side: Int) -> Data {
    let scaled = context(side: side)
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return NSBitmapImageRep(cgImage: scaled.makeImage()!).representation(using: .png, properties: [:])!
}

guard let source = NSImage(contentsOf: support.appending(path: "icon-art.png")),
      let artwork = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Support/icon-art.png is missing or is not an image")
}
let icon = drawIcon(artwork)

let iconset = FileManager.default.temporaryDirectory.appending(path: "Fosco-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(icon, side: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(icon, side: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", support.appending(path: "Fosco.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try png(icon, side: 256).write(to: support.appending(path: "icon.png"))
print("wrote Support/Fosco.icns and Support/icon.png")
