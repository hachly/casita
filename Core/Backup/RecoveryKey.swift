import CryptoKit
import Foundation

enum RecoveryKeyError: Error, Equatable {
    case wrongWordCount
    case unknownWord(String)
    case badChecksum
}

/// The secret behind a recovery phrase, shown once and never stored: the
/// phrase stretched with PBKDF2 (a phrase holds about 87 bits, and each guess
/// must cost about a second), or, for keys made before phrases, 12 BIP-39
/// words' 128 bits as they are.
///
/// The seed gives one X25519 key pair per slot through HKDF. Only public
/// keys are kept: in the headers of the spaces sealed to these words, and in
/// plain at the front of each of their portable slots, so the app can seal
/// slots and backups to them while every space is locked. Each slot has its
/// own key, so the slots of spaces that share words can't be matched up.
/// Opening anything sealed this way needs the words again.
struct RecoveryKey: Sendable, Equatable {
    static let wordCount = 12
    /// PBKDF2-SHA256 rounds for a phrase: about a second on an iPhone 11.
    static let phraseRounds: UInt32 = 2_000_000
    /// What every slot's key comes from.
    let seed: Data

    /// A random key with no phrase, for tests.
    init() {
        seed = ReservedStorage.randomBytes(16)
    }

    /// A key from before phrases: 12 words' 128 bits.
    init(entropy: Data) {
        precondition(entropy.count == 16)
        seed = entropy
    }

    /// Stretches the phrase: slow on purpose, so call it off the main thread.
    init(phrase: RecoveryPhrase, rounds: UInt32 = phraseRounds) {
        seed = pbkdf2(Data(phrase.canonical.utf8), salt: Data("casita.recovery.phrase".utf8), iterations: rounds)
    }

    /// Checks what the person typed reads as a phrase, or as the 12 words
    /// of a key made before phrases, without the slow stretching.
    static func check(_ text: String) throws {
        _ = try read(text)
    }

    /// What the person typed, as a key. Stretching runs off the main thread.
    static func typed(_ text: String) async throws -> RecoveryKey {
        switch try read(text) {
        case .words(let key): key
        case .phrase(let phrase): await Task.detached(priority: .userInitiated) { RecoveryKey(phrase: phrase) }.value
        }
    }

    private enum Typed { case words(RecoveryKey), phrase(RecoveryPhrase) }

    private static func read(_ text: String) throws -> Typed {
        let tokens = RecoveryPhrase.tokens(text)
        if tokens.count == wordCount, tokens.allSatisfy({ wordIndex[$0] != nil }) { return .words(try RecoveryKey(words: tokens)) }
        return .phrase(try RecoveryPhrase(typed: text))
    }

    /// Parses what the user typed. Case and surrounding spaces don't matter.
    init(words typed: [String]) throws {
        let words = typed.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard words.count == Self.wordCount else { throw RecoveryKeyError.wrongWordCount }
        var bits: [Bool] = []
        for word in words {
            guard let index = Self.wordIndex[word] else { throw RecoveryKeyError.unknownWord(word) }
            for b in (0..<11).reversed() { bits.append((index >> b) & 1 == 1) }
        }
        let entropy = Data(Array(bits.prefix(128)).chunks(of: 8).map(Self.byte))
        guard Array(bits.suffix(4)) == Self.checksumBits(entropy) else { throw RecoveryKeyError.badChecksum }
        seed = entropy
    }

    /// The 12 words of a key from before phrases.
    var words: [String] {
        var bits: [Bool] = []
        for byte in seed { for b in (0..<8).reversed() { bits.append((byte >> b) & 1 == 1) } }
        bits += Self.checksumBits(seed)
        return bits.chunks(of: 11).map { chunk in
            Self.wordList[chunk.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }]
        }
    }

    /// The key for one portable slot (and that slot's seal in a backup).
    func privateKey(forSlot slot: Int) -> Curve25519.KeyAgreement.PrivateKey {
        let raw = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: Data("casita".utf8), info: Data("recovery.x25519.slot.\(slot)".utf8), outputByteCount: 32
        )
        return try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw.withUnsafeBytes { Data($0) })
    }

    func publicKey(forSlot slot: Int) -> Curve25519.KeyAgreement.PublicKey { privateKey(forSlot: slot).publicKey }

    // MARK: Bits

    private static let wordIndex: [String: Int] = Dictionary(uniqueKeysWithValues: wordList.enumerated().map { ($1, $0) })

    private static func checksumBits(_ entropy: Data) -> [Bool] {
        let first = SHA256.hash(data: entropy).withUnsafeBytes { $0[0] }
        return (0..<4).reversed().map { (first >> ($0 + 4)) & 1 == 1 }
    }

    private static func byte(_ bits: ArraySlice<Bool>) -> UInt8 {
        bits.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
    }
}

