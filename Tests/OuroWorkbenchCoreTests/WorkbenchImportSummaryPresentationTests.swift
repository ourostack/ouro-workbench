import XCTest
@testable import OuroWorkbenchCore

/// The import false-green fix: importing a workspace used to show a GREEN
/// "Imported N terminals" banner + log `succeeded:true` EVEN WHEN the durable
/// `store.save(state)` failed — a false success over an in-memory-only import
/// that's lost on quit.
///
/// This seam routes the banner's green-vs-warning decision through one pure,
/// framework-free function so the honesty rule is unit-tested: the SUCCESS
/// (green) tone is reachable ONLY when the import actually persisted. An import
/// whose write failed is ALWAYS a `.warning`, regardless of how many terminals
/// were created.
///
/// HONESTY INVARIANT (asserted exhaustively below): `.success` (the green check
/// + green color) is produced ONLY when `persisted == true`. `persisted == false`
/// is ALWAYS `.warning` (orange) — green is unreachable for an unsaved import.
final class WorkbenchImportSummaryPresentationTests: XCTestCase {
    typealias P = WorkbenchImportSummaryPresentation

    // MARK: - tone(persisted:createdCount:) — the four (persisted × hasImports) combos

    func testPersistedWithImportsIsSuccess() {
        XCTAssertEqual(P.tone(persisted: true, createdCount: 3), .success)
    }

    func testPersistedWithNoImportsIsSuccess() {
        // "Nothing imported" that DID persist is still an honest (green/neutral)
        // success — there was no write failure to warn about.
        XCTAssertEqual(P.tone(persisted: true, createdCount: 0), .success)
    }

    func testNotPersistedWithImportsIsWarning() {
        XCTAssertEqual(P.tone(persisted: false, createdCount: 3), .warning)
    }

    func testNotPersistedWithNoImportsIsWarning() {
        // A failed write is a warning even when nothing was created — the honesty
        // rule keys on `persisted`, not on the count.
        XCTAssertEqual(P.tone(persisted: false, createdCount: 0), .warning)
    }

    // MARK: - iconSystemName(for:) — every Tone arm

    func testIconForSuccessIsGreenCheck() {
        XCTAssertEqual(P.iconSystemName(for: .success), "checkmark.seal.fill")
    }

    func testIconForWarningIsTriangle() {
        XCTAssertEqual(P.iconSystemName(for: .warning), "exclamationmark.triangle.fill")
    }

    // MARK: - color(for:) — every Tone arm

    func testColorForSuccessIsGreen() {
        XCTAssertEqual(P.color(for: .success), .green)
    }

    func testColorForWarningIsOrange() {
        XCTAssertEqual(P.color(for: .warning), .orange)
    }

    // MARK: - notPersistedNote — the honest "lost on quit" line

    func testNotPersistedNoteIsHonestAboutLoss() {
        let note = P.notPersistedNote
        XCTAssertTrue(
            note.contains("save") || note.contains("disk"),
            "the note must name the durable-write failure"
        )
        XCTAssertTrue(
            note.lowercased().contains("quit") || note.lowercased().contains("lost"),
            "the note must warn the import is lost on quit"
        )
    }

    // MARK: - Honesty invariant — green/.success reachable ONLY when persisted

    func testSuccessReachableOnlyWhenPersisted() {
        // Sweep every (persisted × createdCount) combo. The .success tone, its
        // green check, and its .green color may appear ONLY when persisted == true
        // and NEVER when persisted == false.
        for persisted in [true, false] {
            for createdCount in [0, 1, 7] {
                let tone = P.tone(persisted: persisted, createdCount: createdCount)
                let isSuccess = (tone == .success)
                XCTAssertEqual(
                    isSuccess, persisted,
                    "success must appear iff persisted (persisted=\(persisted), count=\(createdCount))"
                )
                // The green check + .green ride the .success tone alone.
                XCTAssertEqual(
                    P.iconSystemName(for: tone) == "checkmark.seal.fill", persisted,
                    "green check must appear iff persisted (persisted=\(persisted), count=\(createdCount))"
                )
                XCTAssertEqual(
                    P.color(for: tone) == .green, persisted,
                    ".green must appear iff persisted (persisted=\(persisted), count=\(createdCount))"
                )
            }
        }
    }

    func testNotPersistedIsNeverGreen() {
        // A failed-write import is ALWAYS a warning/orange — the count can't make
        // it green.
        for createdCount in [0, 1, 7] {
            let tone = P.tone(persisted: false, createdCount: createdCount)
            XCTAssertEqual(tone, .warning)
            XCTAssertEqual(P.color(for: tone), .orange)
            XCTAssertNotEqual(P.iconSystemName(for: tone), "checkmark.seal.fill")
        }
    }
}
