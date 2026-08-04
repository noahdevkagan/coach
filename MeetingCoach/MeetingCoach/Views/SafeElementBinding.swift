import SwiftUI

extension Binding where Value: MutableCollection, Value.Element: Identifiable {
    /// A per-row binding that survives the row being deleted mid-edit.
    ///
    /// The element bindings `ForEach($array)` vends are positional — they
    /// read `array[index]` on every access. Delete a row while one of its
    /// text fields still has a pending edit and SwiftUI re-reads the stale
    /// binding on the next layout pass: index out of range, hard crash
    /// (seen in the wild on 0.10.1). This looks the element up by identity
    /// instead; reads of a gone row fall back to its last value, writes no-op.
    func safeElement(_ element: Value.Element) -> Binding<Value.Element> {
        Binding<Value.Element>(
            get: {
                wrappedValue.first { $0.id == element.id } ?? element
            },
            set: { newValue in
                guard let i = wrappedValue.firstIndex(where: { $0.id == element.id }) else { return }
                wrappedValue[i] = newValue
            }
        )
    }
}
