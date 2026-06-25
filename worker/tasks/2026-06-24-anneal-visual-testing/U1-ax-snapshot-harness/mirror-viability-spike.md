# U1 Unit 0.5 — `Mirror`-source viability spike (complex surface)

**VERDICT: `MIRROR NOT VIABLE`.** A dependency-free `Mirror` walk of a SwiftUI `body` produces a
**deterministic-but-shallow** snapshot for trivial leaf views, but for the campaign's actual
COMPLEX, COMPOSED surfaces it is **(1) not meaningful** (it cannot see into child views' bodies, so
the rendered per-item tree — `TextField` vs `Text`, the thing a view-logic regression would flip —
is invisible) **AND (2) not deterministic across machines** (reflecting a view that holds an
`@ObservedObject model` recurses into the entire view-model object graph and leaks 25+
machine-specific absolute paths that no whitelist can reliably remove). → **ViewInspector is
NECESSARY, not merely preferable.** Surface to the operator with this evidence.

Environment: Apple Swift 6.3.2, macOS 26.5, target `arm64-apple-macosx26.0`, plain `swift test`.

Fixtures built via the REAL seam (provenance): `AgentProposalQueue(paths:).enqueue(proposal)` →
`WorkbenchViewModel(paths:).loadPendingProposals()` → `model.pendingProposals` →
`BossProposalCardList(model:).body`; sidebar via `WorkbenchStore.save(state)` →
`model.workspaceSidebarModel.rows` → `WorkspaceSidebarRow(row:model:).body`. Nothing hand-assembled.

---

## Finding 1 — DETERMINISM: byte-identical in-process, but NOT across machines (FATAL)

- Same fixture serialized twice in one process → **byte-identical** (`true`) for both the proposal
  card and the sidebar row. So *in-process* determinism holds.
- BUT the `WorkspaceSidebarRow` output leaked **25 absolute machine-specific paths**, e.g.:
  ```
  str="/Users/microsoft/AgentBundles/ouroboros.ouro/agent.json"
  str="/Users/microsoft/AgentBundles/slugger.ouro/agent.json"
  str="/Users/microsoft/Applications/Ouro Workbench.app/Contents/MacOS/OuroWorkbenchMCP"
  str="/Users/microsoft/.claude-cli/2.1.187/clau…"
  ```
- **Root cause:** the view holds `@ObservedObject var model: WorkbenchViewModel` as a STORED
  property. `Mirror(reflecting: view.body)` recurses through that stored reference into the ENTIRE
  view-model object graph — every cached agent-bundle scan, discovered binary path, and
  environment-derived string the VM has loaded. These differ per machine / per install / per run,
  so the committed reference would never match on CI or another machine.
