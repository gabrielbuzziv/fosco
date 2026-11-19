import Foundation
import FoscoCore

/// Blurs one image file from the command line. Writes next to the input unless an output is given.
func runRedactCommand(_ arguments: [String]) -> Int32 {
    guard let inputPath = arguments.first else {
        FileHandle.standardError.write(Data("uso: Fosco redact <imagem> [saída]\n".utf8))
        return 64
    }
    let input = URL(fileURLWithPath: inputPath)
    let output = arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        ?? input.deletingPathExtension().appendingPathExtension("fosco").appendingPathExtension(input.pathExtension)
    do {
        guard let decoded = decodeImage(try Data(contentsOf: input)) else {
            FileHandle.standardError.write(Data("\(input.lastPathComponent) não é uma imagem que o Fosco consiga ler\n".utf8))
            return 65
        }
        let started = Date()
        guard let redacted = redactSensitiveContent(in: decoded.image, pixelsPerPoint: decoded.pixelsPerPoint) else {
            print("Nada a borrar em \(input.lastPathComponent)")
            return 0
        }
        guard let data = encodeImage(redacted.image, as: decoded.typeIdentifier, like: decoded) else {
            FileHandle.standardError.write(Data("Não foi possível codificar a imagem borrada\n".utf8))
            return 70
        }
        try data.write(to: output)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        print("\(describeRedaction(redacted.regions)) em \(seconds) s → \(output.path)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        return 74
    }
}
