#if os(macOS)
import AppKit
import OuroWorkbenchCore
import SwiftTerm
import SwiftUI

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
                    ZStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            HeaderView(model: model)
                            Divider()
                            if !model.state.bossPaneCollapsed {
                                BossDashboardView(model: model)
                                Divider()
                            }
                            if let agentName = model.selectedAgentName,
                               let agent = model.ouroAgent(named: agentName) {
                                AgentDetailView(agent: agent, model: model)
                            } else if let entry = model.selectedEntry {
                                SessionDetailView(entry: entry, model: model)
                            } else {
                                AgentHomeEmptyState(model: model)
                            }
                        }
                        ImportSummaryBanner(model: model)
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
            model.refreshOnboardingReadiness()
            await model.refreshBossDashboard()
            if model.shouldPresentOnboardingOnLaunch {
                model.isOnboardingPresented = true
            }
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
        .sheet(isPresented: $model.isOnboardingPresented) {
            WorkbenchOnboardingSheet(model: model)
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
    private static let frameAutosaveName = "OuroWorkbenchMainWindow"

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
        window.minSize = NSSize(width: 1100, height: 700)
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }
}

/// Slim slide-in banner that confirms what Arrange just did. Auto-dismisses
/// after a few seconds; user can dismiss it explicitly with the close button.
struct ImportSummaryBanner: View {
    @ObservedObject var model: WorkbenchViewModel
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let summary = model.lastImportSummary {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: summary.hasImports ? "checkmark.seal.fill" : "info.circle.fill")
                        .foregroundStyle(summary.hasImports ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.headline)
                            .font(.subheadline.weight(.semibold))
                        if let detail = summary.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 8)
                    if let entryID = summary.firstSelectedEntryID,
                       model.state.processEntries.contains(where: { $0.id == entryID }) {
                        Button("Open") {
                            model.selectedEntryID = entryID
                            model.lastImportSummary = nil
                        }
                        .controlSize(.small)
                    }
                    Button {
                        model.lastImportSummary = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
                .padding(.top, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: 560)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    scheduleDismiss()
                }
                .onDisappear {
                    dismissTask?.cancel()
                    dismissTask = nil
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.lastImportSummary)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled {
                model.lastImportSummary = nil
            }
        }
    }
}

