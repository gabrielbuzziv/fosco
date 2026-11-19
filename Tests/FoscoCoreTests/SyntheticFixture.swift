import AppKit
@testable import FoscoCore

extension Fixture {
    /// One line of text drawn at the given size, centred, with the frame of `secret` inside it.
    static func headline(_ text: String, secret: String, kind: String, fontSize: CGFloat, width: Int, height: Int) -> Fixture {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.black]
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        (text as NSString).draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let prefix = String(text[..<text.range(of: secret)!.lowerBound])
        let offset = (prefix as NSString).size(withAttributes: attributes).width
        let secretWidth = (secret as NSString).size(withAttributes: attributes).width
        let frame: [CGFloat] = [origin.x + offset, CGFloat(height) - origin.y - size.height, secretWidth, size.height]
        let decoded = decodeImage(bitmap.representation(using: .png, properties: [:])!)!
        return Fixture(name: "headline-\(Int(fontSize))px", decoded: decoded, pixelsPerPoint: 1,
                       targets: [Item(kind: kind, text: secret, rects: [frame])], decoys: [])
    }

    /// A screen with text but nothing sensitive on it.
    static func harmlessText(width: Int, height: Int) -> Fixture {
        let lines = [
            "Relatório de vendas — novembro de 2026", "Pedido #48213 confirmado em 19/11/2026 às 14:32",
            "Total: R$ 128.480,90 (+12,5% sobre outubro)", "CNPJ 12.345.678/0001-90 · CEP 01310-100",
            "npm install react@18.2.0 next@canary", "Siga @fulano.detal para mais dicas", "Versão 4.18.2 · build 4815162342",
        ]
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (row, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 24, y: CGFloat(height) - 40 - CGFloat(row) * 30), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        let decoded = decodeImage(bitmap.representation(using: .png, properties: [:])!)!
        return Fixture(name: "harmless", decoded: decoded, pixelsPerPoint: 1, targets: [], decoys: [])
    }

    /// A worst case no real screen reaches: every row packed with addresses and numbers.
    static func denseGrid(width: Int, height: Int, fontSize: CGFloat, dark: Bool = false) -> Fixture {
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.15, alpha: 1),
        ]
        let rowHeight = ceil(fontSize * 2), columnWidth = fontSize * 36
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        var targets: [Item] = []
        var decoys: [Item] = []
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var index = 0
        var baseline = CGFloat(height) - rowHeight - 10
        while baseline > 10 {
            var x: CGFloat = 16
            while x + columnWidth < CGFloat(width) {
                let label = "Linha \(index)  "
                let secret = index.isMultiple(of: 2)
                    ? "cliente\(index)@empresa\(index % 7).com.br"
                    : String(format: "(11) 9%04d-%04d", index % 10000, (index * 7) % 10000)
                (label + secret as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: attributes)
                let labelSize = (label as NSString).size(withAttributes: attributes)
                let secretSize = (secret as NSString).size(withAttributes: attributes)
                // AppKit's origin is bottom-left; fixtures use top-left.
                let top = CGFloat(height) - baseline - labelSize.height
                targets.append(Item(kind: index.isMultiple(of: 2) ? "email" : "phone", text: secret,
                                    rects: [[x + labelSize.width, top, secretSize.width, secretSize.height]]))
                decoys.append(Item(kind: "decoy", text: label, rects: [[x, top, labelSize.width - fontSize * 0.6, labelSize.height]]))
                index += 1
                x += columnWidth
            }
            baseline -= rowHeight
        }
        NSGraphicsContext.restoreGraphicsState()
        let decoded = decodeImage(bitmap.representation(using: .png, properties: [:])!)!
        return Fixture(name: "dense-\(width)x\(height)-\(Int(fontSize))px", decoded: decoded, pixelsPerPoint: 1, targets: targets, decoys: decoys)
    }
}
