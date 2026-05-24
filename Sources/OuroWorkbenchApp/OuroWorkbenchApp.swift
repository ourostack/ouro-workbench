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
            WorkbenchSidebarView(model: model)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HeaderView(summary: model.summary)
                Divider()
                BossDashboardView(model: model)
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
        .task {
            model.recoverEligibleSessionsOnStartup()
            model.launchDefaultShellIfNeeded()
            model.refreshExecutableHealth()
            await model.refreshBossDashboard()
        }
        .sheet(isPresented: $model.isNewSessionSheetPresented) {
            NewTerminalSessionSheet(model: model)
        }
        .sheet(item: $model.editingSession) { entry in
            EditTerminalSessionSheet(model: model, entry: entry)
        }
        .confirmationDialog("Delete Terminal Session?", isPresented: model.deleteConfirmationIsPresented) {
            if let entry = model.pendingDeleteSession {
                Button("Delete \(entry.name)", role: .destructive) {
                    model.deleteCustomSession(entry)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let entry = model.pendingDeleteSession {
                Text("This removes \(entry.name) from the workbench and clears its run records. Transcript files remain on disk.")
            }
        }
        .task {
            await model.runExternalActionPump()
        }
    }
}

struct WorkbenchSidebarView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        List(selection: $model.selectedEntryID) {
            Section("Boss") {
                Label(model.state.boss.agentName, systemImage: "person.crop.circle.badge.checkmark")
            }
            Section("Sessions") {
                ForEach(model.sessionEntries) { entry in
                    TerminalAgentRow(
                        entry: entry,
                        isSelected: model.selectedEntryID == entry.id,
                        health: model.executableHealth(for: entry)
                    )
                        .tag(entry.id)
                }
                Button {
                    model.isNewSessionSheetPresented = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
            if !model.archivedSessionEntries.isEmpty {
                Section("Archived") {
                    ForEach(model.archivedSessionEntries) { entry in
                        TerminalAgentRow(
                            entry: entry,
                            isSelected: model.selectedEntryID == entry.id,
                            health: model.executableHealth(for: entry)
                        )
                            .tag(entry.id)
                    }
                }
            }
            Section("Recovery") {
                Label(model.summary.oneLineStatus, systemImage: "arrow.clockwise.circle")
            }
        }
        .navigationTitle("Ouro Workbench")
    }
}

struct TerminalAgentRow: View {
    var entry: ProcessEntry
    var isSelected: Bool
    var health: ExecutableHealth?

    var body: some View {
        HStack {
            Label(entry.name, systemImage: rowIcon)
            Spacer()
            if let health, health.status != .available {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(health.detail)
            }
            StatusDot(attention: entry.attention)
        }
        .fontWeight(isSelected ? .semibold : .regular)
    }

