# U5 PR#1 — WorkbenchViewModel extract plan (from first-hand structural read @ 687b6c7)

## VM extent
- `@MainActor public final class WorkbenchViewModel: ObservableObject {` opens at **line 10607**.
- Closing `}` at column 0 at **line 20716**. One contiguous block, **10,110 lines**. No interleaving.

## File breakdown
| Region | lines | contents |
|---|---|---|
| View structs + helpers | 167–10606 (10,440) | 121 views, private view helpers, styling extensions |
| WorkbenchViewModel | 10607–20716 (10,110) | single @MainActor class, 300+ members |
| post-VM terminal types | 20717–21444 (728) | TerminalPane, TerminalHostView, TerminalSessionController, CapturingLocalProcessTerminalView, palette/theme enums, extensions |

## private→internal promotions (N = 3)
Defined in the VIEW section, referenced INSIDE the VM body → the split breaks same-file access:
| line | symbol | kind | VM uses | fix |
|---|---|---|---|---|
| 104 | `ProviderCheckProcessResult` | private struct | 2 refs | promote `private`→`internal` |
| 5833 | `BossQuickQuestion` | private struct | 6 refs | promote `private`→`internal` |
| 5839 | `bossQuickQuestions` | private let | 1+ ref | promote `private`→`internal` |

9 `private extension` blocks (1621, 1667, 1683, 3561, 3574, 4906, 4961, 4985, 5002) are view-section-only
→ NO promotion needed (do NOT widen them; keep the surface minimal).

**The doer MUST re-verify N at execution** (a fresh compiler error is the ground truth: build the split,
let the compiler name every broken access, promote exactly those — no more). N=3 is the read-estimate.

## Move-set (what goes into the new WorkbenchViewModel.swift)
**MOVE with the VM (behavioral terminal lifecycle the VM orchestrates):**
- `MailboxFetchResult` (private struct, ~20718) — used by VM's `fetchResult<T>` generic.
- `SingleShotContinuation` (private class, ~21107) — used by TerminalSessionController only.
- `TerminalSessionController` (@MainActor final class, ~21125) — calls `WorkbenchViewModel.spawnScreenQuit()`; tight VM coupling.
- `CapturingLocalProcessTerminalView` (final class, ~21357) — subclass used by TerminalSessionController.

**STAYS in the views file (UI / config):** per the Explore read —
- `TerminalPane` (NSViewRepresentable, ~20908), `TerminalHostView` (NSView, ~20922),
  `WorkbenchTerminalPalette` (enum, ~20767), `TerminalThemeOverride` (enum, ~20733).

> **FORK on TerminalPane/TerminalHostView (see Decision D3, REVISED):** these are live-PTY/AppKit UI that
> the campaign already treats as `@main`-allowlisted (categorically uncoverable). If they STAY in the
> gated views file they need allowlist carves. The cleaner gate is to move them into the NON-gated
> WorkbenchViewModel.swift WITH the terminal machinery (D3 default), so the gated views file contains ZERO
> categorically-uncoverable AppKit-representable code. The Explore read's "stays in views" is a
> code-organization preference; the GATE preference is the opposite. Doer resolves at exec, records which.
> Either way: NO guard retarget is triggered if TerminalSessionController + CapturingLocalProcessTerminalView
> stay paired (their sourceSlice from/to markers stay adjacent in the same file).

## Guard-slice retargets (M = 0 expected)
Both observed cross-declaration `sourceSlice` pairs stay WITHIN one file after the split:
- `CheckpointPromptDeliveryWiringTests`: `from: "final class TerminalSessionController"` →
  `to: "\nfinal class CapturingLocalProcessTerminalView"` — both move together → adjacency preserved.
- `ReadinessStalenessRefreshWiringTests`: `from: "struct WorkbenchRootView: View {"` →
  `to: "\nfinal class WorkbenchMenuBarController"` — both stay in the views file (pre-VM) → preserved.
- **No `sourceSlice` pair straddles the VM boundary** (verified: no marker is inside the VM body that is
  paired with a marker outside it). M = 0 retargets. The doer RE-VERIFIES by grepping every `sourceSlice`
  from/to marker against the post-split file boundaries before declaring M.

## appSource()/orderedLibFiles update
Insert the two files into `WorkbenchAppSource.orderedLibFiles` in DECLARATION order. Today the list has
`WorkbenchViewsAndModel.swift` first. After the split, declaration order is: the VIEW structs begin at old
line 167 (before the VM @ 10607). So in the union the views file still leads; `WorkbenchViewModel.swift`
slots AFTER the views file's pre-VM decls but its content is one contiguous block — since the union concat
is per-FILE (whole file appended), the ordering that matters is: any cross-file slice must not invert.
Because M=0 (no slice straddles the boundary), the simplest correct ordering is:
`["WorkbenchViews.swift", "WorkbenchViewModel.swift", "Views/DashboardRowLabel.swift",
"WorkbenchUpdateInstaller.swift", "WorkbenchKeyboardAccessibilityContract.swift"]`
(rename `WorkbenchViewsAndModel.swift`→`WorkbenchViews.swift`). `assertEveryLibFileIsOrdered()` forces the
new file to be listed. The doer confirms the full guard suite + `assertEveryLibFileIsOrdered` green.

## Proof-of-pure-move
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green.
- Full `swift test` 0-fail (3426 tests today) — same count after the move.
- `git diff` shows only: file creation, the rename, the ≤3 access-widen edits, the orderedLibFiles edit.
- A normalized-content check (sort+diff of the moved block) shows byte-identical relocation.
