#if os(macOS)
import AppKit
import OuroWorkbenchCore
import SwiftTerm
import SwiftUI

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
    @StateObject private var model = WorkbenchViewModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedEntryID) {
                Section("Boss") {
                    Label(model.state.boss.agentName, systemImage: "person.crop.circle.badge.checkmark")
                }
                Section("Terminal Agents") {
                    ForEach(model.terminalEntries) { entry in
                        TerminalAgentRow(entry: entry, isSelected: model.selectedEntryID == entry.id)
                            .tag(entry.id)
                    }
                }
                Section("Recovery") {
                    Label(model.summary.oneLineStatus, systemImage: "arrow.clockwise.circle")
                }
            }
            .navigationTitle("Ouro Workbench")
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HeaderView(summary: model.summary)
                Divider()
                if let entry = model.selectedEntry {
                    SessionDetailView(entry: entry, model: model)
                } else {
                    ContentUnavailableView("No session selected", systemImage: "terminal")
                }
            }
        }
        .alert("Workbench Error", isPresented: model.errorIsPresented) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }
}

struct TerminalAgentRow: View {
    var entry: ProcessEntry
    var isSelected: Bool

    var body: some View {
        HStack {
            Label(entry.name, systemImage: "terminal")
            Spacer()
            StatusDot(attention: entry.attention)
        }
        .fontWeight(isSelected ? .semibold : .regular)
    }
}

struct StatusDot: View {
    var attention: AttentionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(attention.rawValue)
    }

    private var color: SwiftUI.Color {
        switch attention {
        case .idle:
            return .secondary
        case .active:
            return .green
        case .waitingOnHuman:
            return .orange
        case .blocked:
            return .red
        case .needsBossReview:
            return .blue
        }
    }
}

struct HeaderView: View {
    var summary: WorkspaceSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ouro Workbench")
                    .font(.headline)
                Text("Boss: \(summary.boss.agentName) | \(summary.oneLineStatus)")
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

struct SessionDetailView: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name)
                        .font(.title3.weight(.semibold))
                    Text(model.launchCommand(for: entry))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    model.launch(entry)
                } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            if let session = model.activeSession(for: entry) {
                TerminalPane(session: session)
                    .id(session.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.lastSummary ?? "Configured")
                        .font(.body)
                    Text("Recovery: \(model.recoveryReason(for: entry))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                Spacer()
            }
        }
    }
}

@MainActor
final class WorkbenchViewModel: ObservableObject {
    @Published var state: WorkspaceState
    @Published var selectedEntryID: UUID?
    @Published var activeSessions: [UUID: TerminalSessionController] = [:]
    @Published var errorMessage: String?

    private let paths: WorkbenchPaths
    private let store: WorkbenchStore
    private let bootstrapper = WorkbenchBootstrapper()
    private let startupRecoveryReconciler = StartupRecoveryReconciler()
    private let summarizer = WorkspaceSummarizer()

