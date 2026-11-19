import AppKit
import os
import FoscoCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let pipeline = RedactionPipeline()
    private lazy var clipboardGuard = ClipboardGuard(pipeline: pipeline, knownClean: DigestStore())
    private lazy var folderGuard = FolderGuard(folders: screenshotFolders(), pipeline: pipeline)
    private var statusMenu: StatusMenu?
    /// Notifications belong to app bundles; the bare executable has none to post from.
    private lazy var notice = Bundle.main.bundleIdentifier == nil ? nil : RedactionNotice()
    private var accessWatch: Timer?
    private var didLogState = false
    /// App Nap would slow the pasteboard polling of an app with no windows down to seconds.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching for screen captures"
    )
    /// Where the last blurred capture lives, to know which original "Restaurar Original" brings back.
    private var lastRedaction: (summary: String, source: Source)?

    private enum Source { case clipboard, folder }

    private enum Key {
        static let isPaused = "isPaused"
        static let didSetUpLoginItem = "didSetUpLoginItem"
        static let didExplainClipboardAccess = "didExplainClipboardAccess"
    }

    private var isEnabled: Bool {
        get { !defaults.bool(forKey: Key.isPaused) }
        set {
            defaults.set(!newValue, forKey: Key.isPaused)
            clipboardGuard.isEnabled = newValue
            folderGuard.isEnabled = newValue
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAlreadyRunning, !isInTemporaryLocation || confirmsStayingInTemporaryLocation() else {
            NSApp.terminate(nil)
            return
        }
        clipboardGuard.isEnabled = isEnabled
        folderGuard.isEnabled = isEnabled
        clipboardGuard.onRedaction = { [weak self] in self?.didRedact($0, in: .clipboard) }
        clipboardGuard.onReadingChange = { [weak self] in self?.statusMenu?.isReading = $0 }
        folderGuard.onRedaction = { [weak self] in self?.didRedact($0, in: .folder) }
        clipboardGuard.start()
        folderGuard.start()
        pipeline.warmUp()
        log.notice("Watching the clipboard and \(screenshotFolders().map(\.url.path).joined(separator: ", "), privacy: .public); opens at login: \(LoginItem.isEnabled, privacy: .public)")

        statusMenu = StatusMenu(state: { [unowned self] in menuState }, perform: { [unowned self] in perform($0) })
        // The user grants or revokes pasteboard access in System Settings, at any time.
        let watch = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
        RunLoop.main.add(watch, forMode: .common)
        accessWatch = watch
        refreshIcon()

        setUpLoginItemOnce()
        explainClipboardAccessOnce()
        // Asks for permission now rather than in the middle of the first capture.
        _ = notice
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Gives back a capture that is off the pasteboard while being read.
        clipboardGuard.stop()
        folderGuard.stop()
    }

    private var isAlreadyRunning: Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1
    }

    /// True when the app was opened straight from the download or the disk image it came in.
    private var isInTemporaryLocation: Bool {
        let bundle = Bundle.main.bundleURL
        let volumeIsReadOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return isTemporaryLocation(path: bundle.path, volumeIsReadOnly: volumeIsReadOnly)
    }

    private func confirmsStayingInTemporaryLocation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Mova o Fosco para a pasta Aplicativos"
        alert.informativeText = "Fora dela, ele não abre sozinho quando você inicia a sessão."
        alert.addButton(withTitle: "Encerrar")
        alert.addButton(withTitle: "Continuar Mesmo Assim")
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Runs every couple of seconds, so it asks only for what the icon depends on.
    private func refreshIcon() {
        let icon = statusIcon(for: MenuState(
            isEnabled: isEnabled, needsClipboardAccess: clipboardGuard.needsPermission,
            lastRedaction: nil, canRestoreOriginal: false, opensAtLogin: false
        ))
        if icon != statusMenu?.icon || !didLogState {
            didLogState = true
            log.notice("State: \(String(describing: icon), privacy: .public)")
        }
        statusMenu?.icon = icon
    }

    private var menuState: MenuState {
        MenuState(
            isEnabled: isEnabled,
            needsClipboardAccess: clipboardGuard.needsPermission,
            lastRedaction: lastRedaction?.summary,
            canRestoreOriginal: canRestoreOriginal,
            opensAtLogin: LoginItem.isEnabled
        )
    }

    private func perform(_ action: MenuAction) {
        switch action {
        case .toggleEnabled:
            isEnabled.toggle()
            refreshIcon()
        case .restoreOriginal: restoreOriginal()
        case .grantClipboardAccess: grantClipboardAccess()
        case .toggleOpensAtLogin: setOpensAtLogin(!LoginItem.isEnabled)
        case .quit: NSApp.terminate(nil)
        }
    }

    // MARK: - Redactions

    private func didRedact(_ regions: [SensitiveRegion], in source: Source) {
        let summary = describeRedaction(regions)
        lastRedaction = (summary, source)
        statusMenu?.flash()
        notice?.post(title: summary, body: source == .clipboard ? "Na área de transferência" : "No arquivo salvo")
        // Counts only: what a capture shows never goes to the log.
        log.notice("Blurred \(regions.count, privacy: .public) regions in a capture from the \(source == .clipboard ? "clipboard" : "screenshot folder", privacy: .public)")
    }

    private var canRestoreOriginal: Bool {
        switch lastRedaction?.source {
        case .clipboard: clipboardGuard.canRestoreOriginal
        case .folder: folderGuard.canRestoreOriginal
        case nil: false
        }
    }

    private func restoreOriginal() {
        guard let source = lastRedaction?.source else { return }
        let didRestore = switch source {
        case .clipboard: clipboardGuard.restoreOriginal()
        case .folder: folderGuard.restoreOriginal()
        }
        if didRestore { lastRedaction = nil }
    }

    // MARK: - Setup

    /// Guarding every capture means being there from login on; the menu item turns it off.
    private func setUpLoginItemOnce() {
        guard Bundle.main.bundleURL.pathExtension == "app", !isInTemporaryLocation, !defaults.bool(forKey: Key.didSetUpLoginItem) else { return }
        defaults.set(true, forKey: Key.didSetUpLoginItem)
        setOpensAtLogin(true)
    }

    private func setOpensAtLogin(_ opensAtLogin: Bool) {
        do {
            try LoginItem.setEnabled(opensAtLogin)
        } catch {
            log.error("Could not change the login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func explainClipboardAccessOnce() {
        guard clipboardGuard.needsPermission, !defaults.bool(forKey: Key.didExplainClipboardAccess) else { return }
        defaults.set(true, forKey: Key.didExplainClipboardAccess)
        let alert = NSAlert()
        alert.messageText = "Permita que o Fosco leia a área de transferência"
        alert.informativeText = "É assim que ele borra as capturas que você copia. Em Ajustes do Sistema › Privacidade e Segurança › Colar de Outros Apps, libere o acesso para o Fosco."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Agora Não")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { grantClipboardAccess() }
    }

    private func grantClipboardAccess() {
        // The app only appears in that list after macOS has asked about it once.
        clipboardGuard.requestAccess()
        if let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard") {
            NSWorkspace.shared.open(pane)
        }
    }
}

private let log = Logger(subsystem: "com.gabrielbuzzi.fosco", category: "app")
