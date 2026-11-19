import Testing
@testable import FoscoCore

@Suite struct MenuModel {
    private func state(isEnabled: Bool = true, needsAccess: Bool = false, last: String? = nil, canRestore: Bool = false, login: Bool = true) -> MenuState {
        MenuState(isEnabled: isEnabled, needsClipboardAccess: needsAccess, lastRedaction: last, canRestoreOriginal: canRestore, opensAtLogin: login)
    }

    private func command(_ title: String, in entries: [MenuEntry]) -> (isEnabled: Bool, isChecked: Bool)? {
        for case .command(title, _, let isEnabled, let isChecked, _) in entries { return (isEnabled, isChecked) }
        return nil
    }

    @Test func showsTheWholeMenuWhenAllIsWell() {
        #expect(menuEntries(for: state()) == [
            .status("Nenhuma captura borrada ainda"),
            .separator,
            .command(title: "Borrar E-mails e Telefones", action: .toggleEnabled, isChecked: true),
            .command(title: "Restaurar Original", action: .restoreOriginal, isEnabled: false),
            .separator,
            .command(title: "Abrir ao Iniciar Sessão", action: .toggleOpensAtLogin, isChecked: true),
            .command(title: "Encerrar Fosco", action: .quit, key: "q"),
        ])
        #expect(statusIcon(for: state()) == .active)
    }

    @Test func reportsTheLastRedactionAndOffersToUndoIt() {
        let entries = menuEntries(for: state(last: "2 e-mails e 1 telefone borrados", canRestore: true))
        #expect(entries.first == .status("2 e-mails e 1 telefone borrados"))
        #expect(command("Restaurar Original", in: entries)?.isEnabled == true)
    }

    @Test func keepsTheSummaryButNotTheUndoOnceTheCaptureIsGone() {
        let entries = menuEntries(for: state(last: "1 e-mail borrado", canRestore: false))
        #expect(entries.first == .status("1 e-mail borrado"))
        #expect(command("Restaurar Original", in: entries)?.isEnabled == false)
    }

    @Test func saysSoWhenPaused() {
        let paused = state(isEnabled: false, last: "1 e-mail borrado")
        #expect(menuEntries(for: paused).first == .status("Em pausa"))
        #expect(command("Borrar E-mails e Telefones", in: menuEntries(for: paused))?.isChecked == false)
        #expect(statusIcon(for: paused) == .paused)
    }

    @Test func leadsWithTheWayToGrantClipboardAccessWhenItIsMissing() {
        let entries = menuEntries(for: state(needsAccess: true))
        #expect(Array(entries.prefix(4)) == [
            .status("Sem acesso à área de transferência"),
            .separator,
            .command(title: "Permitir Acesso à Área de Transferência…", action: .grantClipboardAccess),
            .separator,
        ])
        #expect(statusIcon(for: state(needsAccess: true)) == .needsClipboardAccess)
        // Pausing is the user's own doing and says more than a missing permission.
        #expect(statusIcon(for: state(isEnabled: false, needsAccess: true)) == .paused)
    }

    @Test func reflectsTheLoginItem() {
        #expect(command("Abrir ao Iniciar Sessão", in: menuEntries(for: state(login: false)))?.isChecked == false)
    }
}
