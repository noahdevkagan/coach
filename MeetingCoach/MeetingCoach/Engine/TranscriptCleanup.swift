import Foundation

// Post-ASR transcript hygiene, applied where pipeline text enters the
// session (AudioCaptureManager.deliver + the partial display path):
//
//  - WakeWordFilter drops stray voice-assistant activations ("Siri",
//    "Hey Siri") that a phone/HomePod in the room leaks into the mic.
//  - VocabularyNormalizer repairs domain terms the recognizer garbles
//    ("Tidy Khắc Việt" → TidyCal, "app sumo" → AppSumo) and folds
//    Vietnamese-script artifacts back to ASCII.
//
// Both are deterministic text transforms — no model, no network — so they
// behave identically on Parakeet and the SFSpeech fallback and are covered
// by pure-logic tests (tests/hygiene).

// MARK: - Wake-word noise

/// Drops utterances that are nothing but a voice-assistant callout. Only
/// pure wake phrases are noise — "Siri", "Hey Siri.", "Okay Google" — a
/// sentence that merely mentions an assistant ("we integrated Siri") is
/// real speech and always kept.
enum WakeWordFilter {
    private static let fillers: Set<String> = ["hey", "ok", "okay"]
    private static let assistants: Set<String> = ["siri", "alexa", "cortana"]

    static func isWakeNoise(_ text: String) -> Bool {
        let ws = tokens(text)
        guard !ws.isEmpty, ws.count <= 4 else { return false }
        var sawAssistant = false
        for (i, w) in ws.enumerated() {
            if assistants.contains(w) { sawAssistant = true; continue }
            if fillers.contains(w) { continue }
            // "google" is a company name in normal speech; it only reads as
            // a wake word right after hey/ok ("Okay Google").
            if w == "google", i > 0, fillers.contains(ws[i - 1]) {
                sawAssistant = true
                continue
            }
            return false
        }
        return sawAssistant
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Vocabulary normalization

/// Repairs recognizer garbles of known terms. Built-in defaults cover the
/// product's home domain; users extend them by right-clicking a transcript
/// line ("Fix a misheard term") or in Settings → General → Vocabulary
/// (one term per line, optional garble aliases after "="):
///
///     AppSumo
///     UGC = utc, u g c
///
/// Canonical terms double as SFSpeech contextual hints, so one list serves
/// both engines: bias recognition where the engine supports it, repair the
/// output where it doesn't.
struct VocabularyNormalizer: @unchecked Sendable {
    struct Term {
        let canonical: String
        let garbles: [String]
        init(_ canonical: String, garbles: [String] = []) {
            self.canonical = canonical
            self.garbles = garbles
        }
    }

    /// Garbles observed in real captures (2026-07-29 field report): each
    /// alias is a mis-transcription seen in the wild, kept narrow enough
    /// that ordinary English never matches. "utc" is deliberately NOT a
    /// default garble for UGC — it's a real timezone said in real meetings;
    /// users who never say UTC can add it to their custom list.
    static let defaultTerms: [Term] = [
        Term("AppSumo", garbles: ["app sumo", "up sumo", "app summo", "absumo",
                                  "ab sumo", "epsom", "apsu"]),
        Term("TidyCal", garbles: ["tidy cal", "tidy call", "tidy cow", "tidy kal",
                                  "teddy cal", "tidy khac viet"]),
        Term("SendFox", garbles: ["send fox"]),
        Term("KingSumo", garbles: ["king sumo"]),
        Term("MRR", garbles: ["mri pay", "m r r"]),
        Term("UGC", garbles: ["u g c"]),
    ]

    private let replacements: [(regex: NSRegularExpression, canonical: String)]
    /// Canonical terms, for SFSpeech contextual hints.
    let canonicals: [String]

    init(customText: String = "", extraTerms: [Term] = []) {
        var merged: [String: Term] = [:]
        for t in Self.defaultTerms + extraTerms + Self.parse(customText) {
            if let existing = merged[t.canonical.lowercased()] {
                merged[t.canonical.lowercased()] =
                    Term(existing.canonical, garbles: existing.garbles + t.garbles)
            } else {
                merged[t.canonical.lowercased()] = t
            }
        }
        let terms = merged.values.sorted { $0.canonical < $1.canonical }
        canonicals = terms.map(\.canonical)
        replacements = terms.compactMap { term -> (regex: NSRegularExpression, canonical: String)? in
            // The canonical itself is included so casing self-heals
            // ("Tidycal" → "TidyCal"). Longest alternative first, so
            // "app summo" wins over any shorter overlapping alias.
            let alternatives = ([term.canonical] + term.garbles)
                .map { $0.lowercased() }
                .sorted { $0.count > $1.count }
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            guard let regex = try? NSRegularExpression(
                pattern: "\\b(?:\(alternatives))\\b",
                options: [.caseInsensitive]) else { return nil }
            return (regex, term.canonical)
        }
    }

    /// "AppSumo = epsom, apsu" / bare "AppSumo" per line. Bare terms still
    /// normalize casing and feed recognition hints.
    private static func parse(_ text: String) -> [Term] {
        text.components(separatedBy: .newlines).compactMap { line -> Term? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard let head = parts.first?.trimmingCharacters(in: .whitespaces),
                  !head.isEmpty, !head.hasPrefix("#") else { return nil }
            let garbles = parts.count > 1
                ? parts[1].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            return Term(head, garbles: garbles)
        }
    }

    func normalize(_ text: String) -> String {
        var out = Self.foldVietnameseArtifacts(text)
        for (regex, canonical) in replacements {
            let range = NSRange(out.startIndex..., in: out)
            guard regex.firstMatch(in: out, range: range) != nil else { continue }
            out = regex.stringByReplacingMatches(
                in: out, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: canonical))
        }
        return out
    }

    // MARK: Vietnamese-script artifacts

    /// The multilingual ASR model occasionally decodes an English phrase as
    /// Vietnamese ("Tidy Khắc Việt"). Words carrying distinctly-Vietnamese
    /// marks are folded to ASCII; Western European diacritics are left
    /// alone — "Mbappé" and "Dembélé" are correct output, not artifacts.
    static func foldVietnameseArtifacts(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isVietnameseMark) else { return text }
        return text.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard word.unicodeScalars.contains(where: isVietnameseMark) else {
                    return String(word)
                }
                return String(word)
                    .replacingOccurrences(of: "đ", with: "d")
                    .replacingOccurrences(of: "Đ", with: "D")
                    .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            }
            .joined(separator: " ")
    }

    /// Vietnamese-only codepoints: the Latin Extended Additional block's
    /// Vietnamese range plus ă/đ/ơ/ư — none appear in Western European
    /// names, so their presence marks a mis-decoded word.
    private static func isVietnameseMark(_ scalar: Unicode.Scalar) -> Bool {
        let v = Int(scalar.value)
        return (0x1EA0...0x1EF9).contains(v)
            || [0x0102, 0x0103, 0x0110, 0x0111, 0x01A0, 0x01A1, 0x01AF, 0x01B0].contains(v)
    }
}
