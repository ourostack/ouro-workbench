#!/usr/bin/env python3
"""B6: list uncovered region ENTRIES (count==0, isRegionEntry) for a decl line range
in WorkbenchViews.swift, matching the b4-records measurement basis."""
import json, subprocess, sys

BIN = sys.argv[1]
PROF = sys.argv[2]
SRC = "Sources/OuroWorkbenchAppViews/WorkbenchViews.swift"

DECLS = {
    "DecisionLogSheet":    (2168, 2223),
    "DecisionInboxSheet":  (2235, 2423),
    "DecisionLogRow":      (2599, 2835),
    "CommandPaletteSheet": (5054, 5221),
}

raw = subprocess.run(
    ["xcrun", "llvm-cov", "export", BIN, "-instr-profile", PROF, SRC],
    capture_output=True, text=True, check=True).stdout
data = json.loads(raw)

# find the file entry
fobj = None
for f in data["data"][0]["files"]:
    if f["filename"].endswith("WorkbenchViews.swift"):
        fobj = f
        break
seg = fobj["segments"]  # [line, col, count, hasCount, isRegionEntry, isGapRegion]

for name, (lo, hi) in DECLS.items():
    uncovered = []
    for s in seg:
        line, col, count, hasCount, isRegionEntry = s[0], s[1], s[2], s[3], s[4]
        if lo <= line <= hi and isRegionEntry and hasCount and count == 0:
            uncovered.append((line, col))
    print(f"== {name} (L{lo}-{hi}): {len(uncovered)} uncovered region entries ==")
    for line, col in uncovered:
        print(f"   L{line}:{col}")
    print()
