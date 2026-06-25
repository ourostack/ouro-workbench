# U1 Unit 0 — AX-walk reality-check spike (GO/NO-GO)

**Verdict: NO-GO for the serialization source as specified.** Hosting a SwiftUI view in
`NSHostingView` inside a **headless `xctest` process** yields an **EMPTY AppKit accessibility
tree** (`accessibilityChildren()` == `[]`, zero NSView subviews). This is the F-2 "one true
feasibility wall" the doing doc flagged. The doc directs: *"If NONE expose a readable tree, STOP
and surface to the operator — do not fake a tree."* — so U1 is **STOPPED pending an operator
decision on a different serialization source.**

The harness MECHANISM (host → walk → serialize → compare) is sound and was proven against raw
AppKit (see Control below). The wall is specifically **SwiftUI's AppKit AX surface being unpopulated
in-process.** This is a *source* problem, not a harness-architecture problem.

---

## Environment

- Toolchain: Apple Swift 6.3.2 (swiftlang-6.3.2.1.108), swift-driver 1.148.6
- Target triple: `arm64-apple-macosx26.0`
- OS: macOS 26.5 (build 25F71)
- Test host: `swift test` → `OuroWorkbenchPackageTests.xctest` (un-bundled `xctest` process,
  i.e. NOT a registered `.app`).

## What was tried (7 approaches, all empty for the SwiftUI host)

The probe hosted `DashboardRowLabel(title: "SPIKE-TITLE-XYZZY", …)` under forced
`en_US_POSIX`/UTC and tried, in order:

| # | Approach | Result |
|---|----------|--------|
| A | bare `NSHostingView`, `layoutSubtreeIfNeeded()` on a fixed frame | `role=AXGroup`, **0 children** |
| B | `NSHostingController.view` inside a borderless `NSWindow`, `layoutIfNeeded()` | `role=AXGroup`, **0 children** |
| B' | walk the `NSWindow` AX root | `NSWindow` is not the method-form AX surface (non-AX in walker); n/a |
| C | `NSAccessibility.unignoredDescendant(of: controller.view)` | returns the host itself, **0 children** |
| D | `controller.view.accessibilityChildren()` | **count = 0** |
| E | real `NSApplication` (`.accessory` + `activate`), **key titled window**, bigger frame (400×200), `RunLoop.run(until: +0.3s)` | `role=AXGroup`, **0 children**; raw NSView subview tree = host only (no subviews) |
| F | `AXUIElement` C-API (`AXUIElementCreateApplication(pid)`) walk over the process | application element returns `role=?`, **no children** (xctest is not a served `.app`) |
| G | force `display()`/`displayIfNeeded()` on host + window, re-read `accessibilityChildren()` (host AND `window.contentView`) | **count = 0** both |

`NSWorkspace.shared.isVoiceOverEnabled == false`; `AXIsProcessTrusted() == true` (the test runner
is trusted, but that only governs *querying other apps*, not serving this process's own SwiftUI tree).

## Control — the harness mechanism IS sound (raw AppKit walks correctly)

Hosting a **raw AppKit `NSView` containing an `NSButton`** (`setAccessibilityLabel("RAW-APPKIT-LABEL")`)
and walking `accessibilityChildren()`:

```
role=AXUnknown label=<nil> value=<nil> id= [kids=1 type=NSView]
  <NSButtonCell>   ← child present
```

→ The `NSView` correctly reports **1 child** (its `NSButtonCell`). So the walk/serialize mechanism
works for AppKit; only the SwiftUI host produces nothing. (Side note for any future adapter: AppKit
AX children can be plain `NSObject`/`NSCell` conforming to the `NSAccessibility` informal protocol —
the property form `accessibilityLabel` — not just `NSView`/`NSAccessibilityElement` method-form;
an adapter would need to handle both. Moot under the current verdict.)

## Root cause (why this is a wall, not a bug)

Modern SwiftUI does **not** build an in-process AppKit accessibility child tree. `NSHostingView`
renders into a single layer-backed host (0 NSView subviews) and serves its accessibility tree
**out-of-process via the remote-AX server**, which only materializes when a real assistive client
(VoiceOver / Accessibility Inspector) connects to a **properly bundled `.app`**. A headless `xctest`
process — the harness's specified home (D-U1-1) — has no such client and is not a registered app,
so the SwiftUI AX tree never instantiates. This is not fixable by frame size, layout, key-window,
activation policy, runloop spinning, `display()`, or the `AXUIElement` C-API (all tried).

## F-1 packaging fix — VERIFIED (independent of the wall; keep it)

- BEFORE `exclude:`: dropping `__Snapshots__/_probe.txt` under the test target → SwiftPM emits
  `warning: 'ouro-workbench': found 1 file(s) which are unhandled … __Snapshots__/_probe.txt`.
  Confirmed it is a **build-PLAN warning, build exits 0** (NOT promoted by `-warnings-as-errors`).
- AFTER adding `exclude: ["__Snapshots__"]` to the `OuroWorkbenchAppViewsTests` test target in
  `Package.swift`: the warning is **GONE** (`grep -c unhandled` → 0), build still exits 0.
- This touches no `dependencies`, no `COVERAGE_DIRS`, no allowlist (D-U1-2 holds). Correct and
  reversible regardless of the serialization-source decision.

## 2nd proof view — construction confirmed (but un-walkable for the same reason)

`SidebarWorkspaceEmptyRow()` constructs `@testable` across the module boundary (it is `internal`,
VM-free, zero-stored-prop, explicit `.accessibilityLabel("No tabs yet")`, no `TimelineView`). It
hosts fine but its SwiftUI AX tree is **equally empty** (same wall) — so it cannot serve as a proof
under the AppKit-AX-walk source either.

## Recommended pivots (operator decision — the campaign "different serialization source")

The brief anticipated this: *"the campaign may need a different serialization source."* Ranked:

1. **ViewInspector / SwiftUI-introspection source** (currently an explicit U1 anti-scope-creep
   guard — "no ViewInspector"). It walks SwiftUI's *own* view tree in-process (no AppKit AX server
   needed), and can read `.accessibilityLabel`/`.accessibilityIdentifier`/`Text` content. This is
   the standard way the Swift community structurally snapshots SwiftUI in unit tests. **Cost:** adds
   a package dependency (violates the current "no new dependency" criterion) and changes the
   "serialize the AX tree" framing to "serialize the SwiftUI view tree." Highest-confidence GO.
