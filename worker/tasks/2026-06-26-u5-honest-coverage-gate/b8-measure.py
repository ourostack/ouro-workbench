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
# Ranges RE-MEASURED post-init-seams (ActionLogView +18, BossActionReceiptStrip +18).
VIEWS = [
    ("InboxDoorPill",            5396, 5443),
    ("BossNeedsMeCodingColumns", 5443, 5534),
    ("HabitHistoryPanelView",    5534, 5589),
    ("MetricStateChip",          5677, 5720),
    ("BossConversationView",     5868, 5913),
    ("BossProposalCardList",     7473, 7491),
    ("BossProposalCard",         7491, 7536),
    ("BossProposalItemRow",      7536, 7628),
    ("ActionLogView",            7782, 7925),
    ("BossActionReceiptStrip",   7925, 8019),
    ("BossWatchStatusView",      8019, 8069),
    ("BossWorkbenchMCPSetupView",8137, 8179),
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
