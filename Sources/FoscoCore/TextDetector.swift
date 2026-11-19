import Foundation

public enum SensitiveKind: String, CaseIterable, Sendable {
    case email
    case phone
}

public struct SensitiveMatch: Equatable, Sendable {
    public let kind: SensitiveKind
    public let range: Range<String.Index>
}

/// Finds e-mail addresses and phone numbers in one line of text. Built for OCR output, so it
/// tolerates the damage Vision typically does (a stray space after a dot, a missing separator).
public func findSensitiveMatches(
    in text: String,
    kinds: Set<SensitiveKind> = Set(SensitiveKind.allCases)
) -> [SensitiveMatch] {
    let source = text as NSString
    let whole = NSRange(location: 0, length: source.length)
    var found: [(kind: SensitiveKind, range: NSRange)] = []
    for detector in detectors where kinds.contains(detector.kind) {
        for result in detector.regex.matches(in: text, range: whole) {
            guard let range = detector.refine(source, result.range) else { continue }
            found.append((detector.kind, range))
        }
    }
    return mergeOverlapping(found).compactMap { item in
        Range(item.range, in: text).map { SensitiveMatch(kind: item.kind, range: $0) }
    }
}

// MARK: - Patterns

private struct Detector: Sendable {
    let kind: SensitiveKind
    let regex: NSRegularExpression
    let refine: @Sendable (NSString, NSRange) -> NSRange?

    init(_ kind: SensitiveKind, _ pattern: String, refine: @escaping @Sendable (NSString, NSRange) -> NSRange? = { _, range in range }) {
        self.kind = kind
        // Patterns are compile-time constants; a failure here is a programming error.
        self.regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        self.refine = refine
    }
}

private let localChars = #"[a-z0-9._%+\-…]"#
/// Suffixes accepted after an OCR-inserted space ("gmail. com"). Lowercase only, and no suffix that
/// doubles as a word ("me", "us"), so "x@exemplo.com. Me liga" keeps its next sentence.
private let spacedSuffix = #"(?-i:com|net|org|br|io|dev|app|edu|gov)(?![a-z0-9\-])"#
private let fullDomain = #"(?:[a-z0-9\-]+(?:\.\s(?=\#(spacedSuffix))|\.))+[a-z]{2,24}(?![a-z0-9\-])"#
/// Domain cut off by the UI: "maria@gm…".
private let truncatedDomain = #"[a-z0-9.\-]*(?:…|\.{3})"#
private let mailProviders = "gmail|hotmail|outlook|yahoo|icloud|live|uol|bol|terra|proton(?:mail)?"

/// One separator between digit groups (space, dot, any hyphen or dash).
private let sep = #"[\s.\-‐-—]"#
/// Do not start inside a longer number, an id (#123…) or a decimal.
private let leftEdge = #"(?<![\d#.,+\-])"#
/// Do not stop inside a longer number or a decimal.
private let rightEdge = #"(?!\d)(?![.,\-]\d)"#
/// Brazilian area codes (DDD) in use.
private let areaCode = "(?:1[1-9]|2[12478]|3[1-578]|4[1-9]|5[1345]|6[1-9]|7[134579]|8[1-9]|9[1-9])"

