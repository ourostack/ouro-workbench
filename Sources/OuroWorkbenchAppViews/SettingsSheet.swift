#if os(macOS)
import AppKit
import SwiftUI

/// User preferences sheet, opened by ⌘, or the More menu's "Settings…"
/// action. Consolidates settings that were previously scattered as raw
/// UserDefaults reads — terminal font size, theme override, and menu-bar
/// icon visibility — into a single discoverable surface. Every control
/// binds directly to a `WorkbenchViewModel` setter so changes persist
/// immediately; no Save button needed.
struct SettingsSheet: View {
    @ObservedObject var model: WorkbenchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    terminalSection
                    appearanceSection
                    chromeSection
                    startupSection
                    updatesSection
                    bossSection
                    advancedSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 540)
    }

    private var fontSizeBounds: ClosedRange<Int> {
        let lo = Int(WorkbenchViewModel.terminalFontSizeBounds.lowerBound)
        let hi = Int(WorkbenchViewModel.terminalFontSizeBounds.upperBound)
        return lo...hi
    }

    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { Int(model.terminalFontSize) },
            set: { model.setTerminalFontSize(CGFloat($0)) }
        )
    }

    @ViewBuilder
    private var terminalSection: some View {
        SettingsSection(title: "Terminal", systemImage: "terminal") {
            HStack(spacing: 12) {
                Text("Font size")
                    .frame(width: 110, alignment: .leading)
                Stepper(value: fontSizeBinding, in: fontSizeBounds) {
                    fontSizeLabel
                }
                Button("Reset") {
                    model.resetTerminalFontSize()
                }
                .help("Reset to macOS default (13pt). Also bound to ⌘0.")
            }
            Text("Also bound to ⌘+ / ⌘- / ⌘0 in any terminal.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var fontSizeLabel: some View {
        let display = "\(Int(model.terminalFontSize))pt"
        Text(display)
            .monospacedDigit()
            .frame(width: 50, alignment: .leading)
    }

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsSection(title: "Appearance", systemImage: "paintpalette") {
            HStack(spacing: 12) {
                Text("Terminal theme")
                    .frame(width: 110, alignment: .leading)
                Picker(
                    "",
                    selection: Binding(
                        get: { model.terminalThemeOverride },
                        set: { model.setTerminalThemeOverride($0) }
                    )
                ) {
                    ForEach(TerminalThemeOverride.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            Text("Follow System matches your macOS light/dark setting. Light or Dark pins the terminal palette regardless of the system appearance.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var chromeSection: some View {
        SettingsSection(title: "Workbench Chrome", systemImage: "menubar.rectangle") {
            Toggle(isOn: Binding(
                get: { model.showMenuBarStatusItem },
                set: { model.setShowMenuBarStatusItem($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show menu bar icon")
                    Text("Adds the ∞ status item with running-session count, jump-to-session menu, and Boss Watch toggle.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private var startupSection: some View {
        SettingsSection(title: "Startup", systemImage: "power") {
            Toggle(isOn: Binding(
                get: { model.autoLaunchResumableOnStartup },
                set: { model.setAutoLaunchResumableOnStartup($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-launch resumable terminals on startup")
                    Text("On launch, start every terminal marked Auto Resume that isn't already running. Lets a `.workbench.json` workspace come up with its agents waiting for you.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        SettingsSection(title: "Software Updates", systemImage: "arrow.down.app") {
            WorkbenchUpdatePanel(model: model, showTitle: false)
            Toggle(isOn: Binding(
                get: { model.autoUpdateEnabled },
                set: { model.setAutoUpdateEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically check for updates and install on quit")
                    Text("Workbench verifies the release manifest and applies staged updates the next time you quit.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    private var bossSection: some View {
        SettingsSection(title: "Boss", systemImage: "person.2.badge.gearshape") {
            Toggle(isOn: $model.bossAutoAdvanceEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let the boss auto-advance waiting sessions")
                    Text("When a session is waiting, the boss answers the prompt for you using that session's friend's preferences — automatically (Boss Watch is on by default). Mark a session \u{201C}hands off\u{201D} (untrusted) to exclude it. It never auto-answers destructive or secret prompts, and every decision — acted or not — is in the Boss Decision Log (⌘K). Turn this off to make the boss escalate everything instead.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        SettingsSection(title: "Advanced", systemImage: "wrench.and.screwdriver") {
            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Notification Preferences…", systemImage: "bell.badge")
                }
                .help("Opens System Settings → Notifications so you can manage Workbench banners.")
            }
            Text("Notification permission is required for Boss-Watch needs-me pings and unexpected-exit alerts.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// A section within the Settings sheet — header + content slot — so each
/// settings group renders the same way.
private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
