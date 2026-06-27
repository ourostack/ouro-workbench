#!/usr/bin/env python3
"""Attribute every uncovered region-entry in WorkbenchViews.swift to its enclosing K4 helper,
using the CURRENT (post-move) decl boundaries. Confirms each K4 helper is at 0 residual.
argv[1] = llvm-cov export JSON for the views file.
argv[2] = path to the views file (to compute decl boundaries live).
"""
import json, re, sys

cov, src = sys.argv[1], sys.argv[2]
with open(cov) as fh:
    data = json.load(fh)
fentry = next(f for f in data["data"][0]["files"] if f["filename"].endswith("WorkbenchViews.swift"))
seg = fentry["segments"]

# The K4 helpers' decl start lines (post-move), in file order. End = next top-level decl start.
k4_starts = {
    98: "DetailSplitState",
    136: "DetailSplitAxis.ext(init/persist)",
    152: "DetailPaneID.ext(init/persist)",
    1629: "HarnessHealthState.ext",
    1657: "WorkbenchToolsInjectionRecorder",
    1676: "BossWorkbenchMCPRegistrationStatus.ext",
    1693: "Optional<BossMCPRegStatus>.ext",
    3912: "AttentionState.ext(health*)",
    4904: "AutonomyRemediationKind.ext",
    4960: "AutonomyReadinessState.ext",
    4985: "HeaderCalmPresentation.BossDotColor.ext",
    10560: "WorkbenchImportApplyResult",
    10619: "WorkbenchGroupColor.ext",
}

# All top-level decl start lines (to bound each K4 helper's end).
lines = open(src).read().split('\n')
top = []
pat = re.compile(r'^(public |internal |private |final |@MainActor\s+)*(struct|enum|class|extension|protocol)\s')
for i, ln in enumerate(lines, 1):
    if pat.match(ln):
        top.append(i)
top.sort()

def end_of(start):
    for t in top:
        if t > start:
            return t
    return len(lines) + 1

def uncov_in(a, b):
    return [(s[0], s[1]) for s in seg
            if s[4] and s[3] and s[2] == 0 and a <= s[0] < b]

total = 0
print("%-42s %5s  %s" % ("K4 HELPER (post-move boundaries)", "UNCOV", "locs"))
print("-"*80)
for start in sorted(k4_starts):
    name = k4_starts[start]
    u = uncov_in(start, end_of(start))
    total += len(u)
    print("%-42s %5d  %s" % (name, len(u), ", ".join("%d:%d" % x for x in u)))
print("-"*80)
print("%-42s %5d" % ("TOTAL K4 RESIDUAL", total))
S = fentry["summary"]
print("\nFILE region: %.2f%% (%d uncov of %d)"
      % (S["regions"]["percent"], S["regions"]["count"]-S["regions"]["covered"], S["regions"]["count"]))
