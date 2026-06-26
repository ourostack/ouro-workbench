#!/usr/bin/env python3
"""Partition the views-file uncovered REGIONS into pre-VM views / VM body / post-VM terminal.

Reads `llvm-cov export <bin> -instr-profile <prof> <viewsfile>` JSON (full, not
-summary-only) on stdin. Uses caller-supplied VM body range [vm_start, vm_end]
and the post-VM terminal start line to bucket uncovered region entries.

Usage: ... | split-residual-probe.py <vm_start> <vm_end> <postvm_start>
"""
import json
import sys

vm_start = int(sys.argv[1])
vm_end = int(sys.argv[2])
postvm_start = int(sys.argv[3])

data = json.load(sys.stdin)
f = data["data"][0]["files"][0]
seg = f.get("segments", [])

pre_vm = vm = post_vm = 0
for s in seg:
    line, col, count, has_count, is_region_entry = s[0], s[1], s[2], s[3], s[4]
    if not (is_region_entry and has_count and count == 0):
        continue
    if line < vm_start:
        pre_vm += 1
    elif line <= vm_end:
        vm += 1
    elif line < postvm_start:
        # gap between vm_end and postvm_start (helpers right after VM close)
        post_vm += 1
    else:
        post_vm += 1

summ = f["summary"]
print("=== gate metric (summary, authoritative for the per-file gate) ===")
print("lines:   %d/%d covered  -> %d uncovered  (%.1f%%)" % (
    summ["lines"]["covered"], summ["lines"]["count"],
    summ["lines"]["count"] - summ["lines"]["covered"], summ["lines"]["percent"]))
print("regions: %d/%d covered  -> %d uncovered  (%.1f%%)" % (
    summ["regions"]["covered"], summ["regions"]["count"],
    summ["regions"]["count"] - summ["regions"]["covered"], summ["regions"]["percent"]))
print()
print("=== raw uncovered region-entry SEGMENTS partitioned by line range ===")
print("(segments != summary-region-count exactly, but show WHERE the gaps cluster)")
print("pre-VM views  (167 - %d):       %d uncovered region entries" % (vm_start - 1, pre_vm))
print("VM body       (%d - %d):  %d uncovered region entries" % (vm_start, vm_end, vm))
print("post-VM       (%d+):          %d uncovered region entries" % (postvm_start, post_vm))
print("(post-VM = TerminalPane/HostView/SessionController/Capturing + palette/theme)")
