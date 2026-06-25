#if os(macOS)
import Foundation
import XCTest

/// Shared reader for the source-grep "guard" tests (U0 Unit 2).
///
/// **Why this exists.** ~257 guard call sites across 43 test files each used to carry an
/// identical private `appSource()` that hardcoded `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`.
/// U0 extracts the 121 views + the view-model + the coupled types out of that single file into
/// the `OuroWorkbenchAppViews` library, so a guard's marker may now live in the OLD exe file OR in
/// a NEW lib file. This reader returns the UNION of both so a guard finds its marker regardless of
/// which side the code currently lives on — decoupling every guard from the physical file path in
/// ONE place (the retarget is a one-line change here, not 43).
///
/// **Adjacency-preserving concat order (CRITICAL — review finding C1).** `sourceSlice(from:to:)`
/// finds `from`, then `to` ONLY in the range AFTER `from`. Several guards slice ACROSS two
/// declarations in DECLARATION order (e.g. `TerminalSessionController` → `CapturingLocalProcessTerminalView`,
/// `WorkbenchRootView` → `WorkbenchMenuBarController`). A naïve ALPHABETICAL glob would reorder the
/// lib files and INVERT those pairs, turning a behavior-preserving move into a RED guard (a false
/// fail). So the lib files are concatenated in a DETERMINISTIC, declaration-order list
/// (`orderedLibFiles`), NOT alphabetically. Any lib `.swift` file not yet listed is appended in a
/// stable sorted order AND surfaced by `assertEveryLibFileIsOrdered()` so a future move that adds a
/// file is forced to place it in declaration order rather than silently relying on the fallback.
///
/// The old exe file is concatenated FIRST (it still holds every not-yet-moved declaration), then the
/// lib files in `orderedLibFiles` order. While a guarded declaration still lives in the exe file,
/// the lib copy does not exist yet, so there is exactly one occurrence — no duplicate-marker hazard
/// (each declaration is removed from the exe file in the SAME increment it lands in the lib).
enum WorkbenchAppSource {
    /// Repo root, resolved from this file's location: Tests/OuroWorkbenchCoreTests/<file> → repo root.
    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The thinning executable file that originally held all 121 views + the view-model.
    private static var exeFileURL: URL {
        repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
    }

    /// The extracted views library source root.
    private static var libRootURL: URL {
        repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchAppViews")
    }

    /// Lib files in ORIGINAL DECLARATION ORDER (the order the code appeared in the old
    /// single file). Declaration-order — NOT alphabetical — so cross-declaration slices keep
    /// their `from`/`to` markers in the right relative order. Extend this list (in declaration
    /// order) as each later increment moves code into the lib.
    ///
    /// Paths are relative to `Sources/OuroWorkbenchAppViews/`.
    static let orderedLibFiles: [String] = [
        // U0 Unit 3′ (Reading #2 — full view-layer move, merges campaign U3+U4): the entire
        // post-`App`/`AppDelegate` body of the old single file (original lines 132–21313) moved
        // here as ONE file in BYTE-EXACT original declaration order. Listed FIRST because in the
        // old file it began at line 132, BEFORE DashboardRowLabel (was @ 4930). Keeping the whole
        // body contiguous in declaration order guarantees every cross-declaration `sourceSlice`
        // pair (e.g. `TerminalSessionController`→`CapturingLocalProcessTerminalView`,
        // `WorkbenchRootView`→`WorkbenchMenuBarController`) stays byte-adjacent in the union.
        "WorkbenchViewsAndModel.swift",
        // U0 Unit 1 keystone — the one VM-free leaf view moved first (was @ line 4930 in the old
        // file; unguarded, so its position relative to the big file does not affect any slice).
        "Views/DashboardRowLabel.swift",
        // U0 Unit 3′ — relocated from the exe (was its OWN file, never inside OuroWorkbenchApp.swift),
        // so it is not part of any cross-declaration slice; the VM (now in the lib) depends on it.
        // Byte-identical relocation; position here is immaterial to every slice.
        "WorkbenchUpdateInstaller.swift",
        // Native menu shortcut + accessibility contract catalog. It depends on the menu-command
        // declarations above and is not part of any cross-declaration source-slice adjacency.
        "WorkbenchKeyboardAccessibilityContract.swift",
    ]

    /// The UNION source: the old exe file followed by the lib files in declaration order.
    static func appSource() throws -> String {
        var parts: [String] = []
        parts.append(try String(contentsOf: exeFileURL, encoding: .utf8))
        for relative in orderedLibSwiftFilesResolved() {
            parts.append(try String(contentsOf: libRootURL.appendingPathComponent(relative), encoding: .utf8))
        }
        // Join with a newline so an end-of-file declaration in one part and a start-of-file
        // declaration in the next never accidentally fuse on the same line.
        return parts.joined(separator: "\n")
    }

    /// Slice a passed-in source string: find `from`, then `to` ONLY in the range AFTER `from`.
    static func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound, "missing start marker: \(startMarker)")
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound,
            "missing end marker: \(endMarker)"
        )
        return String(source[start..<end])
    }

    /// Self-reading slice: read `appSource()` then slice it (the variant used by
    /// `BossMCPPillVerdictWiringTests` / `DaemonChipAvailabilityWiringTests`).
    static func sourceSlice(from startMarker: String, to endMarker: String) throws -> String {
        try sourceSlice(in: appSource(), from: startMarker, to: endMarker)
    }

    /// Resolve the ordered lib-file list, appending any present-but-unlisted lib `.swift` file in a
    /// STABLE sorted order so a newly-added file never silently drops out of `appSource()`. A move
    /// that adds a file SHOULD add it to `orderedLibFiles` in declaration order; until it does, the
    /// fallback keeps the guard suite finding the marker (sorted, deterministic), and
    /// `assertEveryLibFileIsOrdered()` flags the omission.
    private static func orderedLibSwiftFilesResolved() -> [String] {
        let listed = orderedLibFiles
        let present = presentLibSwiftFiles()
        let listedSet = Set(listed)
        let extras = present.filter { !listedSet.contains($0) }.sorted()
        // Keep only listed files that actually exist (so a stale list entry can't crash the read),
        // then the deterministic extras.
        let presentSet = Set(present)
        return listed.filter { presentSet.contains($0) } + extras
    }

    /// Every `.swift` file under the lib root, as a path relative to the lib root, sorted.
    private static func presentLibSwiftFiles() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: libRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [String] = []
        let prefix = libRootURL.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) {
                files.append(String(path.dropFirst(prefix.count)))
            }
        }
        return files.sorted()
    }

    /// Test hook: assert every present lib `.swift` file is explicitly listed in `orderedLibFiles`
    /// (in declaration order), so the deterministic-sort fallback never silently owns a file whose
    /// declaration order matters for a cross-declaration slice. Called by a dedicated guard test.
    static func assertEveryLibFileIsOrdered(file: StaticString = #filePath, line: UInt = #line) {
        let listedSet = Set(orderedLibFiles)
        let unlisted = presentLibSwiftFiles().filter { !listedSet.contains($0) }
        XCTAssertTrue(
            unlisted.isEmpty,
            "lib file(s) not declared in WorkbenchAppSource.orderedLibFiles (add them in DECLARATION order so cross-decl slices stay adjacency-correct): \(unlisted)",
            file: file,
            line: line
        )
    }
}
#endif
