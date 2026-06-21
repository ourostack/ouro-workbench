import XCTest
@testable import OuroWorkbenchCore

/// U16: the in-app bug reporter's disclosure must tell the truth about what's anonymized
/// vs verbatim-and-local. The OLD copy framed the WHOLE bundle as anonymized ("The report
/// text is anonymized — … before it's saved or filed") right after listing the screenshot
/// and diagnostics zip — but the screenshot is raw window pixels and the diagnostics zip is
/// copied verbatim; only `report.md` is redacted. The careful operator who reads the
/// disclosure is the one most misled. This seam holds the corrected copy so it's testable.
final class ReportBugDisclosureCopyTests: XCTestCase {
    private let copy = ReportBugDisclosureCopy.disclosure.lowercased()

    func testDistinguishesAnonymizedTextFromVerbatimArtifacts() {
        // The report TEXT is anonymized…
        XCTAssertTrue(copy.contains("anonymiz"), "must say the report text is anonymized")
        // …and the screenshot + diagnostics zip are explicitly NOT.
        XCTAssertTrue(copy.contains("screenshot"))
        XCTAssertTrue(copy.contains("diagnostics"))
        XCTAssertTrue(
            copy.contains("not") && (copy.contains("verbatim") || copy.contains("as-is") || copy.contains("literal")),
            "must mark the screenshot/zip as verbatim / not anonymized: \(ReportBugDisclosureCopy.disclosure)"
        )
    }

    func testNamesBroadZipContentsInOnePhrase() {
        // One short phrase naming what the diagnostics zip holds (app logs / versions /
        // environment / local paths), so the operator knows it isn't scrubbed.
        XCTAssertTrue(
            copy.contains("log") || copy.contains("version") || copy.contains("environment") || copy.contains("path"),
            "must name the broad zip contents: \(ReportBugDisclosureCopy.disclosure)"
        )
    }

    func testStatesEverythingStaysLocalAndNothingIsUploadedAutomatically() {
        XCTAssertTrue(copy.contains("local") || copy.contains("your mac") || copy.contains("on your"),
                      "must say it stays local")
        // The screenshot + zip are never uploaded to the GitHub issue (already true in code).
        XCTAssertTrue(copy.contains("not uploaded") || copy.contains("never uploaded") || copy.contains("aren't uploaded"),
                      "must say the screenshot/zip are not uploaded when filing")
        XCTAssertTrue(copy.contains("github") || copy.contains("issue"),
                      "must reference filing as a GitHub issue")
    }

    func testDoesNotImplyTheWholeBundleIsAnonymized() {
        // The OLD misleading framing put "anonymized … before it's saved or filed" right
        // after listing the screenshot + zip, inviting the whole-bundle-scrubbed reading.
        // The corrected copy must NOT claim the screenshot or the zip is anonymized.
        let lowered = ReportBugDisclosureCopy.disclosure.lowercased()
        XCTAssertFalse(lowered.contains("screenshot is anonymized"))
        XCTAssertFalse(lowered.contains("anonymized screenshot"))
        XCTAssertFalse(lowered.contains("everything is anonymized"))
        XCTAssertFalse(lowered.contains("whole bundle is anonymized"))
    }

    func testIsNonEmptyAndSingleLineFriendly() {
        XCTAssertFalse(ReportBugDisclosureCopy.disclosure.isEmpty)
        // No embedded newlines — it's a single inline Label string in the sheet.
        XCTAssertFalse(ReportBugDisclosureCopy.disclosure.contains("\n"))
    }
}
