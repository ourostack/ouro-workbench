#if os(macOS)
import AppKit
import SwiftTerm
import SwiftUI
import OuroWorkbenchCore

@main
struct OuroWorkbenchApp: App {
    var body: some Scene {
        WindowGroup("Ouro Workbench") {
            WorkbenchRootView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct WorkbenchRootView: View {
    private let boss = BossAgentSelection()
    private let presets = TerminalAgentPresets.all

    var body: some View {
        NavigationSplitView {
            List {
                Section("Boss") {
                    Label(boss.agentName, systemImage: "person.crop.circle.badge.checkmark")
                }
                Section("Terminal Agents") {
                    ForEach(presets) { preset in
                        Label(preset.displayName, systemImage: "terminal")
                    }
                }
                Section("Recovery") {
                    Label("Restart persistence: P0", systemImage: "arrow.clockwise.circle")
                }
            }
            .navigationTitle("Ouro Workbench")
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HeaderView(bossName: boss.agentName)
                Divider()
                TerminalPane(
                    executable: "/bin/zsh",
                    arguments: ["-l"],
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
            }
        }
    }
}

struct HeaderView: View {
    var bossName: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Native terminal-agent workbench")
                    .font(.headline)
                Text("Boss agent: \(bossName) | Claude Code, Copilot CLI, and Codex are P0 lanes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("TTFA")
                .font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.green.opacity(0.16), in: Capsule())
        }
        .padding()
    }
}

struct TerminalPane: NSViewRepresentable {
    var executable: String
    var arguments: [String]
    var workingDirectory: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.configureNativeFeel()
        terminal.startProcess(
            executable: executable,
            args: arguments,
            execName: "-" + URL(fileURLWithPath: executable).lastPathComponent,
            currentDirectory: workingDirectory
        )
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}

private extension LocalProcessTerminalView {
    func configureNativeFeel() {
        metalBufferingMode = .perFrameAggregated
        try? setUseMetal(true)
        getTerminal().setCursorStyle(.steadyBlock)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
}
#endif