/// Default detail-pane content when nothing is selected: surface the agent
/// hatching + onboarding entry points instead of an empty "no session" card.
struct AgentHomeEmptyState: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "infinity")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Pick a terminal — or hatch a new one")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Ouro Workbench is a calm home for your terminal agents. Choose one on the left to open its live session, or set up a fresh Ouro agent below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 540)
            }
            HStack(spacing: 12) {
                Button {
                    model.isOuroAgentInstallSheetPresented = true
                } label: {
                    Label("Hatch an Agent", systemImage: "sparkles")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Install or refresh an Ouro agent bundle on this Mac.")

                Button {
                    model.presentOnboarding()
                } label: {
                    Label("Set Up Workbench", systemImage: "wand.and.stars")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Choose a boss, connect MCP tools, and import recent terminals.")

                Button {
                    model.isNewSessionSheetPresented = true
                } label: {
                    Label("New Terminal", systemImage: "plus")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Open a blank terminal session.")
            }
            if !model.ouroAgents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                        Text("Installed agents")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.ouroAgents) { agent in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(agent.status == .ready ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(agent.name)
                                .font(.callout.monospaced())
                            Spacer()
                            if agent.name == model.state.boss.agentName {
                                Text("boss")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: 440)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct WorkbenchSidebarView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        List(selection: $model.selectedEntryID) {
            Section("Agents") {
                ForEach(model.ouroAgents) { agent in
                    SidebarAgentRow(
                        agent: agent,
                        isBoss: model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame,
                        isSelected: model.selectedAgentName?.caseInsensitiveCompare(agent.name) == .orderedSame,
                        select: { model.selectAgent(agent.name) }
                    )
                }
                if model.ouroAgents.isEmpty {
                    SidebarActionRow(title: "Hatch Your First Agent", systemImage: "sparkles") {
                        model.isOuroAgentInstallSheetPresented = true
                    }
                } else {
                    SidebarActionRow(title: "Hatch / Clone Agent", systemImage: "plus") {
                        model.isOuroAgentInstallSheetPresented = true
                    }
                }
            }
            Section("Groups") {
                ForEach(model.state.projects) { project in
                    SidebarProjectRow(
                        project: project,
                        activeTerminalCount: model.terminalCount(in: project),
                        totalTerminalCount: model.totalTerminalCount(in: project),
                        isSelected: model.selectedProject?.id == project.id,
                        canDelete: model.totalTerminalCount(in: project) == 0 && model.state.projects.count > 1,
                        select: {
                            model.selectProject(project.id)
                        },
                        rename: {
                            model.beginEditingGroup(project)
                        },
                        delete: {
                            model.requestDeleteGroup(project)
                        }
                    )
                }
                SidebarActionRow(title: "New Group", systemImage: "folder.badge.plus") {
                    model.isNewGroupSheetPresented = true
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
                SidebarActionRow(title: "New Terminal", systemImage: "plus") {
                    model.isNewSessionSheetPresented = true
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

struct SidebarProjectRow: View {
    var project: WorkbenchProject
    var activeTerminalCount: Int
    var totalTerminalCount: Int
    var isSelected: Bool
    var canDelete: Bool
    var select: () -> Void
    var rename: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "folder.fill" : "folder")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .fontWeight(isSelected ? .semibold : .regular)
                        Text(project.rootPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            SidebarCountBadge(count: activeTerminalCount)

            Menu {
                Button(action: rename) {
                    Label("Rename Group", systemImage: "pencil")
                }
                Button(role: .destructive, action: delete) {
                    Label("Delete Empty Group", systemImage: "trash")
                }
                .disabled(!canDelete)
            } label: {
                Label("Group Actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .help("Group actions")
            .fixedSize()
        }
        .padding(.vertical, 1)
        .help(project.rootPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name), \(activeTerminalCount) active terminals, \(totalTerminalCount) total terminals, root \(project.rootPath)")
    }
}

struct SidebarActionRow: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Compact sidebar row representing one Ouro agent bundle. Clicking selects
/// the agent in the detail pane; the boss flag and a health dot keep status
/// glanceable.
struct SidebarAgentRow: View {
    var agent: OuroAgentRecord
    var isBoss: Bool
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isBoss {
                            Text("boss")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .fixedSize()
                        }
                    }
                    if let lane = agent.humanFacing?.summary {
                        Text(lane)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(agent.detail)
    }

    private var statusColor: SwiftUI.Color {
        switch agent.status {
        case .ready:
            return .green
        case .disabled, .missingConfig:
            return .orange
        case .invalidConfig:
            return .red
        }
    }
}

struct SidebarCountBadge: View {
    var count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 16, minHeight: 16)
            .background(.secondary.opacity(0.10), in: Capsule())
            .accessibilityLabel("\(count) active terminals")
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
        HStack(alignment: .center, spacing: 10) {
            BossSelectorView(model: model)
                .layoutPriority(2)
            Text(model.summary.oneLineStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.summary.oneLineStatus)
            Spacer(minLength: 8)
            AutonomyStatusButton(model: model)
                .fixedSize()
            Button {
                model.setBossPaneCollapsed(!model.state.bossPaneCollapsed)
            } label: {
                Label(
                    model.state.bossPaneCollapsed ? "Show Boss Pane" : "Hide Boss Pane",
                    systemImage: model.state.bossPaneCollapsed
                        ? "chevron.compact.down"
                        : "chevron.compact.up"
                )
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(model.state.bossPaneCollapsed ? "Show boss dashboard" : "Hide boss dashboard")
            .fixedSize()
            Menu {
                Button {
                    model.presentOnboarding()
                } label: {
                    Label("Set Up Workbench…", systemImage: "wand.and.stars")
                }
                Button {
                    model.isOuroAgentInstallSheetPresented = true
                } label: {
                    Label("Hatch an Agent…", systemImage: "sparkles")
                }
                Divider()
                Toggle(isOn: Binding(
                    get: { model.bossWatchIsEnabled },
                    set: { model.setBossWatchEnabled($0) }
                )) {
                    Label("Boss Watch", systemImage: "eye")
                }
                .disabled(model.bossCheckInIsRunning)
                Button {
                    Task {
                        model.refreshExecutableHealth()
                        await model.refreshBossDashboard()
                    }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More Workbench actions")
            Button {
                model.isCommandPalettePresented = true
            } label: {
                Label("Commands", systemImage: "command")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("k", modifiers: [.command])
            .help("Open the command palette (⌘K)")
            .fixedSize()
            Button {
                Task {
                    await model.runBossCheckIn()
                }
            } label: {
                Label("Check In", systemImage: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.bossCheckInIsRunning)
            .keyboardShortcut("i", modifiers: [.command])
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
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
            Divider()
            Button {
                model.selectAgent(model.state.boss.agentName)
            } label: {
                Label("Manage Agents…", systemImage: "person.2.badge.gearshape")
            }
            Button {
                model.isOuroAgentInstallSheetPresented = true
            } label: {
                Label("Hatch / Clone Agent…", systemImage: "sparkles")
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

struct OnboardingBossChoice: Identifiable {
    var id: String { name }
    var name: String
    var detail: String
    var status: OuroAgentBundleStatus?
    var registrationStatus: BossWorkbenchMCPRegistrationStatus?
    var isSelected: Bool

    var isUsable: Bool {
        status == .ready && BossWorkbenchMCPRegistrar.isValidAgentBundleName(name)
    }

    var statusLabel: String {
        switch status {
        case .ready?:
            return "ready"
        case .disabled?:
            return "disabled"
        case .missingConfig?:
            return "missing config"
        case .invalidConfig?:
            return "invalid config"
        case nil:
            return "missing"
        }
    }

    var statusColor: SwiftUI.Color {
        switch status {
        case .ready?:
            return .green
        case .disabled?, .missingConfig?, .invalidConfig?, nil:
            return .orange
        }
    }

    var registrationIsCurrent: Bool {
        registrationStatus == .registered
    }

    var registrationActionTitle: String {
        switch registrationStatus {
        case .registered?:
            return "Tools On"
        case .needsUpdate?:
            return "Update Tools"
        default:
            return "Enable Tools"
        }
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
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct DashboardRowLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .frame(width: 132, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DashboardStatusLine: View {
    var text: String
    var color: SwiftUI.Color = .secondary
    var help: String?
    var truncationMode: Text.TruncationMode = .middle

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(truncationMode)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .help(help ?? text)
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
                    if model.filteredCommandPaletteItems.isEmpty {
                        ContentUnavailableView(
                            "No Commands",
                            systemImage: "command",
                            description: Text("Try another action, terminal name, or alias.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
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

/// Calm, terminal-first boss pane. The "Essentials" section shows the only
/// things you usually need at-a-glance — needs-me / coding counts, watch
/// status, the boss text field, and the latest reply. Everything else
/// (Ouro agent manager, transcript search, machine runtime, release updates,
/// recovery drill, MCP setup, full action log) lives behind an Advanced
/// disclosure so it never eats the screen.
struct BossDashboardView: View {
    @ObservedObject var model: WorkbenchViewModel
    @State private var showsAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.bossCheckInIsRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Asking \(model.state.boss.agentName)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let dashboard = model.bossDashboard {
                    DashboardMetricsStrip(dashboard: dashboard)
                }
                if let dashboard = model.bossDashboard,
                   !dashboard.availability.issues.isEmpty {
                    MailboxWarningView(issues: dashboard.availability.issues)
                }
                BossConversationView(model: model)
                if let answer = model.bossCheckInAnswer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Boss Reply")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(answer)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.tail)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
                if let dashboard = model.bossDashboard,
                   !dashboard.needsMeItems.isEmpty || !dashboard.codingItems.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        if !dashboard.needsMeItems.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Needs Me")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(dashboard.needsMeItems.prefix(3))) { item in
                                    Text("\(item.label) – \(item.detail)")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !dashboard.codingItems.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Coding")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(dashboard.codingItems.prefix(3))) { item in
                                    Text("\(item.runner) – \(item.status)")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsAdvanced.toggle()
                    }
                } label: {
                    Label(showsAdvanced ? "Hide Advanced" : "Show Advanced", systemImage: showsAdvanced ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Watch, agent manager, transcript search, runtime, release, recovery drill, and the full action log live here.")
                if showsAdvanced {
                    VStack(alignment: .leading, spacing: 10) {
                        BossWatchStatusView(model: model)
                        OuroAgentManagerView(model: model)
                        TranscriptSearchView(model: model)
                        MachineRuntimeView(model: model)
                        ReleaseUpdateView(model: model)
                        RecoveryDrillView(model: model)
                        BossWorkbenchMCPSetupView(model: model)
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
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 100, idealHeight: showsAdvanced ? 320 : 160, maxHeight: showsAdvanced ? 380 : 200, alignment: .topLeading)
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
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(issues.joined(separator: "\n"))
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
                HStack(spacing: 6) {
                    Image(systemName: "person.2.badge.gearshape")
                        .frame(width: 16)
                    Text("Ouro Agents")
                }
                    .font(.caption.weight(.semibold))
                    .fixedSize()
                Text(model.ouroAgentStatusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Button {
                    model.refreshOuroAgents()
                } label: {
                    Label("Refresh Agents", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh local Ouro agents")
                .fixedSize()
                Button {
                    model.isOuroAgentInstallSheetPresented = true
                } label: {
                    Label("Install Agent", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .fixedSize()
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
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame {
                        StatusPill(text: "boss", color: .blue)
                            .fixedSize()
                    }
                    if let registration {
                        StatusPill(text: registrationPillText(registration.status), color: registrationTint(registration.status))
                            .fixedSize()
                    }
                }
                Text(agent.summaryLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button {
                model.selectBoss(agentName: agent.name)
            } label: {
                Label("Use as Boss", systemImage: "person.crop.circle.badge.checkmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Use \(agent.name) as boss")
            .disabled(!agent.isUsableAsBoss || model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame)
            .fixedSize()
            if registration?.isActionable == true {
                Button {
                    model.installWorkbenchMCP(for: agent)
                } label: {
                    Label(registration?.status == .needsUpdate ? "Update MCP" : "Install MCP", systemImage: "link.badge.plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(registration?.detail ?? "Register Workbench MCP")
                .fixedSize()
            }
            Button {
                model.revealAgentBundle(agent)
            } label: {
                Label("Reveal Bundle", systemImage: "folder")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(agent.bundlePath)
            .fixedSize()
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

struct WorkbenchOnboardingSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var instructionStatus: String?
    @State private var page: OnboardingPage = .welcome

    fileprivate enum OnboardingPage: Int, CaseIterable {
        case welcome
        case boss
        case connect
        case importWork

        var title: String {
            switch self {
            case .welcome:
                return "Welcome"
            case .boss:
                return "Choose Boss"
            case .connect:
                return "Connect"
            case .importWork:
                return "Import"
            }
        }

        var systemImage: String {
            switch self {
            case .welcome:
                return "sparkles"
            case .boss:
                return "person.crop.circle.badge.checkmark"
            case .connect:
                return "link"
            case .importWork:
                return "square.grid.2x2"
            }
        }

        var next: OnboardingPage? {
            OnboardingPage(rawValue: rawValue + 1)
        }

        var previous: OnboardingPage? {
            OnboardingPage(rawValue: rawValue - 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingFlowHeader(page: page, dismiss: dismiss)

            Divider()

            OnboardingPageContent(page: page, model: model)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Button {
                        if let previous = page.previous {
                            page = previous
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .disabled(page.previous == nil)

                    Spacer()

                    OnboardingProgressDots(page: page)

                    Spacer()

                    Button {
                        advance()
                    } label: {
                        Label(primaryActionTitle, systemImage: primaryActionImage)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryActionIsDisabled)
                    .keyboardShortcut(.defaultAction)
                }

                OnboardingAssistantBox(
                    model: model,
                    instruction: $instruction,
                    instructionStatus: instructionStatus,
                    onSubmit: handleInstruction
                )
            }
            .padding(22)
        }
        .frame(width: 860, height: 680)
        .onAppear {
            model.refreshOuroAgents()
            model.refreshWorkbenchMCPRegistration()
            model.refreshOnboardingReadiness()
            model.runOnboardingProviderChecksIfNeeded()
        }
    }

    private func handleInstruction() {
        let text = instruction
        instruction = ""
        instructionStatus = model.handleOnboardingInstruction(text)
        syncPageAfterInstruction(text)
    }

    private var primaryActionTitle: String {
        switch page {
        case .welcome:
            return "Begin"
        case .boss:
            return "Continue"
        case .connect:
            return model.onboardingReadiness?.isReady == true ? "Scan Recent Work" : "Finish Setup"
        case .importWork:
            return model.onboardingProposal == nil ? "Scan" : "Arrange"
        }
    }

    private var primaryActionImage: String {
        switch page {
        case .welcome, .boss:
            return "chevron.right"
        case .connect:
            return "magnifyingglass"
        case .importWork:
            return model.onboardingProposal == nil ? "magnifyingglass" : "checkmark.circle"
        }
    }

    private var primaryActionIsDisabled: Bool {
        switch page {
        case .welcome:
            return false
        case .boss:
            return model.onboardingBossChoices.contains { $0.isSelected && $0.isUsable } == false
        case .connect:
            return model.onboardingReadiness?.isReady != true
        case .importWork:
            if model.onboardingIsScanning || model.onboardingReadiness?.isReady != true {
                return true
            }
            // Once a proposal is on screen, Arrange should be gated by whether
            // anything is actually selected — otherwise the button "does nothing".
            if let proposal = model.onboardingProposal, proposal.selectedTerminalCount == 0 {
                return true
            }
            return false
        }
    }

    private func advance() {
        switch page {
        case .welcome:
            page = .boss
        case .boss:
            page = .connect
        case .connect:
            page = .importWork
            if model.onboardingReadiness?.isReady == true, model.onboardingProposal == nil {
                model.scanForOnboardingSessions()
            }
        case .importWork:
            if model.onboardingProposal == nil {
                model.scanForOnboardingSessions()
            } else {
                let result = model.applyOnboardingProposal()
                // Whether anything new landed or every selection was already
                // imported, hand the user back to the workbench with a banner
                // explaining what just happened. The banner is set by the apply
                // path itself.
                if result != nil {
                    dismiss()
                }
            }
        }
    }

    private func syncPageAfterInstruction(_ text: String) {
        let lowered = text.lowercased()
        if lowered.contains("scan") || lowered.contains("bootstrap") {
            page = model.onboardingReadiness?.isReady == true ? .importWork : .connect
        } else if lowered.contains("mcp") || lowered.contains("tool") || lowered.contains("provider") {
            page = .connect
        }
    }
}

private struct OnboardingFlowHeader: View {
    var page: WorkbenchOnboardingSheet.OnboardingPage
    var dismiss: DismissAction

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: page.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                Text("Ouro Workbench")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }
}

private struct OnboardingPageContent: View {
    var page: WorkbenchOnboardingSheet.OnboardingPage
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 26) {
                switch page {
                case .welcome:
                    OnboardingWelcomePage()
                case .boss:
                    OnboardingBossChoiceView(model: model)
                case .connect:
                    OnboardingReadinessView(model: model)
                case .importWork:
                    OnboardingBootstrapView(model: model)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
        }
    }
}

private struct OnboardingWelcomePage: View {
    var body: some View {
        VStack(alignment: .center, spacing: 26) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .center, spacing: 12) {
                Text("Welcome to Ouro Workbench")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Your terminal agents stay real terminals. Your Ouro agent becomes the calm layer that knows what is happening and can keep work moving.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620)
            }
            HStack(alignment: .top, spacing: 26) {
                OnboardingWelcomePoint(systemImage: "terminal", title: "Keep Your Tools", detail: "Claude Code, Codex, Copilot CLI, shells, cmux.")
                OnboardingWelcomePoint(systemImage: "person.crop.circle.badge.checkmark", title: "Choose a Boss", detail: "One Ouro agent watches this Mac for you.")
                OnboardingWelcomePoint(systemImage: "square.grid.2x2", title: "Recover the Thread", detail: "Recent work returns as named project groups.")
            }
            .frame(maxWidth: 680)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

private struct OnboardingWelcomePoint: View {
    var systemImage: String
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(height: 28)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingProgressDots: View {
    var page: WorkbenchOnboardingSheet.OnboardingPage

    var body: some View {
        HStack(spacing: 7) {
            ForEach(WorkbenchOnboardingSheet.OnboardingPage.allCases, id: \.self) { candidate in
                Circle()
                    .fill(candidate == page ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: candidate == page ? 9 : 7, height: candidate == page ? 9 : 7)
                    .accessibilityLabel(candidate.title)
            }
        }
    }
}

private struct OnboardingAssistantBox: View {
    @ObservedObject var model: WorkbenchViewModel
    @Binding var instruction: String
    var instructionStatus: String?
    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Setup Assistant", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.caption.weight(.semibold))
                Text("Ask \(model.state.boss.agentName) for help, or type a setup request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.bossCheckInIsRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(alignment: .center, spacing: 8) {
                TextField("Ask about setup, providers, or which sessions to import", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)
                    .disabled(model.bossCheckInIsRunning)
                Button {
                    onSubmit()
                } label: {
                    Label("Ask", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.bossCheckInIsRunning)
            }

            if let instructionStatus {
                Label(instructionStatus, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let answer = model.bossCheckInAnswer {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.state.boss.agentName) replied")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(answer)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 88)
                }
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct OnboardingStatusRow: View {
    var systemImage: String
    var title: String
    var detail: String
    var color: SwiftUI.Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OnboardingBossChoiceView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(alignment: .center, spacing: 10) {
                Text("Who should watch this Mac?")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Pick the Ouro agent Workbench should ask when you say \"what's going on?\" Desk workers inside terminal sessions are separate.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640)
            }
            Button {
                model.refreshOuroAgents()
                model.refreshWorkbenchMCPRegistration()
                model.refreshOnboardingReadiness()
                model.runOnboardingProviderChecksIfNeeded()
            } label: {
                Label("Refresh Agents", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            if model.onboardingBossChoices.isEmpty {
                OnboardingStatusRow(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: "No local agents found",
                    detail: "Hatch a new agent or clone an existing bundle, then refresh this list.",
                    color: .orange
                )
                HStack(spacing: 8) {
                    Button {
                        model.launchOuroAgentInstall(mode: "hatch", agentName: "", remote: "")
                    } label: {
                        Label("Hatch Agent", systemImage: "plus.circle")
                    }
                    Button {
                        model.isOuroAgentInstallSheetPresented = true
                    } label: {
                        Label("Clone Agent", systemImage: "square.and.arrow.down")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.onboardingBossChoices) { choice in
                        OnboardingBossChoiceRow(choice: choice, model: model)
                    }
                }
                .frame(maxWidth: 660)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

private struct OnboardingBossChoiceRow: View {
    var choice: OnboardingBossChoice
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: choice.isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(choice.isSelected ? Color.accentColor : .secondary)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(choice.name)
                        .font(.headline.weight(.semibold))
                    if choice.isSelected {
                        StatusPill(text: "selected", color: .green)
                            .fixedSize()
                    }
                    StatusPill(text: choice.statusLabel, color: choice.statusColor)
                        .fixedSize()
                }
                Text(choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Button {
                model.registerWorkbenchForBossChoice(choice.name)
            } label: {
                Label(choice.registrationActionTitle, systemImage: choice.registrationIsCurrent ? "checkmark" : "link.badge.plus")
            }
            .controlSize(.small)
            .disabled(!choice.isUsable || choice.registrationIsCurrent)
            .help("Give this Ouro agent the Workbench tools it uses to inspect and control local sessions.")
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(choice.isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(choice.isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            guard choice.isUsable else {
                return
            }
            model.selectBoss(agentName: choice.name)
            model.refreshOnboardingReadiness()
        }
    }
}

private struct OnboardingReadinessView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(alignment: .center, spacing: 10) {
                Text("Give the boss its tools")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Workbench enables its local tool bridge and automatically verifies both provider lanes before import.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640)
            }
            if let readiness = model.onboardingReadiness {
                if readiness.isReady {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(Color.green)
                        Text("\(readiness.selectedBossName) is ready")
                            .font(.title3.weight(.semibold))
                        Text("Next, Workbench can look for recent terminal work and propose project groups.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: 520)
                    if !readiness.repairSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Optional checks")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(readiness.repairSteps) { step in
                                OnboardingRepairStepRow(step: step, model: model)
                            }
                        }
                        .frame(maxWidth: 660)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        OnboardingStatusRow(
                            systemImage: "exclamationmark.triangle.fill",
                            title: readiness.headline,
                            detail: readiness.detail,
                            color: .orange
                        )
                        ForEach(readiness.repairSteps) { step in
                            OnboardingRepairStepRow(step: step, model: model)
                        }
                    }
                    .frame(maxWidth: 660)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

private struct OnboardingRepairStepRow: View {
    var step: OnboardingRepairStep
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusPill(text: actorLabel, color: color)
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.caption.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if step.id == "workbench-mcp" {
                Button {
                    model.installWorkbenchMCPForBoss()
                    model.refreshOnboardingReadiness()
                    model.runOnboardingProviderChecksIfNeeded()
                } label: {
                    Label("Register", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if step.id.hasPrefix("check-") {
                ProgressView()
                    .controlSize(.small)
            } else if step.commandLine != nil {
                Button {
                    model.openOnboardingRepair(step)
                } label: {
                    Label(commandButtonTitle, systemImage: "terminal")
                }
                .controlSize(.small)
            }
        }
    }

    private var actorLabel: String {
        if step.id.hasPrefix("check-") {
            return "checking"
        }
        switch step.actor {
        case .agentRunnable:
            return "agent"
        case .humanRequired:
            return "you"
        case .humanChoice:
            return "choose"
        }
    }

    private var commandButtonTitle: String {
        step.id.hasPrefix("check-") ? "Run" : "Open"
    }

    private var color: SwiftUI.Color {
        switch step.actor {
        case .agentRunnable:
            return .blue
        case .humanRequired:
            return .orange
        case .humanChoice:
            return .purple
        }
    }
}

private struct OnboardingBootstrapView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 22) {
            VStack(alignment: .center, spacing: 10) {
                Text("Bring your work in")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Workbench can find recent cmux, Claude Code, Codex, Copilot CLI, shell, and Workbench sessions from the last week.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 640)
            }
            HStack(spacing: 10) {
                if model.onboardingIsScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    model.scanForOnboardingSessions()
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(model.onboardingIsScanning || model.onboardingReadiness?.isReady != true)
                if let proposal = model.onboardingProposal {
                    Button {
                        _ = model.applyOnboardingProposal()
                    } label: {
                        Label("Arrange", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        model.onboardingReadiness?.isReady != true
                        || proposal.selectedTerminalCount == 0
                    )
                    .help(
                        proposal.selectedTerminalCount == 0
                        ? "Select at least one terminal to arrange."
                        : "Import \(proposal.selectedTerminalCount) selected terminal\(proposal.selectedTerminalCount == 1 ? "" : "s") into the Workbench."
                    )
                }
            }
            if model.onboardingReadiness?.isReady != true {
                Text("Finish connecting the boss before scanning.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.onboardingIsScanning {
                Text("Scanning recent local sessions...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let proposal = model.onboardingProposal {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingStatusRow(
                        systemImage: "square.grid.2x2.fill",
                        title: model.onboardingReadiness?.isReady == true ? "Ready to arrange" : "Proposal waiting",
                        detail: "\(proposal.groups.count) group\(proposal.groups.count == 1 ? "" : "s"), \(proposal.selectedTerminalCount) terminal\(proposal.selectedTerminalCount == 1 ? "" : "s") selected.",
                        color: .blue
                    )
                    ForEach(proposal.groups) { group in
                        OnboardingGroupProposalView(group: group, model: model)
                    }
                    if !model.onboardingDeskChanges.isEmpty {
                        OnboardingStatusRow(
                            systemImage: "checkmark.seal.fill",
                            title: "Desk mirror updated",
                            detail: "Mirrored \(model.onboardingDeskChanges.count) Desk file\(model.onboardingDeskChanges.count == 1 ? "" : "s").",
                            color: .green
                        )
                    }
                }
                .frame(maxWidth: 700)
            } else {
                Text("Nothing is imported until you review the proposal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}

private struct OnboardingGroupProposalView: View {
    var group: ProposedWorkbenchGroup
    @ObservedObject var model: WorkbenchViewModel
    @State private var previewTerminal: ProposedTerminalImport?

    private var selectedCount: Int {
        group.terminals.filter(\.selectedByDefault).count
    }

    private var allSelected: Bool {
        !group.terminals.isEmpty && selectedCount == group.terminals.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    model.setOnboardingGroupSelection(groupID: group.id, selected: !allSelected)
                } label: {
                    Image(systemName: allSelected
                          ? "checkmark.square.fill"
                          : (selectedCount == 0 ? "square" : "minus.square.fill"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(allSelected ? "Deselect every terminal in this group" : "Select every terminal in this group")
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                    Text("Desk track: \(group.deskTrackSlug) - \(group.rootPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(selectedCount)/\(group.terminals.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(group.terminals) { terminal in
                ProposedTerminalRow(
                    terminal: terminal,
                    group: group,
                    model: model,
                    onToggle: {
                        model.toggleOnboardingSelection(groupID: group.id, terminalID: terminal.id)
                    },
                    onPreview: {
                        previewTerminal = terminal
                    }
                )
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .sheet(item: $previewTerminal) { terminal in
            OnboardingSessionPreviewSheet(group: group, terminal: terminal, model: model)
        }
    }
}

private struct ProposedTerminalRow: View {
    var terminal: ProposedTerminalImport
    var group: ProposedWorkbenchGroup
    @ObservedObject var model: WorkbenchViewModel
    var onToggle: () -> Void
    var onPreview: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: terminal.selectedByDefault ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(terminal.selectedByDefault ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(terminal.selectedByDefault ? "Selected" : "Not selected")
                VStack(alignment: .leading, spacing: 3) {
                    Text(terminal.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                    Text(terminal.candidate.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(terminal.candidate.resumeCommandLine)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let kind = terminal.candidate.agentKind,
                   let bridge = model.deskBridgePlan(for: kind),
                   let commandLine = bridge.commandLine {
                    Button {
                        model.openDeskBridgeSetup(bridge)
                    } label: {
                        Label("Desk Bridge", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(commandLine)
                }
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        onPreview()
                    } label: {
                        Label("Preview", systemImage: "text.bubble")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    Text("confidence \(Int(terminal.candidate.confidence * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help(model.onboardingConfidenceExplanation(for: terminal))
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(terminal.selectedByDefault ? Color.accentColor.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(terminal.selectedByDefault ? "Click to skip this terminal in Arrange" : "Click to include this terminal in Arrange")
    }
}

private struct OnboardingSessionPreviewSheet: View {
    var group: ProposedWorkbenchGroup
    var terminal: ProposedTerminalImport
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: terminal.candidate.agentKind == nil ? "terminal" : "text.bubble")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(terminal.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text("\(model.onboardingSourceLabel(for: terminal.candidate)) · \(group.name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    OnboardingPreviewInfoGrid(terminal: terminal, model: model)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What Workbench Found")
                            .font(.headline)
                        Text(terminal.candidate.summary)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session Preview")
                            .font(.headline)
                        Text(model.onboardingPreviewText(for: terminal))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 620)
    }
}

private struct OnboardingPreviewInfoGrid: View {
    var terminal: ProposedTerminalImport
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("Confidence").foregroundStyle(.secondary)
                Text("\(Int(terminal.candidate.confidence * 100))% - \(model.onboardingConfidenceExplanation(for: terminal))")
            }
            GridRow {
                Text("Resume").foregroundStyle(.secondary)
                Text(terminal.candidate.resumeCommandLine)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            GridRow {
                Text("Root").foregroundStyle(.secondary)
                Text(terminal.candidate.workingDirectory)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !terminal.candidate.evidencePaths.isEmpty {
                GridRow {
                    Text("Evidence").foregroundStyle(.secondary)
                    Text(terminal.candidate.evidencePaths.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
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
                        .fixedSize()
                    Text("\(entries.count) recent")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    actionLogEntryRow(entry)
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
                        actionLogEntryRow(entry)
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
        .fixedSize()
    }

    private func actionLogEntryRow(_ entry: WorkbenchActionLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(entry.succeeded ? .green : .orange)
                .fixedSize()
            Text(entry.occurredAt.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            Text("\(entry.source) \(entry.action)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
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
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .clipped()
        .help(actionLogEntryHelp(entry))
    }

    private func actionLogEntryHelp(_ entry: WorkbenchActionLogEntry) -> String {
        let target = entry.targetName.map { " \($0)" } ?? ""
        return "\(entry.source) \(entry.action)\(target): \(entry.result)"
    }
}

struct BossWatchStatusView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Label("Boss Watch", systemImage: model.bossWatchIsEnabled ? "eye.fill" : "eye")
                    .font(.caption.weight(.semibold))
                    .fixedSize()
                Text(model.bossWatchStatusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(model.bossWatchStatusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .help(model.bossWatchStatusLine)
            }
            if !model.bossWatchChangeSummaries.isEmpty {
                ForEach(model.bossWatchChangeSummaries.prefix(5)) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(change.occurredAt.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(change.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(change.detail)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                    }
                    .help("\(change.title): \(change.detail)")
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
                .fixedSize()
            }
            if !model.transcriptSearchResults.isEmpty {
                ForEach(model.transcriptSearchResults.prefix(6)) { match in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.groupName(for: match).map { "\($0) / \(match.entryName)" } ?? match.entryName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Text("line \(match.lineNumber)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(match.line)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
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
            DashboardRowLabel(title: "Workbench MCP", systemImage: "point.3.connected.trianglepath.dotted")
            DashboardStatusLine(
                text: model.bossWorkbenchMCPStatusLine,
                color: model.bossWorkbenchMCPStatusColor
            )
            Button {
                model.refreshWorkbenchMCPRegistration()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Refresh Workbench MCP registration")
            .fixedSize()
            if model.bossWorkbenchMCPRegistration?.isActionable == true {
                Button {
                    model.installWorkbenchMCPForBoss()
                } label: {
                    Label(model.bossWorkbenchMCPActionTitle, systemImage: "link.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .task {
            model.refreshWorkbenchMCPRegistration()
        }
    }
}

/// Detail pane for the Agents sidebar. Mirrors the SessionDetailView chrome
/// philosophy: a slim title strip with the essentials, a calm body card with
/// lane info + MCP status, and an inspector disclosure for the bundle paths
/// and detailed status. Lets the user switch boss, repair providers, fix MCP,
/// open agent.json, reveal the bundle, or clone — all without diving into the
/// dashboard's Advanced disclosure.
struct AgentDetailView: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    @State private var showsInspector = false

    private var isBoss: Bool {
        model.state.boss.agentName.caseInsensitiveCompare(agent.name) == .orderedSame
    }

    private var registration: BossWorkbenchMCPRegistrationSnapshot? {
        model.workbenchMCPRegistration(for: agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentTitleStrip(
                agent: agent,
                model: model,
                isBoss: isBoss,
                showsInspector: $showsInspector
            )
            Divider()
            if showsInspector {
                AgentInspectorPanel(agent: agent, model: model, registration: registration)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AgentStatusCard(agent: agent, model: model, registration: registration)
                    AgentLanesCard(agent: agent, model: model)
                    AgentActionsCard(agent: agent, model: model)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct AgentTitleStrip: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    var isBoss: Bool
    @Binding var showsInspector: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: showsInspector ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(showsInspector ? "Hide bundle details" : "Show bundle path and config status")

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(agent.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)

            if isBoss {
                Text("boss")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 6)

            Menu {
                Button {
                    model.openAgentConfig(agent)
                } label: {
                    Label("Open agent.json…", systemImage: "doc.text")
                }
                Button {
                    model.revealAgentBundle(agent)
                } label: {
                    Label("Reveal Bundle in Finder", systemImage: "folder")
                }
                Divider()
                Button {
                    model.repairAgent(agent)
                } label: {
                    Label("Run ouro check…", systemImage: "stethoscope")
                }
                .help("Open a Workbench terminal pre-loaded with `ouro check --agent \(agent.name)`")
                Button {
                    model.isOuroAgentInstallSheetPresented = true
                } label: {
                    Label("Hatch / Clone Another…", systemImage: "plus")
                }
                Divider()
                Button {
                    model.refreshOuroAgents()
                } label: {
                    Label("Refresh Agents", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .help("More actions for this agent")

            Button {
                model.selectBoss(agentName: agent.name)
            } label: {
                Label(isBoss ? "Boss" : "Use as Boss", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isBoss || !agent.isUsableAsBoss)
            .help(isBoss
                  ? "\(agent.name) is already this Mac's boss"
                  : (agent.isUsableAsBoss
                     ? "Make \(agent.name) this Mac's boss"
                     : "Bundle must be ready before it can act as boss"))
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
    }

    private var statusColor: SwiftUI.Color {
        switch agent.status {
        case .ready:
            return .green
        case .disabled, .missingConfig:
            return .orange
        case .invalidConfig:
            return .red
        }
    }
}

private struct AgentInspectorPanel: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    var registration: BossWorkbenchMCPRegistrationSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(agent.bundlePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(agent.configPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(agent.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if let registration {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("MCP: \(registration.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentStatusCard: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel
    var registration: BossWorkbenchMCPRegistrationSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusHeadline)
                        .font(.title3.weight(.semibold))
                    Text(agent.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer()
                if let registration, registration.isActionable {
                    Button {
                        model.installWorkbenchMCP(for: agent)
                    } label: {
                        Label(
                            registration.status == .needsUpdate ? "Update MCP" : "Install MCP",
                            systemImage: "link.badge.plus"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(registration.detail)
                }
            }
            HStack(spacing: 6) {
                StatusPill(
                    text: bundleStatusPillText,
                    color: statusColor
                )
                if let registration {
                    StatusPill(
                        text: "mcp \(mcpPillText(registration.status))",
                        color: mcpPillColor(registration.status)
                    )
                }
                if !agent.isUsableAsBoss {
                    StatusPill(text: "boss blocked", color: .secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var statusIcon: String {
        switch agent.status {
        case .ready:
            return "checkmark.seal.fill"
        case .disabled:
            return "pause.circle.fill"
        case .missingConfig:
            return "exclamationmark.triangle.fill"
        case .invalidConfig:
            return "xmark.octagon.fill"
        }
    }

    private var statusColor: SwiftUI.Color {
        switch agent.status {
        case .ready:
            return .green
        case .disabled, .missingConfig:
            return .orange
        case .invalidConfig:
            return .red
        }
    }

    private var statusHeadline: String {
        switch agent.status {
        case .ready:
            return "Bundle ready"
        case .disabled:
            return "Bundle disabled in agent.json"
        case .missingConfig:
            return "Bundle missing agent.json"
        case .invalidConfig:
            return "Bundle config could not be read"
        }
    }

    private var bundleStatusPillText: String {
        switch agent.status {
        case .ready:
            return "ready"
        case .disabled:
            return "disabled"
        case .missingConfig:
            return "no config"
        case .invalidConfig:
            return "invalid"
        }
    }

    private func mcpPillText(_ status: BossWorkbenchMCPRegistrationStatus) -> String {
        switch status {
        case .registered:
            return "registered"
        case .notRegistered:
            return "not registered"
        case .needsUpdate:
            return "needs update"
        case .agentMissing:
            return "agent missing"
        case .executableMissing:
            return "app missing"
        case .invalidConfig:
            return "config"
        }
    }

    private func mcpPillColor(_ status: BossWorkbenchMCPRegistrationStatus) -> SwiftUI.Color {
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

private struct AgentLanesCard: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Model providers")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.openAgentConfig(agent)
                } label: {
                    Label("Edit agent.json", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the agent bundle's agent.json in your default JSON editor")
            }
            LanePanel(title: "Human-facing", systemImage: "person.crop.circle", lane: agent.humanFacing)
            LanePanel(title: "Agent-facing", systemImage: "infinity", lane: agent.agentFacing)
            Text("Workbench edits agent.json out-of-band. Use `ouro check` (in More menu) to verify the new lane after you save.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct LanePanel: View {
    var title: String
    var systemImage: String
    var lane: OuroAgentLane?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let lane, lane.summary != nil {
                    HStack(spacing: 6) {
                        if let provider = lane.provider, !provider.isEmpty {
                            StatusPill(text: provider, color: .blue)
                        }
                        if let model = lane.model, !model.isEmpty {
                            Text(model)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } else {
                    Text("Not configured")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AgentActionsCard: View {
    var agent: OuroAgentRecord
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bundle actions")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                Button {
                    model.repairAgent(agent)
                } label: {
                    Label("Run ouro check", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .help("Opens a Workbench terminal running `ouro check --agent \(agent.name)`")
                Button {
                    model.openAgentConfig(agent)
                } label: {
                    Label("Open agent.json", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
                Button {
                    model.revealAgentBundle(agent)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    model.isOuroAgentInstallSheetPresented = true
                } label: {
                    Label("Hatch / Clone Another…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct SessionDetailView: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    @State private var showsInspector = false
    @State private var showsTranscriptSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionTitleStrip(
                entry: entry,
                model: model,
                showsInspector: $showsInspector
            )
            Divider()
            if showsInspector {
                SessionInspectorPanel(
                    entry: entry,
                    model: model,
                    onShowTranscript: { showsTranscriptSheet = true }
                )
                Divider()
            }
            if let session = model.activeSession(for: entry) {
                TerminalPane(session: session)
                    .id(session.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                InactiveTerminalSurface(
                    entry: entry,
                    model: model,
                    onShowTranscript: { showsTranscriptSheet = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
        }
        .sheet(isPresented: $showsTranscriptSheet) {
            SessionTranscriptSheet(entry: entry, model: model)
        }
    }
}

/// Slim, single-row session title strip. Status pills inline, a tight
/// keyboard-control cluster, and everything else hidden behind an inspector
/// chevron or an overflow menu. The terminal owns the screen.
private struct SessionTitleStrip: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    @Binding var showsInspector: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: showsInspector ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(showsInspector ? "Hide session details" : "Show session details, transcripts, and management actions")

            statusDot
                .frame(width: 8, height: 8)

            Text(entry.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)

            if let cliName = model.cliName(for: entry) {
                Text(cliName)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .fixedSize()
            }

            Spacer(minLength: 6)

            if entry.isArchived {
                Label("Archived", systemImage: "archivebox")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button {
                    model.restoreCustomSession(entry)
                } label: {
                    Label("Restore", systemImage: "tray.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            } else {
                if model.activeSession(for: entry) != nil {
                    RunningSessionHeaderControls(entry: entry, model: model)
                        .fixedSize()
                }
                Menu {
                    Button {
                        Task { await model.runBossQuestion(about: entry) }
                    } label: {
                        Label("Ask Boss About This Session", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .disabled(model.bossCheckInIsRunning)
                    Divider()
                    Button {
                        model.copyLaunchCommand(for: entry)
                    } label: {
                        Label("Copy Launch Command", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.openWorkingDirectory(for: entry)
                    } label: {
                        Label("Open Working Directory", systemImage: "folder")
                    }
                    .help(entry.workingDirectory)
                    if model.isCustomSession(entry) {
                        Divider()
                        Button {
                            model.beginEditingSession(entry)
                        } label: {
                            Label("Edit Session…", systemImage: "pencil")
                        }
                        .disabled(model.activeSession(for: entry) != nil)
                        Button {
                            model.duplicateCustomSession(entry)
                        } label: {
                            Label("Duplicate Session", systemImage: "plus.square.on.square")
                        }
                        Menu {
                            ForEach(model.state.projects) { project in
                                Button(project.name) {
                                    model.moveSession(entry, to: project.id)
                                }
                                .disabled(project.id == entry.projectId)
                            }
                        } label: {
                            Label("Move to Group", systemImage: "folder")
                        }
                        .disabled(model.activeSession(for: entry) != nil || model.state.projects.count < 2)
                        Button {
                            model.archiveCustomSession(entry)
                        } label: {
                            Label("Archive Session", systemImage: "archivebox")
                        }
                        Divider()
                        Button(role: .destructive) {
                            model.requestDeleteCustomSession(entry)
                        } label: {
                            Label("Delete Session…", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .controlSize(.small)
                .fixedSize()
                .help("More actions for this terminal")

                Button {
                    model.launch(entry)
                } label: {
                    Label(
                        model.activeSession(for: entry) == nil ? "Launch" : "Restart",
                        systemImage: "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command])
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
    }

    @ViewBuilder
    private var statusDot: some View {
        if entry.isArchived {
            Circle().fill(Color.secondary.opacity(0.5))
        } else if model.activeSession(for: entry) != nil {
            Circle().fill(Color.green)
        } else if model.canRecover(entry) {
            Circle().fill(Color.orange)
        } else {
            Circle().fill(Color.secondary)
        }
    }
}

/// Disclosure panel that owns everything the title strip dropped: pills,
/// resume command, transcript, notes, and recovery context. Closed by default.
private struct SessionInspectorPanel: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    var onShowTranscript: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.launchCommand(for: entry))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let notes = entry.trimmedNotes {
                SessionNotesView(notes: notes)
            }
            HStack(spacing: 10) {
                Text("Recovery: \(model.recoveryReason(for: entry))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if model.transcriptTail(for: entry) != nil {
                    Button {
                        onShowTranscript()
                    } label: {
                        Label("Transcript", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
    }
}

/// Modal sheet for transcript review — keeps the chrome out of the live view.
private struct SessionTranscriptSheet: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript")
                        .font(.title3.weight(.semibold))
                    Text(entry.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if let tail = model.transcriptTail(for: entry) {
                TranscriptHistoryView(tail: tail)
                    .padding()
            } else {
                Text("No transcript captured yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(width: 720, height: 540)
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

/// Calm, single-card view shown when the selected session is not currently
/// running. No fragmented transcript snippets, no embedded mini-terminal — just
/// the headline status, the launch command, and the one button you want.
struct InactiveTerminalSurface: View {
    var entry: ProcessEntry
    @ObservedObject var model: WorkbenchViewModel
    var onShowTranscript: () -> Void = {}

    private var isArchived: Bool { entry.isArchived }
    private var canRecover: Bool { !isArchived && model.canRecover(entry) }

    private var statusHeadline: String {
        if isArchived {
            return "Archived"
        }
        if let summary = entry.lastSummary, !summary.isEmpty {
            return summary
        }
        return canRecover ? "Ready to recover" : "Ready to launch"
    }

    private var statusTint: SwiftUI.Color {
        if isArchived { return .secondary }
        if canRecover { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isArchived ? "archivebox" : (canRecover ? "arrow.clockwise" : "terminal"))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(statusTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusHeadline)
                        .font(.title3.weight(.semibold))
                    Text(isArchived ? "Restore this session to launch it again." : "Recovery: \(model.recoveryReason(for: entry))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer()
                if isArchived {
                    Button {
                        model.restoreCustomSession(entry)
                    } label: {
                        Label("Restore", systemImage: "tray.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        if canRecover {
                            model.recover(entry)
                        } else {
                            model.launch(entry)
                        }
                    } label: {
                        Label(canRecover ? model.recoveryButtonTitle(for: entry) : "Launch",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }

            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(model.launchCommand(for: entry))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isArchived ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    model.copyLaunchCommand(for: entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy launch command")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            if !isArchived, let health = model.executableHealth(for: entry), health.status != .available {
                Label("Executable: \(health.detail)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.transcriptTail(for: entry) != nil {
                Button {
                    onShowTranscript()
                } label: {
                    Label("View latest transcript", systemImage: "doc.text")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Focus this terminal")
            .accessibilityLabel("Full Screen")
            .frame(width: 28)

            Button {
                model.redrawTerminal(entry)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Send Ctrl-L to redraw the terminal")
            .keyboardShortcut("l", modifiers: [.command])
            .accessibilityLabel("Redraw")
            .frame(width: 28)

            Button {
                model.sendControlC(to: entry)
            } label: {
                Image(systemName: "command")
            }
            .help("Send Ctrl-C to this terminal")
            .accessibilityLabel("Ctrl-C")
            .frame(width: 28)
            Button {
                model.sendEscape(to: entry)
            } label: {
                Image(systemName: "escape")
            }
            .help("Send Esc to this terminal")
            .accessibilityLabel("Esc")
            .frame(width: 28)
            Button {
                model.sendEOF(to: entry)
            } label: {
                Image(systemName: "eject")
            }
            .help("Send Ctrl-D / EOF to this terminal")
            .accessibilityLabel("EOF")
            .frame(width: 28)
            Button(role: .destructive) {
                model.terminate(entry)
            } label: {
                Image(systemName: "stop.fill")
            }
            .keyboardShortcut(".", modifiers: [.command])
            .help("Stop this terminal")
            .accessibilityLabel("Stop")
            .frame(width: 28)
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
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("Return to the split workbench view")
                .accessibilityLabel("Exit Full Screen")
                .frame(width: 28)
                Button {
                    model.redrawTerminal(entry)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Send Ctrl-L to redraw the terminal")
                .keyboardShortcut("l", modifiers: [.command])
                .accessibilityLabel("Redraw")
                .frame(width: 28)
                Button {
                    model.sendControlC(to: entry)
                } label: {
                    Image(systemName: "command")
                }
                .help("Send Ctrl-C to this terminal")
                .accessibilityLabel("Ctrl-C")
                .frame(width: 28)
                Button {
                    model.sendEscape(to: entry)
                } label: {
                    Image(systemName: "escape")
                }
                .help("Send Esc to this terminal")
                .accessibilityLabel("Esc")
                .frame(width: 28)
                Button {
                    model.sendEOF(to: entry)
                } label: {
                    Image(systemName: "eject")
                }
                .help("Send Ctrl-D / EOF to this terminal")
                .accessibilityLabel("EOF")
                .frame(width: 28)
                Button(role: .destructive) {
                    model.terminate(entry)
                } label: {
                    Image(systemName: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: [.command])
                .help("Stop this terminal")
                .accessibilityLabel("Stop")
                .frame(width: 28)
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
        .onAppear {
            session.focusInput()
            session.redrawDisplayBurst(after: [0.12, 0.35, 0.75, 1.25])
        }
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
    @ObservedObject var model: WorkbenchViewModel
    @StateObject private var loginItem = LoginItemController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Native Runtime", systemImage: "macwindow")
                Toggle("Open at Login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(loginItem.isUpdating)
                .fixedSize()
                DashboardStatusLine(text: loginItem.statusLine)
                Button {
                    loginItem.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Refresh login item status")
                .fixedSize()
            }
            if let lastError = loginItem.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Support Diagnostics", systemImage: "lifepreserver")
                DashboardStatusLine(
                    text: model.supportDiagnosticsStatusLine,
                    color: model.supportDiagnosticsStatusColor,
                    help: model.supportDiagnosticsURL?.path ?? model.supportDiagnosticsStatusLine
                )
                if model.supportDiagnosticsIsCollecting {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                }
                Button {
                    model.collectSupportDiagnostics()
                } label: {
                    Label("Collect", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.supportDiagnosticsIsCollecting)
                .help("Create a support diagnostics zip without transcript contents or raw workspace state")
                .fixedSize()
                if model.supportDiagnosticsURL != nil {
                    Button {
                        model.revealSupportDiagnostics()
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reveal the latest diagnostics zip in Finder")
                    .fixedSize()
                    Button {
                        model.copySupportDiagnosticsPath()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy the latest diagnostics zip path")
                    .fixedSize()
                }
            }
        }
    }
}

struct ReleaseUpdateView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Release Updates", systemImage: "arrow.down.app")
                DashboardStatusLine(
                    text: model.releaseUpdateStatusLine,
                    color: model.releaseUpdateStatusColor
                )
                if model.releaseUpdateIsChecking {
                    ProgressView()
                        .controlSize(.small)
                        .fixedSize()
                }
                Button {
                    Task {
                        await model.checkForReleaseUpdate()
                    }
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.releaseUpdateIsChecking)
                .fixedSize()
                if model.releaseUpdateURL != nil {
                    Button {
                        model.openReleaseUpdate()
                    } label: {
                        Label("Open Release", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            if let snapshot = model.releaseUpdateSnapshot, snapshot.status == .updateAvailable {
                Text(snapshot.hasInstallableAssets ? "Release assets include a verified app zip and manifest." : "Release is published, but installable app assets were not found.")
                    .font(.caption)
                    .foregroundStyle(snapshot.hasInstallableAssets ? SwiftUI.Color.secondary : SwiftUI.Color.orange)
            }
        }
    }
}

struct RecoveryDrillView: View {
    @ObservedObject var model: WorkbenchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                DashboardRowLabel(title: "Recovery Drill", systemImage: "arrow.clockwise.circle")
                DashboardStatusLine(text: model.recoveryDrillStatusLine)
                Button {
                    model.runRecoveryDrill()
                } label: {
                    Label("Run Drill", systemImage: "play.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
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

struct WorkbenchImportApplyResult: Equatable {
    var createdCount: Int
    var groupNames: [String]
    var deskChangeCount: Int
    var skippedNames: [String]
    var firstSelectedEntryID: UUID?

    var hasImports: Bool { createdCount > 0 }

    var headline: String {
        switch (createdCount, groupNames.count) {
        case (0, _):
            return "Nothing imported"
        case (1, _):
            return "Arranged 1 terminal"
        case (let n, 1):
            return "Arranged \(n) terminals in 1 group"
        case (let n, let g):
            return "Arranged \(n) terminals across \(g) groups"
        }
    }

    var detail: String? {
        var parts: [String] = []
        if !groupNames.isEmpty {
            parts.append(groupNames.joined(separator: ", "))
        }
        if deskChangeCount > 0 {
            parts.append("Desk mirror updated (\(deskChangeCount) file\(deskChangeCount == 1 ? "" : "s"))")
        }
        if !skippedNames.isEmpty {
            parts.append("Skipped: \(skippedNames.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
               !projectSessionEntries.contains(where: { $0.id == selectedEntryID }) {
                self.selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
            }
            save()
        }
    }
    @Published var selectedEntryID: UUID? {
        didSet {
            guard selectedEntryID != oldValue else {
                return
            }
            if selectedEntryID != nil {
                // Selecting a terminal pulls focus off the Agents pane so the
                // detail pane switches back to the live SessionDetailView.
                selectedAgentName = nil
            }
            state.selectedEntryId = selectedEntryID
            save()
        }
    }
    /// Currently focused Ouro agent for the Agents sidebar / detail pane.
    /// Mutually exclusive with `selectedEntryID`: setting either clears the other.
    /// Not persisted — the sidebar restores the natural session selection on
    /// next launch.
    @Published var selectedAgentName: String? {
        didSet {
            guard selectedAgentName != oldValue, selectedAgentName != nil else {
                return
            }
            selectedEntryID = nil
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
    @Published var releaseUpdateSnapshot: ReleaseUpdateSnapshot?
    @Published var releaseUpdateIsChecking = false
    @Published var supportDiagnosticsResult: SupportDiagnosticsResult?
    @Published var supportDiagnosticsIsCollecting = false
    @Published var supportDiagnosticsError: String?
    @Published var isOnboardingPresented = false
    @Published var onboardingReadiness: OnboardingReadiness?
    @Published var onboardingProviderChecks: [String: OnboardingProviderCheckResult] = [:]
    @Published var onboardingCandidates: [RecentSessionCandidate] = []
    @Published var onboardingProposal: WorkbenchImportProposal?
    @Published var onboardingIsScanning = false
    @Published var onboardingDeskChanges: [String] = []
    @Published var lastImportSummary: WorkbenchImportApplyResult?

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
    private let onboardingAdvisor = WorkbenchOnboardingAdvisor()
    private let onboardingProposalBuilder = WorkbenchImportProposalBuilder()
    private let deskBridgePlanner = DeskBridgePlanner()
    private let externalActionQueue: WorkbenchActionRequestQueue
    private let releaseUpdateChecker: ReleaseUpdateChecker
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
        executableHealthChecker: ExecutableHealthChecker = ExecutableHealthChecker(),
        releaseUpdateChecker: ReleaseUpdateChecker = ReleaseUpdateChecker()
    ) {
        self.paths = paths
        self.store = WorkbenchStore(paths: paths)
        self.mailboxClient = mailboxClient
        self.bossMCPClient = bossMCPClient
        self.bossWorkbenchMCPRegistrar = bossWorkbenchMCPRegistrar
        self.ouroAgentInventory = ouroAgentInventory
        self.executableHealthChecker = executableHealthChecker
        self.releaseUpdateChecker = releaseUpdateChecker
        self.externalActionQueue = WorkbenchActionRequestQueue(paths: paths)
        self.state = WorkspaceState()
        load()
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        refreshExecutableHealth()
        refreshOnboardingReadiness()
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
            return sessionEntries.first ?? archivedSessionEntries.first
        }
        return projectSessionEntries.first { $0.id == selectedEntryID }
            ?? sessionEntries.first
            ?? archivedSessionEntries.first
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

    var releaseUpdateStatusLine: String {
        guard let snapshot = releaseUpdateSnapshot else {
            return "not checked"
        }
        return snapshot.detail
    }

    var releaseUpdateStatusColor: SwiftUI.Color {
        guard let status = releaseUpdateSnapshot?.status else {
            return .secondary
        }
        switch status {
        case .current:
            return .green
        case .updateAvailable:
            return .orange
        case .unavailable:
            return .secondary
        }
    }

    var releaseUpdateURL: URL? {
        guard let htmlURL = releaseUpdateSnapshot?.htmlURL else {
            return nil
        }
        return URL(string: htmlURL)
    }

    var supportDiagnosticsStatusLine: String {
        if supportDiagnosticsIsCollecting {
            return "collecting"
        }
        if let supportDiagnosticsError {
            return "failed: \(supportDiagnosticsError)"
        }
        guard let supportDiagnosticsResult else {
            return "not run"
        }
        return "wrote \(supportDiagnosticsResult.archiveURL.lastPathComponent)"
    }

    var supportDiagnosticsStatusColor: SwiftUI.Color {
        if supportDiagnosticsError != nil {
            return .orange
        }
        return supportDiagnosticsResult == nil ? .secondary : .green
    }

    var supportDiagnosticsURL: URL? {
        supportDiagnosticsResult?.archiveURL
    }

    var shouldPresentOnboardingOnLaunch: Bool {
        onboardingReadiness?.isReady == false
    }

    var onboardingPhaseLabel: String {
        if onboardingReadiness?.isReady != true {
            return "choose boss"
        }
        if onboardingProposal == nil {
            return "ready to scan"
        }
        if onboardingDeskChanges.isEmpty {
            return "ready to arrange"
        }
        return "ready"
    }

    var onboardingPhaseColor: SwiftUI.Color {
        if onboardingReadiness?.isReady != true {
            return .orange
        }
        if onboardingProposal == nil {
            return .blue
        }
        return onboardingDeskChanges.isEmpty ? .purple : .green
    }

    var onboardingOpeningLine: String {
        if onboardingReadiness?.isReady == true {
            return "\(state.boss.agentName) is selected as this Mac's boss. Workbench can now scan recent terminal-agent work and arrange it into Desk-shaped groups."
        }
        if ouroAgents.count > 1 {
            return "This Mac has multiple Ouro agents. Choose the one that should be boss for Workbench before importing sessions."
        }
        return "First choose or repair this Mac's Ouro boss, then Workbench can scan recent sessions and create a clean Desk mirror."
    }

    var onboardingBossChoices: [OnboardingBossChoice] {
        bossAgentChoices.map { name in
            let agent = ouroAgents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let registration = bossWorkbenchMCPRegistrationByAgentName[name]
            let isSelected = state.boss.agentName.caseInsensitiveCompare(name) == .orderedSame
            return OnboardingBossChoice(
                name: name,
                detail: agent?.summaryLine ?? "Agent bundle not found on this machine.",
                status: agent?.status,
                registrationStatus: registration?.status,
                isSelected: isSelected
            )
        }
    }

    var commandPaletteItems: [WorkbenchCommandDescriptor] {
        func command(
            _ id: WorkbenchCommandID,
            _ title: String,
            _ detail: String,
            _ systemImage: String,
            keywords: [String] = []
        ) -> WorkbenchCommandDescriptor {
            WorkbenchCommandDescriptor(
                id: id,
                title: title,
                detail: detail,
                systemImage: systemImage,
                keywords: keywords
            )
        }

        var commands: [WorkbenchCommandDescriptor] = [
            command(
                .newSession,
                "New Terminal",
                "Create a terminal/TUI tab in the selected group",
                "plus",
                keywords: ["session", "tab", "agent", "shell", "cli"]
            ),
            command(
                .toggleBossWatch,
                bossWatchIsEnabled ? "Pause Boss Watch" : "Start Boss Watch",
                "Toggle automatic boss monitoring",
                bossWatchIsEnabled ? "eye.slash" : "eye",
                keywords: ["watch", "monitor", "autonomy", "boss"]
            ),
            command(
                .toggleBossPane,
                state.bossPaneCollapsed ? "Show Boss Pane" : "Hide Boss Pane",
                state.bossPaneCollapsed ? "Reveal boss chat and diagnostics" : "Collapse boss chat and diagnostics",
                "sidebar.leading",
                keywords: ["collapse", "expand", "dashboard", "boss"]
            ),
            command(
                .openOnboarding,
                "Set Up Workbench",
                "Open the conversational setup and recent-session import surface",
                "wand.and.stars",
                keywords: ["onboarding", "setup", "bootstrap", "desk", "import"]
            ),
            command(
                .installOuroAgent,
                "Install Ouro Agent",
                "Open a managed hatch conversation or clone terminal",
                "square.and.arrow.down",
                keywords: ["hatch", "clone", "agent", "install"]
            ),
            command(
                .refreshWorkspace,
                "Refresh Workspace",
                "Refresh dashboard, agents, MCP registration, and executable health",
                "arrow.clockwise",
                keywords: ["reload", "status", "health", "dashboard"]
            ),
            command(
                .refreshOuroAgents,
                "Refresh Ouro Agents",
                "Rescan local agent bundles",
                "person.2.badge.gearshape",
                keywords: ["agent", "bundle", "inventory"]
            ),
            command(
                .refreshWorkbenchMCP,
                "Refresh Workbench MCP",
                "Refresh selected boss MCP registration status",
                "point.3.connected.trianglepath.dotted",
                keywords: ["mcp", "boss", "registration"]
            ),
            command(
                .installWorkbenchMCPForBoss,
                "Install Workbench MCP",
                "Register or update Workbench MCP for the selected boss",
                "wrench.and.screwdriver",
                keywords: ["mcp", "boss", "register", "bridge"]
            ),
            command(
                .searchTranscripts,
                "Search Transcripts",
                "Run the current transcript search query",
                "text.magnifyingglass",
                keywords: ["history", "output", "find"]
            ),
            command(
                .runRecoveryDrill,
                "Run Recovery Drill",
                "Simulate restart recovery planning",
                "arrow.clockwise.circle",
                keywords: ["restart", "resume", "recover", "drill"]
            ),
            command(
                .collectSupportDiagnostics,
                "Collect Support Diagnostics",
                "Create a local diagnostics zip without transcript contents",
                "lifepreserver",
                keywords: ["diag", "diagnostic", "support", "bug", "zip"]
            ),
            command(
                .openSupportDiagnosticsFolder,
                "Open Diagnostics Folder",
                "Open the support diagnostics output folder",
                "folder",
                keywords: ["diag", "diagnostic", "support", "finder"]
            ),
            command(
                .checkReleaseUpdates,
                "Check Release Updates",
                "Look for the latest published Workbench release",
                "arrow.down.app",
                keywords: ["version", "update", "release"]
            )
        ]

        if !bossCheckInIsRunning {
            commands.insert(
                command(
                    .bossCheckIn,
                    "Boss Check In",
                    "Ask \(state.boss.agentName) what is going on",
                    "bubble.left.and.text.bubble.right",
                    keywords: ["boss", "ask", "status"]
                ),
                at: 1
            )
            commands.insert(contentsOf: [
                command(
                    .bossQuickWhatsGoingOn,
                    "Ask Boss: What's Going On?",
                    "Ask \(state.boss.agentName) for the current workspace situation",
                    "questionmark.bubble",
                    keywords: ["boss", "status", "what"]
                ),
                command(
                    .bossQuickWaitingOnMe,
                    "Ask Boss: Waiting On Me?",
                    "Ask \(state.boss.agentName) what needs human input",
                    "person.crop.circle.badge.questionmark",
                    keywords: ["boss", "human", "blocked", "waiting"]
                ),
                command(
                    .bossQuickKeepMoving,
                    "Ask Boss: Keep Moving",
                    "Ask \(state.boss.agentName) to advance trusted work",
                    "forward",
                    keywords: ["boss", "continue", "autonomy", "ttfa"]
                ),
                command(
                    .bossQuickRespondForMe,
                    "Ask Boss: Respond For Me",
                    "Ask \(state.boss.agentName) for response-ready next actions",
                    "arrowshape.turn.up.left",
                    keywords: ["boss", "reply", "respond"]
                )
            ], at: 2)
        }

        if supportDiagnosticsURL != nil {
            commands.append(contentsOf: [
                command(
                    .revealSupportDiagnostics,
                    "Reveal Diagnostics Zip",
                    "Reveal the latest support diagnostics zip in Finder",
                    "folder",
                    keywords: ["diag", "diagnostic", "support", "finder"]
                ),
                command(
                    .copySupportDiagnosticsPath,
                    "Copy Diagnostics Path",
                    "Copy the latest support diagnostics zip path",
                    "doc.on.doc",
                    keywords: ["diag", "diagnostic", "support", "clipboard", "path"]
                )
            ])
        }

        if releaseUpdateURL != nil {
            commands.append(command(
                .openReleaseUpdate,
                "Open Release Page",
                "Open the latest Workbench release page",
                "safari",
                keywords: ["release", "update", "github"]
            ))
        }

        if let selectedEntry, !selectedEntry.isArchived {
            commands.append(contentsOf: [
                command(
                    .launchSelectedSession,
                    activeSession(for: selectedEntry) == nil ? "Launch \(selectedEntry.name)" : "Restart \(selectedEntry.name)",
                    launchCommand(for: selectedEntry),
                    "play.fill",
                    keywords: ["terminal", "session", "start"]
                ),
                command(
                    .askBossAboutSelectedSession,
                    "Ask Boss About \(selectedEntry.name)",
                    "Ask \(state.boss.agentName) what this terminal is doing",
                    "bubble.left.and.text.bubble.right",
                    keywords: ["boss", "terminal", "session", "status"]
                ),
                command(
                    .copySelectedLaunchCommand,
                    "Copy \(selectedEntry.name) Launch Command",
                    launchCommand(for: selectedEntry),
                    "doc.on.doc",
                    keywords: ["clipboard", "copy", "command"]
                ),
                command(
                    .openSelectedWorkingDirectory,
                    "Open \(selectedEntry.name) Directory",
                    selectedEntry.workingDirectory,
                    "folder",
                    keywords: ["finder", "cwd", "working directory", "project"]
                )
            ])
            if latestRun(for: selectedEntry)?.transcriptPath != nil {
                commands.append(command(
                    .revealSelectedTranscript,
                    "Reveal \(selectedEntry.name) Transcript",
                    "Reveal the latest transcript file in Finder",
                    "doc.text.magnifyingglass",
                    keywords: ["history", "output", "transcript", "finder"]
                ))
            }
            if activeSession(for: selectedEntry) != nil {
                commands.append(contentsOf: [
                    command(
                        .focusSelectedSession,
                        "Focus \(selectedEntry.name)",
                        "Open the terminal-only view",
                        "arrow.up.left.and.arrow.down.right",
                        keywords: ["fullscreen", "terminal", "focus"]
                    ),
                    command(
                        .redrawSelectedSession,
                        "Redraw \(selectedEntry.name)",
                        "Send Ctrl-L to refresh the terminal display",
                        "arrow.clockwise",
                        keywords: ["clear", "refresh", "terminal", "screen"]
                    ),
                    command(
                        .sendControlCToSelectedSession,
                        "Send Ctrl-C To \(selectedEntry.name)",
                        "Interrupt the running terminal session",
                        "command",
                        keywords: ["signal", "interrupt", "terminal"]
                    ),
                    command(
                        .sendEscapeToSelectedSession,
                        "Send Esc To \(selectedEntry.name)",
                        "Send Escape to the running terminal session",
                        "escape",
                        keywords: ["signal", "terminal", "cancel"]
                    ),
                    command(
                        .sendEOFToSelectedSession,
                        "Send EOF To \(selectedEntry.name)",
                        "Send Ctrl-D to the running terminal session",
                        "eject",
                        keywords: ["signal", "ctrl-d", "exit", "terminal"]
                    ),
                    command(
                        .stopSelectedSession,
                        "Stop \(selectedEntry.name)",
                        "Terminate the running terminal session",
                        "stop.fill",
                        keywords: ["kill", "terminate", "terminal"]
                    )
                ])
            }
            if canRecover(selectedEntry) {
                commands.append(command(
                    .recoverSelectedSession,
                    "\(recoveryButtonTitle(for: selectedEntry)) \(selectedEntry.name)",
                    recoveryReason(for: selectedEntry),
                    "arrow.clockwise",
                    keywords: ["resume", "recover", "restart"]
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

    /// Open `agent.json` in the user's default editor (or whichever app the
    /// finder has bound to .json). Used by the Agents pane "Open Config…"
    /// button so users can flip provider/model without dropping out to a
    /// terminal.
    func openAgentConfig(_ agent: OuroAgentRecord) {
        let url = URL(fileURLWithPath: agent.configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Agent config not found at \(agent.configPath)"
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Open a Workbench terminal pre-loaded with the `ouro check` invocation
    /// for this agent so the user can repair providers, refresh the daemon,
    /// or fix MCP tools without remembering the CLI shape. The terminal is
    /// trusted and auto-resumable so the user can rerun it after editing.
    @discardableResult
    func repairAgent(_ agent: OuroAgentRecord) -> Bool {
        let workingDirectory = FileManager.default.fileExists(atPath: agent.bundlePath)
            ? agent.bundlePath
            : FileManager.default.homeDirectoryForCurrentUser.path
        let command = ShellArgumentEscaper.commandLine(["ouro", "check", "--agent", agent.name])
        let draft = CustomTerminalSessionDraft(
            name: "Ouro Repair: \(agent.name)",
            command: command,
            workingDirectory: workingDirectory,
            trust: .trusted,
            autoResume: false,
            notes: "Workbench repair shortcut: \(command)"
        )
        let entry = createCustomSession(draft, launchAfterCreate: true)
        if entry != nil {
            recordActionLog(
                source: "native",
                action: "repairAgent",
                targetName: agent.name,
                result: "Opened repair terminal",
                succeeded: true
            )
        }
        return entry != nil
    }

    /// Helper used by the sidebar / boss menu to set the Agents pane focus.
    /// If `name` doesn't resolve to a known bundle, fall back to the first
    /// available agent so the detail pane never lands on an empty record.
    func selectAgent(_ name: String?) {
        guard let name else {
            selectedAgentName = nil
            return
        }
        if ouroAgent(named: name) != nil {
            selectedAgentName = name
        } else if let first = ouroAgents.first {
            selectedAgentName = first.name
        } else {
            // No agent bundles installed yet — kick into the hatching flow
            // instead of landing on a blank Agents pane.
            selectedAgentName = nil
            isOuroAgentInstallSheetPresented = true
        }
    }

    /// Convenience accessor for the AgentDetailView.
    func ouroAgent(named name: String) -> OuroAgentRecord? {
        ouroAgents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
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
        onboardingProposal = nil
        onboardingCandidates = []
        onboardingDeskChanges = []
        onboardingProviderChecks = [:]
        save()
        refreshWorkbenchMCPRegistration()
        refreshOnboardingReadiness()
        runOnboardingProviderChecksIfNeeded()
        Task {
            await refreshBossDashboard()
        }
    }

    func registerWorkbenchForBossChoice(_ agentName: String) {
        let previousBoss = state.boss.agentName
        if previousBoss.caseInsensitiveCompare(agentName) != .orderedSame {
            selectBoss(agentName: agentName)
        }
        installWorkbenchMCPForBoss()
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        refreshOnboardingReadiness()
        runOnboardingProviderChecksIfNeeded()
    }

    func selectProject(_ projectId: UUID) {
        guard state.projects.contains(where: { $0.id == projectId }) else {
            return
        }
        selectedProjectID = projectId
        selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
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
            selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
        }
        recordActionLog(
            source: "native",
            action: "deleteGroup",
            targetName: project.name,
            result: "Deleted empty group \(project.name)",
            succeeded: true
        )
    }

    func moveSession(_ entry: ProcessEntry, to projectId: UUID, recordNativeAction: Bool = true) {
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
        if recordNativeAction {
            recordActionLog(
                source: "native",
                action: "moveSession",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: "Moved \(entry.name) to \(project.name)",
                succeeded: true
            )
        } else {
            save()
        }
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

    func checkForReleaseUpdate() async {
        guard !releaseUpdateIsChecking else {
            return
        }
        releaseUpdateIsChecking = true
        defer {
            releaseUpdateIsChecking = false
        }
        let snapshot = await releaseUpdateChecker.check()
        releaseUpdateSnapshot = snapshot
        recordActionLog(
            source: "native",
            action: "checkReleaseUpdates",
            result: snapshot.detail,
            succeeded: snapshot.status != .unavailable
        )
    }

    func openReleaseUpdate() {
        guard let releaseUpdateURL else {
            return
        }
        NSWorkspace.shared.open(releaseUpdateURL)
    }

    func collectSupportDiagnostics() {
        guard !supportDiagnosticsIsCollecting else {
            return
        }
        supportDiagnosticsIsCollecting = true
        supportDiagnosticsError = nil

        let runner = SupportDiagnosticsRunner(resourceDirectory: Bundle.main.resourceURL)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<SupportDiagnosticsResult, Error>.success(try runner.run())
                } catch {
                    return Result<SupportDiagnosticsResult, Error>.failure(error)
                }
            }.value

            supportDiagnosticsIsCollecting = false
            switch outcome {
            case let .success(result):
                supportDiagnosticsResult = result
                recordActionLog(
                    source: "native",
                    action: "collectSupportDiagnostics",
                    result: "Wrote \(result.archiveURL.lastPathComponent)",
                    succeeded: true
                )
            case let .failure(error):
                supportDiagnosticsError = error.localizedDescription
                recordActionLog(
                    source: "native",
                    action: "collectSupportDiagnostics",
                    result: "Failed: \(error.localizedDescription)",
                    succeeded: false
                )
            }
        }
    }

    func revealSupportDiagnostics() {
        guard let supportDiagnosticsURL else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([supportDiagnosticsURL])
        recordActionLog(
            source: "native",
            action: "revealSupportDiagnostics",
            result: "Revealed \(supportDiagnosticsURL.lastPathComponent)",
            succeeded: true
        )
    }

    func copySupportDiagnosticsPath() {
        guard let supportDiagnosticsURL else {
            errorMessage = "No support diagnostics zip has been collected yet"
            return
        }
        copyToPasteboard(supportDiagnosticsURL.path)
        recordActionLog(
            source: "native",
            action: "copySupportDiagnosticsPath",
            result: "Copied diagnostics path",
            succeeded: true
        )
    }

    func openSupportDiagnosticsFolder() {
        let folder = supportDiagnosticsURL?.deletingLastPathComponent()
            ?? SupportDiagnosticsRunner.defaultOutputDirectory()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            recordActionLog(
                source: "native",
                action: "openSupportDiagnosticsFolder",
                result: "Opened diagnostics folder",
                succeeded: true
            )
        } catch {
            errorMessage = "Diagnostics folder could not be opened: \(error.localizedDescription)"
            recordActionLog(
                source: "native",
                action: "openSupportDiagnosticsFolder",
                result: "Failed: \(error.localizedDescription)",
                succeeded: false
            )
        }
    }

    func refreshWorkspace() async {
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        refreshExecutableHealth()
        refreshOnboardingReadiness()
        await refreshBossDashboard()
        recordActionLog(
            source: "native",
            action: "refreshWorkspace",
            result: "Refreshed workspace status",
            succeeded: true
        )
    }

    func refreshOnboardingReadiness() {
        onboardingReadiness = onboardingAdvisor.readiness(
            boss: state.boss,
            agents: ouroAgents,
            mcpRegistration: bossWorkbenchMCPRegistration,
            providerChecks: onboardingProviderChecks
        )
    }

    func presentOnboarding() {
        refreshOuroAgents()
        refreshWorkbenchMCPRegistration()
        refreshOnboardingReadiness()
        runOnboardingProviderChecksIfNeeded()
        isOnboardingPresented = true
    }

    func runOnboardingProviderChecksIfNeeded() {
        let selectedAgent = ouroAgents.first {
            $0.name.caseInsensitiveCompare(state.boss.agentName) == .orderedSame
        }
        guard let selectedAgent, selectedAgent.status == .ready else {
            return
        }
        let laneConfigurations: [(lane: String, configured: Bool)] = [
            ("outward", selectedAgent.humanFacing?.provider != nil && selectedAgent.humanFacing?.model != nil),
            ("inner", selectedAgent.agentFacing?.provider != nil && selectedAgent.agentFacing?.model != nil)
        ]
        for laneConfiguration in laneConfigurations where laneConfiguration.configured {
            let existingState = onboardingProviderChecks[laneConfiguration.lane]?.state
            guard existingState != .running, existingState != .passed else {
                continue
            }
            onboardingProviderChecks[laneConfiguration.lane] = OnboardingProviderCheckResult(
                lane: laneConfiguration.lane,
                state: .running,
                detail: "Checking \(laneConfiguration.lane) provider..."
            )
            refreshOnboardingReadiness()
            Task {
                let result = await runOnboardingProviderCheck(agentName: selectedAgent.name, lane: laneConfiguration.lane)
                onboardingProviderChecks[laneConfiguration.lane] = result
                refreshOuroAgents()
                refreshWorkbenchMCPRegistration()
                refreshOnboardingReadiness()
            }
        }
    }

    private func runOnboardingProviderCheck(agentName: String, lane: String) async -> OnboardingProviderCheckResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ouro", "check", "--agent", agentName, "--lane", lane]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(20)
                while process.isRunning && Date() < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                    return OnboardingProviderCheckResult(
                        lane: lane,
                        state: .failed,
                        detail: "`ouro check --agent \(agentName) --lane \(lane)` did not finish. Open Ouro provider setup to repair auth or daemon state."
                    )
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    return OnboardingProviderCheckResult(
                        lane: lane,
                        state: .passed,
                        detail: output.isEmpty ? "\(lane) provider check passed." : output
                    )
                }
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: output.isEmpty ? "\(lane) provider check failed." : output
                )
            } catch {
                return OnboardingProviderCheckResult(
                    lane: lane,
                    state: .failed,
                    detail: "Could not run `ouro check --agent \(agentName) --lane \(lane)`: \(error.localizedDescription)"
                )
            }
        }.value
    }

    @discardableResult
    func handleOnboardingInstruction(_ rawText: String) -> String? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else {
            return nil
        }
        if text.looksLikeOnboardingQuestion {
            bossQuestion = rawText
            Task {
                await runBossQuestion()
            }
            return "Asking \(state.boss.agentName). The reply will appear here."
        }
        if text.contains("scan") || text.contains("bootstrap") || text == "yes" {
            refreshOnboardingReadiness()
            guard onboardingReadiness?.isReady == true else {
                runOnboardingProviderChecksIfNeeded()
                return "Finish connecting the boss first. Workbench is checking provider and tool readiness now."
            }
            scanForOnboardingSessions()
            return "Scanning recent terminal work. The import proposal will update above."
        } else if text.contains("apply") || text.contains("arrange") || text.contains("import") {
            refreshOnboardingReadiness()
            guard onboardingReadiness?.isReady == true else {
                runOnboardingProviderChecksIfNeeded()
                return "Finish connecting the boss first. Import stays locked until provider checks pass."
            }
            applyOnboardingProposal()
            return "Arranging proposed sessions into Workbench groups."
        } else if text.contains("mcp") || text.contains("tool") {
            installWorkbenchMCPForBoss()
            refreshOnboardingReadiness()
            return "Registering Workbench tools with the selected boss agent."
        } else if text.contains("hatch") {
            launchOuroAgentInstall(mode: "hatch", agentName: "", remote: "")
            return "Opening the agent hatch flow."
        } else {
            bossQuestion = rawText
            Task {
                await runBossQuestion()
            }
            return "Asking \(state.boss.agentName). The reply will appear here."
        }
    }

    func scanForOnboardingSessions() {
        guard !onboardingIsScanning else {
            return
        }
        guard onboardingReadiness?.isReady == true else {
            refreshOnboardingReadiness()
            runOnboardingProviderChecksIfNeeded()
            return
        }
        onboardingIsScanning = true
        onboardingDeskChanges = []
        let currentState = state
        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                let scanner = RecentSessionScanner()
                let discovered = scanner.scan()
                let existing = scanner.scanWorkbench(state: currentState)
                return discovered + existing
            }.value
            onboardingCandidates = candidates
            onboardingProposal = onboardingProposalBuilder.build(candidates: candidates)
            onboardingIsScanning = false
            recordActionLog(
                source: "native",
                action: "scanOnboardingSessions",
                result: "Found \(candidates.count) recent session candidates",
                succeeded: true
            )
        }
    }

    /// Toggle whether a terminal in the current import proposal is selected.
    /// Returns `true` after the toggle if the terminal is now selected.
    @discardableResult
    func toggleOnboardingSelection(groupID: String, terminalID: String) -> Bool? {
        guard var proposal = onboardingProposal else {
            return nil
        }
        let result = proposal.toggleSelection(groupID: groupID, terminalID: terminalID)
        onboardingProposal = proposal
        return result
    }

    /// Bulk select / clear an entire onboarding group.
    func setOnboardingGroupSelection(groupID: String, selected: Bool) {
        guard var proposal = onboardingProposal else {
            return
        }
        proposal.setSelection(groupID: groupID, selected: selected)
        onboardingProposal = proposal
    }

    @discardableResult
    func applyOnboardingProposal() -> WorkbenchImportApplyResult? {
        guard onboardingReadiness?.isReady == true else {
            refreshOnboardingReadiness()
            runOnboardingProviderChecksIfNeeded()
            return nil
        }
        guard let proposal = onboardingProposal else {
            scanForOnboardingSessions()
            return nil
        }
        var createdEntries: [ProcessEntry] = []
        var firstImportedProjectID: UUID?
        var importedGroupNames: [String] = []
        var skipped: [String] = []
        for group in proposal.groups {
            let project = ensureProject(for: group)
            firstImportedProjectID = firstImportedProjectID ?? project.id
            var groupCreated = false
            for terminal in group.terminals where terminal.selectedByDefault {
                guard !state.processEntries.contains(where: { $0.deskTaskSlug == terminal.deskTaskSlug && $0.projectId == project.id }) else {
                    continue
                }
                let draft = CustomTerminalSessionDraft(
                    name: terminal.name,
                    command: terminal.candidate.resumeCommandLine,
                    workingDirectory: terminal.candidate.workingDirectory,
                    trust: .trusted,
                    autoResume: true,
                    notes: onboardingNotes(for: terminal, group: group)
                )
                do {
                    var entry = try customSessionFactory.makeEntry(projectId: project.id, draft: draft)
                    entry.deskTaskSlug = terminal.deskTaskSlug
                    state.processEntries.append(entry)
                    createdEntries.append(entry)
                    groupCreated = true
                } catch {
                    skipped.append(terminal.name)
                    recordActionLog(
                        source: "native",
                        action: "applyOnboardingProposal",
                        result: "Skipped \(terminal.name): \(error.localizedDescription)",
                        succeeded: false
                    )
                }
            }
            if groupCreated {
                importedGroupNames.append(group.name)
            }
        }

        do {
            onboardingDeskChanges = try DeskMirrorWriter().apply(proposal)
        } catch {
            onboardingDeskChanges = []
            recordActionLog(
                source: "native",
                action: "mirrorDesk",
                result: "Desk mirror failed: \(error.localizedDescription)",
                succeeded: false
            )
        }

        selectedProjectID = firstImportedProjectID ?? state.projects.first?.id
        selectedEntryID = createdEntries.first?.id ?? selectedEntryID
        save()
        refreshExecutableHealth()
        for entry in createdEntries {
            launch(entry)
        }
        recordActionLog(
            source: "native",
            action: "applyOnboardingProposal",
            result: "Created \(createdEntries.count) terminals, mirrored \(onboardingDeskChanges.count) Desk files",
            succeeded: true
        )
        let result = WorkbenchImportApplyResult(
            createdCount: createdEntries.count,
            groupNames: importedGroupNames,
            deskChangeCount: onboardingDeskChanges.count,
            skippedNames: skipped,
            firstSelectedEntryID: createdEntries.first?.id
        )
        lastImportSummary = result
        return result
    }

    func openOnboardingRepair(_ step: OnboardingRepairStep) {
        guard let commandLine = step.commandLine else {
            return
        }
        let draft = CustomTerminalSessionDraft(
            name: "Ouro Setup: \(step.title)",
            command: commandLine,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            trust: .trusted,
            autoResume: false,
            notes: "\(step.actor.rawValue): \(step.detail)"
        )
        _ = createCustomSession(draft, launchAfterCreate: true)
    }

    func deskBridgePlan(for kind: TerminalAgentKind) -> DeskBridgePlan? {
        deskBridgePlanner.plan(agentName: state.boss.agentName, terminalKind: kind)
    }

    func openDeskBridgeSetup(_ bridge: DeskBridgePlan) {
        guard let commandLine = bridge.commandLine else {
            errorMessage = bridge.detail
            return
        }
        let draft = CustomTerminalSessionDraft(
            name: "Desk Bridge: \(bridge.terminalKind.rawValue)",
            command: commandLine,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            trust: .trusted,
            autoResume: false,
            notes: bridge.detail
        )
        _ = createCustomSession(draft, launchAfterCreate: true)
    }

    private func ensureProject(for group: ProposedWorkbenchGroup) -> WorkbenchProject {
        if let existing = state.projects.first(where: { $0.deskTrackSlug == group.deskTrackSlug || $0.rootPath == group.rootPath || $0.name == group.name }) {
            var updated = existing
            updated.deskTrackSlug = updated.deskTrackSlug ?? group.deskTrackSlug
            if let index = state.projects.firstIndex(where: { $0.id == existing.id }) {
                state.projects[index] = updated
            }
            return updated
        }
        let project = WorkbenchProject(
            name: group.name,
            rootPath: group.rootPath,
            boss: state.boss,
            deskTrackSlug: group.deskTrackSlug
        )
        state.projects.append(project)
        return project
    }

    private func onboardingNotes(for terminal: ProposedTerminalImport, group: ProposedWorkbenchGroup) -> String {
        let candidate = terminal.candidate
        var lines = [
            "Imported by Workbench onboarding.",
            "Desk track: \(group.deskTrackSlug)",
            "Desk task: \(terminal.deskTaskSlug)",
            "Source: \(candidate.source.rawValue)",
            "Confidence: \(Int(candidate.confidence * 100))%",
            "Summary: \(candidate.summary)"
        ]
        if !candidate.evidencePaths.isEmpty {
            lines.append("Evidence: \(candidate.evidencePaths.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    func onboardingSourceLabel(for candidate: RecentSessionCandidate) -> String {
        switch candidate.source {
        case .claudeCode:
            return "Claude Code history"
        case .cmux:
            return "cmux live panel"
        case .openAICodex:
            return "OpenAI Codex history"
        case .githubCopilotCLI:
            return "GitHub Copilot CLI history"
        case .shellHistory:
            return "shell history"
        case .workbench:
            return "existing Workbench session"
        }
    }

    func onboardingConfidenceExplanation(for terminal: ProposedTerminalImport) -> String {
        let candidate = terminal.candidate
        if candidate.source == .cmux {
            return "live cmux panel matched to a terminal process and session metadata"
        }
        if candidate.confidence >= 0.95 {
            return "live or Workbench-owned session with strong resume evidence"
        }
        if candidate.confidence >= 0.90 {
            return "recent session with a known working directory and native resume command"
        }
        if candidate.confidence >= 0.70 {
            return "recent history with enough context to resume, but weaker project evidence"
        }
        return "low-confidence shell/history signal; review before importing"
    }

    func onboardingPreviewText(for terminal: ProposedTerminalImport) -> String {
        let candidate = terminal.candidate
        if candidate.source == .openAICodex,
           let rolloutPath = codexRolloutPath(for: candidate),
           let preview = previewText(fromEvidencePath: rolloutPath),
           !preview.isEmpty {
            return preview
        }
        let existingEvidence = candidate.evidencePaths.filter { path in
            !path.hasPrefix("process:") &&
                !path.hasPrefix("tty:") &&
                FileManager.default.fileExists(atPath: path)
        }
        for path in existingEvidence {
            if let preview = previewText(fromEvidencePath: path), !preview.isEmpty {
                return preview
            }
        }
        return [
            "No transcript preview file was available for this candidate.",
            "",
            "Source: \(onboardingSourceLabel(for: candidate))",
            "Summary: \(candidate.summary)",
            "Resume: \(candidate.resumeCommandLine)",
            "Evidence: \(candidate.evidencePaths.isEmpty ? "none" : candidate.evidencePaths.joined(separator: ", "))"
        ].joined(separator: "\n")
    }

    private func codexRolloutPath(for candidate: RecentSessionCandidate) -> String? {
        guard let sessionId = candidate.resumeCommand.last,
              candidate.resumeCommand.count >= 2,
              candidate.resumeCommand[candidate.resumeCommand.count - 2] == "resume",
              let sqlitePath = candidate.evidencePaths.first(where: { $0.hasSuffix(".sqlite") }) else {
            return nil
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let escapedSessionId = sessionId.replacingOccurrences(of: "'", with: "''")
        process.arguments = [
            sqlitePath,
            "select rollout_path from threads where id='\(escapedSessionId)' limit 1;"
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }

    private func previewText(fromEvidencePath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text.split(whereSeparator: \.isNewline).suffix(120)
        var messages: [String] = []
        for line in lines {
            guard let message = readablePreviewLine(String(line)),
                  message != messages.last else {
                continue
            }
            messages.append(message)
        }
        let preview = messages.suffix(60).joined(separator: "\n\n")
        if preview.isEmpty {
            return String(lines.suffix(60).joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return preview
    }

    private func readablePreviewLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let eventType = object["type"] as? String else {
            return nil
        }
        if eventType == "response_item",
           let payload = object["payload"] as? [String: Any] {
            return readableResponseItem(payload)
        }
        if eventType == "event_msg",
           let payload = object["payload"] as? [String: Any] {
            return readableEventMessage(payload)
        }
        let content = firstReadableContent(in: object)
        guard let content, !content.isEmpty else {
            return nil
        }
        return "\(eventType): \(content)"
    }

    private func readableResponseItem(_ payload: [String: Any]) -> String? {
        guard let type = payload["type"] as? String else {
            return nil
        }
        if type == "message" {
            let role = stringValue(in: payload, keys: ["role"]) ?? "assistant"
            guard let contentObject = payload["content"],
                  let content = firstReadableContent(in: contentObject) else {
                return nil
            }
            return "\(role): \(content)"
        }
        return nil
    }

    private func readableEventMessage(_ payload: [String: Any]) -> String? {
        guard let type = payload["type"] as? String else {
            return nil
        }
        if type == "agent_message",
           let message = payload["message"] as? String {
            return "assistant: \(clippedPreview(message))"
        }
        if type == "user_message",
           let message = payload["message"] as? String {
            return "user: \(clippedPreview(message))"
        }
        return nil
    }

    private func firstReadableContent(in object: Any) -> String? {
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : clippedPreview(trimmed)
        }
        if let array = object as? [Any] {
            return array.compactMap(firstReadableContent(in:)).first
        }
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        if let itemType = dictionary["type"] as? String,
           itemType == "image_url" || itemType == "input_image" {
            return nil
        }
        for key in ["content", "message", "summary", "text", "prompt", "title"] {
            if let value = dictionary[key],
               let content = firstReadableContent(in: value) {
                return content
            }
        }
        return nil
    }

    private func clippedPreview(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 1_200 else {
            return normalized
        }
        let end = normalized.index(normalized.startIndex, offsetBy: 1_200)
        return "\(normalized[..<end])..."
    }

    private func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }
        return nil
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
        case .bossQuickWhatsGoingOn:
            Task {
                await runBossQuickQuestion("What's going on?")
            }
        case .bossQuickWaitingOnMe:
            Task {
                await runBossQuickQuestion("Is anything waiting on me?")
            }
        case .bossQuickKeepMoving:
            Task {
                await runBossQuickQuestion("Keep trusted work moving. If there is an obvious safe next step, take it through Workbench actions.")
            }
        case .bossQuickRespondForMe:
            Task {
                await runBossQuickQuestion("Respond for me where appropriate. Tell me what you did or what draft response you recommend.")
            }
        case .toggleBossWatch:
            setBossWatchEnabled(!bossWatchIsEnabled)
        case .toggleBossPane:
            setBossPaneCollapsed(!state.bossPaneCollapsed)
        case .openOnboarding:
            presentOnboarding()
        case .installOuroAgent:
            isOuroAgentInstallSheetPresented = true
        case .refreshWorkspace:
            Task {
                await refreshWorkspace()
            }
        case .refreshOuroAgents:
            refreshOuroAgents()
            recordActionLog(
                source: "native",
                action: "refreshOuroAgents",
                result: "Refreshed local Ouro agents",
                succeeded: true
            )
        case .refreshWorkbenchMCP:
            refreshWorkbenchMCPRegistration()
            recordActionLog(
                source: "native",
                action: "refreshWorkbenchMCP",
                result: "Refreshed Workbench MCP registration",
                succeeded: true
            )
        case .installWorkbenchMCPForBoss:
            installWorkbenchMCPForBoss()
        case .launchSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            launch(selectedEntry)
        case .askBossAboutSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            Task {
                await runBossQuestion(about: selectedEntry)
            }
        case .focusSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            focusTerminal(selectedEntry)
        case .redrawSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            redrawTerminal(selectedEntry)
        case .sendControlCToSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            sendControlC(to: selectedEntry)
        case .sendEscapeToSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            sendEscape(to: selectedEntry)
        case .sendEOFToSelectedSession:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            sendEOF(to: selectedEntry)
        case .copySelectedLaunchCommand:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            copyLaunchCommand(for: selectedEntry)
        case .openSelectedWorkingDirectory:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            openWorkingDirectory(for: selectedEntry)
        case .revealSelectedTranscript:
            guard let selectedEntry else {
                errorMessage = "No session is selected"
                return
            }
            revealLatestTranscript(for: selectedEntry)
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
        case .collectSupportDiagnostics:
            collectSupportDiagnostics()
        case .revealSupportDiagnostics:
            revealSupportDiagnostics()
        case .copySupportDiagnosticsPath:
            copySupportDiagnosticsPath()
        case .openSupportDiagnosticsFolder:
            openSupportDiagnosticsFolder()
        case .checkReleaseUpdates:
            Task {
                await checkForReleaseUpdate()
            }
        case .openReleaseUpdate:
            openReleaseUpdate()
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
        recordActionLog(
            source: "native",
            action: "sendControlC",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Sent Ctrl-C to \(entry.name)",
            succeeded: true
        )
        save()
    }

    func redrawTerminal(_ entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.redrawDisplay()
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Redrew \(entry.name)"
        }
        recordActionLog(
            source: "native",
            action: "redrawTerminal",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Redrew \(entry.name)",
            succeeded: true
        )
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
        recordActionLog(
            source: "native",
            action: "sendEscape",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Sent Esc to \(entry.name)",
            succeeded: true
        )
        save()
    }

    func sendEOF(to entry: ProcessEntry) {
        guard let session = activeSessions[entry.id] else {
            errorMessage = "\(entry.name) is not running"
            return
        }
        session.sendBytes([0x04])
        updateEntry(entry.id) { entry in
            entry.attention = .active
            entry.lastSummary = "Sent EOF to \(entry.name)"
        }
        recordActionLog(
            source: "native",
            action: "sendEOF",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Sent Ctrl-D / EOF to \(entry.name)",
            succeeded: true
        )
        save()
    }

    func copyLaunchCommand(for entry: ProcessEntry) {
        let command = launchCommand(for: entry)
        copyToPasteboard(command)
        recordActionLog(
            source: "native",
            action: "copyLaunchCommand",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Copied launch command for \(entry.name)",
            succeeded: true
        )
    }

    func openWorkingDirectory(for entry: ProcessEntry) {
        let directoryURL = URL(fileURLWithPath: entry.workingDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            errorMessage = "Working directory does not exist: \(entry.workingDirectory)"
            recordActionLog(
                source: "native",
                action: "openWorkingDirectory",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: "Missing directory: \(entry.workingDirectory)",
                succeeded: false
            )
            return
        }
        NSWorkspace.shared.open(directoryURL)
        recordActionLog(
            source: "native",
            action: "openWorkingDirectory",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Opened \(entry.workingDirectory)",
            succeeded: true
        )
    }

    func revealLatestTranscript(for entry: ProcessEntry) {
        guard let transcriptPath = latestRun(for: entry)?.transcriptPath else {
            errorMessage = "No transcript has been recorded for \(entry.name)"
            return
        }
        let transcriptURL = URL(fileURLWithPath: transcriptPath)
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            errorMessage = "Transcript file is missing: \(transcriptPath)"
            recordActionLog(
                source: "native",
                action: "revealTranscript",
                targetEntryId: entry.id,
                targetName: entry.name,
                result: "Missing transcript: \(transcriptPath)",
                succeeded: false
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([transcriptURL])
        recordActionLog(
            source: "native",
            action: "revealTranscript",
            targetEntryId: entry.id,
            targetName: entry.name,
            result: "Revealed latest transcript",
            succeeded: true
        )
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
        let projectId = selectedProject?.id ?? state.projects.first?.id
        return createCustomSession(draft, in: projectId, launchAfterCreate: launchAfterCreate)
    }

    @discardableResult
    private func createCustomSession(_ draft: CustomTerminalSessionDraft, in projectId: UUID?, launchAfterCreate: Bool) -> ProcessEntry? {
        do {
            if state.projects.isEmpty {
                state = bootstrapper.bootstrappedState(from: state)
            }
            guard let project = projectId.flatMap({ id in state.projects.first { $0.id == id } }) ?? selectedProject ?? state.projects.first else {
                errorMessage = "No workbench project is available"
                return nil
            }
            let entry = try customSessionFactory.makeEntry(projectId: project.id, draft: draft)
            state.processEntries.append(entry)
            selectedProjectID = project.id
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

    func archiveCustomSession(_ entry: ProcessEntry, recordNativeAction: Bool = true) {
        guard activeSessions[entry.id] == nil else {
            errorMessage = "Stop \(entry.name) before archiving it"
            return
        }
        do {
            let archived = try customSessionManager.archivedEntry(entry)
            replaceEntry(archived)
            selectedEntryID = archived.id
            if recordNativeAction {
                recordActionLog(
                    source: "native",
                    action: "archiveSession",
                    targetEntryId: archived.id,
                    targetName: archived.name,
                    result: "Archived \(archived.name)",
                    succeeded: true
                )
            } else {
                save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreCustomSession(_ entry: ProcessEntry, recordNativeAction: Bool = true) {
        do {
            let restored = try customSessionManager.restoredEntry(entry)
            replaceEntry(restored)
            selectedEntryID = restored.id
            if recordNativeAction {
                recordActionLog(
                    source: "native",
                    action: "restoreSession",
                    targetEntryId: restored.id,
                    targetName: restored.name,
                    result: "Restored \(restored.name)",
                    succeeded: true
                )
            } else {
                save()
            }
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
        do {
            try action.validateForQueueing()
        } catch {
            return finishBossAction(
                source: source,
                action: action,
                entry: nil,
                result: "Skipped \(action.action.rawValue): \(error.localizedDescription)"
            )
        }

        switch action.action {
        case .createGroup:
            guard createGroup(name: action.name ?? "", rootPath: action.workingDirectory ?? "") else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Failed createGroup: \(errorMessage ?? "invalid group")")
            }
            return finishBossAction(source: source, action: action, entry: nil, result: "Created group \(action.name ?? "unnamed")")
        case .createTerminal:
            guard let project = project(matching: action.group) else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Skipped createTerminal: no unique group matches \(action.group ?? "selected group")")
            }
            let draft = CustomTerminalSessionDraft(
                name: action.name ?? "",
                command: action.command ?? "",
                workingDirectory: nonEmpty(action.workingDirectory) ?? project.rootPath,
                trust: action.trust ?? .untrusted,
                autoResume: action.autoResume ?? false,
                notes: action.text ?? "Created by \(source)"
            )
            guard let entry = createCustomSession(draft, in: project.id, launchAfterCreate: false) else {
                return finishBossAction(source: source, action: action, entry: nil, result: "Failed createTerminal: \(errorMessage ?? "invalid terminal")")
            }
            return finishBossAction(source: source, action: action, entry: entry, result: "Created terminal \(entry.name) in \(project.name)")
        case .launch, .recover, .terminate, .sendInput, .moveSession, .setTrust, .setAutoResume, .archive, .restore:
            break
        }

        guard let entryValue = action.entry,
              let entry = processEntry(matching: entryValue) else {
            return finishBossAction(
                source: source,
                action: action,
                entry: nil,
                result: "Skipped \(action.action.rawValue): no unique process entry matches \(action.entry ?? "missing entry")"
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
        case .moveSession:
            guard let project = project(matching: action.group) else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped moveSession for \(entry.name): no unique group matches \(action.group ?? "missing group")")
            }
            guard activeSessions[entry.id] == nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped moveSession for \(entry.name): stop it first")
            }
            moveSession(entry, to: project.id, recordNativeAction: false)
            return finishBossAction(source: source, action: action, entry: entry, result: "Moved \(entry.name) to \(project.name)")
        case .setTrust:
            guard let trust = action.trust else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped setTrust for \(entry.name): missing trust")
            }
            updateEntry(entry.id) { entry in
                entry.trust = trust
                entry.lastSummary = "\(entry.name) trust set to \(trust.rawValue)"
            }
            save()
            return finishBossAction(source: source, action: action, entry: entry, result: "Set \(entry.name) trust to \(trust.rawValue)")
        case .setAutoResume:
            guard let autoResume = action.autoResume else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped setAutoResume for \(entry.name): missing autoResume")
            }
            updateEntry(entry.id) { entry in
                entry.autoResume = autoResume
                entry.lastSummary = "\(entry.name) auto-resume \(autoResume ? "enabled" : "disabled")"
            }
            save()
            return finishBossAction(source: source, action: action, entry: entry, result: "\(autoResume ? "Enabled" : "Disabled") auto-resume for \(entry.name)")
        case .archive:
            guard activeSessions[entry.id] == nil else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Skipped archive for \(entry.name): stop it first")
            }
            archiveCustomSession(entry, recordNativeAction: false)
            guard state.processEntries.first(where: { $0.id == entry.id })?.isArchived == true else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Failed archive for \(entry.name): \(errorMessage ?? "not archivable")")
            }
            return finishBossAction(source: source, action: action, entry: entry, result: "Archived \(entry.name)")
        case .restore:
            restoreCustomSession(entry, recordNativeAction: false)
            guard state.processEntries.first(where: { $0.id == entry.id })?.isArchived == false else {
                return finishBossAction(source: source, action: action, entry: entry, result: "Failed restore for \(entry.name): \(errorMessage ?? "not restorable")")
            }
            return finishBossAction(source: source, action: action, entry: entry, result: "Restored \(entry.name)")
        case .createGroup, .createTerminal:
            return finishBossAction(source: source, action: action, entry: entry, result: "Skipped \(action.action.rawValue): already handled")
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
            targetName: entry?.name ?? action.entry ?? action.name ?? action.group,
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

    private func project(matching value: String?) -> WorkbenchProject? {
        guard let value = nonEmpty(value) else {
            return selectedProject ?? state.projects.first
        }
        if let id = UUID(uuidString: value), let project = state.projects.first(where: { $0.id == id }) {
            return project
        }
        let nameMatches = state.projects.filter { project in
            project.name.caseInsensitiveCompare(value) == .orderedSame
        }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
        let detachedPersistentSession = isCurrentSession
            && !manuallyTerminated
            && currentPlan?.persistentSessionName.map(persistentSessionIsListed) == true
        if detachedPersistentSession {
            activeSessions[entryId] = nil
            if terminalFocusEntryID == entryId {
                terminalFocusEntryID = nil
            }
            updateEntry(entryId) { entry in
                entry.attention = .needsBossReview
                entry.lastSummary = "\(entry.name) detached; recovery can reattach the persistent terminal session"
            }
            state.processRuns[runIndex].status = .needsRecovery
            state.processRuns[runIndex].pid = nil
            state.processRuns[runIndex].endedAt = nil
            state.processRuns[runIndex].exitCode = nil
            state.processRuns[runIndex].rawExitStatus = nil
            save()
            return
        }
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

    private func persistentSessionIsListed(_ sessionName: String) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: PersistentTerminalSession.executable)
        process.arguments = PersistentTerminalSession.listArguments()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return PersistentTerminalSession.listOutput(output, contains: sessionName)
        } catch {
            return false
        }
    }

    private static let collapsedChromeMigrationKey = "ouro.workbench.collapsedChromeMigration.v17"

    private func load() {
        do {
            let loaded = try store.load()
            state = startupRecoveryReconciler.reconcile(bootstrapper.bootstrappedState(from: loaded))
            applyCollapsedChromeMigrationIfNeeded()
            bossWatchIsEnabled = state.bossWatchEnabled
            bossWatchBaselineState = bossWatchIsEnabled ? state : nil
            selectedProjectID = state.selectedProjectId.flatMap { id in
                state.projects.contains(where: { $0.id == id }) ? id : nil
            } ?? state.projects.first?.id
            selectedEntryID = state.selectedEntryId.flatMap { id in
                projectSessionEntries.contains(where: { $0.id == id }) ? id : nil
            } ?? sessionEntries.first?.id ?? archivedSessionEntries.first?.id
            try store.save(state)
        } catch {
            errorMessage = String(describing: error)
            state = bootstrapper.bootstrappedState(from: WorkspaceState())
            bossWatchIsEnabled = state.bossWatchEnabled
            bossWatchBaselineState = nil
            selectedProjectID = state.projects.first?.id
            selectedEntryID = sessionEntries.first?.id ?? archivedSessionEntries.first?.id
        }
    }

    /// One-time migration: the Workbench 0.1.17 redesign defaults the boss
    /// dashboard to collapsed. Existing users had it expanded; flip them to
    /// collapsed on first launch of this version. They can still re-open it
    /// from the header chevron at any time.
    private func applyCollapsedChromeMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.collapsedChromeMigrationKey) else {
            return
        }
        state.bossPaneCollapsed = true
        defaults.set(true, forKey: Self.collapsedChromeMigrationKey)
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
            return MailboxFetchResult(value: nil, issue: "\(label): \(error.localizedDescription)")
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MailboxFetchResult<Value: Sendable>: Sendable {
    var value: Value?
    var issue: String?
}

struct TerminalPane: NSViewRepresentable {
    var session: TerminalSessionController

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        host.attach(session.terminal)
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        nsView.attach(session.terminal)
    }
}

final class TerminalHostView: NSView {
    private weak var terminal: CapturingLocalProcessTerminalView?
    private var lastLaidOutSize: NSSize = .zero
    private var pendingRedrawWorkItems: [DispatchWorkItem] = []
    private static let contentInset = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 2)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureBacking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureBacking()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        terminal?.claimKeyboardFocus()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        terminal?.claimKeyboardFocus()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let terminal else {
            super.keyDown(with: event)
            return
        }
        terminal.keyDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        if let terminal,
           hitView === terminal || hitView?.isDescendant(of: terminal) == true {
            terminal.claimKeyboardFocus()
        }
        return hitView
    }

    func attach(_ terminal: CapturingLocalProcessTerminalView) {
        guard self.terminal !== terminal else {
            focusTerminal()
            return
        }
        self.terminal?.removeFromSuperview()
        self.terminal = terminal
        cancelPendingRedraws()
        lastLaidOutSize = .zero
        terminal.removeFromSuperview()
        terminal.frame = terminalContentFrame
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        needsLayout = true
        focusTerminal()
        scheduleTerminalRedraws(after: [0.08, 0.22, 0.55, 1.0])
    }

    override func layout() {
        super.layout()
        guard let terminal else {
            return
        }
        terminal.frame = terminalContentFrame
        let size = bounds.size
        guard size.width > 20, size.height > 20 else {
            return
        }
        if abs(size.width - lastLaidOutSize.width) > 1 || abs(size.height - lastLaidOutSize.height) > 1 {
            lastLaidOutSize = size
            scheduleTerminalRedraws(after: [0.05, 0.18, 0.55, 1.0])
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTerminal()
    }

    private var terminalContentFrame: NSRect {
        let inset = Self.contentInset
        return NSRect(
            x: bounds.minX + inset.left,
            y: bounds.minY + inset.bottom,
            width: max(0, bounds.width - inset.left - inset.right),
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
    }

    private func configureBacking() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    private func focusTerminal() {
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else {
                return
            }
            terminal.claimKeyboardFocus()
        }
    }

    private func cancelPendingRedraws() {
        pendingRedrawWorkItems.forEach { $0.cancel() }
        pendingRedrawWorkItems.removeAll()
    }

    private func scheduleTerminalRedraws(after delays: [TimeInterval]) {
        cancelPendingRedraws()
        pendingRedrawWorkItems = delays.map { delay in
            let workItem = DispatchWorkItem { [weak self, weak terminal] in
                guard let self,
                      let terminal,
                      terminal.superview === self else {
                    return
                }
                terminal.send([0x0c])
                terminal.claimKeyboardFocus()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }
}

@MainActor
final class TerminalSessionController: NSObject, ObservableObject, Identifiable, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let plan: TerminalCommandPlan
    let terminal: CapturingLocalProcessTerminalView
    private static let initialTerminalFrame = CGRect(x: 0, y: 0, width: 960, height: 520)
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
        self.terminal = CapturingLocalProcessTerminalView(frame: Self.initialTerminalFrame)
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

    func redrawDisplay() {
        sendBytes([0x0c])
    }

    func redrawDisplayBurst(after delays: [TimeInterval]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.redrawDisplay()
                self?.focusInput()
            }
        }
    }

    func focusInput() {
        DispatchQueue.main.async { [weak terminal] in
            guard let terminal else {
                return
            }
            terminal.claimKeyboardFocus()
        }
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?(slice)
        super.dataReceived(slice: slice)
    }

    func claimKeyboardFocus() {
        window?.makeFirstResponder(self)
    }
}

private extension LocalProcessTerminalView {
    func configureNativeFeel() {
        metalBufferingMode = .perFrameAggregated
        try? setUseMetal(true)
        getTerminal().setCursorStyle(.steadyBlock)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
}

private extension String {
    var looksLikeOnboardingQuestion: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if trimmed.contains("?") {
            return true
        }
        let questionPrefixes = [
            "what ",
            "why ",
            "how ",
            "which ",
            "when ",
            "where ",
            "who ",
            "should ",
            "do i ",
            "does ",
            "can you tell",
            "help me understand"
        ]
        return questionPrefixes.contains { trimmed.hasPrefix($0) }
    }
}
#endif
