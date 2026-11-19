import AppKit

/// One pasteboard item: its representations in the order the source app declared them.
public typealias PasteboardItemContent = [(type: NSPasteboard.PasteboardType, data: Data)]

/// Watches a pasteboard and replaces a copied screen capture with a blurred copy when it shows an
/// e-mail address or a phone number.
///
/// While a capture is being read it is taken off the pasteboard, so it cannot be pasted (or picked
/// up by a clipboard manager) before the verdict; a capture with nothing to hide is put back
/// byte for byte.
@MainActor
public final class ClipboardGuard {
    public var isEnabled = true
    /// Called after a copied capture was replaced by its blurred version.
    public var onRedaction: (@MainActor ([SensitiveRegion]) -> Void)?
    /// Called with true when a capture is taken off the pasteboard to be read, and with false once
    /// the pasteboard is usable again. A large capture can take seconds; this is the cue to say so.
    public var onReadingChange: (@MainActor (Bool) -> Void)?

    private let pasteboard: NSPasteboard
    private let pipeline: RedactionPipeline
    private let knownClean: DigestStore
    private var lastChangeCount: Int
    /// Polls left in which to look again at a change whose content had not arrived yet.
    private var looksLeft = 0
    private var timer: Timer?
    private var work: Task<Void, Never>?
    /// The capture currently off the pasteboard, and the change count our hold left behind.
    private var held: (items: [PasteboardItemContent], changeCount: Int)?
    /// Blurred versions of the last few captures, for when the same capture is copied again.
    private var recent: [(digest: Data, item: PasteboardItemContent, regions: [SensitiveRegion])] = []
    /// What the last blurred capture looked like before, and the change count of our replacement.
    private var original: (items: [PasteboardItemContent], changeCount: Int)?
    /// Originals the user asked to keep. A screenshot app showing one copies it again in its own
    /// encoding, which no digest would match.
    private var restored: [Data] = []

    public init(pasteboard: NSPasteboard = .general, pipeline: RedactionPipeline, knownClean: DigestStore) {
        self.pasteboard = pasteboard
        self.pipeline = pipeline
        self.knownClean = knownClean
        self.lastChangeCount = pasteboard.changeCount
    }

    /// macOS asks the user before an app may read the general pasteboard on its own; until they
    /// choose to always allow it, reading would raise that alert on every capture.
    public var needsPermission: Bool {
        // Only the general pasteboard is restricted; elsewhere "default" already means allowed.
        pasteboard.name == .general ? pasteboard.accessBehavior != .alwaysAllow : pasteboard.accessBehavior == .alwaysDeny
    }

    /// Reads the pasteboard once on purpose. The first time, this raises the system alert that
    /// lists the app under Privacy & Security › Paste from Other Apps.
    public func requestAccess() {
        guard let item = pasteboard.pasteboardItems?.first, let type = item.types.first else { return }
        _ = item.data(forType: type)
    }

    public func start() {
        guard timer == nil else { return }
        // There is no notification for pasteboard changes; polling the change count is the API.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        releaseHold()
    }

    /// Looks at the pasteboard now. `start()` calls this on a timer.
    public func poll() {
        let changeCount = pasteboard.changeCount
        if changeCount != lastChangeCount {
            lastChangeCount = changeCount
            // An app clears the pasteboard and then writes to it, possibly after encoding a large
            // image; only the clearing moves the change count. A poll landing in between sees
            // nothing yet, so keep looking for a few seconds.
            looksLeft = 60
        }
        guard looksLeft > 0 else { return }
        looksLeft -= 1
        guard isEnabled, !needsPermission else {
            looksLeft = 0
            return
        }
        switch readCapture() {
        case .notWrittenYet: break
        case .notACapture: looksLeft = 0
        case .capture(let items, let imageData):
            looksLeft = 0
            handle(items, imageData: imageData)
        }
    }

    private func handle(_ items: [PasteboardItemContent], imageData: Data) {
        let key = digest(of: imageData)
        guard !knownClean.contains(key) else { return }
        if let known = recent.first(where: { $0.digest == key }) {
            replace(with: known.item, original: items, regions: known.regions)
            return
        }

        pasteboard.clearContents()
        let heldCount = pasteboard.changeCount
        lastChangeCount = heldCount
        held = (items, heldCount)
        onReadingChange?(true)
        let settled = recent.compactMap { preferredImageData(in: $0.item) } + restored
        work = Task { [pipeline] in
            let outcome = await pipeline.outcome(for: imageData, settled: settled)
            var blurred: PasteboardItemContent?
            // Verdicts are kept even when this read ends up dropped below.
            switch outcome {
            case .redacted(let capture):
                blurred = await Task.detached { Self.pasteboardContent(for: capture, like: items[0]) }.value
                if let blurred { remember(blurred, for: key, regions: capture.redacted.regions) }
            case .clean: knownClean.insert(key)
            case .unreadable: break
            }
            // Another capture took over the hold meanwhile: its own read reports the end.
            guard held?.changeCount == heldCount else { return }
            held = nil
            onReadingChange?(false)
            // Something else was copied while this was being read: it stays, this is dropped.
            guard pasteboard.changeCount == heldCount else { return }
            switch (outcome, blurred) {
            case (.redacted(let capture), let blurred?):
                replace(with: blurred, original: items, regions: capture.redacted.regions)
            case (.redacted, nil):
                // Known to show something and no blurred copy to offer: an empty clipboard is the safe answer.
                logger.error("Could not encode the blurred capture; it was not put back on the clipboard")
            case (.clean, _), (.unreadable, _):
                write(items)
            }
        }
    }

