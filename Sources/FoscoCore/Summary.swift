/// "2 e-mails e 1 telefone borrados", for the menu.
public func describeRedaction(_ regions: [SensitiveRegion]) -> String {
    let emails = regions.count { $0.kind == .email }
    let phones = regions.count { $0.kind == .phone }
    let parts = [
        emails > 0 ? "\(emails) \(emails == 1 ? "e-mail" : "e-mails")" : nil,
        phones > 0 ? "\(phones) \(phones == 1 ? "telefone" : "telefones")" : nil,
    ].compactMap { $0 }
    guard !parts.isEmpty else { return "Nada borrado" }
    return "\(parts.joined(separator: " e ")) \(emails + phones == 1 ? "borrado" : "borrados")"
}
