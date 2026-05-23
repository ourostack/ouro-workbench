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
                    Button {
                        model.isNewSessionSheetPresented = true
                    } label: {
                        Label("New Session", systemImage: "plus")
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
            await model.refreshBossDashboard()
        }
        .sheet(isPresented: $model.isNewSessionSheetPresented) {
            NewTerminalSessionSheet(model: model)
        }
        .task {
            await model.runExternalActionPump()
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
        }
        .padding()
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
                SessionControlBar(entry: entry, model: model)
                Divider()
                TerminalPane(session: session)
                    .id(session.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.lastSummary ?? "Configured")
                        .font(.body)
                    Text("Recovery: \(model.recoveryReason(for: entry))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.canRecover(entry) {
                        Button {
                            model.recover(entry)
                        } label: {
                            Label(model.recoveryButtonTitle(for: entry), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let tail = model.transcriptTail(for: entry) {
                        TranscriptHistoryView(tail: tail)
                    }
                }
                .padding()
                Spacer()
            }
        }
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
    private let bossActionParser = BossWorkbenchActionParser()
    private let bossActionAuthorizer = BossWorkbenchActionAuthorizer()
    private let terminationPolicy = ProcessTerminationPolicy()
    private let customSessionFactory = CustomTerminalSessionFactory()
    private let transcriptTailReader = TranscriptTailReader()
    private let externalActionQueue: WorkbenchActionRequestQueue
    private var manuallyTerminatedRunIDs = Set<UUID>()
    private var didAttemptStartupRecovery = false

    init(
        paths: WorkbenchPaths = .defaultPaths(),
        mailboxClient: MailboxClient = MailboxClient(),
        bossMCPClient: BossAgentMCPClient = BossAgentMCPClient()
    ) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.mailboxClient = mailboxClient
        self.bossMCPClient = bossMCPClient
        self.externalActionQueue = WorkbenchActionRequestQueue(paths: paths)
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

    var mailboxStatusLine: String {
        mailboxError ?? "Mailbox status unavailable"
    }

    var bossMCPCommand: String {
        bossBridgePlanner.mcpServePlan(for: state.boss).displayCommand
    }

    var bossAgentChoices: [String] {
        let names = (bossDashboard?.knownAgentNames ?? []) + [state.boss.agentName]
        return Array(Set(names))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func selectBoss(agentName: String) {
        guard !agentName.isEmpty, agentName != state.boss.agentName else {
            return
        }
        state.boss.agentName = agentName
        bossDashboard = nil
        bossCheckInPrompt = nil
        bossCheckInAnswer = nil
        bossAppliedActions = []
        save()
        Task {
            await refreshBossDashboard()
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
            dashboard: bossDashboard
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
            bossAppliedActions = actions.map(applyBossAction)
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
                "External \(request.source): \(applyBossAction(request.action))"
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

    func recover(_ entry: ProcessEntry) {
        guard let plan = recoveryPlan(for: entry) else {
            errorMessage = "No recovery plan is available for \(entry.name)"
            return
        }
        recover(entry, recoveryPlan: plan)
    }

    func launch(_ entry: ProcessEntry) {
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
            if launchAfterCreate {
                launch(entry)
            }
            return entry
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
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

    private func applyBossAction(_ action: BossWorkbenchAction) -> String {
        guard let entry = processEntry(matching: action.entry) else {
            return "Skipped \(action.action.rawValue): no unique process entry matches \(action.entry)"
        }
        let authorization = bossActionAuthorizer.authorize(action, for: entry)
        guard authorization.isAllowed else {
            return "Skipped \(action.action.rawValue) for \(entry.name): \(authorization.reason ?? "not authorized")"
        }

        switch action.action {
        case .launch:
            guard activeSessions[entry.id] == nil else {
                return "Skipped launch for \(entry.name): already running"
            }
            launch(entry)
            return "Launched \(entry.name)"
        case .recover:
            guard canRecover(entry) else {
                return "Skipped recover for \(entry.name): \(recoveryReason(for: entry))"
            }
            recover(entry)
            return "Recovered \(entry.name)"
        case .terminate:
            guard activeSessions[entry.id] != nil else {
                return "Skipped terminate for \(entry.name): not running"
            }
            terminate(entry)
            return "Stopped \(entry.name)"
        case .sendInput:
            guard activeSessions[entry.id] != nil else {
                return "Skipped sendInput for \(entry.name): not running"
            }
            guard let text = action.text, !text.isEmpty else {
                return "Skipped sendInput for \(entry.name): missing text"
            }
            sendInput(text, to: entry, appendNewline: action.appendNewline)
            return "Sent input to \(entry.name)"
        }
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
