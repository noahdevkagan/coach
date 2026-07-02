import Foundation

enum TranscriptFormat {
    case simulator   // [mm:ss] SPEAKER: text
    case zoomDocs    // **Speaker** · HH:MM:SS\ntext
    case zoomVTT     // HH:MM:SS --> HH:MM:SS\nspeaker: text
}

struct TranscriptParser {
    /// Parse a transcript string, auto-detecting format.
    /// `youName` maps a speaker name to "You" (for Zoom transcripts).
    static func parse(_ text: String, youName: String = "noah kagan") -> [Utterance] {
        let lines = text.components(separatedBy: .newlines)
        let format = detectFormat(lines)
        switch format {
        case .simulator:
            return parseSimulator(lines)
        case .zoomDocs:
            return parseZoomDocs(lines, youName: youName)
        case .zoomVTT:
            return parseZoomVTT(lines, youName: youName)
        }
    }

    // MARK: - Format detection

    private static let simPattern = try! NSRegularExpression(
        pattern: #"^\[(\d{1,2}):(\d{2})\]\s*([^:]+?):\s*(.*)$"#)
    private static let zoomPattern = try! NSRegularExpression(
        pattern: #"^\*\*(.+?)\*\*\s*·\s*(\d{1,2}):(\d{2}):(\d{2})"#)
    /// Matches "11:12:46 --> 11:12:48" (Zoom VTT/SRT style), capturing both ends
    private static let vttTimestampPattern = try! NSRegularExpression(
        pattern: #"^(\d{1,2}):(\d{2}):(\d{2})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})"#)

    private static func detectFormat(_ lines: [String]) -> TranscriptFormat {
        for line in lines.prefix(30) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if simPattern.firstMatch(in: trimmed, range: range) != nil {
                return .simulator
            }
            if zoomPattern.firstMatch(in: trimmed, range: range) != nil {
                return .zoomDocs
            }
            if vttTimestampPattern.firstMatch(in: trimmed, range: range) != nil {
                return .zoomVTT
            }
        }
        return .simulator // default
    }

    // MARK: - [mm:ss] SPEAKER: text

    private static func parseSimulator(_ lines: [String]) -> [Utterance] {
        var utterances: [Utterance] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let m = simPattern.firstMatch(in: trimmed, range: range) else { continue }
            let mm = Int((trimmed as NSString).substring(with: m.range(at: 1))) ?? 0
            let ss = Int((trimmed as NSString).substring(with: m.range(at: 2))) ?? 0
            let speaker = (trimmed as NSString).substring(with: m.range(at: 3))
                .trimmingCharacters(in: .whitespaces)
            let text = (trimmed as NSString).substring(with: m.range(at: 4))
                .trimmingCharacters(in: .whitespaces)
            utterances.append(Utterance(t: Double(mm * 60 + ss), speaker: speaker, text: text))
        }
        utterances.sort { $0.t < $1.t }
        return utterances
    }

    // MARK: - Zoom Docs: **Speaker** · HH:MM:SS

    private static func parseZoomDocs(_ lines: [String], youName: String) -> [Utterance] {
        var entries: [(absSeconds: Int, speaker: String, text: String)] = []
        var i = 0
        while i < lines.count {
            let range = NSRange(lines[i].startIndex..., in: lines[i])
            if let m = zoomPattern.firstMatch(in: lines[i], range: range) {
                let speaker = (lines[i] as NSString).substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
                let hh = Int((lines[i] as NSString).substring(with: m.range(at: 2))) ?? 0
                let mm = Int((lines[i] as NSString).substring(with: m.range(at: 3))) ?? 0
                let ss = Int((lines[i] as NSString).substring(with: m.range(at: 4))) ?? 0
                let absSecs = hh * 3600 + mm * 60 + ss

                i += 1
                var textParts: [String] = []
                while i < lines.count {
                    let nextRange = NSRange(lines[i].startIndex..., in: lines[i])
                    if zoomPattern.firstMatch(in: lines[i], range: nextRange) != nil { break }
                    if lines[i].trimmingCharacters(in: .whitespaces) == "---" { break }
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        textParts.append(trimmed)
                    }
                    i += 1
                }
                let text = textParts.joined(separator: " ")
                if !text.isEmpty {
                    entries.append((absSecs, speaker, text))
                }
            } else {
                i += 1
            }
        }

        guard let startTime = entries.first?.absSeconds else { return [] }
        let youLower = youName.lowercased()
        return entries.map { entry in
            let rel = entry.absSeconds - startTime
            let label = entry.speaker.lowercased() == youLower ? "You" : entry.speaker
            return Utterance(t: Double(rel), speaker: label, text: entry.text)
        }.sorted { $0.t < $1.t }
    }

    // MARK: - Zoom VTT/SRT: HH:MM:SS --> HH:MM:SS\nspeaker: text

    /// Matches "speaker name: text"
    private static let speakerTextPattern = try! NSRegularExpression(
        pattern: #"^([^:]+?):\s+(.+)$"#)

    private static func parseZoomVTT(_ lines: [String], youName: String) -> [Utterance] {
        var entries: [(absSeconds: Int, endSeconds: Int, speaker: String, text: String)] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)

            // Look for timestamp line: "11:12:46 --> 11:12:48"
            if let m = vttTimestampPattern.firstMatch(in: trimmed, range: range) {
                let hh = Int((trimmed as NSString).substring(with: m.range(at: 1))) ?? 0
                let mm = Int((trimmed as NSString).substring(with: m.range(at: 2))) ?? 0
                let ss = Int((trimmed as NSString).substring(with: m.range(at: 3))) ?? 0
                let absSecs = hh * 3600 + mm * 60 + ss
                let eh = Int((trimmed as NSString).substring(with: m.range(at: 4))) ?? 0
                let em = Int((trimmed as NSString).substring(with: m.range(at: 5))) ?? 0
                let es = Int((trimmed as NSString).substring(with: m.range(at: 6))) ?? 0
                let endSecs = max(eh * 3600 + em * 60 + es, absSecs)

                i += 1
                // Next non-empty line(s) should be "speaker: text"
                var textParts: [String] = []
                var speaker = "Unknown"
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty { i += 1; break }
                    let nextRange = NSRange(nextTrimmed.startIndex..., in: nextTrimmed)
                    // Check if this is a new timestamp (no blank line separator)
                    if vttTimestampPattern.firstMatch(in: nextTrimmed, range: nextRange) != nil { break }
                    // Try to extract "speaker: text"
                    if let sm = speakerTextPattern.firstMatch(in: nextTrimmed, range: nextRange), textParts.isEmpty {
                        speaker = (nextTrimmed as NSString).substring(with: sm.range(at: 1))
                            .trimmingCharacters(in: .whitespaces)
                        let text = (nextTrimmed as NSString).substring(with: sm.range(at: 2))
                            .trimmingCharacters(in: .whitespaces)
                        textParts.append(text)
                    } else {
                        textParts.append(nextTrimmed)
                    }
                    i += 1
                }
                let text = textParts.joined(separator: " ")
                if !text.isEmpty {
                    entries.append((absSecs, endSecs, speaker, text))
                }
            } else {
                i += 1
            }
        }

        guard let startTime = entries.first?.absSeconds else { return [] }
        let youLower = youName.lowercased()
        return entries.map { entry in
            let rel = entry.absSeconds - startTime
            let relEnd = entry.endSeconds - startTime
            let label = entry.speaker.lowercased() == youLower ? "You" : entry.speaker
            return Utterance(t: Double(rel), speaker: label, text: entry.text, endT: Double(relEnd))
        }.sorted { $0.t < $1.t }
    }
}
