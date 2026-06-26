#!/usr/bin/env python3
"""Attribute pre-VM uncovered region segments to the enclosing top-level View/decl.

Reads two stdin-less inputs via argv:
  argv[1] = path to llvm-cov export JSON (full) for the views file
  argv[2] = path to a 'decls.txt' listing '<startline>:<name>' for each top-level
            decl (col-0 struct/class/enum/extension), produced by a grep.

Buckets uncovered region-entry segments (count==0) in line range [167, vm_start)
by which top-level decl they fall in, prints the top offenders.
"""
import json
import sys

VM_START = 10607

cov_path = sys.argv[1]
decls_path = sys.argv[2]

with open(cov_path) as fh:
    data = json.load(fh)
f = data["data"][0]["files"][0]
seg = f["segments"]

# Build ordered decl boundaries.
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
    # last decl whose start <= line
    lo, hi, ans = 0, len(decls) - 1, ("<prologue>", 0)
    name = "<prologue>"
    start = 0
    for s, n in decls:
        if s <= line:
            name, start = n, s
        else:
            break
    return name

from collections import Counter
c = Counter()
for s in seg:
    line, col, count, has_count, is_region_entry = s[0], s[1], s[2], s[3], s[4]
    if not (is_region_entry and has_count and count == 0):
        continue
    if 167 <= line < VM_START:
        c[owner(line)] += 1

print("Top pre-VM views by uncovered region-entry segments:")
print("(>=3 uncovered region entries; these are where the per-file-100% gap lives)")
tot = 0
for name, n in c.most_common():
    tot += n
    if n >= 3:
        print("  %-44s %d" % (name, n))
print()
print("decls with >=1 uncovered region entry: %d" % len(c))
print("total pre-VM uncovered region entries:  %d" % sum(c.values()))
