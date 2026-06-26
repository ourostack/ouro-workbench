#!/usr/bin/env python3
"""B8 per-view uncovered-region measure.

Reads `llvm-cov export <bin> -instr-profile <profdata> <WorkbenchViews.swift>`
JSON on stdin and prints, per B8 view line range, the uncovered REGION entries
(segment with isRegionEntry && hasCount && count==0). Counts the count==0 region
ENTRIES whose start line falls in [lo, hi].

Segment tuple (llvm-cov export schema):
  [line, col, count, hasCount, isRegionEntry, isGapRegion, ...]
"""
import json
import sys

# B8 view decl line ranges (start of decl -> just before next decl). Computed
# from the grep of struct decls; hi is exclusive upper bound of the NEXT decl.
# Ranges RE-MEASURED post-init-seams + post-rebase onto B1/B3/B6 (+22 file shift).
VIEWS = [
    ("InboxDoorPill",            5418, 5465),
    ("BossNeedsMeCodingColumns", 5465, 5556),
    ("HabitHistoryPanelView",    5556, 5611),
    ("MetricStateChip",          5699, 5742),
    ("BossConversationView",     5890, 5935),
    ("BossProposalCardList",     7508, 7526),
    ("BossProposalCard",         7526, 7571),
    ("BossProposalItemRow",      7571, 7663),
    ("ActionLogView",            7817, 7960),
    ("BossActionReceiptStrip",   7960, 8054),
    ("BossWatchStatusView",      8054, 8104),
    ("BossWorkbenchMCPSetupView",8172, 8214),
]

data = json.load(sys.stdin)
f = data["data"][0]["files"][0]
segs = f["segments"]

uncovered = []  # (line, col)
for s in segs:
    line, col, count, has_count, is_region_entry = s[0], s[1], s[2], s[3], s[4]
    if is_region_entry and has_count and count == 0:
        uncovered.append((line, col))

total = 0
for name, lo, hi in VIEWS:
    hits = [(l, c) for (l, c) in uncovered if lo <= l < hi]
    total += len(hits)
    locs = " ".join(f"{l}:{c}" for l, c in sorted(hits))
    print(f"{name:28s} [{lo}-{hi}) : {len(hits):3d}  {locs}")
print(f"{'TOTAL':28s}        : {total:3d}")
