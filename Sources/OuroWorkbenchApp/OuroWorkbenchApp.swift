#if os(macOS)
import AppKit
import OuroWorkbenchCore
import SwiftTerm
import SwiftUI

@main
struct OuroWorkbenchApp: App {
    var body: some Scene {
        WindowGroup("") {
            WorkbenchRootView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct WorkbenchRootView: View {
    @StateObject private var model = WorkbenchViewModel()

    var body: some View {
        Group {
            if let entry = model.terminalFocusEntry,
               let session = model.activeSession(for: entry) {
                TerminalFocusView(entry: entry, session: session, model: model)
            } else {
                NavigationSplitView {
                    WorkbenchSidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
                } detail: {
                    VStack(alignment: .leading, spacing: 0) {
                        HeaderView(model: model)
                        Divider()
                        if !model.state.bossPaneCollapsed {
                            BossDashboardView(model: model)
                            Divider()
                        }
                        if let entry = model.selectedEntry {
                            SessionDetailView(entry: entry, model: model)
                        } else {
                            ContentUnavailableView("No session selected", systemImage: "terminal")
                        }
                    }
                }
            }
        }
        .background(WindowChromeConfigurator())
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
            if model.bossWatchIsEnabled {
                await model.runBossWatchTick(force: true)
            }
        }
        .sheet(isPresented: $model.isNewSessionSheetPresented) {
            NewTerminalSessionSheet(model: model)
        }
        .sheet(isPresented: $model.isNewGroupSheetPresented) {
            NewTerminalGroupSheet(model: model)
        }
        .sheet(item: $model.editingGroup) { project in
            EditTerminalGroupSheet(model: model, project: project)
        }
        .sheet(item: $model.editingSession) { entry in
            EditTerminalSessionSheet(model: model, entry: entry)
        }
        .sheet(isPresented: $model.isCommandPalettePresented) {
            CommandPaletteSheet(model: model)
        }
        .sheet(isPresented: $model.isOuroAgentInstallSheetPresented) {
            OuroAgentInstallSheet(model: model)
        }
        .confirmationDialog("Delete Terminal?", isPresented: model.deleteConfirmationIsPresented) {
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
        .confirmationDialog("Delete Terminal Group?", isPresented: model.deleteGroupConfirmationIsPresented) {
            if let project = model.pendingDeleteGroup {
                Button("Delete \(project.name)", role: .destructive) {
                    model.deleteGroup(project)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let project = model.pendingDeleteGroup {
                Text("This removes the empty group \(project.name). Groups with terminals cannot be deleted.")
            }
        }
        .task {
            await model.runExternalActionPump()
        }
        .task {
            await model.runBossWatchLoop()
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else {
            return
        }
        window.title = ""
        window.subtitle = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }
}

struct WorkbenchSidebarView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        List(selection: $model.selectedEntryID) {
            Section("Groups") {
                ForEach(model.state.projects) { project in
                    HStack(spacing: 6) {
                        Button {
                            model.selectProject(project.id)
                        } label: {
                            Label(project.name, systemImage: model.selectedProject?.id == project.id ? "folder.fill" : "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .fontWeight(model.selectedProject?.id == project.id ? .semibold : .regular)
                        Spacer()
                        Text("\(model.terminalCount(in: project))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Menu {
                            Button {
                                model.beginEditingGroup(project)
                            } label: {
                                Label("Rename Group", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                model.requestDeleteGroup(project)
                            } label: {
                                Label("Delete Empty Group", systemImage: "trash")
                            }
                            .disabled(model.totalTerminalCount(in: project) > 0 || model.state.projects.count <= 1)
                        } label: {
                            Label("Group Actions", systemImage: "ellipsis.circle")
                        }
                        .labelStyle(.iconOnly)
                        .menuStyle(.borderlessButton)
                        .help("Group actions")
                    }
                    .help(project.rootPath)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(project.name), \(model.terminalCount(in: project)) active terminals, root \(project.rootPath)")
                }
                Button {
                    model.isNewGroupSheetPresented = true
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
            }
            Section(model.selectedProject?.name ?? "Terminals") {
                ForEach(model.sessionEntries) { entry in
                    TerminalAgentRow(
                        entry: entry,
                        isSelected: model.selectedEntryID == entry.id,
                        cliName: model.cliName(for: entry),
                        health: model.executableHealth(for: entry)
                    )
                        .tag(entry.id)
                }
                Button {
                    model.isNewSessionSheetPresented = true
                } label: {
                    Label("New Terminal", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            if !model.archivedSessionEntries.isEmpty {
                Section("Archived") {
                    ForEach(model.archivedSessionEntries) { entry in
                        TerminalAgentRow(
                            entry: entry,
                            isSelected: model.selectedEntryID == entry.id,
                            cliName: model.cliName(for: entry),
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
        .padding(.top, 28)
    }
}

struct TerminalAgentRow: View {
    var entry: ProcessEntry
    var isSelected: Bool
    var cliName: String?
    var health: ExecutableHealth?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Label(entry.name, systemImage: rowIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cliName {
                    Text(cliName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let health, health.status != .available {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(health.detail)
            }
            StatusDot(attention: entry.attention)
        }
        .fontWeight(isSelected ? .semibold : .regular)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var rowIcon: String {
        if entry.isArchived {
            return "archivebox"
        }
        return entry.kind == .shell ? "apple.terminal" : "terminal"
    }

    private var accessibilityLabel: String {
        var pieces = [entry.name]
        if let cliName {
            pieces.append(cliName)
        }
        pieces.append(entry.attention.rawValue)
        pieces.append(entry.isArchived ? "archived" : "active")
        if let health, health.status != .available {
            pieces.append(health.detail)
        }
        return pieces.joined(separator: ", ")
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
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                BossSelectorView(model: model)
                Text(model.summary.oneLineStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Button {
                model.setBossPaneCollapsed(!model.state.bossPaneCollapsed)
            } label: {
                Label(model.state.bossPaneCollapsed ? "Show Boss Pane" : "Hide Boss Pane", systemImage: model.state.bossPaneCollapsed ? "rectangle.topthird.inset.filled" : "rectangle.bottomthird.inset.filled")
            }
            .labelStyle(.iconOnly)
            .help(model.state.bossPaneCollapsed ? "Show boss dashboard pane" : "Collapse boss dashboard pane")
            .fixedSize()
            AutonomyStatusButton(model: model)
                .fixedSize()
            Button {
                model.isCommandPalettePresented = true
            } label: {
                Label("Commands", systemImage: "command")
            }
            .keyboardShortcut("k", modifiers: [.command])
            .fixedSize()
            Toggle(isOn: Binding(
                get: { model.bossWatchIsEnabled },
                set: { model.setBossWatchEnabled($0) }
            )) {
                Label("Watch", systemImage: "eye")
            }
            .toggleStyle(.switch)
            .disabled(model.bossCheckInIsRunning)
            .help(model.bossCheckInIsRunning ? "Check-in already running" : "Toggle boss watch mode")
            .fixedSize()
            Button {
                Task {
                    model.refreshExecutableHealth()
                    await model.refreshBossDashboard()
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .fixedSize()
            Button {
                Task {
                    await model.runBossCheckIn()
                }
            } label: {
                Label("Check In", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.bossCheckInIsRunning)
            .keyboardShortcut("i", modifiers: [.command])
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 68)
    }
}

struct BossSelectorView: View {
    @ObservedObject var model: WorkbenchViewModel
    @State private var customBossIsPresented = false
    @State private var draftAgentName = ""

    var body: some View {
        Menu {
            if !model.bossAgentChoices.isEmpty {
                ForEach(model.bossAgentChoices, id: \.self) { agentName in
                    Button {
                        model.selectBoss(agentName: agentName)
                    } label: {
                        if agentName == model.state.boss.agentName {
                            Label(agentName, systemImage: "checkmark")
                        } else {
                            Text(agentName)
                        }
                    }
                }
                Divider()
            }
            Button {
                draftAgentName = model.state.boss.agentName
                customBossIsPresented = true
            } label: {
                Label("Use Other Boss...", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 5) {
                Text("Boss: \(model.state.boss.agentName)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 220, alignment: .leading)
        .help("Choose boss agent")
        .popover(isPresented: $customBossIsPresented) {
            BossAgentNamePopover(
                agentName: $draftAgentName,
                isPresented: $customBossIsPresented,
                model: model
            )
            .frame(width: 280)
            .padding(14)
        }
    }
}

struct BossAgentNamePopover: View {
    @Binding var agentName: String
    @Binding var isPresented: Bool
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var fieldIsFocused: Bool

    private var trimmedAgentName: String {
        agentName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canApply: Bool {
        BossWorkbenchMCPRegistrar.isValidAgentBundleName(trimmedAgentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Boss Agent")
                .font(.headline)
            TextField("agent bundle name", text: $agentName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldIsFocused)
                .onSubmit(apply)
            if !trimmedAgentName.isEmpty && !canApply {
                Text("Invalid bundle name.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Use") {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
        }
        .onAppear {
            fieldIsFocused = true
        }
    }

    private func apply() {
        guard canApply else {
            return
        }
        model.selectBoss(agentName: trimmedAgentName)
        isPresented = false
    }
}

struct AutonomyStatusButton: View {
    @ObservedObject var model: WorkbenchViewModel
    @StateObject private var loginItem = LoginItemController()
    @State private var isPresented = false

    private var snapshot: AutonomyReadinessSnapshot {
        model.autonomyReadiness.appending(loginItemCheck)
    }

    private var loginItemCheck: AutonomyReadinessCheck {
        switch loginItem.status {
        case .enabled:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "Workbench will reopen after a computer restart.",
                state: .ok
            )
        case .needsUpdate:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "Login item points at a different app bundle and needs an update.",
                state: .warning
            )
        case .notInstalled:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "Workbench will not reopen automatically after restart.",
                state: .warning
            )
        case .appBundleMissing:
            return AutonomyReadinessCheck(
                id: "open-at-login",
                label: "Open at Login",
                detail: "The installed app bundle is missing.",
                state: .blocker
            )
        }
    }

    var body: some View {
        Button {
            loginItem.refresh()
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(snapshot.state.tint)
                    .frame(width: 7, height: 7)
                Text(snapshot.label)
                    .font(.caption.monospaced().weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(snapshot.state.tint.opacity(0.16), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(snapshot.state.tint.opacity(0.32), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("TTFA readiness")
        .popover(isPresented: $isPresented) {
            AutonomyStatusPopover(
                snapshot: snapshot,
                model: model,
                loginItem: loginItem
            )
            .frame(width: 380)
            .padding(14)
        }
        .onAppear {
            loginItem.refresh()
        }
    }
}

struct AutonomyStatusPopover: View {
    var snapshot: AutonomyReadinessSnapshot
    @ObservedObject var model: WorkbenchViewModel
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.label)
                    .font(.headline.monospaced())
                StatusPill(text: snapshot.state.displayName, color: snapshot.state.tint)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.headline)
                    .font(.subheadline.weight(.semibold))
                Text(snapshot.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.checks) { check in
                    AutonomyStatusCheckRow(check: check)
                }
            }
            Divider()
            HStack(spacing: 8) {
                if model.bossWorkbenchMCPRegistration?.isActionable == true {
                    Button {
                        model.installWorkbenchMCPForBoss()
                    } label: {
                        Label(model.bossWorkbenchMCPActionTitle, systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                if !model.bossWatchIsEnabled {
                    Button {
                        model.setBossWatchEnabled(true)
                    } label: {
                        Label("Watch", systemImage: "eye")
                    }
                }
                if !loginItem.isEnabled {
                    Button {
                        loginItem.setEnabled(true)
                    } label: {
                        Label(loginItem.status == .needsUpdate ? "Update Login" : "Login", systemImage: "power")
                    }
                }
                Button {
                    Task {
                        await model.runBossCheckIn()
                    }
                } label: {
                    Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
                }
                .disabled(model.bossCheckInIsRunning)
            }
            .controlSize(.small)
        }
    }
}

struct AutonomyStatusCheckRow: View {
    var check: AutonomyReadinessCheck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.state.systemImage)
                .foregroundStyle(check.state.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.label)
                    .font(.caption.weight(.semibold))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusPill: View {
    var text: String
    var color: SwiftUI.Color

    var body: some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private extension AutonomyReadinessState {
    var tint: SwiftUI.Color {
        switch self {
        case .ready:
            return .green
        case .attention:
            return .orange
        case .blocked:
            return .red
        }
    }

    var displayName: String {
        switch self {
        case .ready:
            return "ready"
        case .attention:
            return "watch"
        case .blocked:
            return "blocked"
        }
    }
}

private extension AutonomyReadinessCheckState {
    var tint: SwiftUI.Color {
        switch self {
        case .ok:
            return .green
        case .warning:
            return .orange
        case .blocker:
            return .red
        }
    }

    var systemImage: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .blocker:
            return "xmark.octagon.fill"
        }
    }
}

struct CommandPaletteSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Run command", text: $model.commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(runFirstCommand)
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.filteredCommandPaletteItems) { command in
                        Button {
                            model.performCommand(command.id)
                            dismiss()
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
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: 360)
        }
        .padding()
        .frame(width: 560)
        .onAppear {
            model.commandPaletteQuery = ""
            searchFocused = true
        }
    }

    private func runFirstCommand() {
        guard let command = model.filteredCommandPaletteItems.first else {
            return
        }
        model.performCommand(command.id)
        dismiss()
    }
}

struct BossDashboardView: View {
    @ObservedObject var model: WorkbenchViewModel
    private let dashboardColumns = [GridItem(.adaptive(minimum: 260), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.bossCheckInIsRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                BossWatchStatusView(model: model)
                if let dashboard = model.bossDashboard {
                    DashboardMetricsStrip(dashboard: dashboard)
                }
                BossConversationView(model: model)
                if let dashboard = model.bossDashboard,
                   !dashboard.availability.issues.isEmpty {
                    MailboxWarningView(issues: dashboard.availability.issues)
                }
                OuroAgentManagerView(model: model)
                TranscriptSearchView(model: model)
                MachineRuntimeView()
                RecoveryDrillView(model: model)
                BossWorkbenchMCPSetupView(model: model)
                if let dashboard = model.bossDashboard {
                    if !dashboard.needsMeItems.isEmpty || !dashboard.codingItems.isEmpty {
                        LazyVGrid(columns: dashboardColumns, alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Needs Me")
                                    .font(.caption.weight(.semibold))
                                ForEach(Array(dashboard.needsMeItems.prefix(3))) { item in
                                    Text("\(item.label) - \(item.detail)")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Coding")
                                    .font(.caption.weight(.semibold))
                                ForEach(Array(dashboard.codingItems.prefix(3))) { item in
                                    Text("\(item.runner) - \(item.status) - \(item.workdir)")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 190, idealHeight: 340, maxHeight: 390, alignment: .topLeading)
    }
}

struct DashboardMetricsStrip: View {
    var dashboard: BossDashboardSnapshot

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                MetricChip(label: "daemon", value: dashboard.daemonStatus)
                MetricChip(label: "needs me", value: dashboard.availability.needsMeAvailable ? "\(dashboard.needsMeItems.count)" : "?")
                MetricChip(label: "coding", value: dashboard.availability.codingAvailable ? "\(dashboard.activeCodingAgents)" : "?")
                MetricChip(label: "blocked", value: dashboard.availability.codingAvailable ? "\(dashboard.blockedCodingAgents)" : "?")
                MetricChip(label: "mode", value: dashboard.daemonMode)
            }
        }
    }
}

struct MetricChip: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct MailboxWarningView: View {
    var issues: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Mailbox warnings: \(issues.joined(separator: "; "))")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct BossQuickQuestion: Identifiable {
    var id: String
    var title: String
    var question: String
}

private let bossQuickQuestions: [BossQuickQuestion] = [
    BossQuickQuestion(
        id: "status",
        title: "What's Going On?",
        question: "Summarize what is currently going on across the Workbench, including running terminal agents, anything waiting on Ari, and the next useful action."
    ),
    BossQuickQuestion(
        id: "waiting",
        title: "Waiting On Me?",
        question: "Inspect the Workbench and tell Ari whether anything is waiting on him. Be concise, and include what decision or input is needed only if a human decision is genuinely required."
    ),
    BossQuickQuestion(
        id: "move",
        title: "Keep Moving",
        question: "Inspect the Workbench and keep trusted terminal agents moving when the next action is clear. Use auditable Workbench actions for safe obvious next steps."
    ),
    BossQuickQuestion(
        id: "respond",
        title: "Respond For Me",
        question: "Inspect the Workbench and respond on Ari's behalf when a terminal agent is clearly waiting on routine input. Use Workbench actions for safe obvious replies; escalate only genuinely human-only decisions."
    )
]

struct BossConversationView: View {
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Boss Line", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.semibold))
                TextField("Ask \(model.state.boss.agentName) about the Workbench", text: $model.bossQuestion)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit {
                        Task {
                            await model.runBossQuestion()
                        }
                    }
                Button {
                    Task {
                        await model.runBossQuestion()
                    }
                } label: {
                    Label("Ask", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.bossQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.bossCheckInIsRunning)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bossQuickQuestions) { item in
                        Button(item.title) {
                            Task {
                                await model.runBossQuickQuestion(item.question)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.bossCheckInIsRunning)
                    }
                }
            }
        }
    }
}

struct OuroAgentManagerView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Label("Ouro Agents", systemImage: "person.2.badge.gearshape")
                    .font(.caption.weight(.semibold))
                Text(model.ouroAgentStatusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    model.refreshOuroAgents()
                } label: {
                    Label("Refresh Agents", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh local Ouro agents")
                Button {
                    model.isOuroAgentInstallSheetPresented = true
                } label: {
                    Label("Install Agent", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            if model.ouroAgents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    Text("No local agent bundles found in ~/AgentBundles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 5) {
                    ForEach(model.ouroAgents) { agent in
                        OuroAgentRowView(agent: agent, model: model)
                    }
                }
            }
        }
        .task {
            model.refreshOuroAgents()
        }
    }
}

struct OuroAgentRowView: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel

    private var registration: BossWorkbenchMCPRegistrationSnapshot? {
        model.workbenchMCPRegistration(for: agent)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: agentStatusImage)
                .foregroundStyle(agentStatusColor)
                .frame(width: 16)
                .help(agent.detail)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame {
                        StatusPill(text: "boss", color: .blue)
                    }
                    if let registration {
                        StatusPill(text: registrationPillText(registration.status), color: registrationTint(registration.status))
                    }
                }
                Text(agent.summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                model.selectBoss(agentName: agent.name)
            } label: {
                Label("Use as Boss", systemImage: "person.crop.circle.badge.checkmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Use \(agent.name) as boss")
            .disabled(!agent.isUsableAsBoss || model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame)
            if registration?.isActionable == true {
                Button {
                    model.installWorkbenchMCP(for: agent)
                } label: {
                    Label(registration?.status == .needsUpdate ? "Update MCP" : "Install MCP", systemImage: "link.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(registration?.detail ?? "Register Workbench MCP")
            }
            Button {
                model.revealAgentBundle(agent)
            } label: {
                Label("Reveal Bundle", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(agent.bundlePath)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.name), \(agent.summaryLine)")
    }

    private var agentStatusImage: String {
        switch agent.status {
        case .ready:
            return "checkmark.circle.fill"
        case .disabled:
            return "pause.circle.fill"
        case .missingConfig:
            return "exclamationmark.triangle.fill"
        case .invalidConfig:
            return "xmark.octagon.fill"
        }
    }

    private var agentStatusColor: SwiftUI.Color {
        switch agent.status {
        case .ready:
            return .green
        case .disabled, .missingConfig:
            return .orange
        case .invalidConfig:
            return .red
        }
    }

    private func registrationPillText(_ status: BossWorkbenchMCPRegistrationStatus) -> String {
        switch status {
        case .registered:
            return "mcp"
        case .notRegistered:
            return "no mcp"
        case .needsUpdate:
            return "mcp update"
        case .agentMissing:
            return "missing"
        case .executableMissing:
            return "app missing"
        case .invalidConfig:
            return "config"
        }
    }

    private func registrationTint(_ status: BossWorkbenchMCPRegistrationStatus) -> SwiftUI.Color {
        switch status {
        case .registered:
            return .green
        case .notRegistered, .needsUpdate:
            return .orange
        case .agentMissing, .executableMissing, .invalidConfig:
            return .red
        }
    }
}

private enum OuroAgentInstallSheetMode: String, CaseIterable, Identifiable {
    case hatch
    case clone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hatch:
            return "Hatch"
        case .clone:
            return "Clone"
        }
    }
}

struct OuroAgentInstallSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: OuroAgentInstallSheetMode = .hatch
    @State private var agentName = ""
    @State private var remote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Ouro Agent")
                .font(.title3.weight(.semibold))
            Picker("Mode", selection: $mode) {
                ForEach(OuroAgentInstallSheetMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Form {
                switch mode {
                case .hatch:
                    Label("SerpentGuide Conversation", systemImage: "bubble.left.and.bubble.right.fill")
                case .clone:
                    TextField("Git Remote", text: $remote)
                    TextField("Agent Name Override", text: $agentName)
                }
            }
            Text(commandPreview)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    guard install() else {
                        return
                    }
                    dismiss()
                } label: {
                    Label(primaryButtonTitle, systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall)
            }
        }
        .padding()
        .frame(width: 560)
    }

    private var canInstall: Bool {
        switch mode {
        case .hatch:
            return true
        case .clone:
            return !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .hatch:
            return "Open Conversation"
        case .clone:
            return "Open Clone"
        }
    }

    private var commandPreview: String {
        do {
            return try model.ouroAgentInstallPlan(
                mode: mode.rawValue,
                agentName: agentName,
                remote: remote
            ).commandLine
        } catch {
            return error.localizedDescription
        }
    }

    private func install() -> Bool {
        model.launchOuroAgentInstall(
            mode: mode.rawValue,
            agentName: agentName,
            remote: remote
        )
    }
}

struct ActionLogView: View {
    var entries: [WorkbenchActionLogEntry]
    @State private var isExpanded = false

    private var displayedEntries: ArraySlice<WorkbenchActionLogEntry> {
        entries.prefix(isExpanded ? 6 : 1)
    }

    var body: some View {
        if !entries.isEmpty {
            if !isExpanded, let entry = entries.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Action Log")
                        .font(.caption.weight(.semibold))
                    Text("\(entries.count) recent")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    actionLogEntryContent(entry)
                    Spacer(minLength: 8)
                    actionLogToggleButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Action Log")
                            .font(.caption.weight(.semibold))
                        Text("\(entries.count) recent")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        actionLogToggleButton
                    }
                    ForEach(displayedEntries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            actionLogEntryContent(entry)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var actionLogToggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label(isExpanded ? "Show Less" : "Show More", systemImage: isExpanded ? "chevron.up" : "chevron.down")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(isExpanded ? "Show fewer action log entries" : "Show more action log entries")
    }

    @ViewBuilder
    private func actionLogEntryContent(_ entry: WorkbenchActionLogEntry) -> some View {
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

struct BossWatchStatusView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Label("Boss Watch", systemImage: model.bossWatchIsEnabled ? "eye.fill" : "eye")
                    .font(.caption.weight(.semibold))
                Text(model.bossWatchStatusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(model.bossWatchStatusColor)
            }
            if !model.bossWatchChangeSummaries.isEmpty {
                ForEach(model.bossWatchChangeSummaries.prefix(5)) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(change.occurredAt.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(change.title)
                            .font(.caption.weight(.semibold))
                        Text(change.detail)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }
}

struct TranscriptSearchView: View {
    @ObservedObject var model: WorkbenchViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Transcript Search", systemImage: "text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                TextField("Search transcripts", text: $model.transcriptSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onChange(of: model.transcriptSearchQuery) {
                        model.transcriptSearchQueryDidChange()
                    }
                    .onSubmit {
                        model.searchTranscripts()
                    }
                Button {
                    searchOrFocus()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: [.command])
            }
            if !model.transcriptSearchResults.isEmpty {
                ForEach(model.transcriptSearchResults.prefix(6)) { match in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.groupName(for: match).map { "\($0) / \(match.entryName)" } ?? match.entryName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("line \(match.lineNumber)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(match.line)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(match.transcriptPath)
                }
            } else if !model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(model.transcriptSearchStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func searchOrFocus() {
        guard !model.transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchFocused = true
            return
        }
        model.searchTranscripts()
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
                    HStack(spacing: 6) {
                        if let groupName = model.groupName(for: entry) {
                            StatusPill(text: groupName, color: .secondary)
                        }
                        if let cliName = model.cliName(for: entry) {
                            StatusPill(text: cliName, color: .purple)
                        }
                        StatusPill(
                            text: entry.trust == .trusted ? "trusted" : "untrusted",
                            color: entry.trust == .trusted ? .green : .orange
                        )
                        StatusPill(
                            text: entry.autoResume ? "auto-resume" : "manual restart",
                            color: entry.autoResume ? .blue : .secondary
                        )
                    }
                }
                Spacer()
                if entry.isArchived {
                    Label("Archived", systemImage: "archivebox")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task {
                            await model.runBossQuestion(about: entry)
                        }
                    } label: {
                        Label("Ask Boss", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.bossCheckInIsRunning)
                    if model.activeSession(for: entry) != nil {
                        RunningSessionHeaderControls(entry: entry, model: model)
                    }
                    Button {
                        model.launch(entry)
                    } label: {
                        Label(model.activeSession(for: entry) == nil ? "Launch" : "Restart", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding()
            if let notes = entry.trimmedNotes {
                SessionNotesView(notes: notes)
                    .padding(.horizontal)
                    .padding(.bottom, model.isCustomSession(entry) ? 8 : 12)
            }
            if model.isCustomSession(entry) {
                CustomSessionManagementBar(entry: entry, model: model)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
            Divider()
            if let session = model.activeSession(for: entry) {
                TerminalPane(session: session)
                    .id(session.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct SessionNotesView: View {
    var notes: String

    var body: some View {
        Text(notes)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionStatusBar: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.isArchived ? "Archived" : (entry.lastSummary ?? "Configured"))
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.isArchived ? "Restore this session before launching it." : "Recovery: \(model.recoveryReason(for: entry))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !entry.isArchived, let health = model.executableHealth(for: entry) {
                    Text("Executable: \(health.detail)")
                        .font(.caption)
                        .foregroundStyle(health.status == .available ? SwiftUI.Color.secondary : SwiftUI.Color.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
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

            Menu {
                ForEach(model.state.projects) { project in
                    Button(project.name) {
                        model.moveSession(entry, to: project.id)
                    }
                    .disabled(project.id == entry.projectId)
                }
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(isRunning || model.state.projects.count < 2)
            .help(isRunning ? "Stop this session before moving it" : "Move this session to another group")

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

struct RunningSessionHeaderControls: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.focusTerminal(entry)
            } label: {
                Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Focus this terminal")

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
            .keyboardShortcut(".", modifiers: [.command])
        }
        .controlSize(.small)
    }
}

struct TerminalFocusView: View {
    var entry: ProcessEntry
    var session: TerminalSessionController
    @ObservedObject var model: WorkbenchViewModel
    private let chrome = WorkbenchSurfaceChrome.contract(for: .terminalFocus)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()
            TerminalPane(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, CGFloat(chrome.terminalContentTopInset))
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Button {
                    model.exitTerminalFocus()
                } label: {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
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
                .keyboardShortcut(".", modifiers: [.command])
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, CGFloat(chrome.floatingControlsTopInset))
            .padding(.trailing, 16)
        }
        .background(Color.black)
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

struct NewTerminalGroupSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var rootPath = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Terminal Group")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Root Path", text: $rootPath)
                        .font(.body.monospaced())
                    Button {
                        chooseRootPath()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    guard model.createGroup(name: name, rootPath: rootPath) else {
                        return
                    }
                    dismiss()
                } label: {
                    Label("Create", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func chooseRootPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
        }
    }
}

struct EditTerminalGroupSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    let project: WorkbenchProject
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var rootPath: String

    init(model: WorkbenchViewModel, project: WorkbenchProject) {
        self.model = model
        self.project = project
        _name = State(initialValue: project.name)
        _rootPath = State(initialValue: project.rootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Terminal Group")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Root Path", text: $rootPath)
                        .font(.body.monospaced())
                    Button {
                        chooseRootPath()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    guard model.renameGroup(project, name: name, rootPath: rootPath) else {
                        return
                    }
                    dismiss()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }

    private func chooseRootPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
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
    @State private var notes = ""

    init(model: WorkbenchViewModel) {
        self.model = model
        _workingDirectory = State(initialValue: model.selectedProject?.rootPath ?? FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Terminal")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                    .font(.body.monospaced())
                    .onChange(of: command) {
                        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return
                        }
                        if let parsed = TerminalCommandParser.parse(command),
                           let kind = TerminalAgentDetector.detect(executable: parsed.executable, arguments: parsed.arguments),
                           let displayName = TerminalAgentDetector.displayName(for: kind) {
                            name = displayName
                        }
                    }
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
                SessionNotesEditor(notes: $notes)
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
            autoResume: autoResume,
            notes: notes
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
    @State private var notes: String

    init(model: WorkbenchViewModel, entry: ProcessEntry) {
        self.model = model
        self.entry = entry
        let draft = model.customSessionDraft(for: entry) ?? CustomTerminalSessionDraft(
            name: entry.name,
            command: "",
            workingDirectory: entry.workingDirectory,
            trust: entry.trust,
            autoResume: entry.autoResume,
            notes: entry.notes ?? ""
        )
        _name = State(initialValue: draft.name)
        _command = State(initialValue: draft.command)
        _workingDirectory = State(initialValue: draft.workingDirectory)
        _trusted = State(initialValue: draft.trust == .trusted)
        _autoResume = State(initialValue: draft.autoResume)
        _notes = State(initialValue: draft.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Terminal")
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
                SessionNotesEditor(notes: $notes)
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
            autoResume: autoResume,
            notes: notes
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

struct SessionNotesEditor: View {
    @Binding var notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
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

struct RecoveryDrillView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Label("Recovery Drill", systemImage: "arrow.clockwise.circle")
                    .font(.caption.weight(.semibold))
                Text(model.recoveryDrillStatusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Button {
                    model.runRecoveryDrill()
                } label: {
                    Label("Run Drill", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
            }
            if let result = model.recoveryDrillResult {
                ForEach(result.items.prefix(5)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.groupName(forEntryId: item.id).map { "\($0) / \(item.entryName)" } ?? item.entryName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(item.beforeStatus?.rawValue ?? "none") -> \(item.afterStatus?.rawValue ?? "none")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(item.action.rawValue)
                            .font(.caption.monospaced())
                        Text(item.reason)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
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
        case .needsUpdate:
            return "update needed"
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
        case .enabled, .needsUpdate:
            try loginItem.uninstall()
        case .notInstalled, .appBundleMissing:
            return
        }
    }
}

@MainActor
final class WorkbenchViewModel: ObservableObject {
    @Published var state: WorkspaceState
    @Published var selectedProjectID: UUID? {
        didSet {
            guard selectedProjectID != oldValue else {
                return
            }
            state.selectedProjectId = selectedProjectID
            if let selectedEntryID,
               !sessionEntries.contains(where: { $0.id == selectedEntryID }) {
                self.selectedEntryID = sessionEntries.first?.id
            }
            save()
        }
    }
    @Published var selectedEntryID: UUID? {
        didSet {
            guard selectedEntryID != oldValue else {
                return
            }
            state.selectedEntryId = selectedEntryID
            save()
        }
    }
    @Published var activeSessions: [UUID: TerminalSessionController] = [:]
    @Published var terminalFocusEntryID: UUID?
    @Published var errorMessage: String?
    @Published var bossDashboard: BossDashboardSnapshot?
    @Published var bossCheckInPrompt: String?
    @Published var bossCheckInAnswer: String?
    @Published var bossCheckInIsRunning = false
    @Published var bossQuestion = ""
    @Published var bossWatchIsEnabled = false
    @Published var bossWatchLastRunAt: Date?
    @Published var bossWatchLastError: String?
    @Published var bossWatchChangeSummaries: [WorkspaceChangeSummary] = []
    @Published var transcriptSearchQuery = ""
    @Published var transcriptSearchResults: [TranscriptSearchMatch] = []
    @Published var transcriptSearchLastQuery: String?
    @Published var recoveryDrillResult: RecoveryDrillResult?
    @Published var bossAppliedActions: [String] = []
    @Published var mailboxError: String?
    @Published var isNewSessionSheetPresented = false
    @Published var isNewGroupSheetPresented = false
    @Published var isCommandPalettePresented = false
    @Published var isOuroAgentInstallSheetPresented = false
    @Published var commandPaletteQuery = ""
    @Published var editingGroup: WorkbenchProject?
    @Published var pendingDeleteGroup: WorkbenchProject?
    @Published var editingSession: ProcessEntry?
    @Published var pendingDeleteSession: ProcessEntry?
    @Published var ouroAgents: [OuroAgentRecord] = []
    @Published var bossWorkbenchMCPRegistration: BossWorkbenchMCPRegistrationSnapshot?
    @Published var bossWorkbenchMCPRegistrationByAgentName: [String: BossWorkbenchMCPRegistrationSnapshot] = [:]
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
    private let autonomyReadinessBuilder = AutonomyReadinessBuilder()
    private let changeSummarizer = WorkspaceChangeSummarizer()
    private let commandPalette = WorkbenchCommandPalette()
    private let bossMCPClient: BossAgentMCPClient
    private let bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar
    private let ouroAgentInventory: OuroAgentInventory
    private let ouroAgentInstallCommandBuilder = OuroAgentInstallCommandBuilder()
    private let executableHealthChecker: ExecutableHealthChecker
    private let bossActionParser = BossWorkbenchActionParser()
    private let bossActionAuthorizer = BossWorkbenchActionAuthorizer()
    private let terminationPolicy = ProcessTerminationPolicy()
    private let customSessionFactory = CustomTerminalSessionFactory()
    private let customSessionManager = CustomTerminalSessionManager()
    private let transcriptTailReader = TranscriptTailReader()
    private let transcriptSearcher = TranscriptSearcher()
    private let recoveryDrill = RecoveryDrill()
    private let externalActionQueue: WorkbenchActionRequestQueue
    private var manuallyTerminatedRunIDs = Set<UUID>()
    private var bossWatchBaselineState: WorkspaceState?
    private var bossWatchTickIsRunning = false
    private var bossWatchLastPromptAt: Date?
    private var didAttemptStartupRecovery = false
    private var didAttemptDefaultShellLaunch = false
    private let bossWatchIntervalNanoseconds: UInt64 = 60_000_000_000

    init(
        paths: WorkbenchPaths = .defaultPaths(),
        mailboxClient: MailboxClient = MailboxClient(),
        bossMCPClient: BossAgentMCPClient = BossAgentMCPClient(),
        bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar = BossWorkbenchMCPRegistrar(),
        ouroAgentInventory: OuroAgentInventory = OuroAgentInventory(),
        executableHealthChecker: ExecutableHealthChecker = ExecutableHealthChecker()
    ) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.mailboxClient = mailboxClient
        self.bossMCPClient = bossMCPClient
        self.bossWorkbenchMCPRegistrar = bossWorkbenchMCPRegistrar
        self.ouroAgentInventory = ouroAgentInventory
        self.executableHealthChecker = executableHealthChecker
        self.externalActionQueue = WorkbenchActionRequestQueue(paths: paths)
        self.state = WorkspaceState()
        load()
        refreshOuroAgents()
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

    var deleteGroupConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { self.pendingDeleteGroup != nil },
            set: { newValue in
                if !newValue {
                    self.pendingDeleteGroup = nil
                }
            }
        )
    }

    var sessionEntries: [ProcessEntry] {
        projectSessionEntries.filter { !$0.isArchived }
    }

    var archivedSessionEntries: [ProcessEntry] {
        projectSessionEntries.filter(\.isArchived)
    }

    private var allSessionEntries: [ProcessEntry] {
        state.processEntries.filter { $0.kind == .terminalAgent || $0.kind == .shell }
    }

    private var projectSessionEntries: [ProcessEntry] {
        guard let selectedProjectID else {
            return allSessionEntries
        }
        return allSessionEntries.filter { $0.projectId == selectedProjectID }
    }

    var selectedProject: WorkbenchProject? {
        guard let selectedProjectID else {
            return state.projects.first
        }
        return state.projects.first { $0.id == selectedProjectID } ?? state.projects.first
    }

    func terminalCount(in project: WorkbenchProject) -> Int {
        allSessionEntries.filter { $0.projectId == project.id && !$0.isArchived }.count
    }

    func totalTerminalCount(in project: WorkbenchProject) -> Int {
        allSessionEntries.filter { $0.projectId == project.id }.count
    }

    func groupName(for entry: ProcessEntry) -> String? {
        state.projects.first { $0.id == entry.projectId }?.name
    }

    func groupName(forEntryId entryId: UUID) -> String? {
        guard let entry = state.processEntries.first(where: { $0.id == entryId }) else {
            return nil
        }
        return groupName(for: entry)
    }

    func groupName(for match: TranscriptSearchMatch) -> String? {
        groupName(forEntryId: match.entryId)
    }

    var selectedEntry: ProcessEntry? {
        guard let selectedEntryID else {
            return sessionEntries.first
        }
        return sessionEntries.first { $0.id == selectedEntryID } ?? sessionEntries.first
    }

    var terminalFocusEntry: ProcessEntry? {
        guard let terminalFocusEntryID,
              activeSessions[terminalFocusEntryID] != nil else {
            return nil
        }
        return allSessionEntries.first { $0.id == terminalFocusEntryID }
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

    var autonomyReadiness: AutonomyReadinessSnapshot {
        autonomyReadinessBuilder.build(
            state: state,
            summary: summary,
            mcpRegistration: bossWorkbenchMCPRegistration,
            executableHealth: executableHealthByEntryID,
            bossWatchIsEnabled: bossWatchIsEnabled
        )
    }

    var recentActionLogEntries: [WorkbenchActionLogEntry] {
        state.actionLog.sorted { $0.occurredAt > $1.occurredAt }
    }

    var bossWatchStatusLine: String {
        if let bossWatchLastError {
            return "error: \(bossWatchLastError)"
        }
        guard bossWatchIsEnabled else {
            return "paused"
        }
        guard let bossWatchLastRunAt else {
            return "watching"
        }
        return "watching; last \(bossWatchLastRunAt.formatted(date: .omitted, time: .standard))"
    }

    var bossWatchStatusColor: SwiftUI.Color {
        if bossWatchLastError != nil {
            return .orange
        }
        return bossWatchIsEnabled ? .green : .secondary
    }

    var transcriptSearchStatusLine: String {
        let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Enter a query to search saved transcripts."
        }
        guard transcriptSearchLastQuery == query else {
            return "Press Search to search saved transcripts."
        }
        return "No transcript matches for \(query)."
    }

    var recoveryDrillStatusLine: String {
        guard let recoveryDrillResult else {
            return "not run"
        }
        return "\(recoveryDrillResult.oneLineStatus); \(recoveryDrillResult.ranAt.formatted(date: .omitted, time: .standard))"
    }

    var commandPaletteItems: [WorkbenchCommandDescriptor] {
        var commands: [WorkbenchCommandDescriptor] = [
            WorkbenchCommandDescriptor(
                id: .newSession,
                title: "New Terminal",
                detail: "Create a terminal/TUI tab in the selected group",
                systemImage: "plus"
            ),
            WorkbenchCommandDescriptor(
                id: .toggleBossWatch,
                title: bossWatchIsEnabled ? "Pause Boss Watch" : "Start Boss Watch",
                detail: "Toggle automatic boss monitoring",
                systemImage: bossWatchIsEnabled ? "eye.slash" : "eye"
            ),
            WorkbenchCommandDescriptor(
                id: .installOuroAgent,
                title: "Install Ouro Agent",
                detail: "Open a managed hatch conversation or clone terminal",
                systemImage: "square.and.arrow.down"
            ),
            WorkbenchCommandDescriptor(
                id: .searchTranscripts,
                title: "Search Transcripts",
                detail: "Run the current transcript search query",
                systemImage: "text.magnifyingglass"
            ),
            WorkbenchCommandDescriptor(
                id: .runRecoveryDrill,
                title: "Run Recovery Drill",
                detail: "Simulate restart recovery planning",
                systemImage: "arrow.clockwise.circle"
            )
        ]

        if !bossCheckInIsRunning {
            commands.insert(
                WorkbenchCommandDescriptor(
                    id: .bossCheckIn,
                    title: "Boss Check In",
                    detail: "Ask \(state.boss.agentName) what is going on",
                    systemImage: "bubble.left.and.text.bubble.right"
                ),
                at: 1
            )
        }

        if let selectedEntry, !selectedEntry.isArchived {
            commands.append(WorkbenchCommandDescriptor(
                id: .launchSelectedSession,
                title: activeSession(for: selectedEntry) == nil ? "Launch \(selectedEntry.name)" : "Restart \(selectedEntry.name)",
                detail: launchCommand(for: selectedEntry),
                systemImage: "play.fill"
            ))
            if activeSession(for: selectedEntry) != nil {
                commands.append(WorkbenchCommandDescriptor(
                    id: .stopSelectedSession,
                    title: "Stop \(selectedEntry.name)",
                    detail: "Terminate the running terminal session",
                    systemImage: "stop.fill"
                ))
            }
            if canRecover(selectedEntry) {
                commands.append(WorkbenchCommandDescriptor(
                    id: .recoverSelectedSession,
                    title: "\(recoveryButtonTitle(for: selectedEntry)) \(selectedEntry.name)",
                    detail: recoveryReason(for: selectedEntry),
                    systemImage: "arrow.clockwise"
                ))
            }
        }

        return commands
    }

    var filteredCommandPaletteItems: [WorkbenchCommandDescriptor] {
        commandPalette.filter(commandPaletteItems, query: commandPaletteQuery)
    }

    func executableHealth(for entry: ProcessEntry) -> ExecutableHealth? {
        executableHealthByEntryID[entry.id]
    }

    func cliName(for entry: ProcessEntry) -> String? {
        guard let cliName = TerminalAgentDetector.displayName(for: TerminalAgentDetector.detect(entry: entry)) else {
            return nil
        }
        return cliName.localizedCaseInsensitiveCompare(entry.name) == .orderedSame ? nil : cliName
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

    var ouroAgentStatusLine: String {
        guard !ouroAgents.isEmpty else {
            return "no local agents"
        }
        let readyCount = ouroAgents.filter { $0.status == .ready }.count
        return "\(ouroAgents.count) local, \(readyCount) ready; boss \(state.boss.agentName)"
    }

    var bossAgentChoices: [String] {
        let names = ouroAgents.map(\.name) + (bossDashboard?.knownAgentNames ?? []) + [state.boss.agentName]
        return Array(Set(names))
            .filter { !$0.isEmpty }
            .filter(BossWorkbenchMCPRegistrar.isValidAgentBundleName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func refreshOuroAgents() {
        ouroAgents = ouroAgentInventory.scan()
        refreshWorkbenchMCPRegistration()
    }

    func workbenchMCPRegistration(for agent: OuroAgentRecord) -> BossWorkbenchMCPRegistrationSnapshot? {
        bossWorkbenchMCPRegistrationByAgentName[agent.name]
    }

    func revealAgentBundle(_ agent: OuroAgentRecord) {
        let targetPath = FileManager.default.fileExists(atPath: agent.configPath)
            ? agent.configPath
            : agent.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: targetPath)
        ])
    }

    func installWorkbenchMCP(for agent: OuroAgentRecord) {
        do {
            let selection = BossAgentSelection(agentName: agent.name)
            let snapshot = try bossWorkbenchMCPRegistrar.install(for: selection)
            bossWorkbenchMCPRegistrationByAgentName[agent.name] = snapshot
            if state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame {
                bossWorkbenchMCPRegistration = snapshot
            }
            let result = "Registered Workbench MCP for \(agent.name)"
            bossAppliedActions = [result] + bossAppliedActions
            recordActionLog(
                source: "native",
                action: "registerWorkbenchMCP",
                targetName: agent.name,
                result: result,
                succeeded: true
            )
        } catch {
            errorMessage = "Workbench MCP registration failed: \(error.localizedDescription)"
            refreshWorkbenchMCPRegistration()
        }
    }

    func ouroAgentInstallPlan(
        mode: String,
        agentName: String,
        remote: String
    ) throws -> OuroAgentInstallPlan {
        switch mode {
        case OuroAgentInstallSheetMode.hatch.rawValue:
            return ouroAgentInstallCommandBuilder.hatch()
        case OuroAgentInstallSheetMode.clone.rawValue:
            return try ouroAgentInstallCommandBuilder.clone(
                remote: remote,
                agentName: agentName
            )
        default:
            return ouroAgentInstallCommandBuilder.hatch()
        }
    }

    @discardableResult
    func launchOuroAgentInstall(
        mode: String,
        agentName: String,
        remote: String
    ) -> Bool {
        do {
            let plan = try ouroAgentInstallPlan(
                mode: mode,
                agentName: agentName,
                remote: remote
            )
            let entry = createCustomSession(
                CustomTerminalSessionDraft(
                    name: plan.sessionName,
                    command: plan.commandLine,
                    workingDirectory: selectedProject?.rootPath ?? FileManager.default.homeDirectoryForCurrentUser.path,
                    trust: .trusted,
                    autoResume: true,
                    notes: plan.notes
                ),
                launchAfterCreate: true
            )
            guard let entry else {
                return false
            }
            recordActionLog(
                source: "native",
                action: "installOuroAgent",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: "Opened \(entry.name)",
                succeeded: true
            )
            return true
        } catch {
            errorMessage = "Ouro agent install failed: \(error.localizedDescription)"
            return false
        }
    }

    func selectBoss(agentName: String) {
        let normalizedAgentName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAgentName.isEmpty, normalizedAgentName != state.boss.agentName else {
            return
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(normalizedAgentName) else {
            errorMessage = "Boss agent name cannot be used as a bundle name: \(normalizedAgentName)"
            return
        }
        state.boss.agentName = normalizedAgentName
        bossDashboard = nil
        bossCheckInPrompt = nil
        bossCheckInAnswer = nil
        bossQuestion = ""
        bossAppliedActions = []
        bossWatchBaselineState = state
        bossWatchChangeSummaries = []
        save()
        refreshWorkbenchMCPRegistration()
        Task {
            await refreshBossDashboard()
        }
    }

    func selectProject(_ projectId: UUID) {
        guard state.projects.contains(where: { $0.id == projectId }) else {
            return
        }
        selectedProjectID = projectId
        selectedEntryID = sessionEntries.first?.id
    }

    func createGroup(name: String, rootPath: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Group name is required"
            return false
        }
        guard !trimmedRoot.isEmpty else {
            errorMessage = "Group root path is required"
            return false
        }
        let project = WorkbenchProject(
            name: trimmedName,
            rootPath: trimmedRoot,
            boss: state.boss
        )
        state.projects.append(project)
        selectedProjectID = project.id
        selectedEntryID = nil
        save()
        return true
    }

    func beginEditingGroup(_ project: WorkbenchProject) {
        guard state.projects.contains(where: { $0.id == project.id }) else {
            errorMessage = "Group no longer exists: \(project.name)"
            return
        }
        editingGroup = project
    }

    @discardableResult
    func renameGroup(_ project: WorkbenchProject, name: String, rootPath: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Group name is required"
            return false
        }
        guard !trimmedRoot.isEmpty else {
            errorMessage = "Group root path is required"
            return false
        }
        guard let index = state.projects.firstIndex(where: { $0.id == project.id }) else {
            errorMessage = "Group no longer exists: \(project.name)"
            return false
        }
        state.projects[index].name = trimmedName
        state.projects[index].rootPath = trimmedRoot
        editingGroup = nil
        recordActionLog(
            source: "native",
            action: "editGroup",
            targetName: trimmedName,
            result: "Edited group \(trimmedName)",
            succeeded: true
        )
        return true
    }

    func requestDeleteGroup(_ project: WorkbenchProject) {
        guard state.projects.count > 1 else {
            errorMessage = "Keep at least one terminal group"
            return
        }
        guard totalTerminalCount(in: project) == 0 else {
            errorMessage = "Move or delete terminals before deleting \(project.name)"
            return
        }
        pendingDeleteGroup = project
    }

    func deleteGroup(_ project: WorkbenchProject) {
        guard state.projects.count > 1 else {
            errorMessage = "Keep at least one terminal group"
            return
        }
        guard totalTerminalCount(in: project) == 0 else {
            errorMessage = "Move or delete terminals before deleting \(project.name)"
            pendingDeleteGroup = nil
            return
        }
        state.projects.removeAll { $0.id == project.id }
        pendingDeleteGroup = nil
        if selectedProjectID == project.id {
            selectedProjectID = state.projects.first?.id
            selectedEntryID = sessionEntries.first?.id
        }
        recordActionLog(
            source: "native",
            action: "deleteGroup",
            targetName: project.name,
            result: "Deleted empty group \(project.name)",
            succeeded: true
        )
    }

    func moveSession(_ entry: ProcessEntry, to projectId: UUID) {
        guard let project = state.projects.first(where: { $0.id == projectId }) else {
            errorMessage = "Target group no longer exists"
            return
        }
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before moving it"
            return
        }
        guard let index = state.processEntries.firstIndex(where: { $0.id == entry.id }) else {
            errorMessage = "Terminal no longer exists: \(entry.name)"
            return
        }
        state.processEntries[index].projectId = projectId
        state.processEntries[index].workingDirectory = project.rootPath
        selectedProjectID = projectId
        selectedEntryID = entry.id
        recordActionLog(
            source: "native",
            action: "moveSession",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Moved \(entry.name) to \(project.name)",
            succeeded: true
        )
    }

    func setBossPaneCollapsed(_ collapsed: Bool) {
        guard state.bossPaneCollapsed != collapsed else {
            return
        }
        state.bossPaneCollapsed = collapsed
        save()
    }

    func setBossWatchEnabled(_ enabled: Bool) {
        guard bossWatchIsEnabled != enabled else {
            return
        }
        bossWatchIsEnabled = enabled
        state.bossWatchEnabled = enabled
        bossWatchLastError = nil
        if enabled {
            bossWatchBaselineState = state
            bossWatchChangeSummaries = []
            bossWatchLastPromptAt = nil
            save()
            Task {
                await runBossWatchTick(force: true)
            }
        } else {
            bossWatchBaselineState = nil
            bossWatchChangeSummaries = []
            bossWatchLastRunAt = nil
            bossWatchLastPromptAt = nil
            save()
        }
    }

    func runBossWatchLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: bossWatchIntervalNanoseconds)
            guard bossWatchIsEnabled else {
                continue
            }
            await runBossWatchTick(force: false)
        }
    }

    func runBossWatchTick(force: Bool) async {
        guard bossWatchIsEnabled, !bossCheckInIsRunning, !bossWatchTickIsRunning else {
            return
        }
        bossWatchTickIsRunning = true
        defer {
            bossWatchTickIsRunning = false
        }
        let observedAt = Date()
        let previousState = bossWatchBaselineState ?? state
        let changes = changeSummarizer.summarize(previous: previousState, current: state, occurredAt: observedAt)

        let hasActionableState = !summary.waitingOnHuman.isEmpty || !summary.needsRecovery.isEmpty
        let shouldAskBoss = force || !changes.isEmpty || (hasActionableState && bossWatchLastPromptAt == nil)
        bossWatchLastRunAt = observedAt
        guard shouldAskBoss else {
            recordBossWatchChanges(changes)
            bossWatchBaselineState = state
            return
        }

        await runBossCheckIn(
            question: bossBridgePlanner.watchQuestion(),
            recentChanges: changes
        )
        bossWatchLastPromptAt = Date()
        let finalChanges = changeSummarizer.summarize(previous: previousState, current: state, occurredAt: Date())
        recordBossWatchChanges(finalChanges.isEmpty ? changes : finalChanges)
        bossWatchBaselineState = state
    }

    func refreshWorkbenchMCPRegistration() {
        let selectedSnapshot = bossWorkbenchMCPRegistrar.snapshot(for: state.boss)
        bossWorkbenchMCPRegistration = selectedSnapshot
        var snapshots = Dictionary(
            uniqueKeysWithValues: ouroAgents.map { agent in
                (
                    agent.name,
                    bossWorkbenchMCPRegistrar.snapshot(for: BossAgentSelection(agentName: agent.name))
                )
            }
        )
        snapshots[state.boss.agentName] = selectedSnapshot
        bossWorkbenchMCPRegistrationByAgentName = snapshots
    }

    func refreshExecutableHealth() {
        executableHealthByEntryID = Dictionary(
            uniqueKeysWithValues: allSessionEntries.map { entry in
                let executable = ExecutableHealthTarget.executable(for: entry)
                return (entry.id, executableHealthChecker.health(for: executable))
            }
        )
    }

    func installWorkbenchMCPForBoss() {
        let selectedAgent = ouroAgents.first {
            $0.name.caseInsensitiveCompare(state.boss.agentName) == .orderedSame
        } ?? OuroAgentRecord(
            name: state.boss.agentName,
            bundlePath: "",
            configPath: bossWorkbenchMCPRegistration?.agentConfigPath ?? "",
            status: .ready,
            detail: "selected boss"
        )
        installWorkbenchMCP(for: selectedAgent)
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

    func searchTranscripts() {
        let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptSearchLastQuery = query.isEmpty ? nil : query
        transcriptSearchResults = transcriptSearcher.search(
            query: query,
            state: state,
            maxMatches: TranscriptSearchLimit.defaultMatches
        )
    }

    func transcriptSearchQueryDidChange() {
        let query = transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != transcriptSearchLastQuery else {
            return
        }
        transcriptSearchResults = []
        transcriptSearchLastQuery = nil
    }

    func runRecoveryDrill() {
        recoveryDrillResult = recoveryDrill.run(state: state)
    }

    func performCommand(_ command: WorkbenchCommandID) {
        switch command {
        case .newSession:
            isNewSessionSheetPresented = true
        case .bossCheckIn:
            guard !bossCheckInIsRunning else {
                errorMessage = "A boss check-in is already running"
                return
            }
            Task {
                await runBossCheckIn()
            }
        case .toggleBossWatch:
            setBossWatchEnabled(!bossWatchIsEnabled)
        case .installOuroAgent:
            isOuroAgentInstallSheetPresented = true
        case .launchSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            launch(selectedEntry)
        case .stopSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            terminate(selectedEntry)
        case .recoverSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            recover(selectedEntry)
        case .searchTranscripts:
            setBossPaneCollapsed(false)
            searchTranscripts()
        case .runRecoveryDrill:
            runRecoveryDrill()
        }
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

    func prepareBossCheckIn(
        question: String? = nil,
        recentChanges: [WorkspaceChangeSummary] = []
    ) {
        let question = question ?? bossBridgePlanner.checkInQuestion()
        bossCheckInPrompt = bossPromptBuilder.checkInPrompt(
            question: question,
            state: state,
            summary: summary,
            dashboard: bossDashboard,
            executableHealth: executableHealthByEntryID,
            ouroAgents: ouroAgents,
            recentChanges: recentChanges
        )
    }

    func runBossCheckIn() async {
        setBossPaneCollapsed(false)
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(), recentChanges: [])
    }

    func runBossQuestion() async {
        let question = bossQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            return
        }
        setBossPaneCollapsed(false)
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(userQuestion: question), recentChanges: [])
    }

    func runBossQuickQuestion(_ question: String) async {
        bossQuestion = question
        setBossPaneCollapsed(false)
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(userQuestion: question), recentChanges: [])
    }

    func runBossQuestion(about entry: ProcessEntry) async {
        let shortQuestion = "What is going on with \(entry.name)?"
        bossQuestion = shortQuestion
        setBossPaneCollapsed(false)
        let question = """
        Focus on \(entry.name) (id=\(entry.id.uuidString)). Tell Ari what this session is doing, whether it is waiting on him, and what should happen next. If the next step is obvious for a trusted session, use auditable Workbench actions.
        """
        await runBossCheckIn(question: bossBridgePlanner.checkInQuestion(userQuestion: question), recentChanges: [])
    }

    private func runBossCheckIn(
        question: String,
        recentChanges: [WorkspaceChangeSummary]
    ) async {
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
        prepareBossCheckIn(question: question, recentChanges: recentChanges)
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
            bossWatchLastError = nil
        } catch {
            bossCheckInAnswer = "Check-in failed: \(error.localizedDescription)"
            bossAppliedActions = []
            if bossWatchIsEnabled {
                bossWatchLastError = error.localizedDescription
            }
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

    func focusTerminal(_ entry: ProcessEntry) {
        guard activeSessions[entry.id] != nil else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        terminalFocusEntryID = entry.id
    }

    func exitTerminalFocus() {
        terminalFocusEntryID = nil
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
        markTerminated(entryId: entry.id, runId: session.plan.runId, rawStatus: nil)
    }

    @discardableResult
    func createCustomSession(_ draft: CustomTerminalSessionDraft, launchAfterCreate: Bool) -> ProcessEntry? {
        do {
            if state.projects.isEmpty {
                state = bootstrapper.bootstrappedState(from: state)
            }
            guard let project = selectedProject ?? state.projects.first else {
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
        guard let runIndex = state.processRuns.firstIndex(where: { $0.id == runId && $0.entryId == entryId }),
              state.processRuns[runIndex].status == .running
        else {
            return
        }
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
            if terminalFocusEntryID == entryId {
                terminalFocusEntryID = nil
            }
            updateEntry(entryId) { entry in
                entry.attention = nextRunStatus == .manualActionNeeded ? .needsBossReview : .idle
                if nextRunStatus == .manualActionNeeded {
                    entry.lastSummary = "\(entry.name) recovery attempt exited with code \(status.exitCode.map(String.init) ?? "unknown")"
                } else {
                    entry.lastSummary = "\(entry.name) exited with code \(status.exitCode.map(String.init) ?? "unknown")"
                }
            }
        }
        state.processRuns[runIndex].status = nextRunStatus
        state.processRuns[runIndex].endedAt = Date()
        state.processRuns[runIndex].exitCode = status.exitCode
        state.processRuns[runIndex].rawExitStatus = status.rawWaitStatus
        save()
    }

    private func load() {
        do {
            let loaded = try store.load()
            state = startupRecoveryReconciler.reconcile(bootstrapper.bootstrappedState(from: loaded))
            bossWatchIsEnabled = state.bossWatchEnabled
            bossWatchBaselineState = bossWatchIsEnabled ? state : nil
            selectedProjectID = state.selectedProjectId.flatMap { id in
                state.projects.contains(where: { $0.id == id }) ? id : nil
            } ?? state.projects.first?.id
            selectedEntryID = state.selectedEntryId.flatMap { id in
                sessionEntries.contains(where: { $0.id == id }) ? id : nil
            } ?? sessionEntries.first?.id
            try store.save(state)
        } catch {
            errorMessage = String(describing: error)
            state = bootstrapper.bootstrappedState(from: WorkspaceState())
            bossWatchIsEnabled = state.bossWatchEnabled
            bossWatchBaselineState = nil
            selectedProjectID = state.projects.first?.id
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

    private func recordBossWatchChanges(_ changes: [WorkspaceChangeSummary]) {
        guard !changes.isEmpty else {
            return
        }
        var seen = Set<UUID>()
        bossWatchChangeSummaries = Array((changes + bossWatchChangeSummaries).filter { change in
            seen.insert(change.id).inserted
        }.prefix(25))
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
        let terminal = session.terminal
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: CapturingLocalProcessTerminalView, context: Context) {}
}

@MainActor
final class TerminalSessionController: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let plan: TerminalCommandPlan
    let terminal: CapturingLocalProcessTerminalView
    private let environmentValues: [String: String]
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
        self.environmentValues = TerminalEnvironment().valuesWithResolvedPath()
        self.environment = environmentValues
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
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
        terminatePersistentSessionIfNeeded()
        terminal.terminate()
    }

    private func terminatePersistentSessionIfNeeded() {
        guard let sessionName = plan.persistentSessionName else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PersistentTerminalSession.executable)
        process.arguments = PersistentTerminalSession.terminateArguments(sessionName: sessionName)
        process.environment = environmentValues
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The attached terminal process may already be gone; the Workbench stop path
            // still terminates the local client below and records the run as manually ended.
        }
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
