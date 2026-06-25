#if os(macOS)
import Foundation
import OuroWorkbenchCore
import SwiftUI

public struct WorkbenchShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = WorkbenchShortcutModifiers(rawValue: 1 << 0)
    public static let shift = WorkbenchShortcutModifiers(rawValue: 1 << 1)
    public static let option = WorkbenchShortcutModifiers(rawValue: 1 << 2)
    public static let control = WorkbenchShortcutModifiers(rawValue: 1 << 3)

    public var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if contains(.command) { modifiers.insert(.command) }
        if contains(.shift) { modifiers.insert(.shift) }
        if contains(.option) { modifiers.insert(.option) }
        if contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

public enum WorkbenchShortcutKey: Hashable, Sendable {
    case character(Character)
    case rightArrow
    case downArrow

    public var keyEquivalent: KeyEquivalent {
        switch self {
        case let .character(character):
            return KeyEquivalent(character)
        case .rightArrow:
            return .rightArrow
        case .downArrow:
            return .downArrow
        }
    }

    var rawID: String {
        switch self {
        case let .character(character): return String(character)
        case .rightArrow: return "rightArrow"
        case .downArrow: return "downArrow"
        }
    }
}

public struct WorkbenchNativeMenuShortcut: Hashable, Sendable {
    public let title: String
    public let command: WorkbenchMenuCommand
    public let key: WorkbenchShortcutKey
    public let modifiers: WorkbenchShortcutModifiers
    public let guideKeys: String

    public init(
        title: String,
        command: WorkbenchMenuCommand,
        key: WorkbenchShortcutKey,
        modifiers: WorkbenchShortcutModifiers = .command,
        guideKeys: String
    ) {
        self.title = title
        self.command = command
        self.key = key
        self.modifiers = modifiers
        self.guideKeys = guideKeys
    }

    public var chord: String {
        "\(modifiers.rawValue):\(key.rawID)"
    }
}

public enum WorkbenchNativeMenuCatalog {
    public static let allShortcuts: [WorkbenchNativeMenuShortcut] = [
        .init(title: "New Terminal", command: .newTerminal, key: .character("n"), guideKeys: "⌘N"),
        .init(title: "New Terminal Tab", command: .newTerminalTab, key: .character("t"), guideKeys: "⌘T"),
        .init(title: "Open Workspace…", command: .openWorkspace, key: .character("o"), guideKeys: "⌘O"),
        .init(title: "Save Workspace As…", command: .saveWorkspace, key: .character("s"), modifiers: [.command, .shift], guideKeys: "⇧⌘S"),
        .init(title: "Toggle Sidebar", command: .toggleSidebar, key: .character("b"), modifiers: [.command, .control], guideKeys: "⌃⌘B"),
        .init(title: "Enter / Exit Focus", command: .toggleFocus, key: .character("f"), modifiers: [.command, .shift], guideKeys: "⇧⌘F"),
        .init(title: "Increase Terminal Font", command: .fontIncrease, key: .character("="), guideKeys: "⌘+ / ⌘="),
        .init(title: "Decrease Terminal Font", command: .fontDecrease, key: .character("-"), guideKeys: "⌘-"),
        .init(title: "Reset Terminal Font", command: .fontReset, key: .character("0"), guideKeys: "⌘0"),
        .init(title: "Find in Terminal", command: .findInTerminal, key: .character("f"), guideKeys: "⌘F"),
        .init(title: "Redraw", command: .redraw, key: .character("l"), guideKeys: "⌘L"),
        .init(title: "Stop", command: .stopSelected, key: .character("."), guideKeys: "⌘."),
        .init(title: "Previous Terminal", command: .prevTerminal, key: .character("["), guideKeys: "⌘["),
        .init(title: "Next Terminal", command: .nextTerminal, key: .character("]"), guideKeys: "⌘]"),
        .init(title: "Previous Workspace", command: .prevGroup, key: .character("["), modifiers: [.command, .shift], guideKeys: "⇧⌘["),
        .init(title: "Next Workspace", command: .nextGroup, key: .character("]"), modifiers: [.command, .shift], guideKeys: "⇧⌘]"),
        .init(title: "Rename Workspace…", command: .renameWorkspace, key: .character("r"), modifiers: [.command, .shift], guideKeys: "⇧⌘R"),
        .init(title: "Rename Tab…", command: .renameTab, key: .character("r"), guideKeys: "⌘R"),
        .init(title: "Split Right", command: .splitRight, key: .rightArrow, modifiers: [.command, .option], guideKeys: "⌥⌘→"),
        .init(title: "Split Down", command: .splitDown, key: .downArrow, modifiers: [.command, .option], guideKeys: "⌥⌘↓"),
        .init(title: "Focus Other Pane", command: .focusOtherPane, key: .character("]"), modifiers: [.command, .option], guideKeys: "⌥⌘]"),
        .init(title: "Close Pane", command: .closePane, key: .character("w"), modifiers: [.command, .option], guideKeys: "⌥⌘W"),
        .init(title: "Check In", command: .bossCheckIn, key: .character("i"), guideKeys: "⌘I"),
        .init(title: "Command Palette", command: .commandPalette, key: .character("k"), guideKeys: "⌘K"),
        .init(title: "Jump to Next Needing Me", command: .jumpToAttention, key: .character("j"), guideKeys: "⌘J"),
        .init(title: "Settings…", command: .settings, key: .character(","), guideKeys: "⌘,"),
        .init(title: "Keyboard Shortcuts", command: .shortcutsHelp, key: .character("/"), guideKeys: "⌘/"),
        .init(title: "Report a Bug…", command: .reportBug, key: .character("b"), modifiers: [.command, .shift], guideKeys: "⇧⌘B"),
    ] + (1...9).map { index in
        WorkbenchNativeMenuShortcut(
            title: "Terminal \(index)",
            command: .selectTerminal(index),
            key: .character(Character("\(index)")),
            guideKeys: "⌘1 … ⌘9"
        )
    }