/// A recovery phrase: one sentence of eleven random parts from Casita's
/// own word lists, about 87 bits, made to be remembered:
/// "The old bridge is quietly walking through the dark brown forest with a
/// tiny banjo in Korea at midnight."
struct RecoveryPhrase: Sendable, Equatable {
    /// Adjective, thing, manner, action, adjective, colour, thing, adjective,
    /// thing, place, time. Sentences made before 23 Oct 2026 have eight
    /// (no manner, no "with" part) and still read.
    let parts: [String]

    private static var slots: [[String]] {
        [PhraseWords.adjectives, PhraseWords.things, PhraseWords.manners, PhraseWords.actions.map(\.word),
         PhraseWords.adjectives, PhraseWords.colours, PhraseWords.things, PhraseWords.adjectives, PhraseWords.things,
         PhraseWords.places, PhraseWords.times.map(\.word)]
    }

    private static var shortSlots: [[String]] {
        [PhraseWords.adjectives, PhraseWords.things, PhraseWords.actions.map(\.word), PhraseWords.adjectives,
         PhraseWords.colours, PhraseWords.things, PhraseWords.places, PhraseWords.times.map(\.word)]
    }

    /// A new random phrase. `randomElement()` draws from the system's
    /// cryptographic generator.
    init() {
        parts = Self.slots.map { $0.randomElement()! }
    }

    init(parts: [String]) {
        precondition(parts.count == Self.slots.count || parts.count == Self.shortSlots.count)
        self.parts = parts
    }

    /// The first word of every list: debug builds' `-devRecoveryWords`.
    static let dev = RecoveryPhrase(parts: slots.map { $0[0] })

    /// Reads a typed phrase. Case, punctuation, accents and the joining
    /// words don't matter; a word one or two letters off becomes the only
    /// list word that near.
    init(typed text: String) throws {
        let content = Self.tokens(text).filter { !PhraseWords.joining.contains($0) }
        let slots = content.count == Self.shortSlots.count ? Self.shortSlots : Self.slots
        guard content.count == slots.count else { throw RecoveryKeyError.wrongWordCount }
        parts = try zip(content, slots).map { token, list in
            guard let word = Self.match(token, in: list) else { throw RecoveryKeyError.unknownWord(token) }
            return word
        }
    }

    /// What the key is stretched from: the parts, one space apart.
    var canonical: String { parts.joined(separator: " ") }

    /// The sentence in pieces, each marked as a random part or a joining word.
    var pieces: [(text: String, isPart: Bool)] {
        let long = parts.count == Self.slots.count
        var rest = parts[...]
        func next() -> String { rest.removeFirst() }
        var pieces: [(String, Bool)] = [("The", false), (next(), true), (next(), true), ("is", false)]
        if long { pieces.append((next(), true)) }
        let action = next()
        pieces.append((action, true))
        if let then = PhraseWords.actions.first(where: { $0.word == action })?.then, !then.isEmpty { pieces.append((then, false)) }
        pieces += [("the", false), (next(), true), (next(), true), (next(), true)]
        if long {
            let adjective = next()
            pieces += [("with", false), ("aeiou".contains(adjective.first!) ? "an" : "a", false), (adjective, true), (next(), true)]
        }
        let place = next(), time = next()
        let before = PhraseWords.times.first { $0.word == time }?.before ?? "at"
        pieces += [("in", false), (place.capitalized, true), (before, false),
                   (Self.properTimes.contains(time) ? time.capitalized : time, true)]
        return pieces
    }

    var sentence: String { pieces.map(\.text).joined(separator: " ") + "." }

    private static let properTimes: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    /// Lowercase ASCII words: "Reykjavík," reads as "reykjavik".
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !("a"..."z").contains($0) }
            .map(String.init)
    }

    private static func match(_ token: String, in list: [String]) -> String? {
        if list.contains(token) { return token }
        let reach = token.count >= 5 ? 2 : 1
        let near = list.map { ($0, editDistance(token, $0)) }.filter { $0.1 <= reach }
        guard let best = near.map(\.1).min() else { return nil }
        let closest = near.filter { $0.1 == best }
        return closest.count == 1 ? closest[0].0 : nil
    }

    /// Levenshtein distance: letters added, removed or changed.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = Swift.min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}

private extension Array {
    func chunks(of size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