2. **`Mirror`-based SwiftUI body reflection** (no dependency; the importability test already uses
   `Mirror`). Walks `body`'s `ModifiedContent`/`Text` structure reflectively. **Cost:** brittle to
   SwiftUI internal layout types; not a true *accessibility* tree (P4a/P4b semantics weaken). Lower
   confidence; dependency-free.
3. **Bundle the harness as a real `.app` UI-test target** so the remote-AX server serves the tree
   (XCUITest-style). **Cost:** large — needs an `.xcodeproj`/app bundle + on-device AX; contradicts
   D-U1-1 (test-target home) and the SwiftPM-only setup. Heaviest.
4. **Render-to-image + OCR/pixel** — explicitly rejected by the campaign (P4a "no pixels in the
   gate"). Not recommended.

**My recommendation:** option **1 (ViewInspector)** if the operator will relax the "no new
dependency" guard for the campaign — it's the only path that keeps a genuine *accessibility*-shaped,
deterministic, structured-text snapshot in a plain `swift test`. Otherwise option **2** as the
dependency-free fallback, accepting weaker AX semantics. Either way the doc's harness *shape*
(serializer + host + `__Snapshots__` store + `assertAXSnapshot`) and the F-1 packaging fix are
reusable; only the **node source** swaps from AppKit-AX to SwiftUI-introspection.

### Option-2 viability — VERIFIED in-process (dependency-free)

I probed the `Mirror`-reflection source (no dependency; the importability test already uses
`Mirror` to reach `body`). Reflecting each proof view's `body` recursively and collecting non-empty
`String` leaves:

```
SidebarWorkspaceEmptyRow.body → ["No tabs yet", "No tabs yet"]   (Text content + .accessibilityLabel)
DashboardRowLabel.body        → ["Workbench MCP", "infinity", "infinity"]  (title + systemImage)
```

→ **The rendered/declared text content IS reachable in-process with zero dependency**, for both a
`Text`-based view AND a `Label(_:systemImage:)`-based view. So **option 2 is a confirmed GO** and it
keeps the "no new package dependency" criterion intact.

**The honest caveat (why this still needs an operator call, not a silent swap):** a `Mirror` walk of
`body` is **NOT an accessibility tree** — there are no AX *roles*, and the field model is SwiftUI's
internal `ModifiedContent`/`Text.Storage`/`LabelStyle` shapes, not `role/label/value/identifier`.
That changes the campaign rubric's framing:
- **P4a/P4b** ("role/label/value/id/children", "AX structure") would need to be re-specified as
  "SwiftUI declared-structure" (text leaves + modifier chain), or narrowed to "the accessibility
  *labels/identifiers* declared on the view" (which a Mirror walk can find — `.accessibilityLabel`
  surfaced above) rather than a full AX role tree.
- **P3 determinism** is *easier* here (pure value reflection, no layout/AX-server nondeterminism).
- The `ModifiedContent` reflection is **moderately version-fragile** (SwiftUI internal type names);
  a normalization/whitelist layer in the serializer (already planned, L5) mitigates but the doer
  must pin the observed shapes per toolchain.

This is a **material change to the serialization source the doc + campaign rubric are written
around** — which is precisely the "STOP and surface" trigger. I am stopping here with a *verified*
path forward rather than unilaterally re-scoping the campaign's P4 definition.

## Status

- `exclude: ["__Snapshots__"]` packaging fix: **applied + verified** (keep).
- Scratch spike (`AXWalkSpikeScratch.swift`) + probe (`__Snapshots__/_probe.txt`): **removed** after
  capturing findings here (per Unit 0 "Scratch spike removed before commit").
- Units 1–5: **NOT started** — blocked on the serialization-source decision above.
