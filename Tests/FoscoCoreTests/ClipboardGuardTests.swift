import AppKit
import Testing
@testable import FoscoCore

/// Drives the guard on a private pasteboard, so the tests never touch the real clipboard.
@MainActor @Suite(.serialized) final class ClipboardGuarding {
    private let pasteboard = NSPasteboard.withUniqueName()
    private let watcher: ClipboardGuard
    private var redactions: [[SensitiveRegion]] = []
    private var reading: [Bool] = []

    private static let secrets = Fixture.denseGrid(width: 1100, height: 300, fontSize: 13).decoded
    private static let harmless = Fixture.harmlessText(width: 900, height: 300).decoded
    private static let marker = NSPasteboard.PasteboardType("com.gabrielbuzzi.fosco.processed")

    init() {
        watcher = ClipboardGuard(pasteboard: pasteboard, pipeline: RedactionPipeline(), knownClean: DigestStore(defaults: nil))
        watcher.onRedaction = { [unowned self] regions, _ in redactions.append(regions) }
        watcher.onReadingChange = { [unowned self] in reading.append($0) }
    }

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    /// Copies an image the way Shottr does: one item carrying TIFF and PNG.
    @discardableResult
    private func copy(_ image: DecodedImage) throws -> (tiff: Data, png: Data) {
        let tiff = try #require(encodeImage(image.image, as: "public.tiff", like: image))
        let png = try #require(encodeImage(image.image, as: "public.png", like: image))
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        item.setData(png, forType: .png)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return (tiff, png)
    }

    private var types: [NSPasteboard.PasteboardType] { pasteboard.pasteboardItems?.first?.types ?? [] }

    @Test func blursACopiedCaptureThatShowsSecrets() async throws {
        try copy(Self.secrets)
        watcher.poll()
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true, "the capture must not be pasteable while it is being read")
        await watcher.idle()

