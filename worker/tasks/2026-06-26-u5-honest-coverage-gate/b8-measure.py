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
VIEWS = [
    ("InboxDoorPill",            5396, 5443),
    ("BossNeedsMeCodingColumns", 5443, 5534),
    ("HabitHistoryPanelView",    5534, 5589),
    ("MetricStateChip",          5677, 5719),
    ("BossConversationView",     5868, 5912),
    ("BossProposalCardList",     7473, 7491),   # list only (BossProposalCard/ItemRow are private siblings)
    ("BossProposalCard",         7491, 7535),
    ("BossProposalItemRow",      7536, 7617),
    ("ActionLogView",            7782, 7902),
    ("BossActionReceiptStrip",   7908, 7984),
    ("BossWatchStatusView",      7985, 8034),
    ("BossWorkbenchMCPSetupView",8103, 8138),
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
