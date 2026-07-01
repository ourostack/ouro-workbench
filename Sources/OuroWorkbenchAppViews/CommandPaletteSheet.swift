#if os(macOS)
import OuroWorkbenchCore
import SwiftUI

struct CommandPaletteSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    /// Keyboard-highlighted row. ↑/↓ move it, Return runs it (not just the
    /// first), and clicking a row runs that one directly.
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Run command", text: $model.commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(runSelectedCommand)
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.filteredCommandPaletteItems.isEmpty {
                            ContentUnavailableView(
                                "No Commands",
                                systemImage: "command",
                                description: Text("Try another action, terminal name, or alias.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 220)
                        }
                        // U37(b): render the flat list grouped into labelled
                        // sections (Session / Boss / Workspace / Agents /
                        // Diagnostics / App) via the pure Core classifier. The
                        // global row index (the position in the FLAT filtered list)
                        // drives the keyboard highlight + scroll, so ↑/↓ and Return
                        // keep working across section breaks.
                        ForEach(sectionedRows, id: \.section) { group in
                            Text(group.section.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                            ForEach(group.rows, id: \.index) { row in
                                paletteRow(row.command, index: row.index, proxy: proxy)
                            }
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 360)
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
        .padding()
        .frame(width: 560)
        .onAppear {
            model.commandPaletteQuery = ""
            selectedIndex = 0
            searchFocused = true
        }
        .onChange(of: model.commandPaletteQuery) { _, _ in
            // Filtering changes the list; reset the highlight to the top.
            selectedIndex = 0
        }
        .onDisappear {
            // Run the chosen command now that the palette is fully gone, so a
            // command that opens another sheet doesn't race the dismiss.
            model.performPendingPaletteCommand()
        }
    }

    /// One palette row carrying its global index in the flat filtered list (the
    /// index the keyboard highlight + scroll use).
    private struct IndexedRow {
        var index: Int
        var command: WorkbenchCommandDescriptor
    }

    /// A labelled section of rows for the grouped palette render.
    private struct SectionedRows: Identifiable {
        var section: WorkbenchCommandSection
        var rows: [IndexedRow]
        var id: WorkbenchCommandSection { section }
    }

    /// The filtered palette in VISUAL (grouped) order — the single source the
    /// keyboard highlight, Return, and the rendered rows all index into, so the
    /// selection can't desync from what's on screen now that grouping reorders the
    /// flat list.
    private var visualOrderedItems: [WorkbenchCommandDescriptor] {
        WorkbenchCommandSection.grouped(model.filteredCommandPaletteItems).flatMap(\.commands)
    }

    /// The filtered palette grouped into labelled sections, each row tagged with
    /// its index in `visualOrderedItems` so the keyboard highlight survives the
    /// section breaks.
    private var sectionedRows: [SectionedRows] {
        var nextIndex = 0
        return WorkbenchCommandSection.grouped(model.filteredCommandPaletteItems).map { group in
            let rows = group.commands.map { command -> IndexedRow in
                defer { nextIndex += 1 }
                return IndexedRow(index: nextIndex, command: command)
            }
            return SectionedRows(section: group.section, rows: rows)
        }
    }

    @ViewBuilder
    private func paletteRow(
        _ command: WorkbenchCommandDescriptor,
        index: Int,
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            run(command)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: command.systemImage)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.body.weight(.semibold))
                    Text(command.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
    }

    private func moveSelection(by delta: Int) {
        selectedIndex = Self.clampedSelection(current: selectedIndex, delta: delta, count: visualOrderedItems.count)
    }

    /// Pure ↑/↓ keyboard-navigation clamp: `current + delta` clamped to `0..<count`; an empty
    /// list returns `current` unchanged (the no-op). Extracted as a `static func` so the
    /// selection math is directly unit-testable — `moveSelection(by:)` is reached only from the
    /// `.onKeyPress` closures, which ViewInspector 0.10.3 cannot drive. Behavior-identical to the
    /// prior inline `guard count > 0` + clamp (an empty list left `selectedIndex` untouched).
    static func clampedSelection(current: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return current }
        return min(max(current + delta, 0), count - 1)
    }

    private func runSelectedCommand() {
        let items = visualOrderedItems
        guard selectedIndex >= 0, selectedIndex < items.count else {
            return
        }
        run(items[selectedIndex])
    }

    private func run(_ command: WorkbenchCommandDescriptor) {
        // Defer execution until the palette has dismissed (see
        // pendingPaletteCommand) so commands that open another sheet present
        // reliably.
        model.pendingPaletteCommand = command
        dismiss()
    }
}
#endif
