import Foundation

/// A saved voice: a short mono sample of one person, used to enroll them
/// into the diarizer at session start so their turns are labeled by name.
/// Everything stays on disk under Application Support — never leaves the Mac.
struct VoiceProfile: Codable {
    let name: String
    let sampleRate: Double
    /// Raw little-endian Float32 mono samples.
    let audio: Data
    var createdAt: Date
    var lastUsedAt: Date

    var samples: [Float] {
        audio.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}

/// Disk store for voice profiles: one JSON file per person under
/// Application Support/MeetingCoach/voices/.
enum VoiceProfileStore {
    /// Longest clip worth keeping — enrollment quality plateaus, and
    /// session startup pays for every enrolled second.
    static let maxClipSeconds: TimeInterval = 12
    /// Shortest clip that can meaningfully enroll a voice.
    static let minClipSeconds: TimeInterval = 3

    static var dir: URL { AppSupport.root.appendingPathComponent("voices", isDirectory: true) }

    /// Save (or replace) a person's voice. Clips longer than the cap keep
    /// their most recent seconds — later speech has settled levels.
    static func save(name: String, samples: [Float], sampleRate: Double) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, sampleRate > 0 else { return }
        guard Double(samples.count) / sampleRate >= minClipSeconds else {
            mclog("[Voices] Clip for \(name) too short to save (\(samples.count) samples)")
            return
        }
        var clip = samples
        let cap = Int(maxClipSeconds * sampleRate)
        if clip.count > cap { clip = Array(clip.suffix(cap)) }

        let existing = load(name: name)
        let profile = VoiceProfile(
            name: name,
            sampleRate: sampleRate,
            audio: clip.withUnsafeBufferPointer { Data(buffer: $0) },
            createdAt: existing?.createdAt ?? Date(),
            lastUsedAt: Date()
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(profile) else { return }
        do {
            try data.write(to: url(for: name), options: .atomic)
            mclog("[Voices] Saved profile: \(name) (\(String(format: "%.1f", Double(clip.count) / sampleRate))s)")
        } catch {
            mclog("[Voices] Save failed for \(name): \(error.localizedDescription)")
        }
    }

    static func load(name: String) -> VoiceProfile? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? JSONDecoder().decode(VoiceProfile.self, from: data)
    }

    /// All saved profiles, `preferring` names (pre-call participants) first,
    /// then most recently used. Callers cap how many they enroll.
    static func loadAll(preferring preferred: [String] = []) -> [VoiceProfile] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        let preferredLower = Set(preferred.map { $0.lowercased() })
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(VoiceProfile.self, from: Data(contentsOf: $0)) }
            .sorted {
                let aPref = preferredLower.contains($0.name.lowercased())
                let bPref = preferredLower.contains($1.name.lowercased())
                if aPref != bPref { return aPref }
                return $0.lastUsedAt > $1.lastUsedAt
            }
    }

    static func delete(name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    static func allNames() -> [String] {
        loadAll().map(\.name)
    }

    private static func url(for name: String) -> URL {
        // Sanitize: names come from user input / LLM suggestions.
        let safe = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        return dir.appendingPathComponent("\(safe).json")
    }
}
