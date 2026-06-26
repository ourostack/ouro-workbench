#!/usr/bin/env python3
"""B4-redo: per-view uncovered-region measurement for the 6 terminal-sheet views.

Reads the llvm-cov EXPORT json for WorkbenchViews.swift and reports, per view decl
range, the count + locations of uncovered region-entries (isRegionEntry, count==0).
This mirrors the b4-carve-records measurement basis so the before/after is comparable.

Usage:
  xcrun llvm-cov export "$BIN" -instr-profile "$PROF" \
    Sources/OuroWorkbenchAppViews/WorkbenchViews.swift > views-cov.json
  python3 b4redo-measure.py views-cov.json
"""
import json, sys

# Current decl ranges (recomputed at HEAD via brace-matching).
VIEWS = {
    "TerminalSearchBar":        (9010, 9097),
    "TerminalFocusView":        (9866, 9950),
    "NewTerminalGroupSheet":    (9983, 10063),
    "EditTerminalGroupSheet":   (10065, 10128),
    "NewTerminalSessionSheet":  (10130, 10252),
    "EditTerminalSessionSheet": (10254, 10360),
}

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "views-cov.json"
    data = json.load(open(path))
    # Find the WorkbenchViews.swift file entry.
    fileobj = None
    for f in data["data"][0]["files"]:
        if f["filename"].endswith("WorkbenchViews.swift"):
            fileobj = f
            break
    # llvm-cov export segments live under functions[].regions OR file["segments"].
    # Use the function-level region records for precise region-entry classification.
    # Each region: [lineStart, colStart, lineEnd, colEnd, count, fileID, expandedFileID, kind]
    # kind: 0=Code, 1=Expansion, 2=Skipped, 3=Gap, 4=Branch
    funcs = data["data"][0]["functions"]
    # collect uncovered code-regions per line
    uncovered = []  # (lineStart, colStart, lineEnd, colEnd, kind)
    for fn in funcs:
        # only regions whose file is WorkbenchViews.swift
        filenames = fn.get("filenames", [])
        wv_idx = [i for i, n in enumerate(filenames) if n.endswith("WorkbenchViews.swift")]
        if not wv_idx:
            continue
        for r in fn["regions"]:
            lineStart, colStart, lineEnd, colEnd, count, fileID = r[0], r[1], r[2], r[3], r[4], r[5]
            kind = r[7] if len(r) > 7 else 0
            if fileID not in wv_idx:
                continue
            if kind in (2, 3):  # skipped/gap — not a coverable region
                continue
            if count == 0:
                uncovered.append((lineStart, colStart, lineEnd, colEnd, kind))
    # de-dup
    uncovered = sorted(set(uncovered))
    print(f"WorkbenchViews.swift total uncovered code/branch regions: {len(uncovered)}\n")
    grand = 0
    for name, (lo, hi) in VIEWS.items():
        inview = [u for u in uncovered if lo <= u[0] <= hi]
        grand += len(inview)
        print(f"== {name} (L{lo}-L{hi}): {len(inview)} uncovered region(s)")
        for (ls, cs, le, ce, k) in inview:
            kindname = {0: "code", 1: "expansion", 4: "branch"}.get(k, str(k))
            print(f"    L{ls}:{cs} -> L{le}:{ce}  [{kindname}]")
        print()
    print(f"TOTAL across the 6 views: {grand} uncovered region(s)")

if __name__ == "__main__":
    main()
