/// What the menu bar item shows, as plain data so it can be checked without a menu bar.
public struct MenuState: Equatable, Sendable {
    public var isEnabled: Bool
    public var needsClipboardAccess: Bool
    /// What the last capture had blurred, e.g. "2 e-mails e 1 telefone borrados".
    public var lastRedaction: String?
    public var canRestoreOriginal: Bool
    public var opensAtLogin: Bool

    public init(isEnabled: Bool, needsClipboardAccess: Bool, lastRedaction: String?, canRestoreOriginal: Bool, opensAtLogin: Bool) {
        self.isEnabled = isEnabled
        self.needsClipboardAccess = needsClipboardAccess
        self.lastRedaction = lastRedaction
        self.canRestoreOriginal = canRestoreOriginal
        self.opensAtLogin = opensAtLogin
    }
}

public enum MenuAction: Equatable, Sendable {
    case toggleEnabled, restoreOriginal, grantClipboardAccess, toggleOpensAtLogin, quit
}

public enum MenuEntry: Equatable, Sendable {
    /// A line of information; cannot be chosen.
    case status(String)
    case separator
    case command(title: String, action: MenuAction, isEnabled: Bool = true, isChecked: Bool = false, key: String = "")
}

public enum StatusIcon: Equatable, Sendable {
    case active, paused, needsClipboardAccess
}

public func statusIcon(for state: MenuState) -> StatusIcon {
    if !state.isEnabled { return .paused }
    return state.needsClipboardAccess ? .needsClipboardAccess : .active
}

public func menuEntries(for state: MenuState) -> [MenuEntry] {
    let status: String = switch statusIcon(for: state) {
    case .paused: "Em pausa"
    case .needsClipboardAccess: "Sem acesso à área de transferência"
    case .active: state.lastRedaction ?? "Nenhuma captura borrada ainda"
    }
    let access: [MenuEntry] = state.needsClipboardAccess
        ? [.command(title: "Permitir Acesso à Área de Transferência…", action: .grantClipboardAccess), .separator]
        : []
    return [.status(status), .separator] + access + [
        .command(title: "Borrar E-mails e Telefones", action: .toggleEnabled, isChecked: state.isEnabled),
        .command(title: "Restaurar Original", action: .restoreOriginal, isEnabled: state.canRestoreOriginal),
        .separator,
        .command(title: "Abrir ao Iniciar Sessão", action: .toggleOpensAtLogin, isChecked: state.opensAtLogin),
        .command(title: "Encerrar Fosco", action: .quit, key: "q"),
    ]
}