- **Why a whitelist can't save it:** the model graph is unbounded and its machine-specific strings
  are intermixed, at arbitrary depth, with the legitimate rendered content (`"Pinned WS"`). There
  is no stable structural boundary to whitelist on ("stop at `@ObservedObject`" is exactly the
  boundary SwiftUI doesn't expose to `Mirror`). This is the campaign's **P3 + L4** wall.

## Finding 2 — MEANINGFULNESS: shallow; composed child views are OPAQUE (FATAL)

`Mirror` reflects ONE view's `body` plus any **stored data**, but it does **NOT invoke child views'
`body`**. So:

- For `WorkspaceSidebarRow` (whose `body` directly builds `Image`/`Text`/`Button`), Mirror reaches
  real content: `Image name="pin.fill"`, `Text "Pinned WS"`, the help `Image "bolt.fill"` + `Text
  "Active"`. **Meaningful** — for a view that inlines its primitives.
- For `BossProposalCard` → `BossProposalItemRow` (the real complex surface: a `ForEach` of composed
  subviews), Mirror stops at `<BossProposalCard>` as an **opaque leaf with no children** — the
  per-item rendered tree (the `TextField` for editable fields vs `Text` for static) **never
  appears.** Sample (editable state):
  ```
  <VStack>
    <ForEach>
      <AgentProposal>
        str="spike-proposal-1"
        str="Deploy the substrate"
        <AgentProposalItem>
          str="item-A"
          str="Run migration"
          str="Apply schema v3"
          str="swift run migrate --to v3"
          str="/repo"
          <Bool>          ← item.selected
          <Field><Field><Field><Field>   ← item.editableFields (4 = all editable)
        <AgentProposalItem> … item-B …
      <BossProposalCard>   ← OPAQUE: its body (the TextFields/Texts) is NEVER expanded
  ```
  Static state (`editableFields: []`) differs ONLY by the absence of the four `<Field>` entries:
  ```
        <AgentProposalItem>
          str="item-A" … str="/repo"
          <Bool>          ← (no <Field> entries → not editable)
  ```
- **The editable-vs-static diff survived ONLY because `editableFields` is STORED DATA** in the
  `ForEach`'s source array — NOT because Mirror saw the rendered `TextField` vs `Text`. So the
  snapshot reflects the *model*, not the *view*. It would **NOT catch a view-logic regression** —
  if `BossProposalItemRow.isEditable()` were inverted (editable→static rendering bug) the model
  data is unchanged, so the Mirror snapshot is **byte-identical** and the regression passes
  silently. That defeats the entire point of a *view* snapshot (campaign P4 + P2 negative-control).
- To capture composed surfaces you'd have to manually invoke each subview's `.body` recursively —
  i.e. hand-reimplement SwiftUI's view-tree evaluation (resolving `if`/`ForEach`/environment
  conditionals, `@State`/`@ObservedObject` reads, `ViewBuilder` results) without the runtime. Not
  feasible to do completely or stably.

## Finding 3 — ROBUSTNESS: depends on undocumented SwiftUI internals (FRAGILE)

The walk's structural tokens are pure SwiftUI internal type/field names with no API stability
guarantee: `Tree`, `_VStackLayout`, `Storage`, `ImageProviderBox`, `NamedImageProvider`,
`AccessibilityImageLabel`, `_ForegroundStyleModifier`, `_EnvironmentKeyWritingModifier`,
`PrimitiveButtonStyleContainerModifier`, `HelpView`. The `Image` name extraction relies on parsing
`NamedImageProvider`'s reflected description. An Xcode/SwiftUI bump can rename or restructure any of
these, silently changing every committed reference (a mass-diff with no source change — the opposite
of a trustworthy gate). ViewInspector exists precisely to insulate callers from this churn.

## Why ViewInspector clears all three

ViewInspector walks SwiftUI's view tree through a maintained, version-tracked introspection layer
that (a) **invokes child bodies** so composed surfaces (`BossProposalItemRow`'s `TextField`/`Text`)
are visible — meaningful + a real negative control; (b) extracts *declared* content
(`text()`, `accessibilityLabel()`, image names) rather than dumping the whole stored object graph —
so no VM-graph path leaks (deterministic across machines); (c) absorbs SwiftUI-internal renames in
the library, not in our committed references — robust across toolchains. It is a NEW PACKAGE
DEPENDENCY (the U1 "no new dep" criterion), which is why this is an **operator decision**, not a
silent adoption.

## Spike status

- Throwaway spike (`MirrorViabilitySpikeScratch.swift`): **removed** before any commit (no impl
  committed). Findings + samples captured here.
- No `Package.swift` change; allowlist + `COVERAGE_DIRS` untouched; `SerpentGuide.ouro/` never staged.
- **Recommendation to the coordinator/operator:** `MIRROR NOT VIABLE` → adopt ViewInspector
  (relax the "no new dependency" guard for this campaign) OR re-scope the campaign's snapshot target
  away from full *view*-tree fidelity toward model/presentation-layer snapshots (e.g. snapshot
  `WorkspaceSidebarPresentation.resolve(...).rows` and `AgentProposal`/`model.pendingProposals`
  projections — pure value types, already deterministic and provenance-built — which sidesteps the
  SwiftUI AX/Mirror wall entirely, at the cost of not asserting the *rendered* view). The latter is
  dependency-free and may satisfy much of P2/P3 if the operator accepts presentation-model snapshots
  in place of view-tree snapshots.
