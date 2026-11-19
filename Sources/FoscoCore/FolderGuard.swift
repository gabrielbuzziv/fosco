import CoreServices
import Foundation

/// Watches the folders screenshots are saved to and blurs a new capture in place when it shows an
/// e-mail address or a phone number.
@MainActor
public final class FolderGuard {
    public struct Folder: Equatable, Sendable {
        public enum Scope: Sendable {
            /// A folder used only for screenshots: every new image in it is a capture.
            case everyImage
            /// A shared folder such as the Desktop: only files macOS itself tagged as screen captures.
            case flaggedScreenshots
        }

        public let url: URL
        public let scope: Scope

        public init(url: URL, scope: Scope) {
            self.url = url.standardizedFileURL
            self.scope = scope
        }
    }

    public var isEnabled = true
    /// Called after a saved capture was replaced by its blurred version.
    public var onRedaction: (@MainActor ([SensitiveRegion]) -> Void)?

    private let folders: [Folder]
    private let pipeline: RedactionPipeline
    private var stream: FSEventStreamRef?
    private var inFlight: Set<String> = []
    /// Files as last seen clean or left blurred, so the event our own write causes is not read again.
    private var settled: [String: FileStamp] = [:]
    /// The last blurred file's bytes from before, and what the file looked like once blurred.
    private var original: (url: URL, data: Data, stamp: FileStamp)?

    public init(folders: [Folder], pipeline: RedactionPipeline) {
        self.folders = folders
        self.pipeline = pipeline
    }

    public func start() {
        guard stream == nil, !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil, folderEventsCallback, &context, folders.map(\.url.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, FSEventStreamCreateFlags(flags)
        ) else {
            logger.error("Could not watch the screenshot folders")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        // Attribute changes count too: the screenshot tag may be set a moment after the file is written.
        let relevant = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemXattrMod
        )
        for (path, flag) in zip(paths, flags) where flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 && flag & relevant != 0 {
            Task { await process(URL(fileURLWithPath: path)) }
        }
    }

    /// Reads one file and blurs it in place if needed. Called for every new or changed file in a
    /// watched folder; does nothing for files that are not fresh captures.
    public func process(_ url: URL) async {
        let url = url.standardizedFileURL
        let path = url.path
        guard isEnabled, Self.imageExtensions.contains(url.pathExtension.lowercased()), !inFlight.contains(path),
              let folder = folders.first(where: { path.hasPrefix($0.url.path + "/") }) else { return }
        inFlight.insert(path)
        defer { inFlight.remove(path) }

        guard let stamp = await stampOnceWritten(url), settled[path] != stamp, isRecentlyCreated(url),
              folder.scope == .everyImage || isFlaggedScreenshot(path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Could not read a new capture: \(url.lastPathComponent, privacy: .public)")
            return
        }
        guard case .redacted(let capture) = await pipeline.outcome(for: data) else {
            settled[path] = stamp
            return
        }
        let blurred = await Task.detached { capture.encoded(as: capture.original.typeIdentifier) }.value
        // Changed again while it was being read: the event for that change starts over.
        guard let blurred, FileStamp(url) == stamp else { return }
        do {
            try replaceContents(of: url, with: blurred)
        } catch {
            logger.error("Could not save the blurred capture: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let blurredStamp = FileStamp(url) else { return }
        settled[path] = blurredStamp
        original = (url, data, blurredStamp)
        onRedaction?(capture.redacted.regions)
    }

    /// Whether the last blurred file is still as we left it and can be reverted.
    public var canRestoreOriginal: Bool {
        original.map { FileStamp($0.url) == $0.stamp } ?? false
    }

    /// Puts the unblurred capture back, for when the blur hid something that was meant to show.
    @discardableResult
    public func restoreOriginal() -> Bool {
        guard let original, canRestoreOriginal else { return false }
        self.original = nil
        do {
            try replaceContents(of: original.url, with: original.data)
        } catch {
            logger.error("Could not restore the original capture: \(error.localizedDescription, privacy: .public)")
            return false
        }
        settled[original.url.path] = FileStamp(original.url)
        return true
    }

    // MARK: - Files

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff"]

    /// The file's size and date once it has stopped growing; nil if it never settles or is gone.
    private func stampOnceWritten(_ url: URL) async -> FileStamp? {
        var previous = FileStamp(url)
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            let current = FileStamp(url)
            if let current, current == previous, current.size > 0 { return current }
            previous = current
        }
        return nil
    }

    /// Only captures taken just now are touched. An old file that merely changes (an edit, a sync)
    /// is somebody's deliberate work.
    private func isRecentlyCreated(_ url: URL) -> Bool {
        guard let created = try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date else { return false }
        return Date().timeIntervalSince(created) < 600
    }

    private func isFlaggedScreenshot(_ path: String) -> Bool {
        getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    /// Swaps the file's contents in one step, keeping its creation date and extended attributes
    /// (the screenshot tag, Finder tags), so the capture stays the same file to everything else.
    private func replaceContents(of url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporary)
        do {
            guard copyfile(url.path, temporary.path, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else { throw posixError() }
            if let created = try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] {
                try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: temporary.path)
            }
            guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

/// Enough to tell whether a file changed.
private struct FileStamp: Equatable {
    let size: Int
    let modified: Date

    /// Read from the file system each time: URL resource values are cached per URL and go stale.
    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modified = modified
    }
}

/// FSEvents delivers on the main queue (see `start`), which is where the guard lives.
private let folderEventsCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    let flags = Array(UnsafeBufferPointer(start: flags, count: count))
    let watcher = Unmanaged<FolderGuard>.fromOpaque(info).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.handleEvents(paths: paths, flags: flags) }
}