    /// Waits for the capture being read, if any.
    public func idle() async {
        await work?.value
    }

    /// Whether the last blurred capture is still on the pasteboard and can be reverted.
    public var canRestoreOriginal: Bool {
        original?.changeCount == pasteboard.changeCount
    }

    /// Puts the unblurred capture back, for when the blur hid something that was meant to show.
    @discardableResult
    public func restoreOriginal() -> Bool {
        guard let original, canRestoreOriginal else { return false }
        self.original = nil
        // The user wants this capture as it is: leave it alone from now on, also when the
        // screenshot app copies it again.
        if let imageData = original.items.first.flatMap(preferredImageData) {
            let key = digest(of: imageData)
            recent.removeAll { $0.digest == key }
            knownClean.insert(key)
            restored.append(imageData)
            if restored.count > 3 { restored.removeFirst() }
        }
        write(original.items, marked: true)
        return true
    }

    // MARK: - Reading

    private enum Reading {
        /// Cleared, or types declared whose data is not there yet.
        case notWrittenYet
        case notACapture
        case capture(items: [PasteboardItemContent], imageData: Data)
    }

    /// A capture is exactly one item holding nothing but image representations. A copy that also
    /// carries text, HTML, files or an app's own format is that app's content (a slide, a layer, a
    /// web page), and rewriting it would break pasting it back.
    private func readCapture() -> Reading {
        guard let items = pasteboard.pasteboardItems, let item = items.first, !item.types.isEmpty else { return .notWrittenYet }
        guard items.count == 1, item.types.allSatisfy(Self.imageTypes.contains) else { return .notACapture }
        let content = item.types.compactMap { type in item.data(forType: type).map { (type: type, data: $0) } }
        guard content.count == item.types.count, let imageData = preferredImageData(in: content) else { return .notWrittenYet }
        return .capture(items: [content], imageData: imageData)
    }

    private func preferredImageData(in item: PasteboardItemContent) -> Data? {
        Self.imageTypes.lazy.compactMap { type in item.first { $0.type == type }?.data }.first
    }

    /// Lossless first: it is what gets read and re-encoded.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.heic"), NSPasteboard.PasteboardType("public.jpeg"),
    ]
    private static let marker = NSPasteboard.PasteboardType("com.gabrielbuzzi.fosco.processed")

    // MARK: - Writing

    /// The blurred capture in the same representations, in the same order, as the copied one;
    /// as PNG alone if none of those can be written.
    private nonisolated static func pasteboardContent(for capture: RedactedCapture, like item: PasteboardItemContent) -> PasteboardItemContent? {
        let content = item.compactMap { entry in
            capture.encoded(as: entry.type.rawValue).map { (type: entry.type, data: $0) }
        }
        guard content.isEmpty else { return content }
        return capture.encoded(as: NSPasteboard.PasteboardType.png.rawValue).map { [(type: .png, data: $0)] }
    }

    private func replace(with blurred: PasteboardItemContent, original items: [PasteboardItemContent], regions: [SensitiveRegion]) {
        write([blurred], marked: true)
        original = (items, pasteboard.changeCount)
        for entry in blurred { knownClean.insert(digest(of: entry.data)) }
        onRedaction?(regions)
    }

    private func remember(_ blurred: PasteboardItemContent, for key: Data, regions: [SensitiveRegion]) {
        recent.append((key, blurred, regions))
        if recent.count > 3 { recent.removeFirst() }
    }

    private func write(_ items: [PasteboardItemContent], marked: Bool = false) {
        let pasteboardItems = items.map { content in
            let item = NSPasteboardItem()
            for entry in content { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if marked { pasteboardItems.first?.setData(Data([1]), forType: Self.marker) }
        pasteboard.clearContents()
        pasteboard.writeObjects(pasteboardItems)
        lastChangeCount = pasteboard.changeCount
    }

    /// Gives back a capture still being read, e.g. when the app quits mid-read.
    private func releaseHold() {
        guard let held else { return }
        self.held = nil
        onReadingChange?(false)
        if pasteboard.changeCount == held.changeCount { write(held.items) }
    }
}
