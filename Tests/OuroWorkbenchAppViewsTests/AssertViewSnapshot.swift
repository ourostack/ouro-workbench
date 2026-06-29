#if os(macOS)
import Foundation
import SwiftUI
import XCTest

/// The one-liner test entry (D-U1 Piece 4). Inspects `view` via `ViewSnapshotHost`,
/// serializes it, and compares-or-records against `__Snapshots__/<name>.txt`. On a
/// missing reference (or `OURO_SNAPSHOT_RECORD=1`) it RECORDS; on mismatch it
/// writes a `.actual.txt` artifact, attaches the actual tree to the test, and
/// fails AT THE CALL SITE. `throws` because the ViewInspector traversal is throwing.
///
/// Determinism is injected by the host (`string(locale: en_US_POSIX)`); the caller
/// supplies a fixture built via the real model seam (provenance — P2).
@MainActor
func assertViewSnapshot<V: View>(
    of view: V,
    named name: String,
    record: Bool = isRecordingFromEnvironment(),
    file: StaticString = #filePath,
    line: UInt = #line,
    storeFilePath: String = #filePath
) throws {
    let text = try ViewSnapshotHost.snapshotText(of: view)
    let store = ViewSnapshotStore.default(testFilePath: storeFilePath)
    try compareOrFail(text, named: name, store: store, record: record, file: file, line: line)
}

/// Text-input seam (no SwiftUI view) used by the store's own tests and by callers
/// that already hold a serialized tree. Same record/compare/artifact/attach/fail
/// behavior as `assertViewSnapshot(of:…)`.
@MainActor
func assertViewSnapshotText(
    _ text: String,
    named name: String,
    store: ViewSnapshotStore,
    record: Bool = isRecordingFromEnvironment(),
    file: StaticString = #filePath,
    line: UInt = #line,
    fail: (String, StaticString, UInt) -> Void = { XCTFail($0, file: $1, line: $2) }
) throws {
    try compareOrFail(text, named: name, store: store, record: record, file: file, line: line, fail: fail)
}

/// Shared compare/record + failure-reporting core.
@MainActor
private func compareOrFail(
    _ text: String,
    named name: String,
    store: ViewSnapshotStore,
    record: Bool,
    file: StaticString,
    line: UInt,
    fail: (String, StaticString, UInt) -> Void = { XCTFail($0, file: $1, line: $2) }
) throws {
    let outcome = try store.compareOrRecord(actual: text, named: name, recording: record)
    switch outcome {
    case .matched:
        return
    case .recorded:
        // First-run record (or an intentional re-record) is not a failure, but we
        // surface it so a CI run that records (where it must compare) is visible.
        if record {
            // Intentional re-record: silent.
            return
        }
        // Missing-reference record on a normal run: attach the recorded tree so the
        // operator can eyeball the first reference, but do NOT fail.
        attach(text, named: "\(name).recorded")
        return
    case .mismatch(let mismatch):
        attach(mismatch.actual, named: "\(name).actual")
        fail(mismatch.message, file, line)
    }
}

/// `OURO_SNAPSHOT_RECORD=1` → record mode (D-U1-3). Default = compare.
func isRecordingFromEnvironment() -> Bool {
    ProcessInfo.processInfo.environment["OURO_SNAPSHOT_RECORD"] == "1"
}

/// Attach a serialized tree to the running test (mirrors the repo's artifact
/// discipline). Best-effort; never fails the test on its own.
@MainActor
private func attach(_ text: String, named name: String) {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    XCTContext.runActivity(named: "snapshot:\(name)") { activity in
        activity.add(attachment)
    }
}
#endif
