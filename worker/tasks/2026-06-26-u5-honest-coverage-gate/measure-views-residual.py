#!/usr/bin/env python3
"""Measure per-file uncovered lines/regions for the OuroWorkbenchAppViews dir.

Reads a -summary-only llvm-cov export JSON on stdin (already filtered to the
views dir) and prints, per file, the uncovered line + region counts. Used to
size the U5 honest allowlist budget (the residual after steps 1-2).
"""
import json
import os
import sys

data = json.load(sys.stdin)
rows = []
for f in data["data"][0]["files"]:
    name = os.path.basename(f["filename"])
    L = f["summary"]["lines"]
    R = f["summary"]["regions"]
    ul = L["count"] - L["covered"]
    ur = R["count"] - R["covered"]
    rows.append((name, L["percent"], ul, R["percent"], ur))

rows.sort(key=lambda r: (-r[2], r[0]))
for name, lp, ul, rp, ur in rows:
    print("%-46s lines %5.1f%% (%d uncov)  regions %5.1f%% (%d uncov)" % (name, lp, ul, rp, ur))
