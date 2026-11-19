import AppKit
import FoscoCore

/// The menu bar icon and its menu. What they show is decided by `menuEntries(for:)`.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let currentState: () -> MenuState
    private let perform: (MenuAction) -> Void
    private var actions: [MenuAction] = []
    private var flashEnds: Task<Void, Never>?
    private var readingShows: Task<Void, Never>?
    private var showsReading = false

    var icon: StatusIcon = .active {
        didSet { if icon != oldValue { showIcon() } }
    }

    /// True while a copied capture is off the clipboard being read. Most reads are over before
    /// anyone could paste, so the icon only changes for the ones that take long enough to notice.
    var isReading = false {
        didSet {
            guard isReading != oldValue else { return }
            readingShows?.cancel()
            guard isReading else {
                showsReading = false
                showIcon()
                return
            }
            readingShows = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                showsReading = true
                showIcon()
            }
        }
    }

    init(state: @escaping () -> MenuState, perform: @escaping (MenuAction) -> Void) {
        self.currentState = state
        self.perform = perform
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        // Items say themselves whether they can be chosen.
        menu.autoenablesItems = false
        statusItem.menu = menu
        showIcon()
    }

    /// Fills the icon for a moment: the only sign, besides the blur itself, that a capture was changed.
    func flash() {
        flashEnds?.cancel()
        setSymbol("eye.slash.fill", description: "Captura borrada")
        flashEnds = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            flashEnds = nil
            showIcon()
        }
    }

    private func showIcon() {
        guard flashEnds == nil else { return }
        guard !showsReading else {
            setSymbol("ellipsis", description: "Lendo a captura copiada")
            return
        }
        switch icon {
        case .active: setSymbol("eye.slash", description: "Fosco ativo")
        case .paused: setSymbol("eye", description: "Fosco em pausa")
        case .needsClipboardAccess: setSymbol("eye.trianglebadge.exclamationmark", description: "Fosco sem acesso à área de transferência")
        }
    }

    private func setSymbol(_ name: String, description: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions = []
        for entry in menuEntries(for: currentState()) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .status(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .command(let title, let action, let isEnabled, let isChecked, let key):
                let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: key)
                item.target = self
                item.tag = actions.count
                item.isEnabled = isEnabled
                item.state = isChecked ? .on : .off
                actions.append(action)
                menu.addItem(item)
            }
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        perform(actions[item.tag])
    }
}