private let detectors: [Detector] = [
    // name@domain.tld, with an optional OCR space after a dot in the local part ("ana.bia. souza@x.io").
    Detector(.email, #"(?:\#(localChars)+\.\s)?\#(localChars)+@(?:\#(fullDomain)|\#(truncatedDomain))"#, refine: rejectGitRemote),
    // Top-level domain damaged by OCR: "x@startup-io", "x@startup.1o", "x@gmail,corn".
    Detector(.email, #"\#(localChars)+@[a-z][a-z0-9.\-]*[.,\-][a-z0-9]{2,5}(?![a-z0-9\-])"#, refine: acceptDamagedDomain),
    // "@" misread as a letter in front of a well-known mail provider ("anadgmail.com").
    Detector(.email, #"[a-z0-9._%+\-]{2,}(?<![.@])(?:\#(mailProviders))\.(?:com|me)(?:\.br)?(?![a-z0-9\-])"#),
    // Brazil: optional +55, area code, then mobile (9 + 8 digits) or landline (8 digits).
    Detector(.phone, #"\#(leftEdge)(?:\+?55\#(sep)?)?\(?0?\#(areaCode)\)?\#(sep)?(?:9\#(sep)?\d{4}|[2-8]\d{3})\#(sep)?\d{4}\#(rightEdge)"#),
    // Brazilian mobile without area code: 90765-4321.
    Detector(.phone, #"\#(leftEdge)9\#(sep)?\d{4}-\d{4}\#(rightEdge)"#),
    // North America: (415) 555-0132, 415-555-0199, +1 415 555 0199.
    Detector(.phone, #"\#(leftEdge)(?:\+?1\#(sep)?)?(?:\([2-9]\d{2}\)\s?|[2-9]\d{2}\#(sep))\d{3}\#(sep)\d{4}\#(rightEdge)"#),
    // Any other number written with a country code: +351 912 345 678.
    Detector(.phone, #"(?<![\d#])\+\d{1,3}(?:\#(sep)?\(?\d{1,12}\)?){1,8}"#, refine: trimInternationalNumber),
]

/// "git@github.com:org/repo.git" is an SSH remote, not an address.
private func rejectGitRemote(_ source: NSString, _ range: NSRange) -> NSRange? {
    source.substring(with: range).lowercased().hasPrefix("git@") ? nil : range
}

/// Accepts "name@domain<sep><suffix>" when the suffix is a known one once the usual OCR confusions
/// (0/o, 1/i, rn/m) are undone. A hyphen stands in for the dot only before the suffixes that are
/// rare as the last word of a host name, so "deploy@api-dev" is left alone.
private func acceptDamagedDomain(_ source: NSString, _ range: NSRange) -> NSRange? {
    let text = source.substring(with: range).lowercased()
    guard rejectGitRemote(source, range) != nil, let separator = text.lastIndex(where: { ".,-".contains($0) }) else { return nil }
    let suffix = text[text.index(after: separator)...]
        .replacingOccurrences(of: "0", with: "o")
        .replacingOccurrences(of: "1", with: "i")
        .replacingOccurrences(of: "rn", with: "m")
    let known = text[separator] == "-" ? hyphenatedSuffixes : domainSuffixes
    return known.contains(suffix) ? range : nil
}

private let hyphenatedSuffixes: Set<String> = ["com", "br", "net", "org", "io"]
private let domainSuffixes: Set<String> = hyphenatedSuffixes.union([
    "dev", "app", "co", "me", "ai", "edu", "gov", "info", "tech", "biz", "xyz", "site", "store", "cloud", "online",
    "adv", "med", "eng", "agr", "ind", "art", "pt", "us", "uk", "es", "fr", "de", "it", "ca", "au", "ar", "mx", "cl",
])

/// A "+" candidate can run into the next numeric column ("+44 20 7946 0958 2026-1126"). Keep digit
/// groups only until the number is plausibly complete, and reject what cannot be a phone number.
private func trimInternationalNumber(_ source: NSString, _ range: NSRange) -> NSRange? {
    let candidate = source.substring(with: range) as NSString
    var digitCount = 0
    var end = 0
    for group in digitRuns.matches(in: candidate as String, range: NSRange(location: 0, length: candidate.length)) {
        digitCount += group.range.length
        end = NSMaxRange(group.range)
        if digitCount >= 10 { break }
    }
    guard (8...15).contains(digitCount) else { return nil }
    if end < candidate.length, candidate.character(at: end) == closingParenthesis { end += 1 }
    return NSRange(location: range.location, length: end)
}

private let digitRuns = try! NSRegularExpression(pattern: #"\d+"#)
private let closingParenthesis = UInt16(UInt8(ascii: ")"))

/// Collapses overlapping matches into one, keeping the kind of the longest.
private func mergeOverlapping(_ items: [(kind: SensitiveKind, range: NSRange)]) -> [(kind: SensitiveKind, range: NSRange)] {
    var merged: [(kind: SensitiveKind, range: NSRange, longest: Int)] = []
    for item in items.sorted(by: { $0.range.location < $1.range.location }) {
        guard let last = merged.last, item.range.location < NSMaxRange(last.range) else {
            merged.append((item.kind, item.range, item.range.length))
            continue
        }
        let union = NSUnionRange(last.range, item.range)
        let isLonger = item.range.length > last.longest
        merged[merged.count - 1] = (isLonger ? item.kind : last.kind, union, max(last.longest, item.range.length))
    }
    return merged.map { ($0.kind, $0.range) }
}
