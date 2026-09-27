# Tabbed testing findings

Last updated: 2026-09-27.

This is the status record for the experimental Tabbed implementation. Update
the relevant row after each test or fix. An attempted action is not a passed
test. Use [TABBED_TESTING.md](TABBED_TESTING.md) for the manual procedure.

## Current assessment

The implementation passes automated tests and builds. Real-window behavior is
only partly verified. The inactive-tab strategy is still undecided: Tabbed
stacks inactive windows behind the selected one, and no live experiment has yet
shown that stacking keeps the right window in front across applications. That
experiment is the first remaining check below.

Divider and linked resize pacing is shared with Native and Bento and is
reviewed separately in pull request #67.

## Intended behavior

- Each desktop independently uses Native, Bento, or Tabbed.
- Tabbed panes remain visible when empty. Each pane has ordered tabs and one
  selected window.
- Initial activation uses the chosen default layout. Existing windows join the
  first pane, with the previously focused eligible window selected.
- New windows join the last-used pane and become selected.
- Adding panes preserves groups and adds empty panes. Removing panes merges
  removed groups into the nearest remaining pane. One pane collects all tabs.
- Layout changes support Undo. Returning to Tabbed restores surviving runtime
  assignments and selections. Native restores pre-entry frames; Bento arranges
  windows with its own layout.

### Minimum-width policy

- A pane's minimum width is the greatest minimum width among its tabs,
  including inactive tabs. Empty panes keep a 120-point minimum.
- Side-by-side dividers adjust to satisfy those minimums. Ratios that already
  fit are kept. A requested 50/50 split can become 40/60.
- Row ratios do not change. An operation is rejected if a minimum height cannot
  fit below the tab strip or the combined minimum widths exceed the area.
- An unreported width minimum can cause one retry after a complete rollback.
  Height refusals, stale sessions, cancellation, and degraded restoration do
  not retry.

## Findings

"Automated" means Core, fake-window, or off-screen AppKit tests. "Live" means
real applications on a real desktop.

| ID | Finding | Automated | Live |
| --- | --- | --- | --- |
| T-01 | Width conflicts rejected layouts that could fit | Fixed | Pending |
| T-02 | Tab controls reported themselves as disabled | Fixed | Passed |
| T-03 | A failed Undo discarded its history entry | Fixed | Not needed |
| T-04 | Early live pane interactions were inconclusive | n/a | Open; retest by hand |
| T-05 | Crowded strips exposed hidden tabs; close fired on mouse-down | Fixed | Pending |
| T-06 | Main Repair controls ran Bento repair in Tabbed | Fixed | Pending |
| T-07 | First authorized live smoke test | n/a | Partial: activation, one cross-pane drag, one resize, exact Native restore |
| T-08 | Accessibility presses returned before their tab action | Fixed | Passed |
| T-09 | Raw resize events did excessive synchronous work | Fixed | Pending (sustained drag) |
| T-10 | Divider grab jumped; release used a stale position | Fixed | Pending |
| T-11 | Failed resize restoration left automatic placement on | Fixed | Not needed |
| T-12 | Focus changes within 300 ms of placement were discarded | Fixed | Pending |
| T-13 | A tab click depended on unrelated panes' windows | Fixed | Pending |
| T-14 | Multi-window writes repeated per-app Accessibility setup | Fixed | Pending (timing) |
| T-15 | Pane chrome used HUD styling and a heavy fill | Revised | Pending (appearance) |
| T-16 | Escape could not cancel while a managed app had focus | Fixed | Pending |
| T-17 | Closed floating windows stayed in session and Undo state | Fixed | Not needed |
| T-18 | Tab selection accepted a release outside the tab | Fixed | Pending |
| T-19 | Dragging offered splits at the 12-pane limit | Fixed | Pending |
| T-20 | A Space change kept an unfinished divider resize | Fixed | Pending |
| T-21 | A window slow to take focus rolled back a correct layout | Fixed | Pending |
| T-22 | Tabbed failures showed a generic "Couldn't apply layout" | Fixed | Pending |
| T-23 | A failed focus read left a focus refresh pending | Fixed | Not needed |

### T-21: Slow focus rolled back a correct layout

A Tabbed placement required the target window to take focus within about
150 ms. A slower application saw its accepted frames undone with an error.
Accepted frames now wait up to about 550 ms for focus. If focus never arrives,
the layout stays and the focus observer reconciles selection later. Frame
refusal still rolls back. Regressions cover a delayed focus and a focus that
never arrives. This may explain the unexplained error in T-07; that is not
confirmed.

### T-22: Tabbed failures named no reason

The result pill mapped every Tabbed reason to "Couldn't apply layout". It now
shows "Window refused this size", "Use Repair Tabbed", "Desktop changed", or
"Window changed". The full reason stays in the status message.

### T-23: A failed focus read kept a refresh pending

If reading the focused window failed or returned no window, the pending focus
refresh stayed set, and every later Tabbed placement read focus again. The
flag now clears unless placement or a resize is still in progress.

## Remaining live checks

Start with two panes and two tabs per pane. Put windows from the same app in
different panes, and include another app in at least one pane.

1. **Stacking decision.** Make 100 tab selections for each app setup: Safari
   or Chrome, Finder, Terminal, VS Code, and one slow app. Confirm that the
   wrong window never shows and other panes do not change. Record whether
   Tabbed keeps stacking or needs minimize-backed tabs.
2. Type after selecting a tab. Confirm input reaches the selected window.
3. Try the 50/50 case where a right-hand tab needs about 60% width, including
   an inactive tab imposing the limit. Confirm inactive windows stay covered.
4. Resize toward a width limit. Check clamping, release, Escape, and Undo.
   Try an impossible width and a minimum-height conflict.
5. Use Mission Control and App Exposé to select an inactive window. Confirm its
   tab becomes selected without another pane changing.
6. Switch among Tabbed, Native, and Bento desktops, including a Space change
   during a pending write.
7. Test tab moves, edge splits, presets, group merging, Undo, float, and
   reattachment. Revisit T-04 by hand.
8. Close selected and last tabs. Cancel a save prompt and confirm the tab stays
   until the window closes.
9. Verify exact frame restoration on Native exit and Debug quit, including
   windows opened during Tabbed.
10. Check multiple displays, fullscreen transitions, and sustained drag
    performance separately.
11. Crowd a strip with nine tabs. Check the hidden-tab menu, tooltips, close
    press, drag-away, release, and menu placement.
12. Use both main Repair controls while Tabbed is active, in light and dark
    mode.

Manual VoiceOver testing is not required. Accessibility labels and actions are
covered by automated tests.

## Current implementation limits

Tabbed is available only in Debug builds. Inactive tabs stay on-screen behind
the selected window; nothing is parked off-screen, minimized, or moved between
Spaces. Stage Manager must be off.

Pane assignments and the last 20 layout changes are runtime-only. Edge splits
stop at 12 panes. Title-bar drag integration and cross-display tab dragging are
not implemented. Ordinary snap actions are disabled for Tabbed members until
they are floated.
