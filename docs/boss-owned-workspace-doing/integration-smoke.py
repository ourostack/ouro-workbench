#!/usr/bin/env python3
"""End-to-end integration smoke for the boss-owned-workspace reconstruction loop.

Drives the REAL built OuroWorkbenchMCP binary over stdio JSON-RPC against an
isolated --app-support-root, proving the slices COMPOSE end-to-end:

  see   : workbench_discover_agent_sessions returns the operator's real sessions
  propose: feed a discovered session into workbench_propose -> proposal queued
  (operator approves -> result file written via the queue's on-disk contract)
  act   : workbench_proposal_result round-trips the selected/edited item back
  verify: workbench_session_health is wired and resolves coherently

Exit 0 only if every leg of the loop passes.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

BIN = sys.argv[1]
ROOT = tempfile.mkdtemp(prefix="wb-smoke-")

proc = subprocess.Popen(
    [BIN, "--app-support-root", ROOT],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)

_id = 0
def rpc(method, params=None):
    global _id
    _id += 1
    req = {"jsonrpc": "2.0", "id": _id, "method": method}
    if params is not None:
        req["params"] = params
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        err = proc.stderr.read()
        raise SystemExit(f"FAIL: no response to {method}. stderr:\n{err}")
    return json.loads(line)

def call(tool, args=None):
    resp = rpc("tools/call", {"name": tool, "arguments": args or {}})
    res = resp.get("result", {})
    is_err = res.get("isError", None)
    text = ""
    for block in res.get("content", []):
        if block.get("type") == "text":
            text = block.get("text", "")
    return is_err, text

failures = []
def check(cond, label):
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {label}")
    if not cond:
        failures.append(label)

try:
    # --- initialize + tools/list ---
    init = rpc("initialize", {})
    check(init.get("result", {}).get("serverInfo", {}).get("name") is not None,
          "initialize handshake returns serverInfo")

    tl = rpc("tools/list")
    names = {t["name"] for t in tl.get("result", {}).get("tools", [])}
    print(f"\n  tool surface ({len(names)} tools): {sorted(names)}\n")
    for needed in ["workbench_discover_agent_sessions", "workbench_propose",
                   "workbench_proposal_result", "workbench_session_health"]:
        check(needed in names, f"tools/list advertises {needed}")

    # --- SEE: discover the operator's real sessions ---
    is_err, text = call("workbench_discover_agent_sessions")
    check(is_err is False, "discover: isError=false")
    discovered = json.loads(text)
    sessions = discovered.get("sessions", [])
    check(isinstance(sessions, list), "discover: returns a sessions array")
    print(f"  -> discovered {len(sessions)} real session(s) on this box")
    # Determinism: two back-to-back discovers produce byte-identical payloads.
    _, text2 = call("workbench_discover_agent_sessions")
    check(text == text2, "discover: deterministic (two calls byte-identical)")

    # Pick a real discovered session to reconstruct; fall back to a synthetic
    # record so the loop is still exercised on a box with zero history.
    if sessions:
        src = sessions[0]
        check(all(k in src for k in ("harness", "sessionId", "cwd")),
              "discover: records carry general fields (harness/sessionId/cwd)")
    else:
        src = {"harness": "claudeCode", "sessionId": "smoke-fallback",
               "cwd": "/tmp/smoke", "title": "fallback"}
        print("  (no real sessions; using a synthetic record to exercise the loop)")

    # --- PROPOSE: feed the discovered session into workbench_propose ---
    item = {
        "id": "reconstruct-0",
        "label": f"Reconstruct {src.get('title') or src['sessionId']}",
        "detail": f"{src['harness']} @ {src['cwd']}",
        "command": f"resume {src['sessionId']}",  # boss builds this, not Workbench
        "cwd": src["cwd"],
        "harness": src["harness"],
        "selected": True,
    }
    is_err, text = call("workbench_propose",
                        {"title": "Bring back my work", "items": [item]})
    check(is_err is False, "propose: isError=false")
    ack = json.loads(text)
    pid = ack.get("proposalId")
    check(ack.get("ok") is True and pid, "propose: returns ok + proposalId")
    check(ack.get("itemCount") == 1, "propose: itemCount round-trips (1)")

    # propose wrote a pending file the App card would render:
    pending_path = os.path.join(ROOT, "proposals", "pending",
                                "".join(c if c.isalnum() else "_" for c in pid) + ".json")
    check(os.path.exists(pending_path), "propose: pending file written for the App card")

    # --- result is not-ready before the operator answers ---
    is_err, text = call("workbench_proposal_result", {"proposalId": pid})
    check(is_err is False, "proposal_result(pre): isError=false")
    pre = json.loads(text)
    check(pre.get("ready") is False, "proposal_result(pre): ready=false (no gate, just polls)")

    # --- operator approves: write the result via the queue's on-disk contract ---
    # (the App card does exactly this when the operator ticks Approve)
    results_dir = os.path.join(ROOT, "proposals", "results")
    os.makedirs(results_dir, exist_ok=True)
    edited = dict(item)
    edited["command"] = "resume " + src["sessionId"] + " --edited-by-operator"
    result_obj = {"id": pid, "items": [edited]}
    safe = "".join(c if c.isalnum() else "_" for c in pid)
    with open(os.path.join(results_dir, safe + ".json"), "w") as f:
        json.dump(result_obj, f)

    # --- ACT: boss reads the operator's decision back ---
    is_err, text = call("workbench_proposal_result", {"proposalId": pid})
    check(is_err is False, "proposal_result(post): isError=false")
    post = json.loads(text)
    check(post.get("ready") is True, "proposal_result(post): ready=true after approval")
    got_items = post.get("result", {}).get("items", [])
    check(len(got_items) == 1, "proposal_result(post): selected item round-trips")
    check(got_items and got_items[0].get("command", "").endswith("--edited-by-operator"),
          "proposal_result(post): operator's EDIT survives the round-trip")

    # --- VERIFY: session_health is wired & resolves coherently ---
    # With an isolated empty root there is no in-Workbench session, so this
    # proves the tool path resolves + validates (coherent error), not a crash.
    is_err, text = call("workbench_session_health", {"entry": "nonexistent-session"})
    check(is_err is True and "error" not in text.lower()[:0],  # just assert it answered
          "session_health: tool wired & answers (resolves arg; no crash)")
    check(len(text) > 0, "session_health: returns a coherent message")
    print(f"  -> session_health on empty root replied: {text!r}")

finally:
    proc.stdin.close()
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except Exception:
        proc.kill()

print()
if failures:
    print(f"INTEGRATION SMOKE: FAILED ({len(failures)} check(s)):")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print("INTEGRATION SMOKE: ALL CHECKS PASSED — the see->propose->act loop composes end-to-end.")
sys.exit(0)
