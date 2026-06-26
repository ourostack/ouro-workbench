#!/usr/bin/env python3
"""B9: list uncovered region ENTRIES (count==0, isRegionEntry) for a decl line range
in WorkbenchViews.swift, matching the b6-records measurement basis.

Usage: b9-measure.py <PackageTests-binary> <default.profdata> [DeclName]
If a DeclName is given, prints only that decl.
"""
import json, subprocess, sys

BIN = sys.argv[1]
PROF = sys.argv[2]
ONLY = sys.argv[3] if len(sys.argv) > 3 else None
SRC = "Sources/OuroWorkbenchAppViews/WorkbenchViews.swift"

# Decl line ranges (the named B9 view's OWN struct body; the next decl starts the line after `hi`).
DECLS = {
    "RecoverySheet":            (889, 980),
    "HarnessStatusSheet":       (1193, 1399),
    "HarnessAgentRow":          (1466, 1545),
    "HarnessActionResultBanner":(1589, 1626),
    "ShortcutHelpSheet":        (1701, 1769),
    "SettingsSheet":            (1804, 1994),
    "ImportSummaryBanner":      (2012, 2120),
    "ReportBugSheet":           (2429, 2598),
    "SessionStatusListView":    (7663, 7720),
    "TranscriptSearchView":     (8070, 8137),
    "ReleaseUpdateView":        (10434, 10445),
    "RecoveryDrillView":        (10473, 10517),
}

raw = subprocess.run(
    ["xcrun", "llvm-cov", "export", BIN, "-instr-profile", PROF, SRC],
    capture_output=True, text=True, check=True).stdout
data = json.loads(raw)

fobj = None
for f in data["data"][0]["files"]:
    if f["filename"].endswith("WorkbenchViews.swift"):
        fobj = f
        break
seg = fobj["segments"]  # [line, col, count, hasCount, isRegionEntry, isGapRegion]

total = 0
for name, (lo, hi) in DECLS.items():
    if ONLY and name != ONLY:
        continue
    uncovered = []
    for s in seg:
        line, col, count, hasCount, isRegionEntry = s[0], s[1], s[2], s[3], s[4]
        if lo <= line <= hi and isRegionEntry and hasCount and count == 0:
            uncovered.append((line, col))
    total += len(uncovered)
    print(f"== {name} (L{lo}-{hi}): {len(uncovered)} uncovered region entries ==")
    for line, col in uncovered:
        print(f"   L{line}:{col}")
    print()
print(f"TOTAL uncovered (this selection): {total}")