    public static func shortcut(for command: WorkbenchMenuCommand) -> WorkbenchNativeMenuShortcut? {
        allShortcuts.first { $0.command == command }
    }
}

public enum WorkbenchScopedShortcutScope: String, Hashable, Sendable {
    case selectedTerminalDetail
    case terminalSearchBar
    case commandPaletteQuery
}

public struct WorkbenchScopedShortcut: Hashable, Sendable {
    public let guideKeys: String
    public let summary: String
    public let scope: WorkbenchScopedShortcutScope
}

public enum WorkbenchScopedShortcutCatalog {
    public static let allShortcuts: [WorkbenchScopedShortcut] = [
        .init(
            guideKeys: "⌘↩",
            summary: "Launch or restart the selected terminal from its detail surface",
            scope: .selectedTerminalDetail
        ),
        .init(
            guideKeys: "⌘G / ⇧⌘G",
            summary: "Step through terminal search matches while the search bar is open",
            scope: .terminalSearchBar
        ),
        .init(
            guideKeys: "⌘K, type 'agent <name>'",
            summary: "Jump to an installed agent through the command palette",
            scope: .commandPaletteQuery
        ),
        .init(
            guideKeys: "⌘K, type 'repair'",
            summary: "Run the focused agent repair flow through the command palette",
            scope: .commandPaletteQuery
        ),
        .init(
            guideKeys: "⌘K, type 'manage agents'",
            summary: "Open agent management through the command palette",
            scope: .commandPaletteQuery
        )
    ]
}

public struct WorkbenchKeyboardAccessibilityContractReport: Equatable, Sendable {
    public var failures: [String]

    public var consoleSummary: String {
        if failures.isEmpty {
            return "Workbench keyboard/a11y contract passed"
        }
        return "Workbench keyboard/a11y contract failed:\n" + failures.joined(separator: "\n")
    }
}