        #expect(types == [.tiff, .png, Self.marker])
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let output = try #require(pasteboard.data(forType: type).flatMap(decodeImage))
            #expect(output.image.width == Self.secrets.image.width)
            #expect(redactSensitiveContent(in: output.image) == nil, "\(type.rawValue) still shows something")
        }
        #expect(redactions.count == 1)
        #expect(Set(redactions[0].map(\.kind)) == [.email, .phone])
    }

    @Test func putsBackACaptureWithNothingToHide() async throws {
        let copied = try copy(Self.harmless)
        watcher.poll()
        await watcher.idle()

        #expect(types == [.tiff, .png])
        #expect(pasteboard.data(forType: .tiff) == copied.tiff)
        #expect(pasteboard.data(forType: .png) == copied.png)
        #expect(redactions.isEmpty)
        #expect(!watcher.canRestoreOriginal)
    }

    @Test func leavesContentThatIsNotABareImageAlone() async throws {
        // What a slide, a layer or a web image looks like: a preview image next to the app's own data.
        let png = try #require(encodeImage(Self.secrets.image, as: "public.png", like: Self.secrets))
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString("<img src='x'>", forType: .html)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let changeCount = pasteboard.changeCount

        watcher.poll()
        await watcher.idle()
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.data(forType: .png) == png)
        #expect(redactions.isEmpty)
    }

    @Test func leavesTextAlone() async {
        pasteboard.clearContents()
        pasteboard.setString("ana@exemplo.com 11 90765-4321", forType: .string)
        let changeCount = pasteboard.changeCount
        watcher.poll()
        await watcher.idle()
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "ana@exemplo.com 11 90765-4321")
    }

    @Test func restoresTheOriginalOnRequest() async throws {
        let copied = try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        #expect(watcher.canRestoreOriginal)

        #expect(watcher.restoreOriginal())
        #expect(pasteboard.data(forType: .png) == copied.png)
        #expect(pasteboard.data(forType: .tiff) == copied.tiff)
        // The restored capture is the user's choice: it is not blurred again.
        watcher.poll()
        await watcher.idle()
        #expect(pasteboard.data(forType: .png) == copied.png)
        #expect(!watcher.canRestoreOriginal)
        #expect(!watcher.restoreOriginal())
    }

    @Test func leavesARestoredCaptureAloneWhenItIsCopiedAgain() async throws {
        let copied = try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        #expect(watcher.restoreOriginal())

        // Back in the screenshot app, the user copies the same capture once more.
        try copy(Self.secrets)
        let changeCount = pasteboard.changeCount
        watcher.poll()
        await watcher.idle()
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.data(forType: .png) == copied.png)
        #expect(redactions.count == 1)
    }

    @Test func catchesACaptureWrittenAfterThePasteboardWasCleared() async throws {
        // An app clears first and writes a moment later; a poll can land in between.
        pasteboard.clearContents()
        let clearedCount = pasteboard.changeCount
        watcher.poll()
        let tiff = try #require(encodeImage(Self.secrets.image, as: "public.tiff", like: Self.secrets))
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        pasteboard.writeObjects([item])
        #expect(pasteboard.changeCount == clearedCount, "writing after clearing is expected not to move the change count")

        watcher.poll()
        await watcher.idle()
        #expect(redactions.count == 1)
        #expect(types == [.tiff, Self.marker])
    }

    @Test func stopsLookingOnceAnEmptyPasteboardStaysEmpty() async throws {
        pasteboard.clearContents()
        for _ in 0..<60 { watcher.poll() }
        // Written long after the clearing, without a change of count: nothing announces it.
        let tiff = try #require(encodeImage(Self.secrets.image, as: "public.tiff", like: Self.secrets))
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        pasteboard.writeObjects([item])
        watcher.poll()
        await watcher.idle()
        #expect(redactions.isEmpty)
    }

    @Test func cannotRestoreOnceSomethingElseWasCopied() async throws {
        try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        pasteboard.clearContents()
        pasteboard.setString("outra coisa", forType: .string)

        #expect(!watcher.canRestoreOriginal)
        #expect(!watcher.restoreOriginal())
        #expect(pasteboard.string(forType: .string) == "outra coisa")
    }

    @Test func dropsItsResultWhenSomethingNewerIsCopied() async throws {
        try copy(Self.secrets)
        watcher.poll()
        pasteboard.clearContents()
        pasteboard.setString("copiado durante a leitura", forType: .string)
        watcher.poll()
        await watcher.idle()

        #expect(pasteboard.string(forType: .string) == "copiado durante a leitura")
        #expect(pasteboard.data(forType: .png) == nil)
        #expect(redactions.isEmpty)
    }

    @Test func doesNothingWhilePaused() async throws {
        watcher.isEnabled = false
        let copied = try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        #expect(pasteboard.data(forType: .png) == copied.png)
        #expect(redactions.isEmpty)
    }

    @Test func reusesTheBlurredVersionWhenTheSameCaptureIsCopiedAgain() async throws {
        try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        let blurred = try #require(pasteboard.data(forType: .png))

        // Shottr copies on capture and again on Esc: the second time must not wait for a read.
        try copy(Self.secrets)
        watcher.poll()
        #expect(pasteboard.data(forType: .png) == blurred)
        #expect(types.contains(Self.marker))
        #expect(redactions.count == 2)
    }

    @Test func doesNotHoldACaptureAlreadyKnownToBeClean() async throws {
        try copy(Self.harmless)
        watcher.poll()
        await watcher.idle()

        let copied = try copy(Self.harmless)
        let changeCount = pasteboard.changeCount
        watcher.poll()
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.data(forType: .png) == copied.png)
    }

    @Test func doesNotReadItsOwnBlurredOutputAgain() async throws {
        try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        let blurredPNG = try #require(pasteboard.data(forType: .png))

        // A clipboard manager puts the blurred image back, without our marker.
        pasteboard.clearContents()
        pasteboard.setData(blurredPNG, forType: .png)
        let changeCount = pasteboard.changeCount
        watcher.poll()
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.data(forType: .png) == blurredPNG)
    }

    /// Copies the picture the way a screenshot app does after showing it: in an encoding of its own.
    private func copyAgain(_ image: CGImage) throws -> (tiff: Data, png: Data) {
        try copy(DecodedImage(image: try #require(redrawn(image)), typeIdentifier: "public.png", dpi: 144, orientation: nil))
    }

    @Test func putsBackItsBlurredCopyWhenItReturnsInAnotherEncoding() async throws {
        try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        let blurred = try #require(pasteboard.data(forType: .png).flatMap(decodeImage))

        // Shottr, once its editor shows the blurred copy, copies it again when the editor is closed.
        let again = try copyAgain(blurred.image)
        watcher.poll()
        await watcher.idle()
        #expect(types == [.tiff, .png])
        #expect(pasteboard.data(forType: .png) == again.png)
        #expect(redactions.count == 1)
    }

    @Test func leavesARestoredCaptureAloneWhenItReturnsInAnotherEncoding() async throws {
        try copy(Self.secrets)
        watcher.poll()
        await watcher.idle()
        #expect(watcher.restoreOriginal())

        // Shown the original again, the screenshot app copies it in its own encoding.
        let again = try copyAgain(Self.secrets.image)
        watcher.poll()
        await watcher.idle()
        #expect(pasteboard.data(forType: .png) == again.png)
        #expect(redactions.count == 1, "the capture the user asked to keep was blurred again")
    }

    @Test func reportsWhenThePasteboardIsBeingHeld() async throws {
        try copy(Self.secrets)
        watcher.poll()
        #expect(reading == [true])
        await watcher.idle()
        #expect(reading == [true, false])

        try copy(Self.harmless)
        watcher.poll()
        await watcher.idle()
        #expect(reading == [true, false, true, false])

        // Known captures and things that are not captures never hold the pasteboard.
        try copy(Self.secrets)
        watcher.poll()
        pasteboard.clearContents()
        pasteboard.setString("texto", forType: .string)
        watcher.poll()
        await watcher.idle()
        #expect(reading == [true, false, true, false])
    }

    @Test func reportsTheEndOfAReadThatWasOvertaken() async throws {
        try copy(Self.secrets)
        watcher.poll()
        pasteboard.clearContents()
        pasteboard.setString("copiado durante a leitura", forType: .string)
        await watcher.idle()
        #expect(reading == [true, false])
        #expect(pasteboard.string(forType: .string) == "copiado durante a leitura")
    }

    @Test func givesTheCaptureBackWhenStoppedMidRead() async throws {
        let copied = try copy(Self.secrets)
        watcher.poll()
        watcher.stop()
        #expect(pasteboard.data(forType: .png) == copied.png)
        await watcher.idle()
        #expect(pasteboard.data(forType: .png) == copied.png)
        #expect(redactions.isEmpty)
        #expect(reading == [true, false])
    }

    @Test func noticesCopiesOnItsOwnOnceStarted() async throws {
        watcher.start()
        defer { watcher.stop() }
        try copy(Self.secrets)
        for _ in 0..<100 where redactions.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(redactions.count == 1)
        #expect(types.contains(Self.marker))
    }
}

@MainActor @Suite struct DigestStoring {
    @Test func remembersAcrossInstances() throws {
        let suite = "fosco-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = digest(of: Data("a".utf8))

        DigestStore(defaults: defaults).insert(key)
        #expect(DigestStore(defaults: defaults).contains(key))
        #expect(!DigestStore(defaults: defaults).contains(digest(of: Data("b".utf8))))
        #expect(!DigestStore(defaults: nil).contains(key))
    }

    @Test func forgetsTheOldestBeyondItsCapacity() {
        let store = DigestStore(defaults: nil)
        let keys = (0...300).map { digest(of: Data("\($0)".utf8)) }
        keys.forEach(store.insert)
        #expect(!store.contains(keys[0]))
        #expect(store.contains(keys[1]) && store.contains(keys[300]))
    }
}

@Suite struct Summaries {
    private func regions(emails: Int, phones: Int) -> [SensitiveRegion] {
        Array(repeating: SensitiveRegion(kind: .email, rect: .zero), count: emails)
            + Array(repeating: SensitiveRegion(kind: .phone, rect: .zero), count: phones)
    }

    @Test(arguments: [
        (1, 0, "1 e-mail borrado"), (2, 0, "2 e-mails borrados"), (0, 1, "1 telefone borrado"), (0, 3, "3 telefones borrados"),
        (1, 1, "1 e-mail e 1 telefone borrados"), (2, 3, "2 e-mails e 3 telefones borrados"), (0, 0, "Nada borrado"),
    ])
    func agreesInNumber(emails: Int, phones: Int, expected: String) {
        #expect(describeRedaction(regions(emails: emails, phones: phones)) == expected)
    }
}
