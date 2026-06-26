# U5 B4 — terminal-sheets carve records (for Unit 3 allowlist)

Each entry = a genuinely-unreachable region left after B4 drove the reachable body.
These are NOT padding — every one is an in-view-closure-only / `@State`-no-init-seam /
live-PTY / modal-`NSOpenPanel` region that no render seam executes. The driven body
regions (the asserting + mutation-verified snapshots) are committed per-view.

Carve kind legend:
- **button-action** — a `Button { … }` ACTION closure; ViewInspector descends `label:`
  (rendered) but never invokes the action. No synchronous render seam taps the button.
- **helper-closure** — a `private func` reached ONLY from a button-action closure
  (`save()`, `create()`, `chooseWorkingDirectory()`, `chooseRootPath()`); same un-driven.
- **onChange** — a `.onChange(of:)` closure; not invoked by a render pass.
- **modal-NSOpenPanel** — `NSOpenPanel().runModal()`; categorically untestable in-process
  (blocks on a live GUI modal).
- **live-PTY** — `TerminalPane(session:)` / `TerminalSessionController` — the AppKit
  `NSViewRepresentable` live-pseudoterminal path (the D3-class carve).

> Measurement basis: `xcrun llvm-cov export … WorkbenchViews.swift` segments with
> `isRegionEntry && hasCount && count==0`, scoped to each view's decl line range, AFTER
> the full suite ran with the B4 tests in place.

---

## EditTerminalSessionSheet (L10192–10298) — 22 → 11 driven, 11 carved

Driven (asserting refs `EditTerminalSessionSheet.customDraft` / `.fallbackDraft`,
mutation-verified RED→GREEN on the "Edit Terminal" title): both `init` arms
(custom-session draft seam AND non-custom fallback draft), the full form body
(title + Name/Command/Working-Directory captured `TextField` values + Choose/Trusted/
Auto Resume/Notes/Cancel/Save labels).

Carved (11 regions):
| line:col | region | carve kind |
|---|---|---|
| L10233:28 | Choose button action `{ chooseWorkingDirectory() }` | button-action |
| L10245:34 | Cancel button action `{ dismiss() }` | button-action |
| L10249:24 | Save button action `{ save() }` | button-action |
| L10273:25 | `private func save()` entry | helper-closure |
| L10278:30, :41 | `save()` `trusted ? .trusted : .untrusted` ternary arms | helper-closure |
| L10282:67 | `save()` `guard model.updateCustomSession(...) else` | helper-closure |
| L10284:10 | `save()` `dismiss()` | helper-closure |
| L10288:43 | `private func chooseWorkingDirectory()` entry | modal-NSOpenPanel |
| L10294:12, :57 | `chooseWorkingDirectory()` `if panel.runModal() == .OK, let url` | modal-NSOpenPanel |

---

## NewTerminalGroupSheet (L9948–10014) — 20 → 7 driven, 13 carved

NO `init` seam (the `@State` `rootPath` defaults to the machine home — masked to
`<HOME>` in the committed reference so it is leak-free + deterministic). Driven
(asserting ref `NewTerminalGroupSheet.form`, mutation-verified RED→GREEN on the
"Choose" label): the full form body (title + empty Name field + masked Root-Path +
Choose/Cancel/Create labels + folder/checkmark glyphs).

Carved (13 regions):
| line:col | region | carve kind |
|---|---|---|
| L9951:31 | `@State private var name = ""` default autoclosure | @State-no-init-seam |
| L9952:35 | `@State private var rootPath = …home…` default autoclosure | @State-no-init-seam |
| L9969:49 | `.onChange(of: rootPath)` closure entry | onChange |
| L9970:129 | `if let autofilled = …autofilledName(...)` inside onChange | onChange |
| L9974:28 | Choose button action `{ chooseRootPath() }` | button-action |
| L9983:34 | Cancel button action `{ dismiss() }` | button-action |
| L9987:24 | Create button action `{ … }` | button-action |
| L9988:82 | Create `guard model.createGroup(...) else` | button-action |
| L9990:22 | Create `dismiss()` | button-action |
| L9997:91 | `.disabled(... \|\| rootPath.…isEmpty)` 2nd operand (name=="" short-circuits; no seam sets name) | @State-no-init-seam |
| L10004:35 | `private func chooseRootPath()` entry | modal-NSOpenPanel |
| L10010:12, :57 | `chooseRootPath()` `if panel.runModal() == .OK, let url` | modal-NSOpenPanel |

---

## EditTerminalGroupSheet (L10016–10079) — 17 → 9 driven, 8 carved

HAS `init(model:project:)` seeding `@State` from the project (FIXED `/tmp/u4` rootPath
→ no path leak). Driven (asserting ref `EditTerminalGroupSheet.seeded`, mutation-
verified RED→GREEN on the "Save" label): the init + full form body (title + project-
seeded Name/Root-Path captured TextField values + Choose/Cancel/Save labels + glyphs).

Carved (8 regions):
| line:col | region | carve kind |
|---|---|---|
| L10039:28 | Choose button action `{ chooseRootPath() }` | button-action |
| L10048:34 | Cancel button action `{ dismiss() }` | button-action |
| L10052:24 | Save button action `{ … }` | button-action |
| L10053:91 | Save `guard model.renameGroup(...) else` | button-action |
| L10055:22 | Save `dismiss()` | button-action |
| L10069:35 | `private func chooseRootPath()` entry | modal-NSOpenPanel |
| L10075:12, :57 | `chooseRootPath()` `if panel.runModal() == .OK, let url` | modal-NSOpenPanel |

---

## NewTerminalSessionSheet (L10081–10190) — 17 carved (0 NEW llvm regions, but the fallback VALUE-FLOW is now driven + asserted)