    private var rowIcon: String {
        if entry.isArchived {
            return "archivebox"
        }
        return entry.kind == .shell ? "apple.terminal" : "terminal"
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

struct BossDashboardView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if model.bossAgentChoices.count > 1 {
                        Picker("Boss", selection: Binding(
                            get: { model.state.boss.agentName },
                            set: { model.selectBoss(agentName: $0) }
                        )) {
                            ForEach(model.bossAgentChoices, id: \.self) { agentName in
                                Text(agentName).tag(agentName)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Text("Boss: \(model.state.boss.agentName)")
                            .font(.headline)
                    }
                    Text(model.bossDashboard?.oneLineStatus ?? model.mailboxStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        model.refreshExecutableHealth()
                        await model.refreshBossDashboard()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    Task {
                        await model.runBossCheckIn()
                    }
                } label: {
                    Label("Check In", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.bossCheckInIsRunning)
            }
            if model.bossCheckInIsRunning {
                ProgressView()
                    .controlSize(.small)
            }
            MachineRuntimeView()
            BossWorkbenchMCPSetupView(model: model)
            if let dashboard = model.bossDashboard {
                if !dashboard.availability.issues.isEmpty {
                    Text("Mailbox warnings: \(dashboard.availability.issues.joined(separator: "; "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 18) {
                    MetricView(label: "daemon", value: dashboard.daemonStatus)
                    MetricView(label: "needs me", value: dashboard.availability.needsMeAvailable ? "\(dashboard.needsMeItems.count)" : "?")
                    MetricView(label: "coding", value: dashboard.availability.codingAvailable ? "\(dashboard.activeCodingAgents)" : "?")
                    MetricView(label: "blocked", value: dashboard.availability.codingAvailable ? "\(dashboard.blockedCodingAgents)" : "?")
                    MetricView(label: "mode", value: dashboard.daemonMode)
                }
                if !dashboard.needsMeItems.isEmpty || !dashboard.codingItems.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Needs Me")
                                .font(.caption.weight(.semibold))
                            ForEach(dashboard.needsMeItems.prefix(3)) { item in
                                Text("\(item.label) - \(item.detail)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Coding")
                                .font(.caption.weight(.semibold))
                            ForEach(dashboard.codingItems.prefix(3)) { item in
                                Text("\(item.runner) - \(item.status) - \(item.workdir)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            if let prompt = model.bossCheckInPrompt {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.bossMCPCommand)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(prompt)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            }
            if let answer = model.bossCheckInAnswer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Boss Reply")
                        .font(.caption.weight(.semibold))
                    Text(answer)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            if !model.bossAppliedActions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Applied Actions")
                        .font(.caption.weight(.semibold))
                    ForEach(model.bossAppliedActions, id: \.self) { result in
                        Text(result)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            ActionLogView(entries: model.recentActionLogEntries)
        }
        .padding()
    }
}

struct ActionLogView: View {
    var entries: [WorkbenchActionLogEntry]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Action Log")
                    .font(.caption.weight(.semibold))
                ForEach(entries.prefix(6)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(entry.succeeded ? .green : .orange)
                        Text(entry.occurredAt.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(entry.source) \(entry.action)")
                            .font(.caption.weight(.semibold))
                        if let targetName = entry.targetName {
                            Text(targetName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(entry.result)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }
}

struct BossWorkbenchMCPSetupView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(spacing: 12) {
            Label("Workbench MCP", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
            Text(model.bossWorkbenchMCPStatusLine)
                .font(.caption.monospaced())
                .foregroundStyle(model.bossWorkbenchMCPStatusColor)
            Button {
                model.refreshWorkbenchMCPRegistration()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Refresh Workbench MCP registration")
            if model.bossWorkbenchMCPRegistration?.isActionable == true {
                Button {
                    model.installWorkbenchMCPForBoss()
                } label: {
                    Label(model.bossWorkbenchMCPActionTitle, systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .task {
            model.refreshWorkbenchMCPRegistration()
        }
    }
}

struct MetricView: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 58, alignment: .leading)
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
                if entry.isArchived {
                    Label("Archived", systemImage: "archivebox")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        model.launch(entry)
                    } label: {
                        Label(model.activeSession(for: entry) == nil ? "Launch" : "Restart", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            if model.isCustomSession(entry) {
                CustomSessionManagementBar(entry: entry, model: model)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            Divider()
            if let session = model.activeSession(for: entry) {
                SessionControlBar(entry: entry, model: model)
                Divider()
                TerminalPane(session: session)
                    .id(session.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    SessionStatusBar(entry: entry, model: model)
                    if let tail = model.transcriptTail(for: entry) {
                        TranscriptHistoryView(tail: tail)
                    }
                    InactiveTerminalSurface(entry: entry, model: model)
                }
                .padding()
                Spacer()
            }
        }
    }
}

struct SessionStatusBar: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.isArchived ? "Archived" : (entry.lastSummary ?? "Configured"))
                .font(.body)
            Text(entry.isArchived ? "Restore this session before launching it." : "Recovery: \(model.recoveryReason(for: entry))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !entry.isArchived, let health = model.executableHealth(for: entry) {
                Text("Executable: \(health.detail)")
                    .font(.caption)
                    .foregroundStyle(health.status == .available ? SwiftUI.Color.secondary : SwiftUI.Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if entry.isArchived {
                Button {
                    model.restoreCustomSession(entry)
                } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
                .buttonStyle(.bordered)
            } else if model.canRecover(entry) {
                Button {
                    model.recover(entry)
                } label: {
                    Label(model.recoveryButtonTitle(for: entry), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct CustomSessionManagementBar: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.beginEditingSession(entry)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(isRunning)
            .help(isRunning ? "Stop this session before editing it" : "Edit saved session settings")

            Button {
                model.duplicateCustomSession(entry)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            if entry.isArchived {
                Button {
                    model.restoreCustomSession(entry)
                } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button {
                    model.archiveCustomSession(entry)
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(isRunning)
                .help(isRunning ? "Stop this session before archiving it" : "Archive this session")
            }

            Button(role: .destructive) {
                model.requestDeleteCustomSession(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isRunning)
            .help(isRunning ? "Stop this session before deleting it" : "Delete this saved session")

            Spacer()
        }
        .controlSize(.small)
    }

    private var isRunning: Bool {
        model.activeSession(for: entry) != nil
    }
}

struct InactiveTerminalSurface: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("$ \(model.launchCommand(for: entry))")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(entry.isArchived ? SwiftUI.Color.secondary : SwiftUI.Color.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if entry.isArchived {
                    Button {
                        model.restoreCustomSession(entry)
                    } label: {
                        Label("Restore", systemImage: "tray.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        if model.canRecover(entry) {
                            model.recover(entry)
                        } else {
                            model.launch(entry)
                        }
                    } label: {
                        Label(model.canRecover(entry) ? model.recoveryButtonTitle(for: entry) : "Launch", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
            Text(entry.isArchived ? "archived" : "ready")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SessionControlBar: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    @State private var pendingInput = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Send input to \(entry.name)", text: $pendingInput)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(sendLine)
            Button {
                sendLine()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .disabled(pendingInput.isEmpty)
            Button {
                model.sendControlC(to: entry)
            } label: {
                Label("Ctrl-C", systemImage: "command")
            }
            Button {
                model.sendEscape(to: entry)
            } label: {
                Label("Esc", systemImage: "escape")
            }
            Button(role: .destructive) {
                model.terminate(entry)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        .padding()
    }

    private func sendLine() {
        guard !pendingInput.isEmpty else {
            return
        }
        model.sendInput(pendingInput, to: entry, appendNewline: true)
        pendingInput = ""
    }
}

struct TranscriptHistoryView: View {
    var tail: TranscriptTail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Latest Transcript")
                    .font(.caption.weight(.semibold))
                if tail.truncated {
                    Text("tail")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(tail.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ScrollView {
                Text(tail.text.isEmpty ? "No transcript output yet" : tail.text)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        }
    }
}

struct NewTerminalSessionSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""
    @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var trusted = true
    @State private var autoResume = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Terminal Session")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                    .font(.body.monospaced())
                HStack {
                    TextField("Working Directory", text: $workingDirectory)
                        .font(.body.monospaced())
                    Button {
                        chooseWorkingDirectory()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
                Toggle("Trusted", isOn: $trusted)
                Toggle("Auto Resume", isOn: $autoResume)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    create(launchAfterCreate: false)
                } label: {
                    Label("Create", systemImage: "checkmark")
                }
                .disabled(!canCreate)
                Button {
                    create(launchAfterCreate: true)
                } label: {
                    Label("Create & Launch", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding()
        .frame(width: 560)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create(launchAfterCreate: Bool) {
        let draft = CustomTerminalSessionDraft(
            name: name,
            command: command,
            workingDirectory: workingDirectory,
            trust: trusted ? .trusted : .untrusted,
            autoResume: autoResume
        )
        guard model.createCustomSession(draft, launchAfterCreate: launchAfterCreate) != nil else {
            return
        }
        dismiss()
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
}

struct EditTerminalSessionSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    let entry: ProcessEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var workingDirectory: String
    @State private var trusted: Bool
    @State private var autoResume: Bool

    init(model: WorkbenchViewModel, entry: ProcessEntry) {
        self.model = model
        self.entry = entry
        let draft = model.customSessionDraft(for: entry) ?? CustomTerminalSessionDraft(
            name: entry.name,
            command: "",
            workingDirectory: entry.workingDirectory,
            trust: entry.trust,
            autoResume: entry.autoResume
        )
        _name = State(initialValue: draft.name)
        _command = State(initialValue: draft.command)
        _workingDirectory = State(initialValue: draft.workingDirectory)
        _trusted = State(initialValue: draft.trust == .trusted)
        _autoResume = State(initialValue: draft.autoResume)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Terminal Session")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                    .font(.body.monospaced())
                HStack {
                    TextField("Working Directory", text: $workingDirectory)
                        .font(.body.monospaced())
                    Button {
                        chooseWorkingDirectory()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
                Toggle("Trusted", isOn: $trusted)
                Toggle("Auto Resume", isOn: $autoResume)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 560)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let draft = CustomTerminalSessionDraft(
            name: name,
            command: command,
            workingDirectory: workingDirectory,
            trust: trusted ? .trusted : .untrusted,
            autoResume: autoResume
        )
        guard model.updateCustomSession(entry, draft: draft) else {
            return
        }
        dismiss()
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }
}

struct MachineRuntimeView: View {
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Label("Native Runtime", systemImage: "macwindow")
                    .font(.caption.weight(.semibold))
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(loginItem.isUpdating)
                Text(loginItem.statusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    loginItem.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh login item status")
            }
            if let lastError = loginItem.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LaunchAgentLoginItemStatus
    @Published private(set) var isUpdating = false
    @Published var lastError: String?

    private let loginItem: LaunchAgentLoginItem

    init() {
        self.loginItem = LaunchAgentLoginItem(appURL: LaunchAgentLoginItem.defaultAppURL())
        self.status = loginItem.status()
    }

    var isEnabled: Bool {
        status == .enabled
    }

    var statusLine: String {
        switch status {
        case .enabled:
            return "enabled"
        case .notInstalled:
            return "not registered"
        case .appBundleMissing:
            return "install app first"
        }
    }

    func refresh() {
        status = loginItem.status()
    }

    func setEnabled(_ enabled: Bool) {
        isUpdating = true
        defer {
            refresh()
            isUpdating = false
        }

        do {
            if enabled {
                try registerIfNeeded()
            } else {
                try unregisterIfNeeded()
            }
            lastError = nil
        } catch {
            lastError = "Open at Login update failed: \(error.localizedDescription)"
        }
    }

    private func registerIfNeeded() throws {
        guard status != .enabled else {
            return
        }
        try loginItem.install()
    }

    private func unregisterIfNeeded() throws {
        switch status {
        case .enabled:
            try loginItem.uninstall()
        case .notInstalled, .appBundleMissing:
            return
        }
    }
}

@MainActor
final class WorkbenchViewModel: ObservableObject {
    @Published var state: WorkspaceState
    @Published var selectedEntryID: UUID?
    @Published var activeSessions: [UUID: TerminalSessionController] = [:]
    @Published var errorMessage: String?
    @Published var bossDashboard: BossDashboardSnapshot?
    @Published var bossCheckInPrompt: String?
    @Published var bossCheckInAnswer: String?
    @Published var bossCheckInIsRunning = false
    @Published var bossAppliedActions: [String] = []
    @Published var mailboxError: String?
    @Published var isNewSessionSheetPresented = false
    @Published var editingSession: ProcessEntry?
    @Published var pendingDeleteSession: ProcessEntry?
    @Published var bossWorkbenchMCPRegistration: BossWorkbenchMCPRegistrationSnapshot?
    @Published var executableHealthByEntryID: [UUID: ExecutableHealth] = [:]

    private let paths: WorkbenchPaths
    private let store: WorkbenchStore
    private let bootstrapper = WorkbenchBootstrapper()
    private let startupRecoveryReconciler = StartupRecoveryReconciler()
    private let summarizer = WorkspaceSummarizer()
    private let mailboxClient: MailboxClient
    private let bossDashboardBuilder = BossDashboardBuilder()
    private let bossBridgePlanner = BossAgentBridgePlanner()
    private let bossPromptBuilder = BossAgentPromptBuilder()
    private let bossMCPClient: BossAgentMCPClient
    private let bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar
    private let executableHealthChecker: ExecutableHealthChecker
    private let bossActionParser = BossWorkbenchActionParser()
    private let bossActionAuthorizer = BossWorkbenchActionAuthorizer()
    private let terminationPolicy = ProcessTerminationPolicy()
    private let customSessionFactory = CustomTerminalSessionFactory()
    private let customSessionManager = CustomTerminalSessionManager()
    private let transcriptTailReader = TranscriptTailReader()
    private let externalActionQueue: WorkbenchActionRequestQueue
    private var manuallyTerminatedRunIDs = Set<UUID>()
    private var didAttemptStartupRecovery = false
    private var didAttemptDefaultShellLaunch = false

    init(
        paths: WorkbenchPaths = .defaultPaths(),
        mailboxClient: MailboxClient = MailboxClient(),
        bossMCPClient: BossAgentMCPClient = BossAgentMCPClient(),
        bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar = BossWorkbenchMCPRegistrar(),
        executableHealthChecker: ExecutableHealthChecker = ExecutableHealthChecker()
    ) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.mailboxClient = mailboxClient
        self.bossMCPClient = bossMCPClient
        self.bossWorkbenchMCPRegistrar = bossWorkbenchMCPRegistrar
        self.executableHealthChecker = executableHealthChecker
        self.externalActionQueue = WorkbenchActionRequestQueue(paths: paths)
        self.state = WorkspaceState()
        load()
        refreshWorkbenchMCPRegistration()
        refreshExecutableHealth()
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

    var deleteConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { self.pendingDeleteSession != nil },
            set: { newValue in
                if !newValue {
                    self.pendingDeleteSession = nil
                }
            }
        )
    }

    var sessionEntries: [ProcessEntry] {
        allSessionEntries.filter { !$0.isArchived }
    }

    var archivedSessionEntries: [ProcessEntry] {
        allSessionEntries.filter(\.isArchived)
    }

    private var allSessionEntries: [ProcessEntry] {
        state.processEntries.filter { $0.kind == .terminalAgent || $0.kind == .shell }
    }

    var selectedEntry: ProcessEntry? {
        guard let selectedEntryID else {
            return sessionEntries.first
        }
        return state.processEntries.first { $0.id == selectedEntryID }
    }

    var summary: WorkspaceSummary {
        summarizer.summarize(state)
    }

    var mailboxStatusLine: String {
        mailboxError ?? "Mailbox status unavailable"
    }

    var bossMCPCommand: String {
        bossBridgePlanner.mcpServePlan(for: state.boss).displayCommand
    }

    var recentActionLogEntries: [WorkbenchActionLogEntry] {
        state.actionLog.sorted { $0.occurredAt > $1.occurredAt }
    }

    func executableHealth(for entry: ProcessEntry) -> ExecutableHealth? {
        executableHealthByEntryID[entry.id]
    }

    var bossWorkbenchMCPStatusLine: String {
        guard let bossWorkbenchMCPRegistration else {
            return "unknown"
        }
        switch bossWorkbenchMCPRegistration.status {
        case .registered:
            return "registered for \(bossWorkbenchMCPRegistration.agentName)"
        case .notRegistered:
            return "not registered"
        case .needsUpdate:
            return "update needed"
        case .agentMissing:
            return "agent bundle missing"
        case .executableMissing:
            return "install app first"
        case .invalidConfig:
            return "config issue"
        }
    }

    var bossWorkbenchMCPStatusColor: SwiftUI.Color {
        guard let status = bossWorkbenchMCPRegistration?.status else {
            return .secondary
        }
        switch status {
        case .registered:
            return .green
        case .notRegistered, .needsUpdate:
            return .orange
        case .agentMissing, .executableMissing, .invalidConfig:
            return .red
        }
    }

    var bossWorkbenchMCPActionTitle: String {
        bossWorkbenchMCPRegistration?.status == .needsUpdate ? "Update" : "Install"
    }

    var bossAgentChoices: [String] {
        let names = (bossDashboard?.knownAgentNames ?? []) + [state.boss.agentName]
        return Array(Set(names))
            .filter { !$0.isEmpty }
            .filter(BossWorkbenchMCPRegistrar.isValidAgentBundleName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func selectBoss(agentName: String) {
        guard !agentName.isEmpty, agentName != state.boss.agentName else {
            return
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(agentName) else {
            errorMessage = "Boss agent name cannot be used as a bundle name: \(agentName)"
            return
        }
        state.boss.agentName = agentName
        bossDashboard = nil
        bossCheckInPrompt = nil
        bossCheckInAnswer = nil
        bossAppliedActions = []
        save()
        refreshWorkbenchMCPRegistration()
        Task {
            await refreshBossDashboard()
        }
    }

    func refreshWorkbenchMCPRegistration() {
        bossWorkbenchMCPRegistration = bossWorkbenchMCPRegistrar.snapshot(for: state.boss)
    }

    func refreshExecutableHealth() {
        executableHealthByEntryID = Dictionary(
            uniqueKeysWithValues: allSessionEntries.map { entry in
                (entry.id, executableHealthChecker.health(for: entry.executable))
            }
        )
    }

    func installWorkbenchMCPForBoss() {
        do {
            bossWorkbenchMCPRegistration = try bossWorkbenchMCPRegistrar.install(for: state.boss)
            let result = "Registered Workbench MCP for \(state.boss.agentName)"
            bossAppliedActions = [result] + bossAppliedActions
            recordActionLog(
                source: "native",
                action: "registerWorkbenchMCP",
                targetName: state.boss.agentName,
                result: result,
                succeeded: true
            )
        } catch {
            errorMessage = "Workbench MCP registration failed: \(error.localizedDescription)"
            refreshWorkbenchMCPRegistration()
        }
    }

    func launchCommand(for entry: ProcessEntry) -> String {
        do {
            return try WorkbenchCommandPlanner(paths: paths).launchPlan(for: entry).displayCommand
        } catch {
            return entry.executable
        }
    }

    func recoveryReason(for entry: ProcessEntry) -> String {
        recoveryPlan(for: entry)?.reason ?? "no action"
    }

    func recoveryPlan(for entry: ProcessEntry) -> RecoveryPlan? {
        summary.recoveryPlans.first { $0.entryId == entry.id }
    }

    func canRecover(_ entry: ProcessEntry) -> Bool {
        guard !entry.isArchived else {
            return false
        }
        guard let plan = recoveryPlan(for: entry) else {
            return false
        }
        return plan.action == .autoResume || plan.action == .respawn
    }

    func recoveryButtonTitle(for entry: ProcessEntry) -> String {
        guard let plan = recoveryPlan(for: entry) else {
            return "Recover"
        }
        switch plan.action {
        case .autoResume:
            return "Resume"
        case .respawn:
            return "Respawn"
        case .manualActionNeeded:
            return "Manual Recovery"
        case .noAction:
            return "Recover"
        }
    }

    func activeSession(for entry: ProcessEntry) -> TerminalSessionController? {
        activeSessions[entry.id]
    }

    func latestRun(for entry: ProcessEntry) -> ProcessRun? {
        state.processRuns
            .filter { $0.entryId == entry.id }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }

    func transcriptTail(for entry: ProcessEntry) -> TranscriptTail? {
        transcriptTailReader.read(path: latestRun(for: entry)?.transcriptPath)
    }

    func refreshBossDashboard() async {
        async let machineResult = fetchResult(.machine, as: MailboxMachineView.self, label: "machine")
        async let needsMeResult = fetchResult(.needsMe(state.boss.agentName), as: MailboxNeedsMeView.self, label: "needs-me")
        async let codingResult = fetchResult(.coding(state.boss.agentName), as: MailboxCodingSummary.self, label: "coding")

        let (machine, needsMe, coding) = await (machineResult, needsMeResult, codingResult)
        let issues = [machine.issue, needsMe.issue, coding.issue].compactMap(\.self)

        let snapshot = bossDashboardBuilder.build(
            boss: state.boss,
            machine: machine.value,
            needsMe: needsMe.value,
            coding: coding.value,
            availability: BossDashboardAvailability(
                machineAvailable: machine.issue == nil,
                needsMeAvailable: needsMe.issue == nil,
                codingAvailable: coding.issue == nil,
                issues: issues
            )
        )
        bossDashboard = snapshot
        mailboxError = issues.isEmpty ? nil : "Mailbox warnings: \(issues.joined(separator: "; "))"
    }

    func prepareBossCheckIn() {
        let question = bossBridgePlanner.checkInQuestion()
        bossCheckInPrompt = bossPromptBuilder.checkInPrompt(
            question: question,
            state: state,
            summary: summary,
            dashboard: bossDashboard,
            executableHealth: executableHealthByEntryID
        )
    }

    func runBossCheckIn() async {
        guard !bossCheckInIsRunning else {
            return
        }
        let requestedBoss = state.boss.agentName
        bossCheckInIsRunning = true
        bossCheckInAnswer = nil
        defer {
            bossCheckInIsRunning = false
        }
        refreshExecutableHealth()
        await refreshBossDashboard()
        guard state.boss.agentName == requestedBoss else {
            return
        }
        prepareBossCheckIn()
        guard let bossCheckInPrompt else {
            return
        }
        do {
            let answer = try await bossMCPClient.ask(
                agentName: requestedBoss,
                question: bossCheckInPrompt
            )
            guard state.boss.agentName == requestedBoss else {
                return
            }
            bossCheckInAnswer = answer
            applyBossActions(from: answer)
        } catch {
            bossCheckInAnswer = "Check-in failed: \(error)"
            bossAppliedActions = []
        }
    }

    func applyBossActions(from answer: String) {
        do {
            let actions = try bossActionParser.parse(answer)
            bossAppliedActions = actions.map { action in
                applyBossAction(action, source: "boss:\(state.boss.agentName)")
            }
        } catch {
            bossAppliedActions = ["Failed to parse boss actions: \(error)"]
        }
    }

    func runExternalActionPump() async {
        while !Task.isCancelled {
            drainExternalActionRequests()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func drainExternalActionRequests() {
        do {
            let requests = try externalActionQueue.drain()
            guard !requests.isEmpty else {
                return
            }
            let results = requests.map { request in
                "External \(request.source): \(applyBossAction(request.action, source: "external:\(request.source)"))"
            }
            bossAppliedActions = Array((results + bossAppliedActions).prefix(12))
        } catch {
            errorMessage = "External Workbench action queue failed: \(error.localizedDescription)"
        }
    }

    func recoverEligibleSessionsOnStartup() {
        guard !didAttemptStartupRecovery else {
            return
        }
        didAttemptStartupRecovery = true
        for plan in summary.recoveryPlans where plan.action == .autoResume || plan.action == .respawn {
            guard let entry = state.processEntries.first(where: { $0.id == plan.entryId }) else {
                continue
            }
            recover(entry, recoveryPlan: plan)
        }
    }

    func launchDefaultShellIfNeeded() {
        guard !didAttemptDefaultShellLaunch else {
            return
        }
        didAttemptDefaultShellLaunch = true
        guard activeSessions.isEmpty else {
            return
        }
        guard let shell = state.processEntries.first(where: BuiltInWorkbenchSessions.isAutoLaunchableLocalShell) else {
            return
        }
        selectedEntryID = shell.id
        guard activeSessions[shell.id] == nil else {
            return
        }
        if let latestRun = latestRun(for: shell),
           latestRun.status == .needsRecovery || latestRun.status == .manualActionNeeded {
            return
        }
        launch(shell)
    }

    func recover(_ entry: ProcessEntry) {
        guard !entry.isArchived else {
            errorMessage = "\(entry.name) is archived. Restore it before recovery."
            return
        }
        guard let plan = recoveryPlan(for: entry) else {
            errorMessage = "No recovery plan is available for \(entry.name)"
            return
        }
        recover(entry, recoveryPlan: plan)
    }

    func launch(_ entry: ProcessEntry) {
        guard !entry.isArchived else {
            errorMessage = "\(entry.name) is archived. Restore it before launching."
            return
        }
        do {
            let plan = try WorkbenchCommandPlanner(paths: paths).launchPlan(for: entry)
            start(entry, with: plan)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func sendInput(_ text: String, to entry: ProcessEntry, appendNewline: Bool) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendInput(appendNewline ? "\(text)\n" : text)
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent input to \(entry.name)"
        }
        save()
    }

    func sendControlC(to entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendBytes([0x03])
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent Ctrl-C to \(entry.name)"
        }
        save()
    }

    func sendEscape(to entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendBytes([0x1b])
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent Esc to \(entry.name)"
        }
        save()
    }

    func terminate(_ entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        manuallyTerminatedRunIDs.insert(session.plan.runId)
        session.terminate()
    }

    @discardableResult
    func createCustomSession(_ draft: CustomTerminalSessionDraft, launchAfterCreate: Bool) -> ProcessEntry? {
        do {
            if state.projects.isEmpty {
                state = bootstrapper.bootstrappedState(from: state)
            }
            guard let project = state.projects.first else {
                errorMessage = "No workbench project is available"
                return nil
            }
            let entry = try customSessionFactory.makeEntry(projectId: project.id, draft: draft)
            state.processEntries.append(entry)
            selectedEntryID = entry.id
            save()
            refreshExecutableHealth()
            if launchAfterCreate {
                launch(entry)
            }
            return entry
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func isCustomSession(_ entry: ProcessEntry) -> Bool {
        customSessionManager.isCustomSession(entry)
    }

    func customSessionDraft(for entry: ProcessEntry) -> CustomTerminalSessionDraft? {
        try? customSessionManager.draft(from: entry)
    }

    func beginEditingSession(_ entry: ProcessEntry) {
        guard customSessionManager.isCustomSession(entry) else {
            errorMessage = "\(entry.name) is not a custom session"
            return
        }
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before editing it"
            return
        }
        editingSession = entry
    }

    @discardableResult
    func updateCustomSession(_ entry: ProcessEntry, draft: CustomTerminalSessionDraft) -> Bool {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before editing it"
            return false
        }
        do {
            let updated = try customSessionManager.updatedEntry(entry, draft: draft)
            replaceEntry(updated)
            selectedEntryID = updated.id
            recordActionLog(
                source: "native",
                action: "editSession",
                targetEntryId: updated.id,
                targetName: updated.name,
                result: "Edited \(updated.name)",
                succeeded: true
            )
            refreshExecutableHealth()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func duplicateCustomSession(_ entry: ProcessEntry) -> ProcessEntry? {
        do {
            let duplicate = try customSessionManager.duplicateEntry(
                entry,
                name: uniqueCopyName(for: entry.name)
            )
            state.processEntries.append(duplicate)
            selectedEntryID = duplicate.id
            recordActionLog(
                source: "native",
                action: "duplicateSession",
                targetEntryId: duplicate.id,
                targetName: duplicate.name,
                result: "Duplicated \(entry.name) as \(duplicate.name)",
                succeeded: true
            )
            refreshExecutableHealth()
            return duplicate
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func archiveCustomSession(_ entry: ProcessEntry) {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before archiving it"
            return
        }
        do {
            let archived = try customSessionManager.archivedEntry(entry)
            replaceEntry(archived)
            selectedEntryID = archived.id
            recordActionLog(
                source: "native",
                action: "archiveSession",
                targetEntryId: archived.id,
                targetName: archived.name,
                result: "Archived \(archived.name)",
                succeeded: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreCustomSession(_ entry: ProcessEntry) {
        do {
            let restored = try customSessionManager.restoredEntry(entry)
            replaceEntry(restored)
            selectedEntryID = restored.id
            recordActionLog(
                source: "native",
                action: "restoreSession",
                targetEntryId: restored.id,
                targetName: restored.name,
                result: "Restored \(restored.name)",
                succeeded: true
            )
            refreshExecutableHealth()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestDeleteCustomSession(_ entry: ProcessEntry) {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before deleting it"
            return
        }
        guard customSessionManager.isCustomSession(entry) else {
            errorMessage = "\(entry.name) is not a custom session"
            return
        }
        pendingDeleteSession = entry
    }

    func deleteCustomSession(_ entry: ProcessEntry) {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before deleting it"
            return
        }
        guard customSessionManager.isCustomSession(entry) else {
            errorMessage = "\(entry.name) is not a custom session"
            return
        }
        state.processEntries.removeAll { $0.id == entry.id }
        state.processRuns.removeAll { $0.entryId == entry.id }
        pendingDeleteSession = nil
        if selectedEntryID == entry.id {
            selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
        }
        recordActionLog(
            source: "native",
            action: "deleteSession",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Deleted \(entry.name)",
            succeeded: true
        )
        refreshExecutableHealth()
    }

    private func recover(_ entry: ProcessEntry, recoveryPlan: RecoveryPlan) {
        do {
            guard recoveryPlan.action == .autoResume || recoveryPlan.action == .respawn else {
                errorMessage = "\(entry.name) is not eligible for automatic recovery: \(recoveryPlan.reason)"
                return
            }
            let latestRun = state.processRuns
                .filter { $0.entryId == entry.id }
                .sorted { $0.startedAt > $1.startedAt }
                .first
            let plan = try WorkbenchCommandPlanner(paths: paths).recoveryPlan(
                for: entry,
                latestRun: latestRun,
                action: recoveryPlan.action
            )
            start(entry, with: plan)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func applyBossAction(_ action: BossWorkbenchAction, source: String) -> String {
        guard let entry = processEntry(matching: action.entry) else {
            return finishBossAction(
                source: source,
                action: action,
                entry: nil,
                result: "Skipped \(action.action.rawValue): no unique process entry matches \(action.entry)"
            )
        }
        let authorization = bossActionAuthorizer.authorize(action, for: entry)
        guard authorization.isAllowed else {
            return finishBossAction(
                source: source,
                action: action,
                entry: entry,
                result: "Skipped \(action.action.rawValue) for \(entry.name): \(authorization.reason ?? "not authorized")"
            )
        }

        switch action.action {
        case .launch:
            guard activeSessions[entry.id] == nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped launch for \(entry.name): already running")
            }
            launch(entry)
            return finishBossAction(source: source, action: action, entry: entry, result: "Launched \(entry.name)")
        case .recover:
            guard canRecover(entry) else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped recover for \(entry.name): \(recoveryReason(for: entry))")
            }
            recover(entry)
            return finishBossAction(source: source, action: action, entry: entry, result: "Recovered \(entry.name)")
        case .terminate:
            guard activeSessions[entry.id] != nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped terminate for \(entry.name): not running")
            }
            terminate(entry)
            return finishBossAction(source: source, action: action, entry: entry, result: "Stopped \(entry.name)")
        case .sendInput:
            guard activeSessions[entry.id] != nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped sendInput for \(entry.name): not running")
            }
            guard let text = action.text, !text.isEmpty else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped sendInput for \(entry.name): missing text")
            }
            sendInput(text, to: entry, appendNewline: action.appendNewline)
            return finishBossAction(source: source, action: action, entry: entry, result: "Sent input to \(entry.name)")
        }
    }

    private func finishBossAction(
        source: String,
        action: BossWorkbenchAction,
        entry: ProcessEntry?,
        result: String
    ) -> String {
        recordActionLog(
            source: source,
            action: action.action.rawValue,
            targetEntryId: entry?.id,
            targetName: entry?.name ?? action.entry,
            result: result,
            succeeded: !result.hasPrefix("Skipped") && !result.hasPrefix("Failed")
        )
        return result
    }

    private func recordActionLog(
        source: String,
        action: String,
        targetEntryId: UUID? = nil,
        targetName: String? = nil,
        result: String,
        succeeded: Bool
    ) {
        state.actionLog.insert(
            WorkbenchActionLogEntry(
                source: source,
                action: action,
                targetEntryId: targetEntryId,
                targetName: targetName,
                result: result,
                succeeded: succeeded
            ),
            at: 0
        )
        if state.actionLog.count > 200 {
            state.actionLog.removeLast(state.actionLog.count - 200)
        }
        save()
    }

    private func processEntry(matching value: String) -> ProcessEntry? {
        if let id = UUID(uuidString: value), let entry = state.processEntries.first(where: { $0.id == id }) {
            return entry
        }
        let nameMatches = state.processEntries.filter { entry in
            entry.name.caseInsensitiveCompare(value) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func start(_ entry: ProcessEntry, with plan: TerminalCommandPlan) {
        do {
            if let existingSession = activeSessions[entry.id] {
                manuallyTerminatedRunIDs.insert(existingSession.plan.runId)
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
            entry.lastSummary = plan.reason
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
        let currentPlan = activeSessions[entryId]?.plan
        let isCurrentSession = currentPlan?.runId == runId
        let manuallyTerminated = manuallyTerminatedRunIDs.remove(runId) != nil
        let nextRunStatus = terminationPolicy.statusAfterTermination(
            recoveryAction: isCurrentSession ? currentPlan?.recoveryAction : nil,
            manuallyTerminated: manuallyTerminated
        )
        if isCurrentSession {
            activeSessions[entryId] = nil
            updateEntry(entryId) { entry in
                entry.attention = nextRunStatus == .manualActionNeeded ? .needsBossReview : .idle
                if nextRunStatus == .manualActionNeeded {
                    entry.lastSummary = "\(entry.name) recovery attempt exited with code \(status.exitCode.map(String.init) ?? "unknown")"
                } else {
                    entry.lastSummary = "\(entry.name) exited with code \(status.exitCode.map(String.init) ?? "unknown")"
                }
            }
        }
        if let runIndex = state.processRuns.firstIndex(where: { $0.id == runId && $0.entryId == entryId }) {
            state.processRuns[runIndex].status = nextRunStatus
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
            selectedEntryID = sessionEntries.first?.id
            try store.save(state)
        } catch {
            errorMessage = String(describing: error)
            state = bootstrapper.bootstrappedState(from: WorkspaceState())
            selectedEntryID = sessionEntries.first?.id
        }
    }

    private func updateEntry(_ entryId: UUID, mutate: (inout ProcessEntry) -> Void) {
        guard let index = state.processEntries.firstIndex(where: { $0.id == entryId }) else {
            return
        }
        mutate(&state.processEntries[index])
    }

    private func replaceEntry(_ entry: ProcessEntry) {
        guard let index = state.processEntries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        state.processEntries[index] = entry
    }

    private func uniqueCopyName(for name: String) -> String {
        let baseName = "Copy of \(name)"
        let existingNames = Set(state.processEntries.map(\.name))
        guard existingNames.contains(baseName) else {
            return baseName
        }
        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    private func save() {
        do {
            try store.save(state)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func fetchResult<T: Decodable & Sendable>(
        _ endpoint: MailboxEndpoint,
        as type: T.Type,
        label: String
    ) async -> MailboxFetchResult<T> {
        do {
            let value = try await mailboxClient.fetch(endpoint, as: type)
            return MailboxFetchResult(value: value, issue: nil)
        } catch {
            return MailboxFetchResult(value: nil, issue: "\(label): \(error)")
        }
    }
}

private struct MailboxFetchResult<Value: Sendable>: Sendable {
    var value: Value?
    var issue: String?
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
