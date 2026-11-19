import AppKit
import FoscoCore
import os

/// Shottr keeps showing a capture as it took it, so once the copy on the clipboard is blurred the
/// original is still there to drag out, pin or copy again. Asked to load the clipboard, Shottr
/// replaces what its editor shows; this asks it to after a capture of its own was blurred.
@MainActor
final class ShottrBridge {
    private var lastDeactivated: Date?
    private var observer: NSObjectProtocol?
    /// What Shottr had on screen when the last copied capture was noticed.
    private var before: (takenAt: Date, windows: Set<Int>)?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier == bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.lastDeactivated = Date() }
        }
    }

    /// Call when a copied capture starts being read: whatever Shottr shows by then is not that capture.
    func captureWasCopied() {
        before = (Date(), Set(windows().map(\.number)))
    }

    /// Finds how Shottr shows the capture that was copied at `copiedAt` and, when that is in its
    /// editor, has it show the blurred copy now on the clipboard instead. A thumbnail is reported
    /// and left as it is: Shottr cannot be asked to change it.
    func showBlurredCopy(copiedAt: Date) async -> ShottrView? {
        let changeCount = NSPasteboard.general.changeCount
        // A capture that needed no reading is handled right as it is copied, before any thumbnail.
        let onScreenBefore = before.flatMap { $0.takenAt >= copiedAt.addingTimeInterval(-0.5) ? $0.windows : nil }
            ?? Set(windows().map(\.number))
        // The thumbnail comes up a few tenths of a second after the copy: keep looking for a moment.
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            guard let shottr = running, NSPasteboard.general.changeCount == changeCount else { return nil }
            let windows = windows()
            let view = shottrView(
                of: windows, onScreenBefore: onScreenBefore, isFrontmost: shottr.isActive, lastDeactivated: lastDeactivated, copiedAt: copiedAt
            )
            guard view != nil || attempt == 4 else { continue }
            // Why a capture was or was not handed over is the first question when Shottr still shows the original.
            let seen = windows.map { "\($0.layer):\(Int($0.size.width))x\(Int($0.size.height))\(onScreenBefore.contains($0.number) ? "" : " new")" }
            let leftTheFront = lastDeactivated.map { String(format: "%.1f s after the copy", $0.timeIntervalSince(copiedAt)) } ?? "never"
            log.notice("Shottr windows: \(seen, privacy: .public), in front: \(shottr.isActive, privacy: .public), left the front: \(leftTheFront, privacy: .public)")
            if view == .editor { loadClipboard() }
            return view
        }
        return nil
    }

    /// Shows what is on the clipboard in the editor, if it is still open.
    func showClipboard() {
        guard windows().contains(where: { $0.layer == 0 }) else { return }
        loadClipboard()
    }

    private var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    private func windows() -> [ShottrWindow] {
        guard let shottr = running else { return [] }
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        return onScreen.compactMap { window in
            guard (window[kCGWindowOwnerPID] as? pid_t) == shottr.processIdentifier,
                  let number = window[kCGWindowNumber] as? Int, let layer = window[kCGWindowLayer] as? Int,
                  let bounds = (window[kCGWindowBounds] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return ShottrWindow(number: number, layer: layer, size: bounds.size)
        }
    }

    private func loadClipboard() {
        guard let url = URL(string: "shottr://load/clipboard") else { return }
        // Shottr is in front already, or the user has moved on: either way, do not pull it forward.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
        log.notice("Asked Shottr to show the copy on the clipboard")
    }
}

private let bundleIdentifier = "cc.ffitch.shottr"
private let log = Logger(subsystem: "com.gabrielbuzzi.fosco", category: "app")