public enum WorkbenchKeyboardAccessibilityContract {
    public static func evaluate(packageRoot: URL) -> WorkbenchKeyboardAccessibilityContractReport {
        var failures: [String] = []

        let guide = WorkbenchGuide.shortcutCategories.flatMap(\.shortcuts)
        let guideKeys = Set(guide.map(\.keys))
        let nativeGuideKeys = Set(WorkbenchNativeMenuCatalog.allShortcuts.map(\.guideKeys))
        let scopedGuideKeys = Set(WorkbenchScopedShortcutCatalog.allShortcuts.map(\.guideKeys))
        let representedGuideKeys = nativeGuideKeys.union(scopedGuideKeys)

        for shortcut in guide where !representedGuideKeys.contains(shortcut.keys) {
            failures.append("WorkbenchGuide shortcut '\(shortcut.keys)' is not represented by the native or scoped shortcut catalog")
        }

        for shortcut in WorkbenchNativeMenuCatalog.allShortcuts where !guideKeys.contains(shortcut.guideKeys) {
            failures.append("Native menu shortcut '\(shortcut.guideKeys)' (\(shortcut.title)) is missing from WorkbenchGuide.shortcutCategories")
        }

        for shortcut in WorkbenchScopedShortcutCatalog.allShortcuts where !guideKeys.contains(shortcut.guideKeys) {
            failures.append("Scoped shortcut '\(shortcut.guideKeys)' is missing from WorkbenchGuide.shortcutCategories")
        }

        let chords = WorkbenchNativeMenuCatalog.allShortcuts.map(\.chord)
        let duplicateChords = duplicates(in: chords)
        for chord in duplicateChords {
            let titles = WorkbenchNativeMenuCatalog.allShortcuts
                .filter { $0.chord == chord }
                .map(\.title)
                .joined(separator: ", ")
            failures.append("Native menu shortcut chord collision for \(chord): \(titles)")
        }

        let appSourceURL = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("OuroWorkbenchApp", isDirectory: true)
            .appendingPathComponent("OuroWorkbenchApp.swift")
        if let appSource = try? String(contentsOf: appSourceURL, encoding: .utf8) {
            if !appSource.contains("nativeMenuCommand(.reportBug)") {
                failures.append("Report Bug must be a WorkbenchMenuCommand-backed native menu shortcut")
            }
            if appSource.contains("workbenchReportBug") {
                failures.append("Report Bug still uses the one-off workbenchReportBug notification path")
            }
        } else {
            failures.append("Could not read \(appSourceURL.path)")
        }

        let appViewsURL = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("OuroWorkbenchAppViews", isDirectory: true)
            .appendingPathComponent("WorkbenchViewsAndModel.swift")
        if let appViews = try? String(contentsOf: appViewsURL, encoding: .utf8) {
            for required in [
                ".help(tab.attention.healthLabel)",
                ".accessibilityLabel(\"\\(tab.effectiveTabName), \\(tab.attention.healthLabel)",
                ".help(model.checkInHelpText)",
                ".accessibilityLabel(\"Boss Watch \\(presentation.label)\")"
            ] where !appViews.contains(required) {
                failures.append("Missing representative accessibility/help wiring: \(required)")
            }
        } else {
            failures.append("Could not read \(appViewsURL.path)")
        }

        let matrixURL = packageRoot
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("cmux-workbench-test-matrix.md")
        if let matrix = try? String(contentsOf: matrixURL, encoding: .utf8) {
            if !matrix.contains("Keyboard/a11y contract note") {
                failures.append("cmux matrix must describe the keyboard/a11y contract and live AX limitation")
            }
            for id in 481...520 {
                let needle = "A11Y-\(id)"
                guard let line = matrix.split(separator: "\n").first(where: { $0.contains(needle) }) else {
                    failures.append("cmux matrix is missing \(needle)")
                    continue
                }
                if !line.contains("shortcut/a11y contract") {
                    failures.append("\(needle) must name shortcut/a11y contract coverage instead of only generic UI smoke")
                }
            }
        } else {
            failures.append("Could not read \(matrixURL.path)")
        }

        return WorkbenchKeyboardAccessibilityContractReport(failures: failures)
    }

    private static func duplicates<T: Hashable>(in values: [T]) -> [T] {
        var seen = Set<T>()
        var duplicates = Set<T>()
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return Array(duplicates)
    }
}
#endif
