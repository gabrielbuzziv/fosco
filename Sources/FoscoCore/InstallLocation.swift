/// Whether macOS is running the app from a place it cannot stay in: the temporary read-only copy
/// it makes of an app opened straight from a download, or a disk image.
///
/// A login item registered from there points at nothing after the next restart.
public func isTemporaryLocation(path: String, volumeIsReadOnly: Bool) -> Bool {
    volumeIsReadOnly || path.contains("/AppTranslocation/")
}
