#!/usr/bin/env python3
"""Measure uncovered region-entry segments per K4 helper line-range in WorkbenchViews.swift.
argv[1] = llvm-cov export JSON for the views file.
"""
import json, sys

with open(sys.argv[1]) as fh:
    data = json.load(fh)

fentry = None
for f in data["data"][0]["files"]:
    if f["filename"].endswith("WorkbenchViews.swift"):
        fentry = f
        break
assert fentry, "views file not found"
seg = fentry["segments"]

# (name, start, end) line ranges for each K4 helper (inclusive start, exclusive end).
helpers = [
    ("DetailPaneID(enum+ext)",          72,   76),
    ("DetailSplitAxis(enum+ext)",       77,   87),
    ("DetailSplitState",                88,  103),
    ("DetailSplitAxis.ext(init/persist)",136, 151),
    ("DetailPaneID.ext(init/persist)",  152,  167),
    ("HarnessHealthState.ext",         1627, 1650),
    ("WorkbenchToolsInjectionRecorder",1651, 1672),
    ("BossWorkbenchMCPRegStatus.ext",  1673, 1688),
    ("Optional<BossMCPRegStatus>.ext", 1689, 1696),
    ("WorkspaceFolderDropDelegate",    1770, 1797),
    ("InstalledAgentRowPres.DotColor.ext", 3589, 3600),
    ("BossMCPPillPres.SemanticColor.ext",  3602, 3619),
    ("AttentionState.ext(health*)",    3939, 3976),
    ("AutonomyRemediationKind.ext",    4934, 4947),
    ("AutonomyReadinessState.ext",     4989, 5012),
    ("HeaderCalmPres.BossDotColor.ext",5013, 5029),
    ("AutonomyReadinessCheckState.ext",5030, 5053),
    ("WorkbenchImportApplyResult",    10588,10646),
    ("WorkbenchGroupColor.ext",       10647,10664),
]

def uncovered_in(start, end):
    out = []
    for s in seg:
        line, col, count, has_count, is_region_entry = s[0], s[1], s[2], s[3], s[4]
        if is_region_entry and has_count and count == 0 and start <= line < end:
            out.append((line, col))
    return out

total = 0
print("%-40s %5s  %s" % ("HELPER", "UNCOV", "lines:col"))
print("-"*90)
for name, a, b in helpers:
    u = uncovered_in(a, b)
    total += len(u)
    locs = ", ".join("%d:%d" % (l, c) for l, c in u)
    print("%-40s %5d  %s" % (name, len(u), locs))
print("-"*90)
print("%-40s %5d" % ("TOTAL K4", total))