    init(paths: WorkbenchPaths = .defaultPaths()) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.state = WorkspaceState()
        load()
    }

    var errorIsPresented: Binding<Bool> {
        Binding(
            get: { self.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    self.errorMessage = nil
                }
            }
        )
    }

    var terminalEntries: [ProcessEntry] {
        state.processEntries.filter { $0.kind == .terminalAgent }
    }

    var selectedEntry: ProcessEntry? {
        guard let selectedEntryID else {
            return terminalEntries.first
        }
        return state.processEntries.first { $0.id == selectedEntryID }
    }

    var summary: WorkspaceSummary {
        summarizer.summarize(state)
    }

    func launchCommand(for entry: ProcessEntry) -> String {
        do {
            return try WorkbenchCommandPlanner(paths: paths).launchPlan(for: entry).displayCommand
        } catch {
            return entry.executable
        }
    }

    func recoveryReason(for entry: ProcessEntry) -> String {
        summary.recoveryPlans.first { $0.entryId == entry.id }?.reason ?? "no action"
    }

    func activeSession(for entry: ProcessEntry) -> TerminalSessionController? {
        activeSessions[entry.id]
    }

    func launch(_ entry: ProcessEntry) {
        do {
            let plan = try WorkbenchCommandPlanner(paths: paths).launchPlan(for: entry)
            if let existingSession = activeSessions[entry.id] {
                existingSession.terminate()
                markTerminated(entryId: entry.id, runId: existingSession.plan.runId, rawStatus: nil)
            }
            let session = try TerminalSessionController(
                plan: plan,
                onStarted: { [weak self] pid in
                    self?.markStarted(plan: plan, pid: pid)
                },
                onOutput: { [weak self] in
                    self?.markOutput(entryId: entry.id, runId: plan.runId)
                },
                onTerminated: { [weak self] rawStatus in
                    self?.markTerminated(entryId: entry.id, runId: plan.runId, rawStatus: rawStatus)
                }
            )
            activeSessions[entry.id] = session
            session.start()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func markStarted(plan: TerminalCommandPlan, pid: Int32?) {
        updateEntry(plan.entryId) { entry in
            entry.attention = .active
            entry.lastSummary = "\(entry.name) launched"
        }
        state.processRuns.removeAll { $0.id == plan.runId }
        state.processRuns.append(
            ProcessRun(
                id: plan.runId,
                entryId: plan.entryId,
                pid: pid,
                status: .running,
                transcriptPath: plan.transcriptPath
            )
        )
        save()
    }

    func markOutput(entryId: UUID, runId: UUID) {
        guard let runIndex = state.processRuns.firstIndex(where: { $0.id == runId && $0.entryId == entryId }) else {
            return
        }
        state.processRuns[runIndex].lastOutputAt = Date()
        save()
    }

    func markTerminated(entryId: UUID, runId: UUID, rawStatus: Int32?) {
        let status = ProcessExitStatus(rawWaitStatus: rawStatus)
        let isCurrentSession = activeSessions[entryId]?.plan.runId == runId
        if isCurrentSession {
            activeSessions[entryId] = nil
            updateEntry(entryId) { entry in
                entry.attention = .idle
                entry.lastSummary = "\(entry.name) exited with code \(status.exitCode.map(String.init) ?? "unknown")"
            }
        }
        if let runIndex = state.processRuns.firstIndex(where: { $0.id == runId && $0.entryId == entryId }) {
            state.processRuns[runIndex].status = .exited
            state.processRuns[runIndex].endedAt = Date()
            state.processRuns[runIndex].exitCode = status.exitCode
            state.processRuns[runIndex].rawExitStatus = status.rawWaitStatus
        }
        save()
    }

    private func load() {
        do {
            let loaded = try store.load()
            state = startupRecoveryReconciler.reconcile(bootstrapper.bootstrappedState(from: loaded))
            selectedEntryID = terminalEntries.first?.id
            try store.save(state)
        } catch {
            errorMessage = String(describing: error)
            state = bootstrapper.bootstrappedState(from: WorkspaceState())
            selectedEntryID = terminalEntries.first?.id
        }
    }

    private func updateEntry(_ entryId: UUID, mutate: (inout ProcessEntry) -> Void) {
        guard let index = state.processEntries.firstIndex(where: { $0.id == entryId }) else {
            return
        }
        mutate(&state.processEntries[index])
    }

    private func save() {
        do {
            try store.save(state)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

struct TerminalPane: NSViewRepresentable {
    var session: TerminalSessionController

    func makeNSView(context: Context) -> CapturingLocalProcessTerminalView {
        session.terminal
    }

    func updateNSView(_ nsView: CapturingLocalProcessTerminalView, context: Context) {}
}

@MainActor
final class TerminalSessionController: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let plan: TerminalCommandPlan
    let terminal: CapturingLocalProcessTerminalView
    private let environment: [String]
    private let onStarted: (Int32?) -> Void
    private let onOutput: () -> Void
    private let onTerminated: (Int32?) -> Void
    private var recorder: TranscriptRecorder?
    private var hasStarted = false

    init(
        plan: TerminalCommandPlan,
        onStarted: @escaping (Int32?) -> Void,
        onOutput: @escaping () -> Void,
        onTerminated: @escaping (Int32?) -> Void
    ) throws {
        self.plan = plan
        self.onStarted = onStarted
        self.onOutput = onOutput
        self.onTerminated = onTerminated
        self.terminal = CapturingLocalProcessTerminalView(frame: .zero)
        self.environment = TerminalEnvironment().mergedWithTerminalDefaults()
        if let transcriptPath = plan.transcriptPath {
            self.recorder = try TranscriptRecorder(url: URL(fileURLWithPath: transcriptPath))
        }
        super.init()
        terminal.processDelegate = self
        terminal.onOutput = recordOutput
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.configureNativeFeel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        let invocation = plan.launchInvocation
        terminal.startProcess(
            executable: invocation.executable,
            args: invocation.arguments,
            environment: environment,
            execName: invocation.execName,
            currentDirectory: plan.workingDirectory
        )
        onStarted(terminal.process?.shellPid)
    }

    func sendInput(_ text: String) {
        terminal.send(txt: text)
    }

    func sendBytes(_ bytes: [UInt8]) {
        terminal.send(bytes)
    }

    func terminate() {
        terminal.terminate()
    }

    private func recordOutput(_ bytes: ArraySlice<UInt8>) {
        recorder?.append(bytes)
        onOutput()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        recorder?.close()
        onTerminated(exitCode)
    }
}

final class CapturingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?(slice)
        super.dataReceived(slice: slice)
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
