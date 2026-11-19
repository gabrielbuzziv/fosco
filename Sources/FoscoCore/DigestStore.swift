import Foundation

/// Remembers, across launches, captures already known to have nothing to hide, so that copying the
/// same image again (or a clipboard manager putting it back) is not held up by another read.
@MainActor
public final class DigestStore {
    private static let key = "knownCleanDigests.v1"
    private static let capacity = 300

    private let defaults: UserDefaults?
    private var digests: [Data]

    /// Pass nil to keep the list in memory only.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        self.digests = defaults?.array(forKey: Self.key) as? [Data] ?? []
    }

    public func contains(_ digest: Data) -> Bool {
        digests.contains(digest)
    }

    public func insert(_ digest: Data) {
        guard !digests.contains(digest) else { return }
        digests.append(digest)
        if digests.count > Self.capacity { digests.removeFirst(digests.count - Self.capacity) }
        defaults?.set(digests, forKey: Self.key)
    }
}
