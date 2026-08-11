import Foundation

/// Persists participants across sessions (UserDefaults, local only). One
/// list serves the pre-call form's suggestions AND the rename popover's
/// typeahead — a name entered either place is remembered everywhere.
enum ParticipantStore {
    private static let key = "savedParticipants"

    static func save(_ participants: [PreCallContext.Participant]) {
        // Merge this meeting's people into the remembered list (dedupe by
        // name) — the form only contains today's participants, not everyone.
        let valid = participants.filter { !$0.name.isEmpty }
        var merged = load()
        for person in valid {
            if let i = merged.firstIndex(where: {
                $0.name.caseInsensitiveCompare(person.name) == .orderedSame
            }) {
                merged[i].role = person.role
            } else {
                merged.append(person)
            }
        }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Remember one name the moment a speaker is renamed — independent of
    /// whether enough audio ever exists for a voice profile. A known name
    /// keeps its stored role; casing follows the existing entry.
    static func remember(name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var merged = load()
        guard !merged.contains(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        merged.append(.init(name: name))
        guard let data = try? JSONEncoder().encode(merged) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [PreCallContext.Participant] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let participants = try? JSONDecoder().decode([PreCallContext.Participant].self, from: data)
        else { return [] }
        return participants
    }

    // MARK: - Rename typeahead

    /// Everyone the app knows a name for: remembered participants first
    /// (deliberately entered), then saved voices not already listed.
    /// Loaded once per popover open — profile decode reads whole clips.
    static func typeaheadCandidates() -> [String] {
        var names = load().map(\.name).filter { !$0.isEmpty }
        var seen = Set(names.map { $0.lowercased() })
        for profile in VoiceProfileStore.loadAll()
        where seen.insert(profile.name.lowercased()).inserted {
            names.append(profile.name)
        }
        return names
    }

    /// Case-insensitive matches for the rename popover: prefix matches
    /// before substring matches, candidate order preserved within each
    /// group. An empty query offers the first candidates as-is.
    static func typeaheadMatches(_ query: String, in candidates: [String],
                                 limit: Int = 5) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(candidates.prefix(limit)) }
        var prefix: [String] = []
        var contains: [String] = []
        for name in candidates {
            let lower = name.lowercased()
            if lower.hasPrefix(q) {
                prefix.append(name)
            } else if lower.contains(q) {
                contains.append(name)
            }
        }
        return Array((prefix + contains).prefix(limit))
    }
}