Pre-existing test (`NewTerminalSessionSheetTests`, C11-6) already drove the WITH-project
init arm. B4 ADDS the NO-project init arm (`?? home` fallback) — the masked ref
`NewTerminalSessionSheet.noProjectHome` proves the fallback VALUE reaches the
Working-Directory field (rendered `<HOME>`), mutation-verified (RED→GREEN on the
"Create & Launch" label). NOTE the llvm-cov count did NOT drop: the single region the
fallback would colour (L10093 `?? FileManager…home`) is a `??`-RHS autoclosure inside
`State(initialValue:)` whose region-entry counter llvm-cov does NOT increment even
though it executes (proven: the value renders). So the value-flow is genuinely driven
and asserted; the metric simply can't see this one region.

Carved (17 regions):
| line:col | region | carve kind |
|---|---|---|
| L10093:84 | init `?? FileManager…home` RHS autoclosure | llvm-cov-autoclosure-artifact (DRIVEN: value renders as `<HOME>`, counter not incremented) |
| L10104:44 | `.onChange(of: command)` closure entry | onChange |
| L10105:97 | onChange `guard name.…isEmpty else` | onChange |
| L10107:26 | onChange `return` | onChange |
| L10110:91 | onChange `if let parsed = …, let kind = …, let displayName = …` | onChange |
| L10117:28 | Choose button action `{ chooseWorkingDirectory() }` | button-action |
| L10129:34 | Cancel button action `{ dismiss() }` | button-action |
| L10133:24 | Create button action `{ create(launchAfterCreate: false) }` | button-action |
| L10139:24 | Create&Launch button action `{ create(launchAfterCreate: true) }` | button-action |
| L10165:50 | `private func create(launchAfterCreate:)` entry | helper-closure |
| L10170:30, :41 | `create()` `trusted ? .trusted : .untrusted` ternary arms | helper-closure |
| L10174:98 | `create()` `guard model.createCustomSession(...) != nil else` | helper-closure |
| L10176:10 | `create()` `dismiss()` | helper-closure |
| L10180:43 | `private func chooseWorkingDirectory()` entry | modal-NSOpenPanel |
| L10186:12, :57 | `chooseWorkingDirectory()` `if panel.runModal() == .OK, let url` | modal-NSOpenPanel |

---

## TerminalSearchBar (L8975–9061) — 20 → 8 driven, 12 carved

Drives BOTH arms of the conditional "No matches" badge through the VM's `@Published`
search state (`terminalSearchQuery` + `terminalSearchHasResult`). Driven (asserting
refs `TerminalSearchBar.default` / `.noMatches`, mutation-verified RED→GREEN on the
"No matches" Text): the search glyph + query-bound TextField + the conditional badge
arm + the three toggle buttons (Aa/.*/Wˌ) + chevrons + Done.

Carved (12 regions):
| line:col | region | carve kind |
|---|---|---|
| L8986:27 | `.onSubmit { … }` closure | onSubmit |
| L8989:58 | `.onChange(of: terminalSearchQuery)` closure entry | onChange |
| L8990:24, :41 | onChange `if newValue.isEmpty { … } else { … }` arms | onChange |
| L8992:28 | onChange else-arm body | onChange |
| L9010:27 | "Aa" toggle `onChange:` closure | onChange |
| L9016:27 | ".*" toggle `onChange:` closure | onChange |
| L9022:27 | "Wˌ" toggle `onChange:` closure | onChange |
| L9024:20 | chevron-up (Previous) button action | button-action |
| L9033:20 | chevron-down (Next) button action | button-action |
| L9042:28 | "Done" button action `{ model.dismissTerminalSearch() }` | button-action |
| L9058:19 | `.onAppear { fieldIsFocused = true }` closure | onAppear |

---

## TerminalFocusView (L9831–9915) — 17 → 9 driven, 8 carved

Drives the floating control-overlay chrome through the proven live-session seam (a
real `TerminalSessionController` from a real `TerminalCommandPlan`, NO `start()` → no
process, `transcriptPath: nil` → no file/path leak). Driven (asserting ref
`TerminalFocusView.controlOverlay`, mutation-verified RED→GREEN on the "Redraw" a11y
label): the entry-name title `Text(entry.name)` + the six control buttons' a11y labels
(Exit Full Screen / Redraw / Ctrl-C / Esc / EOF / Stop) + their glyphs.

Carved (8 regions):
| line:col | region | carve kind |
|---|---|---|
| L9835:26 | `private let chrome = WorkbenchSurfaceChrome.contract(for: .terminalFocus)` default-value | llvm-cov-stored-default-artifact (DRIVEN: chrome IS read by the body insets; counter not incremented) |
| L9849:24 | Exit-Full-Screen button action `{ model.exitTerminalFocus() }` | button-action |
| L9858:24 | Redraw button action `{ model.redrawTerminal(entry) }` | button-action |
| L9867:24 | Ctrl-C button action `{ model.sendControlC(to: entry) }` | button-action |
| L9875:24 | Esc button action `{ model.sendEscape(to: entry) }` | button-action |
| L9883:24 | EOF button action `{ model.sendEOF(to: entry) }` | button-action |
| L9891:44 | Stop button action `{ model.requestStop(entry) }` | button-action |
| L9910:19 | `.onAppear { session.focusInput(); session.redrawDisplayBurst(...) }` | onAppear |

> The live `TerminalPane(session:)` `NSViewRepresentable` PTY pane is descended as an
> opaque node by ViewInspector (never launched) — it contributes no capturable node and
> no countable region inside this decl's range (its own regions live in the non-gated
> `WorkbenchViewModel.swift` TerminalPane decl, the D3 carve).
