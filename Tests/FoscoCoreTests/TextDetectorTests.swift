import Testing
@testable import FoscoCore

/// Text of every match, in order, as "kind:text".
private func detect(_ text: String) -> [String] {
    findSensitiveMatches(in: text).map { "\($0.kind.rawValue):\(text[$0.range])" }
}

@Suite struct EmailDetection {
    @Test(arguments: [
        ("Contato: maria.silva@exemplo.com.br", "maria.silva@exemplo.com.br"),
        ("fulano_exemplo+teste@gmail.com", "fulano_exemplo+teste@gmail.com"),
        ("<ANA@EXEMPLO.COM>,", "ANA@EXEMPLO.COM"),
        ("mailto:felipe@exemplo.adv.br.", "felipe@exemplo.adv.br"),
        ("\"email\": \"ana.clara@exemplo.io\",", "ana.clara@exemplo.io"),
        ("jp.alves@exemplo.tech", "jp.alves@exemplo.tech"),
    ])
    func findsPlainAddresses(text: String, expected: String) {
        #expect(detect(text) == ["email:\(expected)"])
    }

    @Test func findsSeveralAddressesOnOneLine() {
        #expect(detect("ana.beatriz.souza@exemplo.io, carlos@exemplo.dev") == ["email:ana.beatriz.souza@exemplo.io", "email:carlos@exemplo.dev"])
    }

    @Test(arguments: [
        ("ana.beatriz. souza@exemplo.io", "ana.beatriz. souza@exemplo.io"),
        ("exemplo@gmail. com", "exemplo@gmail. com"),
        ("rafa@exemplo.com. br", "rafa@exemplo.com. br"),
        ("Bruno Limabruno.lima@exemplo.com.br", "Limabruno.lima@exemplo.com.br"),
        ("anadgmail.com", "anadgmail.com"),
        ("sofiaQhotmail.com.br", "sofiaQhotmail.com.br"),
        ("\"email\": \"ana.clara@exemplo-io\",", "ana.clara@exemplo-io"),
        ("ana.clara@exemplo.1o", "ana.clara@exemplo.1o"),
        ("exemplo@gmail,corn", "exemplo@gmail,corn"),
        ("rafa@exemplo.c0m", "rafa@exemplo.c0m"),
    ])
    func toleratesOCRDamage(text: String, expected: String) {
        #expect(detect(text) == ["email:\(expected)"])
    }

    @Test(arguments: [
        ("fulano.si…@gmail.com", "fulano.si…@gmail.com"),
        ("fulano.si...@gmail.com", "fulano.si...@gmail.com"),
        ("fulano.silva@gm…", "fulano.silva@gm…"),
        ("fulano.silva@gmail.c...", "fulano.silva@gmail.c..."),
    ])
    func findsAddressesTruncatedByTheUI(text: String, expected: String) {
        #expect(detect(text) == ["email:\(expected)"])
    }

    @Test func stopsAtTheEndOfTheSentence() {
        #expect(detect("Escreva para ana@exemplo.com. Me liga depois.") == ["email:ana@exemplo.com"])
        #expect(detect("Escreva para ana@exemplo.com. Depois falamos.") == ["email:ana@exemplo.com"])
    }

    @Test(arguments: [
        "SEGUE @FULANODETAL",
        "Segue @fulano.detal no Instagram",
        "@Injectable() export class Foo",
        "npm i react@18.2.0 next@canary @types/node",
        "fulano@MacBook-Pro ~ %",
        "git clone git@github.com:org/repo.git",
        "https://mail.google.com/mail/u/0",
        "www.gmail.com e outlook.live.com",
        "preço @ R$ 10,00",
        "ssh deploy@api-dev e root@web-app-01",
        "pnpm add typescript@5.4.0-dev eslint@9.0.0-rc.1",
        "docker pull app@sha256-9f86d081884c",
    ])
    func ignoresThingsThatOnlyLookLikeAddresses(text: String) {
        #expect(detect(text).isEmpty)
    }
}

@Suite struct PhoneDetection {
    @Test(arguments: [
        "(11) 90765-4321", "11 90765-4321", "11907654321", "(11)90765-4321", "1190765-4321",
        "+55 11 90765-4321", "+5511907654321", "5511907654321", "+55 (31) 9 0765-4321",
        "47 9 0123-4567", "(47) 4004-5566", "31 4004-7788", "1140045566", "(011) 90765-4321",
        "90765-4321", "11 90765–4321", "11.90765.4321",
    ])
    func findsBrazilianNumbers(number: String) {
        #expect(detect(number) == ["phone:\(number)"])
        #expect(detect("Telefone: \(number), ok?") == ["phone:\(number)"])
    }

    @Test(arguments: [
        "+1 (415) 555-0132", "+1 415-555-0199", "415-555-0199", "(415) 555-0132", "415.555.0199",
        "+351 912 345 678", "+44 20 7946 0958", "+33 1 23 45 67 89", "+54 9 11 1234-5678", "+491512345678",
    ])
    func findsForeignNumbers(number: String) {
        #expect(detect(number) == ["phone:\(number)"])
    }

    @Test func doesNotSwallowTheNextColumn() {
        #expect(detect("+44 20 7946 0958 2026-1126 27/11/2026 16:54") == ["phone:+44 20 7946 0958"])
        #expect(detect("+55 21 90701-3344 2026-1014 07/11/2026 10:26") == ["phone:+55 21 90701-3344"])
        #expect(detect("(47) 4004-5566 2026-1035 16/11/2026 13:05 R$ 2.251,65") == ["phone:(47) 4004-5566"])
    }

    @Test func findsSeveralNumbersOnOneLine() {
        #expect(detect("5511907654321  +5511902345678") == ["phone:5511907654321", "phone:+5511902345678"])
        #expect(detect("Fixo (21) 4004-5566 / Cel (21) 90876-5432") == ["phone:(21) 4004-5566", "phone:(21) 90876-5432"])
    }

    @Test(arguments: [
        "Pedido #1234567890 em 19/11/2026 10:30 - R$ 1.299,90",
        "\"id\": 4815162342, \"created_at\": 1795093188,",
        "1795093188593",
        "CNPJ 12.345.678/0001-90 · CPF 529.982.247-25",
        "192.168.0.12 · v4.18.2 · 2026.11.000482",
        "2026-11-19T14:32:10Z",
        "CEP 01310-100 · Rua das Flores, 1200",
        "R$ 128.480,90 · 1.284 · +12,5% · UTC+03:00",
        "0800 123 4567",
        "#11907654321",
        "2026-1000 01/11/2026 08:00 R$ 189,90",
        "4111 1111 1111 1111",
    ])
    func ignoresOtherNumbers(text: String) {
        #expect(detect(text).isEmpty)
    }
}

@Suite struct MixedDetection {
    @Test func findsBothKindsOnATableRow() {
        #expect(detect("Bruno Lima bruno.lima@exemplo.com.br (47) 9 0888-7777 Inativo") == ["email:bruno.lima@exemplo.com.br", "phone:(47) 9 0888-7777"])
    }

    @Test func reportsANumberInsideAnAddressOnce() {
        #expect(detect("11907654321@exemplo.com") == ["email:11907654321@exemplo.com"])
    }

    @Test func honoursTheRequestedKinds() {
        let text = "ana@exemplo.com 11 90765-4321"
        #expect(findSensitiveMatches(in: text, kinds: [.phone]).map(\.kind) == [.phone])
        #expect(findSensitiveMatches(in: text, kinds: []).isEmpty)
    }
}
