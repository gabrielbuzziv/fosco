import Foundation
import Testing
@testable import FoscoCore

@MainActor @Suite(.serialized) final class FolderGuarding {
    private let folder: URL
    private var redactions: [[SensitiveRegion]] = []

    private static let secrets = Fixture.denseGrid(width: 1100, height: 300, fontSize: 13).decoded
    private static let harmless = Fixture.harmlessText(width: 900, height: 300).decoded
    private static let screenshotFlag = "com.apple.metadata:kMDItemIsScreenCapture"

    init() throws {
        // Resolved, because FSEvents reports /private/var/… for the temporary directory.
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "fosco-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeGuard(_ scope: FolderGuard.Folder.Scope = .everyImage) -> FolderGuard {
        let watcher = FolderGuard(folders: [FolderGuard.Folder(url: folder, scope: scope)], pipeline: RedactionPipeline())
        watcher.onRedaction = { [unowned self] in redactions.append($0) }
        return watcher
    }

    @discardableResult
    private func save(_ image: DecodedImage, as name: String, type: String = "public.png") throws -> (url: URL, data: Data) {
        let data = try #require(encodeImage(image.image, as: type, like: image))
        let url = folder.appending(path: name)
        try data.write(to: url)
        return (url, data)
    }

    private func setAttribute(_ name: String, _ value: String, on url: URL) {
        let bytes = Array(value.utf8)
        #expect(setxattr(url.path, name, bytes, bytes.count, 0, 0) == 0)
    }

    private func creationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
    }

    private func attribute(_ name: String, of url: URL) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = getxattr(url.path, name, &buffer, buffer.count, 0, 0)
        return length >= 0 ? String(decoding: buffer[..<length], as: UTF8.self) : nil
    }

    @Test func blursANewCaptureInPlace() async throws {
        let saved = try save(Self.secrets, as: "SCR-20261119-abcd.png")
        setAttribute(Self.screenshotFlag, "1", on: saved.url)
        setAttribute("com.apple.metadata:_kMDItemUserTags", "trabalho", on: saved.url)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: saved.url.path)
        let created = try #require(creationDate(of: saved.url))

        await makeGuard().process(saved.url)

        let output = try #require(decodeImage(try Data(contentsOf: saved.url)))
        #expect(output.typeIdentifier == "public.png")
        #expect(output.image.width == Self.secrets.image.width)
        #expect(redactSensitiveContent(in: output.image) == nil)
        #expect(redactions.count == 1)
        // Still the same file to Finder and Spotlight.
        #expect(attribute(Self.screenshotFlag, of: saved.url) == "1")
        #expect(attribute("com.apple.metadata:_kMDItemUserTags", of: saved.url) == "trabalho")
        let createdAfter = try #require(creationDate(of: saved.url))
        #expect(abs(createdAfter.timeIntervalSince(created)) < 1)
        #expect(Date().timeIntervalSince(createdAfter) > 100)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["SCR-20261119-abcd.png"])
    }

    @Test func keepsTheFormatOfTheCapture() async throws {
        let saved = try save(Self.secrets, as: "Captura.jpg", type: "public.jpeg")
        await makeGuard().process(saved.url)
        let output = try #require(decodeImage(try Data(contentsOf: saved.url)))
        #expect(output.typeIdentifier == "public.jpeg")
        #expect(redactions.count == 1)
    }

    @Test func leavesACaptureWithNothingToHideUntouched() async throws {
        let saved = try save(Self.harmless, as: "SCR-clean.png")
        await makeGuard().process(saved.url)
        #expect(try Data(contentsOf: saved.url) == saved.data)
        #expect(redactions.isEmpty)
    }

    @Test func touchesOnlyFlaggedScreenshotsInASharedFolder() async throws {
        let watcher = makeGuard(.flaggedScreenshots)
        let photo = try save(Self.secrets, as: "foto-do-evento.png")
        await watcher.process(photo.url)
        #expect(try Data(contentsOf: photo.url) == photo.data)

        let capture = try save(Self.secrets, as: "Captura de Tela 2026-11-19.png")
        setAttribute(Self.screenshotFlag, "1", on: capture.url)
        await watcher.process(capture.url)
        #expect(try Data(contentsOf: capture.url) != capture.data)
        #expect(redactions.count == 1)
    }

    @Test func leavesOldFilesAlone() async throws {
        let saved = try save(Self.secrets, as: "SCR-antiga.png")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: saved.url.path)
        await makeGuard().process(saved.url)
        #expect(try Data(contentsOf: saved.url) == saved.data)
    }

    @Test func ignoresFilesThatAreNotImagesOrNotWatched() async throws {
        let watcher = makeGuard()
        let text = folder.appending(path: "notas.txt")
        try Data("ana@exemplo.com".utf8).write(to: text)
        await watcher.process(text)
        #expect(try Data(contentsOf: text) == Data("ana@exemplo.com".utf8))

        let elsewhere = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: "fosco-outside-\(UUID().uuidString).png")
        let data = try #require(encodeImage(Self.secrets.image, as: "public.png", like: Self.secrets))
        try data.write(to: elsewhere)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        await watcher.process(elsewhere)
        #expect(try Data(contentsOf: elsewhere) == data)
        #expect(redactions.isEmpty)
    }

    @Test func doesNothingWhilePaused() async throws {
        let watcher = makeGuard()
        watcher.isEnabled = false
        let saved = try save(Self.secrets, as: "SCR-paused.png")
        await watcher.process(saved.url)
        #expect(try Data(contentsOf: saved.url) == saved.data)
    }

    @Test func restoresTheOriginalOnRequest() async throws {
        let watcher = makeGuard()
        let saved = try save(Self.secrets, as: "SCR-undo.png")
        #expect(!watcher.canRestoreOriginal)
        await watcher.process(saved.url)
        #expect(watcher.canRestoreOriginal)

        #expect(watcher.restoreOriginal())
        #expect(try Data(contentsOf: saved.url) == saved.data)
        // The restored capture is the user's choice: the event our write causes must not blur it again.
        await watcher.process(saved.url)
        #expect(try Data(contentsOf: saved.url) == saved.data)
        #expect(!watcher.canRestoreOriginal)
        #expect(redactions.count == 1)
    }

    @Test func cannotRestoreAFileThatChangedSince() async throws {
        let watcher = makeGuard()
        let saved = try save(Self.secrets, as: "SCR-edited.png")
        await watcher.process(saved.url)
        try Data("edited elsewhere".utf8).write(to: saved.url)
        #expect(!watcher.canRestoreOriginal)
        #expect(!watcher.restoreOriginal())
        #expect(try Data(contentsOf: saved.url) == Data("edited elsewhere".utf8))
    }

    @Test func noticesNewFilesOnItsOwnOnceStarted() async throws {
        let watcher = makeGuard()
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300)) // let the stream come up
        let saved = try save(Self.secrets, as: "SCR-watched.png")
        for _ in 0..<160 where redactions.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(redactions.count == 1)
        #expect(try Data(contentsOf: saved.url) != saved.data)
    }
}
