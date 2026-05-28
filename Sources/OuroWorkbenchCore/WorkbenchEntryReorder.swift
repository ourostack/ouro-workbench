import Foundation

/// Pure helper that reorders entries in a global array based on indices
/// from a filtered view of that array. Used by the workbench sidebar's
/// drag-to-reorder so the user-visible move (`sessionEntries[i] → j`)
/// translates correctly into a mutation of the underlying
/// `state.processEntries` storage without disturbing unrelated rows.
///
/// `Element` is generic over identifiable types so the same helper backs
/// any future "reorder a filtered view" need (groups, agents, etc.).
public enum WorkbenchEntryReorder {
    /// Move the entries at `offsets` in `visible` to `destination` (also
    /// expressed in visible-space, SwiftUI `.onMove` semantics), returning a
    /// new `global` array with that move applied.
    ///
    /// The function preserves the relative order of all other entries in
    /// `global` — entries the user can't see in `visible` stay where they
    /// were. Out-of-bounds offsets/destination return the input unchanged.
    public static func move<Element: Identifiable>(
        global: [Element],
        visible: [Element],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) -> [Element] {
        guard offsets.allSatisfy({ $0 < visible.count }),
              destination >= 0,
              destination <= visible.count else {
            return global
        }
        let movingIDs = offsets.sorted().map { visible[$0].id }
        // Compute the global insertion anchor before any removals.
        let anchorGlobalIndex: Int
        if destination < visible.count {
            let anchorID = visible[destination].id
            anchorGlobalIndex = global.firstIndex(where: { $0.id == anchorID }) ?? global.count
        } else if let last = visible.last,
                  let lastIdx = global.firstIndex(where: { $0.id == last.id }) {
            anchorGlobalIndex = lastIdx + 1
        } else {
            anchorGlobalIndex = global.count
        }
        let globalIndices = movingIDs.compactMap { id in
            global.firstIndex(where: { $0.id == id })
        }
        guard !globalIndices.isEmpty else { return global }
        var result = global
        var moved: [Element] = []
        for i in globalIndices.sorted(by: >) {
            moved.insert(result.remove(at: i), at: 0)
        }
        let removedBefore = globalIndices.filter { $0 < anchorGlobalIndex }.count
        let insertIndex = min(result.count, max(0, anchorGlobalIndex - removedBefore))
        result.insert(contentsOf: moved, at: insertIndex)
        return result
    }
}
