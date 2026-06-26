#!/usr/bin/env python3
"""POST-SPLIT: attribute every uncovered region segment in WorkbenchViews.swift
to its enclosing top-level decl. No VM in this file, so the whole file [12, end]
is in scope.

argv[1] = llvm-cov export JSON (full, not -summary-only) for the views file
argv[2] = decls.txt ('<startline>:<name>' per top-level decl, post-split lines)
"""
import json
import sys
from collections import Counter

cov_path = sys.argv[1]
decls_path = sys.argv[2]

with open(cov_path) as fh:
    data = json.load(fh)

# find the WorkbenchViews.swift file entry
fentry = None
for f in data["data"][0]["files"]:
    if f["filename"].endswith("WorkbenchViews.swift"):
        fentry = f
        break
if fentry is None:
    print("ERROR: WorkbenchViews.swift not in export", file=sys.stderr)
    sys.exit(1)
seg = fentry["segments"]

decls = []
with open(decls_path) as fh:
    for line in fh:
        line = line.strip()
        if not line or ":" not in line:
            continue
        ln, _, name = line.partition(":")
        try:
            decls.append((int(ln), name))
        except ValueError:
            pass
decls.sort()

def owner(line):
    name = "<prologue>"
    for s, n in decls:
        if s <= line:
            name = n
        else:
            break
    return name

c = Counter()
arms = {}  # name -> list of uncovered (line,col)
for s in seg:
    line, col, count, has_count, is_region_entry = s[0], s[1], s[2], s[3], s[4]
    if not (is_region_entry and has_count and count == 0):
        continue
    o = owner(line)
    c[o] += 1
    arms.setdefault(o, []).append((line, col))

print("POST-SPLIT WorkbenchViews.swift — uncovered region-entry segments by decl")
print("=" * 70)
tot = 0
for name, n in c.most_common():
    tot += n
print("decls with >=1 uncovered region entry: %d / %d" % (len(c), len(decls)))
print("total uncovered region-entry segments:  %d" % sum(c.values()))
print()
print("Per-decl (sorted desc):")
for name, n in c.most_common():
    lines = sorted({l for l, _ in arms[name]})
    rng = "L%d-%d" % (lines[0], lines[-1]) if lines else ""
    print("  %-40s %4d  %s" % (name, n, rng))

# Also emit the file summary as llvm-cov sees it
S = fentry["summary"]
print()
print("FILE SUMMARY (gate metric):")
print("  lines  %.1f%%  (%d uncov of %d)" % (S["lines"]["percent"], S["lines"]["count"]-S["lines"]["covered"], S["lines"]["count"]))
print("  regions %.1f%% (%d uncov of %d)" % (S["regions"]["percent"], S["regions"]["count"]-S["regions"]["covered"], S["regions"]["count"]))
