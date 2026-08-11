import Foundation

/// Decides when a speaker named this session gets their collected voice
/// clip written to the profile store: immediately if enough audio already
/// exists, otherwise as soon as the clip crosses the minimum, plus one
/// final refresh with the fullest clip at session end. Naming before the
/// clip is viable no longer loses the profile — the name stays pending.
///
/// Only slots the user named THIS session ever enter here: profiles
/// enrolled from disk are never auto-refreshed from session audio, so one
/// misattributed session can't silently poison a good profile.
///
/// Pure state (no FluidAudio, no disk) so tests/session can drive it
/// deterministically; SpeakerDiarizer owns the I/O.
struct PendingProfileSaves {
    /// Slots named this session → the name their clip saves under.
    private(set) var nameBySlot: [Int: String] = [:]
    /// Clip seconds already written per slot — gates rewriting on every
    /// publish, and makes the final refresh a no-op unless the clip grew.
    private var savedSeconds: [Int: Double] = [:]

    mutating func name(slot: Int, as name: String) {
        guard nameBySlot[slot] != name else { return }
        nameBySlot[slot] = name
        savedSeconds[slot] = nil   // renamed → a save under the new name is owed
    }

    /// Saves due right now, given each slot's collected clip length.
    /// Non-final: first viable save only. Final (session end, or a rename
    /// after stop): also refresh an already-saved slot whose clip grew.
    /// Marks returned slots as written — caller must actually save them.
    mutating func due(clipSeconds: [Int: Double], minSeconds: Double,
                      final: Bool) -> [(slot: Int, name: String)] {
        var out: [(slot: Int, name: String)] = []
        for (slot, name) in nameBySlot.sorted(by: { $0.key < $1.key }) {
            guard let seconds = clipSeconds[slot], seconds >= minSeconds else { continue }
            if let already = savedSeconds[slot] {
                guard final, seconds > already + 0.5 else { continue }
            }
            savedSeconds[slot] = seconds
            out.append((slot, name))
        }
        return out
    }
}
