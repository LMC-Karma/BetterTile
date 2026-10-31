# Tabbed testing

Product text uses **Adaptive** instead of Bento, **Manual** instead of Native, **Resize Preview** instead of Ghost Preview, and **Repair Layout** instead of Repair Bento or Repair Tabbed.

Tabbed is available in public and Debug builds. It uses normal
on-screen window stacking. Inactive tabs remain open behind their pane's selected
window. Nothing is parked off-screen, minimized, or moved between native Spaces.
Turn off Stage Manager before testing this mode.

Tabbed uses one Tabbed curtain across each display's work area, behind
all selected tabs. Its frosted surface covers inactive tabs across pane
boundaries and gaps. A click selects that pane's selected window or activates
an empty pane. The curtain needs validated exact identities for every tab
and a verified safe window order. Missing identities or unsafe ordering
hide it. Real-application ordering still needs live checks.

Tab strips sit directly above their selected windows. Settings and floating
windows in front retain their order. After an app switch, BetterTile repairs
inactive tabs above any selected tab without activating an application.

Record results and unresolved observations in
[TABBED_TEST_FINDINGS.md](TABBED_TEST_FINDINGS.md).

## Start

1. Build and run the BetterTile scheme with the Debug configuration. Use the
   existing local signing setup in [DEVELOPMENT.md](DEVELOPMENT.md).
2. Grant Accessibility to BetterTile Debug if needed. The public app and Debug
   app must not manage windows at the same time; the normal sibling-app prompt
   handles that transition.
3. In Settings, choose the default Tabbed layout under Window Mode.
4. On the desktop you want to test, choose **Tabbed** in the mode picker.

On a desktop entering Tabbed from Native for the first time, existing eligible
windows become tabs in the first pane of the chosen default layout. Other panes
start empty. Entering from Bento instead adopts its existing panes, with each
window as that pane's selected tab. Returning from Native restores surviving
runtime tab groups. Click an empty pane to send newly opened windows there.

Entry commits only after the selected windows accept their pane frames. If a
selected window is unavailable or placement fails, BetterTile restores the
previous mode and layout and shows **Couldn’t enter Tabbed** with the reason.
No tab strips or curtain remain over the unchanged windows. A desktop that
starts in Tabbed falls back to Native if entry fails. A degraded outcome
suspends automatic placement. Choose a layout to continue, or use Repair Bento
if the desktop returned to Bento. After the application responds again, a
cleanly rejected entry stays in the previous mode. Choose Tabbed again to retry.

## Overlay appearance

Settings → Window Layout → Appearance has **Use Liquid Glass** and
**Glass transparency**. Glass defaults on. The slider runs from Frosted to
Clear. It updates tab strips, dividers, empty panes, the Tabbed curtain and drop
targets, resize ghosts, the Layout Wheel, the menu bar popover, and result
feedback. Clear removes added frosting from ordinary native glass surfaces
and reduces the divider lens body's frosting. The curtain uses regular native
glass and retains a frost floor at Clear to obscure inactive window detail.
Its backing follows the slider from 36 percent to 14 percent. Rounded cutouts
exclude occupied tab strips. Snap and Bento swap/placement previews use light
outlines and tint.

Turning glass off uses solid surfaces, except divider handles, which use a
frosted grey surface. Reduce Transparency and Increase Contrast select solid
surfaces everywhere, including divider handles and when changed while overlays
are visible. The transparency slider is disabled when glass is off. Changes do
not move windows or cancel a drag. The divider lens stretches only in length
when grabbed. Glass handles stay 4 points wider than the Divider width setting;
with glass off, handles use that setting. Changing either width or transparency
updates visible and grabbed handles immediately, including the Settings
preview.

Check light and dark appearances at both transparency endpoints, with glass off,
and with each accessibility display option. Confirm labels stay readable,
minimum-size orange feedback remains visible, and tab clicks and divider drags
still reach the intended control. Check the curtain over oversized inactive
tabs at Clear as well as Frosted. Native glass rendering and sustained drag
performance require an on-screen check.

## Tab bar presentations

Settings → Window Layout → Tabbed → **Tab bar presentation** defaults
to **Always visible**. An existing configuration must keep its 34-point strip
and window frames after upgrade. Check all three settings in light and dark
appearance, with glass on and off, Reduce Transparency, and Increase Contrast.

- Always visible: the strip and window reserve remain 34 points.
- Compact: the strip and reserve are 24 points. Every tab keeps an app icon;
  only the selected tab shows a title. Verify full titles in tooltips,
  VoiceOver labels, and the pane menu, including overflow tabs and long names.
- Auto-hide: the reserve stays 6 points whether hidden or revealed. The
  collapsed band and revealed bar span the pane's full width. Hover inside
  the six-point band, outside its seven-point side input lanes. The 80 ms dwell
  starts at the next display refresh after entry, not at the pointer event.
  The bar starts to grow after about 90–130 ms and is fully visible about
  160 ms later, about 250–290 ms after entry. A screen-capture or window-list
  probe may first read a change up to about 150 ms after entry. The 80 ms
  tolerance of ±40 ms applies to the model clock, not to probe output.
  The 34-point bar must overlay the app without moving or resizing it.
  Unselected titles must remain visible. The side lanes give divider handles
  and resize corners input priority without insetting the glass. Leave for
  300 ms to collapse. An early leave cancels reveal. Re-entry cancels collapse.
  The collapsed line uses reduced-opacity glass; the active pane's line is
  slightly brighter without accent color.
- Use 2 Rows and 2×2 Grid. The lower bands must stay inside their panes,
  below the divider gap. Drag dividers through bands and capsules: no bar
  should reveal. Confirm traffic lights and window resize corners still work.
- Keep a revealed bar open during a tab press, tab drag, pane menu, Layout
  Gallery, and keyboard navigation. Moving from the bar into the Gallery must
  retain the hold until Apply, Cancel, Escape, or outside dismissal closes it.
  Release or close the interaction, then leave to collapse. Cancel a drag with
  Escape. No interaction should remain held after a lost release, mode change,
  or desktop switch.
- Choose **Show Tab Bar** from BetterTile's menu or assign it under Settings →
  Shortcuts → Tabs. It starts unassigned. The active pane receives keyboard
  focus without activating BetterTile. Arrows move the focus marker without
  selecting; Return selects. Escape dismisses and returns typing to the app.
  Press ordinary letters, Tab, and Delete, including key repeat, before and
  after dismissal. No key may crash the app or leave keyboard navigation stuck.
  Check overflow, an empty active pane, VoiceOver activation, and invoking the
  command while Settings is in front. Verify pointer tab clicks keep their
  previous focus behavior.
- Change each setting with selected windows near their minimum heights and
  with stepped-size apps. Each successful change re-fits once. Hover and
  collapse must write no application frames. Try an impossible new reserve:
  the prior layout must remain intact and the failure must be explained.
- Put an oversized hidden tab behind each selected tab. Reveal, collapse,
  resize dividers, switch apps, and change Space. No hidden tab may become
  visible through the band, strip corners, gaps, or other panes. In Auto-hide,
  the curtain has no strip cutouts in either state. Check floating Settings
  and other windows still cover the strips in the normal stack. Without exact
  selected-window identities, put a focused floating window below the 6-point
  band but over the expanded strip. Hover and Show Tab Bar must keep that
  window unobstructed. Collapse must restore the exposed band.

Off-screen AppKit tests use the production strip panel with anchored and
floating ordering. They check the 6-point input frame and content size after a
50 ms yield, at initial display, after repeated Escape, after hover collapse,
and after overlay teardown and re-entry. Drag tests resize the pane first,
then route a press through native hit testing and drop into an empty pane's
strip or content in all three presentations.
Keyboard regressions send events through `NSWindow.sendEvent` and the real
pane/content responder chain. They cover unhandled letters, Tab, Delete, key
repeat, arrows, Return, and Escape in occupied and empty panes for all three
presentations. These checks do not establish native key-focus handoff.

The manual checks above remain required. Fake-window tests cover timing,
geometry, configuration, and intent routing; they cannot prove native key-focus
handoff, material rendering, or cross-application stacking.

## Controls

### Add App to a pane

- Use **+** in both an empty pane and an occupied tab bar. Test All Apps,
  Running, search, Browse, long names, and the shared picker's keyboard path.
  Open the picker at every screen edge. Its entire native window, catalog,
  choice list and buttons must fit the owning screen's visible frame, including
  after Escape and reopening. Repeat on displays with negative origins.
  With **Show Tab Bar** active, `+` opens that pane's picker. Check Tab and
  Shift-Tab through the native controls, Return to choose, and Escape to cancel.
- Select a stopped disposable test app. Its first eligible new window fills the
  captured empty pane or joins the captured populated pane automatically. A
  process launch without an eligible window keeps waiting. The app stays open
  after cancellation and Undo.
- For a running app with an enabled, exposed English **File → New Window**
  command, request a window. A qualifying creation-confirmed arrival can enter
  the pane automatically. Test missing, lazy, translated, disabled, failed and
  duplicate commands. Unconfirmed and existing windows require an explicit
  **Use a window** choice; an unrelated app’s window never qualifies.
- Open several same-app windows during the request. Confirm the selected
  creation policy chooses one qualifying new arrival and never moves an old
  window automatically. Restore an old window while a different popup sends a
  creation event; neither event grants automatic placement. Pending and guarded
  late windows partly outside the work area keep their frames and show no
  fit-failure pill. Review the API’s causal-identity limit in
  [SECURITY.md](../SECURITY.md).
- A running app has 10 seconds to produce an eligible new window; a cold launch
  has 30 seconds. Without an arrival, check the explicit fallback and retry.
  The separate 30-second late-arrival guard prevents overlapping same-app
  creation requests; existing-window choice remains available. On Tabbed,
  guarded late arrivals stay floating, including after explicit selection.
  After the guard expires, new unseen arrivals follow the active pane.
- Cancel through Escape, Cancel, outside dismissal, another destination,
  pane removal, display/work-area change, mode/Space change and permission loss.
  Check stale Browse and launch callbacks. Move a candidate to another display
  during preflight and delayed placement. Never pull it back to the captured
  display or move an off-desktop window. Undo still restores a chosen float's
  original frame.
- In Auto-hide, keep the bar revealed through selection, request, fallback and
  placement. Closing the picker releases the hold without a window reflow.
- Reject a placement and check the previous tabs, selection and frames. Undo
  reverses one successful placement, including a formerly floating window's
  frame. Failed rollback must report Repair Layout and suspend automatic writes.

`PaneApplicationPopoverTests` checks the fitted content size before presentation.
Its opt-in native regression orders test-owned nonactivating panels on each
attached screen. It observes the owned chooser panel, catalog/choice viewports
and buttons at all four edges, then sends Escape and reopens. It uses no live
Accessibility or managed application window. A negative-origin display is covered
when one is attached; a single display cannot establish that coverage.

```sh
BETTERTILE_PANE_POPOVER_BOUNDS=1 swift test \
  --scratch-path /tmp/bettertile-pane-popover-build --filter paneApplicationPopover
```

`PaneApplicationLauncherTests` uses fake application launch and window systems.
`PaneApplicationControlsTests` checks public-command policy, native buttons,
keyboard routing, stale owners and the Auto-hide hold. Optional bitmap renders
capture only test-owned views, with an isolated configuration and no live AX:

```sh
mkdir -p /tmp/bettertile-pane-launcher-renders
BETTERTILE_PANE_LAUNCHER_RENDER_DIR=/tmp/bettertile-pane-launcher-renders \
  swift test --scratch-path /tmp/bettertile-pane-launcher-build --filter paneLauncher
```

These tests do not establish real-app creation compatibility, focus handoff,
cross-app stacking, native materials, or end-to-end arrival latency. The live
checks above remain separate.

### Tabs and pane controls

- Click a tab to select and focus its window. Pane sizes stay stable when it
  fits. A larger minimum can move dividers. An impossible arrangement keeps
  the previous selection and explains the conflict.
  Releasing outside the original tab body cancels selection, including release
  over its close button or another tab.
- Drag within a strip to reorder. Drag into a pane's center to join its tabs.
- Drag to a pane edge to create a split. A preview shows the proposed destination.
  Center and edge previews name the destination pane and action. The release
  position determines the destination, including after a fast drag.
  At the 12-pane limit, edge drops are unavailable; center moves still work.
- Drop on **Float window** to detach. Escape or an invalid drop cancels.
- Drag a divider to resize. Tab strips follow the divider during the drag.
  The shared curtain keeps covering the work area. At release, inactive tabs
  follow the requested frame at best effort. Apps can refuse that size.
  Side-by-side splits adjust
  to each pane's selected tab's minimum width. A requested 50/50 split
  can become 40/60 when the right pane needs more width. Row splits also
  adjust to minimum heights, including the tab strip. Impossible layouts
  are rejected. The real windows update from the latest pointer sample on each
  display tick, up to 60 times per second. Release applies the exact final
  position, then checks the frames accepted by each app. A rejected final frame
  restores the last verified windows and Tabbed state. A minimum learned on
  live release is applied before completion, without requiring another drag
  sample. A stable refusal in either
  dimension can cause one retry after complete
  rollback. Ignored size writes do not become minimum sizes. Gestures on any
  display retain observed limits while Tabbed groups remain stored. Two
  consecutive stable readings of a later smaller size lower that learned limit.
  Grabbing either side of a divider preserves the pointer's offset. A stationary
  grab does not move the divider. If cancellation cannot restore the previous
  arrangement, automatic placement stops until Repair or an explicit layout action.
  Changing Spaces during an active divider drag cancels its stored geometry.
  Frames are restored when returning to that Space, without restoration writes
  on departure. The cancelled drag does not add an Undo entry.
- Resize a selected window by its edge. BetterTile waits until you release the
  mouse button. An edge shared with another pane moves that pane divider and
  stops at each pane's minimum size. Any other change snaps back, including
  every resize in Single Pane. Hidden tabs and strips then follow, and Undo
  restores the previous divider.
- Use the pane's **…** menu for Layout Gallery, Undo, Repair Tabbed, and empty-pane
  removal. Right-click a tab for close, move, split, and float commands.
- Use **Add Floating Window Here** in a pane menu to reattach a detached window.
- When tabs do not fit, the menu shows a hidden-tab count. It lists every tab
  and checks the selected one. Selecting a hidden tab brings it into the strip.
  Hover over a truncated title to read it in full.
- Pane destinations, visible tabs, close buttons, pane menus, and dividers keep
  accessibility labels and actions. Dividers adjust in five-percent steps.
  Automated tests cover these; manual VoiceOver testing is not required.
- A close-button press can be cancelled by releasing outside that button.
  The main Repair controls repair Tabbed while Tabbed is active.
- Closing a tab requests normal application closure. The tab remains until the
  window closes, including while a save confirmation is open.
- Switching to Native restores pre-entry frames for surviving windows. Windows
  opened during Tabbed keep their current frame. Switching to Bento gives every
  tab its own pane. Returning from Native to Tabbed restores runtime assignments;
  entering from Bento adopts the current Bento panes.

Pane assignments and Undo history are runtime-only. Relaunch starts from the
chosen default. The history holds the last 20 layout changes. Edge splits are
limited to 12 panes. Dragging a managed window by its native
title bar uses Bento drops: a center drop adds it to a pane's tabs, and an edge
drop splits the pane. This tracks the window's native drag; dragging a tab strip
starts BetterTile's separate tab drag. Cross-display tab dragging is not
implemented. Keep these checks on one display.
Fixed half, third, two-thirds, quarter, and sixth snaps from the keyboard,
menu, Settings, and Layout Wheel move the focused window's whole pane with all
of its tabs. A pane already in the requested region swaps places with it. The
other panes keep their tabs and fill the remaining space, each as close to its
previous region as the subdivision allows. A new empty pane appears only when
the remainder needs more regions than there are other panes, such as moving
the only pane to a half.

A native title-bar drag into a snap zone moves only the dragged window. An
exact destination pane keeps its tabs and selects the incoming window.
Otherwise BetterTile creates the requested pane and reflows all prior panes
into the remaining space. Existing pane identities and other tab groups
survive, including an emptied source pane.

A new arrangement must fit selected window minimums and the 12-pane limit.
Hidden tabs do not constrain the layout. An unavailable snap leaves the
previous arrangement in place. Tabbed Undo restores one complete pre-snap
arrangement.

Maximize is unavailable for pane members; choose Single Pane in Layout Gallery.
Restore is unavailable for members; use Tabbed Undo. Center, Almost Maximize,
free movement/resizing, and display transfer also remain unavailable for
members. Float a window to use those free-window actions. A fixed partition
snap explicitly attaches a user-floated window again. System floating windows
and apps excluded from Bento stay outside Tabbed.

## Keyboard tab command checks

Settings → Shortcuts lists seven commands under **Tabs**:
**Show Tab Bar**, **Next Tab**, **Previous Tab**, **Move Tab Left**, **Move Tab Right**,
**Move Tab to Next Pane**, and **Move Tab to Previous Pane**. All start without a
shortcut. They can also be assigned under **Tabs** in the Layout Wheel inspector.
No default wheel slot changes. Existing shortcut bindings and wheel assignments
keep their order and values when an older configuration loads.

- Assign temporary shortcuts that do not conflict with application commands.
  With three tabs in a pane, select the first and use Next Tab repeatedly.
  Confirm selection wraps from the last to the first. Repeat with Previous Tab
  in reverse. Type after each command to check real application focus.
- Move a selected middle tab left and right. Confirm its strip order changes
  and it stays selected. At either end, moving farther changes nothing.
- With 2×2 Grid, move a selected tab to the next and previous pane. Destinations
  follow the pane numbers in **Move to Pane**, wrapping at the ends. The incoming
  tab stays selected. Repeat with an occupied destination and an empty one.
  Moving the last tab out leaves an empty pane. Undo restores the prior group.
- In Single Pane with one tab, all six commands leave windows unchanged. Activate
  an empty pane with no focused window and confirm commands do nothing.
- Repeat commands quickly while an application is slow to settle. Each relative
  command uses the committed order after the preceding command. Check a rejected
  pane move: the original group, selection, and window frames must return.
- Assign each command to a temporary Layout Wheel slot. Confirm it works on the
  captured window's pane after focus moves to another pane. A tab command draws
  no placement preview. Clear the temporary assignments afterward.
- In Settings → Menu Bar, enable each command under **Tabs**. Open the Menu Bar
  tile and invoke each command. Confirm it acts on the focused tab's pane.
  Restore the temporary Menu Bar settings afterward.
- Focus a floating window or a window outside the tab groups on a Tabbed desktop.
  Invoke a tab command from its shortcut and the wheel. No window moves, and
  the pill says **Focus a tab to use tab commands.**
- On Manual and Adaptive desktops, invoke each command from its shortcut and
  the wheel. No window moves. The result pill title is **Tabbed not active**;
  its reason explains that tab commands work on Tabbed desktops.
- Relaunch with an existing configuration. Confirm previous shortcuts and wheel
  slots remain unchanged, and the new commands have no assigned shortcut.
  Assign a tab shortcut and wheel command, relaunch, and confirm both persist.

## Manual checks to record

Use disposable windows for the first pass. Automated tests use a fake window
system; the checks below validate real application and macOS behavior.

- In Bento and Tabbed, float an excluded application's window over the middle
  of a divider. Hover over the cover, then above and below it. The handle must
  hide over the cover and stay within the exposed segment beside it. Grab
  the handle and drag; its knob and track must stop at the cover's edge.
  Repeat with a normal window and Picture in Picture. With the Dock shown and
  auto-hidden, the handle must still appear on hover; the Dock draws above it.
  Check straight dividers and junctions in light and dark appearance.
- Cmd-Tab to a window over a visible divider handle. Confirm the handle trims
  or hides without further pointer movement. Move the cover behind the layout;
  a window visible only through the gap must not suppress the handle.
- Drag a seam into a gap shorter than 24 points, or under a cover with no
  exposed segment. The input handle stays visible until release so the drag
  can finish. Its minimum knob can extend beyond that short segment.
- Put two windows from the same app in different panes, with another app selected
  in one pane. Select tabs repeatedly and confirm the other pane stays correct.
- Test curtains with Safari, Finder, Terminal, and VS Code. Shrink a selected
  window by its native edge and drag a divider. Confirm the frosted surface
  hides inactive-tab detail, the selected window stays above it, and the
  curtain covers the work area, including gaps and oversized inactive tabs.
  Repeat with light and dark appearance, Reduce
  Transparency, and Increase Contrast.
- Switch apps with Cmd-Tab and Dock clicks, including an already selected tab.
  Confirm other panes keep their selected windows above the shared curtain.
  Repeat with windows from the same app on two displays.
- Confirm curtains do not appear as windows in Cmd-Tab, Mission Control, or
  App Exposé and do not take keyboard focus or block a floating window. Click
  the frosted area around a smaller selected window. Confirm that window comes
  forward and no hidden tab is selected.
- Open BetterTile Settings over a pane. Click between Settings, other apps, and
  tabs. Confirm Settings keeps focus and stays above the tab strips.
- Put a window from an Ignore Everywhere app over a pane. Cmd-Tab to an app
  with a hidden tab in that pane. Confirm the hidden tab goes back behind the
  selected tab and the ignored window stays in front. Repeat with Spotlight and
  a menu-bar app's window in front.
- Change Spaces, enter fullscreen, disconnect a display, leave Tabbed, and quit
  Debug. Confirm no curtain remains on an unrelated desktop or display.
- Relaunch Debug with `disablePrivateAPIs` enabled as described in
  [SECURITY.md](../SECURITY.md). Confirm Tabbed still works with ordinary
  stacking and no curtains. Restore the default after this comparison.
- Type after selecting a tab. Confirm input reaches the selected window.
- Open Mission Control and App Exposé. Select an inactive window and confirm its
  tab becomes selected without another pane changing.
- Switch between a Tabbed desktop, a Native desktop, and a Bento desktop. Confirm
  their modes and assignments remain independent.
- Enter Tabbed from Bento with one disposable application's window stopped.
  Confirm entry returns to Bento, all frames stay in their previous positions,
  no strips cover title bars, and the pill reads "Couldn't enter Tabbed" with
  "An application is not responding." Resume the
  application. Confirm Bento stays consistent, then choose Tabbed again and
  confirm every selected window moves below its strip.
- Resize toward each app's minimum size. Look for exposed inactive windows,
  flicker, delayed frame changes, or a divider continuing to move after release.
- In Ghost Preview and Live Resize, drag past a minimum and release immediately.
  Repeat for width, height, and a junction. Confirm selected windows, strips,
  and dividers settle to one valid layout without leaving Tabbed. Repeat after
  an app has displaced a selected window, and with a native shared-edge resize.
  A refusal should clamp or restore the verified layout. An app that accepts
  restoration after a short delay should not leave automatic placement suspended.
- Resize a selected window by each edge in Single Pane and 2 Columns, including
  into a neighbor at its minimum width. Confirm nothing moves before release,
  then the window snaps back or the divider moves and stops at the minimum,
  with hidden tabs and strips aligned and no Repair needed.
- Sustain a fast divider drag for at least five seconds on both a 60 Hz and a
  high-refresh display when available. Confirm pointer input remains responsive,
  windows do not fall progressively behind, and release lands at the pointer's
  exact final position. Test Finder, TextEdit, Preview, and a browser separately;
  applications can accept Accessibility writes at different speeds.
- Close the selected tab, cancel an application's save prompt, and close a pane's
  last tab. Confirm selection and empty-pane behavior.
- Try each preset, move groups between panes, reduce the pane count, and Undo.
- Crowd a strip with nine tabs. Select hidden tabs through its menu, inspect
  tooltips, and cancel a close click by dragging away before release.
- Resize a divider and check Undo. Test both main Repair controls while
  Tabbed is active. Inspect light and dark mode.
- Float a window, use it, and reattach it. Check that pane UI does not cover it.
- Switch to Native, switch back, and quit Debug. Confirm windows remain reachable.
- Exercise multiple displays, fullscreen transitions, and a Space change during
  a pending operation. Do not infer those results from the single-display checks.

On a rejected operation, the previous state is retained and restoration is
attempted. An incomplete restore suspends automatic writes for that session.
Use **Repair Tabbed**, a new explicit layout action, or switch to Native.

## Per-Space panel acceptance

Exact native Space sessions retain their own Tabbed strips as the normal
behavior. There is no launch flag. Warm both desktops before timing returns.
Sessions without exact native identity still hide chrome and refresh after
arrival. Keep the normal post-arrival correction checks in both cases.

- Switch between two distinct Tabbed desktops at least ten times with keyboard
  shortcuts. Record both the first correct destination strip and native-window
  slide completion. Check every frame for wrong-desktop strips and a second
  disappearance after arrival. Record the build, configuration, displays,
  refresh rate, and Reduce Motion state. Compare equal workloads on one machine;
  source-level retention is not a new latency measurement.
- Repeat with actual trackpad gestures. Include slow, fast, reversed, and
  cancelled swipes. Do not count keyboard injection as trackpad coverage.
- Record Mission Control entry and exit on both desktops, including App Exposé.
  Retained strips fade over about 100 ms, starting as native windows shrink.
  macOS gives no earlier public signal, so this is a known limitation. Confirm
  the settled overview is clear and strips return on exit. Repeat with Reduce
  Motion.
- Enter a native fullscreen Space, switch through it, exit fullscreen, and
  remove that Space. No desktop strip or curtain may cover fullscreen content.
  Returning to either ordinary desktop must show its own retained strip.
- Use two displays with separate Spaces. Switch one while the other remains
  Tabbed. Verify both strips, clicks, pane **+**, and Layout Gallery. Repeat
  after return and with a hidden overlay from a desktop that left Tabbed. A
  hidden overlay must not cancel the other display's picker. Test the system's
  separate-Spaces-off configuration separately when available.
- While on B, close a known window on A, minimize another, and quit a disposable
  app with several A tabs. Wait for the corresponding lifecycle notifications,
  then return to A. The first visible strip must already omit those tabs. Test
  selected, hidden, and last tabs; the last leaves an empty pane. No application
  window on A may move or activate while B is current. Replacement-tab geometry
  and curtain ordering may correct through the normal arrival placement.
- Repeat Always visible, Compact, and Auto-hide returns. Compact keeps its
  24-point strip. A revealed Auto-hide bar returns collapsed to its 6-point
  band, with no stuck menu, drag, picker, gallery, or keyboard hold. Hover and
  explicit Show Tab Bar must work after arrival. Pointer clicks must preserve
  the selected app's typing focus.
- Repeat many switches, leave and reenter Tabbed, delete an owned empty Space,
  and disconnect/reconnect a test display. Check that panel counts follow live
  Tabbed sessions and stop growing on warmed switches. Permission or native
  observation loss must hide retained chrome safely.

`SpacePanelTests` uses fake window systems and panels whose ordering and key
methods never reach the real window system. It covers cached lifecycle updates,
selection of retained controllers, owner checks, cleanup, bounded panel counts,
fullscreen policy, two displays, picker dismissal, gallery Apply, all three
presentations, shutdown release, and a sweep preceding its Space notification. Core tests cover minimization while a session is inactive and
preservation of its entry frame. These checks do not establish slide pixels,
Mission Control entry timing, real focus, or native display association.

## Layout Gallery checks

- Open **Layout Gallery** from an empty pane card and **Layout Gallery…** from
  the **…** menu of both empty and populated panes. Each opens a compact panel
  anchored to that pane. Confirm **Applies to the whole display** is visible.
  Existing empty-pane actions and local split/remove actions remain available.
- Check all five named miniature arrangements. The current preset has a check
  mark and an accessibility label such as **2 Columns, current layout**.
  A custom arrangement must not mark a preset as current.
- Hover each miniature. Use Tab, Shift-Tab, and arrow keys to focus choices.
  Focus and hover draw the arrangement on the display without moving windows.
  Space selects a choice. Tab reaches the grouping controls, Cancel, and Apply.
  Check VoiceOver labels and visible focus, including with Full Keyboard Access.
- Choose **Keep tab groups**, then Apply. Groups stay together; reducing pane
  count merges overflow groups into the nearest pane. This is the default each
  time the gallery opens.
- Choose **Distribute windows**, then Apply. Windows fill panes once in pane/tab
  order, then extras join as tabs round-robin. Try fewer windows than panes,
  more windows than panes, and redistribution into the current preset.
  Windows you floated stay outside the layout; automatic floats may return.
- Apply each arrangement. **Undo Layout Change** restores the previous pane
  geometry, tab order, and selection in one step. A refused layout must retain
  the previous state and must not add an Undo step.
- Select and preview several choices, then press Escape, click Cancel, or click
  outside. The preview disappears; no window moves and no Undo step is added.
  Repeat while switching Space, changing mode, or resizing the work area.
- Check narrow empty panes, light/dark mode, Reduce Transparency, Increase
  Contrast, and Reduce Motion. The gallery must remain readable and must not
  hide its controls. Repeat on a second display to confirm scope and anchoring.

These checks require live verification. Fake-system tests cover distribution,
model Apply/Undo, refusal, and cancellation without frame writes. AppKit tests
cover labels, keyboard focus callbacks, custom geometry, and entry controls.

## Validation status

Core, fake-window coordinator, and app-model tests cover activation, membership,
geometry, layout changes, focus requests, restoration, and session isolation.
Fake-window tests inject entry frame-write failures to check rollback. A degraded
outcome must stop automatic placement. They also check that a window opened
during a rejected entry joins the restored layout.
The tests also verify display-tick coalescing, exact release geometry, cancellation,
final-frame rejection, and the absence of repeated tab ordering during a live
resize. Curtain tests cover work-area geometry, selected-window
ordering requests, pane clicks, missing identities, cleanup, and solid accessibility
fallbacks. Stacking tests cover the order repair, windows kept in front,
unreadable windows, other displays, strip ordering, and focus while BetterTile
is in front. Off-screen AppKit tests use BetterTile's own windows and cannot prove
real-application ordering. An off-screen pane rendering test checks
accessibility actions without
capturing foreign windows. Real-app stacking, Mission Control/App Exposé, live
performance, and display/Space transition behavior require the manual checks
above. This test build is not evidence that those platform checks have passed.

## Glass and tab-drag regression checks

- Hover a straight divider in Bento and Tabbed. Confirm the accent track is
  invisible at rest. Grab it, drag in both directions, and release. The track
  fades in through a clear lens with soft cap glints as the lens stretches,
  then retracts. Its width and shadow stay constant. Check both axes.
- Resize toward an application's minimum size. The track and thin
  border turn orange together. The cursor shows the available direction.
  Moving away from the limit restores the accent color.
- Drag three-way and four-way junctions. Their arms form one outline with
  rounded inner corners. Check short divider spans: the fading track must end
  inside the span. Resize ghosts must stay below the track and shadow.
- In Ghost Preview, drag straight dividers and junctions rapidly. The preview
  outlines and knob must move together; outlines may pass under the knob.
  Release, press Escape, hide the handle, and switch Spaces. Confirm the preview
  disappears and the normal handle returns. Repeat a gesture to check reuse.
  Record a 60 fps real-application drag when checking frame synchronization.
  Tabbed strips remain separate windows; record any visible lag without treating
  it as evidence that the preview outlines lag.
- Click outside the handle's hit frame, including on its track and shadow.
  The window below receives the click. Hide the handle and check that its
  track and shadow also disappear.
- Repeat the lens checks in light and dark mode. Move **Glass transparency**
  from Frosted to Clear while the handle is visible. Its body frost changes
  without interrupting the drag. Above the default frost level, the track
  also softens. Check widths from 2 to 12 points and the Settings preview too.
- Toggle Reduce Transparency and Increase Contrast while the handle is
  visible. Each uses a solid capsule without a track or shadow. Turn Liquid
  Glass off: the handle is frosted grey, not white, in light and dark mode,
  at rest and while dragged, and in the Settings preview. Restore each option
  and confirm the lens returns. Reduce Motion makes grab and release
  transitions immediate.
- Sustain a divider drag and look for stutter, clipped shadows, or blurred
  edges. Repeat after moving between displays with different scale factors.
- Drag a tab in both directions. Neighboring tabs move before release. Return
  to the original slot, then move to another pane's strip, including an empty
  pane. Check the gap, pointer alignment, and settling motion.
- Hold a dragged tab at either end of a crowded strip. Hidden tabs scroll into
  view. Escape restores the starting strip. Hiding the overlay or closing the
  dragged window also cancels the interaction.
- Change transparency while a tab is held. The appearance updates without
  committing the drag. Check Reduce Motion without changing drag destinations.
- Move Glass transparency while the curtain is visible. Confirm the frost
  changes without changing window order. Check curtain cutouts while resizing
  rows and columns. Inactive windows stay
  concealed outside the strips. Click strip corners and divider gaps to ensure
  inactive windows never receive those clicks.
- Open the menu bar panel and change transparency. Clear keeps the shared
  20-percent popup frost; Frosted raises it to 22 percent. The borderless panel
  hosts one native glass material. Check glass off, Reduce Transparency and
  Increase Contrast. With Full Keyboard Access, Tab enters the mode picker
  once, arrows move focus without changing the desktop, and Space or Return
  selects the focused mode.

Optional compositor previews capture only synthetic test windows by their
WindowServer numbers. These exercise native materials; off-screen bitmap
caching does not reproduce all native glass effects.

```sh
mkdir -p /tmp/bettertile-glass-previews
BETTERTILE_NATIVE_GLASS_PREVIEW_DIR=/tmp/bettertile-glass-previews \
  swift test --scratch-path /tmp/bettertile-build \
  --filter 'nativeGlassCompositorPreviews|nativeDividerLensPreviews|menuGlassPopoverPreviews'
```

## Repeated transfer and selection checks

Start with A/B in one pane and C/D in another. Select A, move A to the second
pane, select C, select A, move A back, then select B and A. Repeat with different
starting tab orders, same-app windows, and mixed apps. Alternate tab-strip and
title-bar drags. Run settled steps first, then issue clicks before each preceding
move settles.

- A valid move must not disappear when a later tab is clicked. The final
  selection in each pane must match the last requested selection there.
- During a pending strip drop, click both an existing destination tab and the
  incoming tab. The click must address the displayed tab. A second drag waits
  for settlement and must not become an accidental selection on release.
- Move the last tab out of a pane and back. The empty pane remains a destination.
- Cancel a native title-bar drag. The tab returns to its original order and
  selection without adding an Undo step. Undo after a rejected drop must undo
  the preceding successful change.
- Start a native drag while a selection or move settles, finish it immediately,
  and select another tab. The next interaction must work without Repair.
- Open or close a window during placement, then activate another pane. The
  deferred window inventory must still reconcile.
- Click rapidly between tabs of a slow-to-focus application. Older selections
  in the same pane must not create a long replay after the final click. Type
  after settlement to check real focus, separately from selected-tab styling.

The automated sequence tests use fake windows and AppKit pointer events. Record
real-app focus, stacking, and flicker results separately in
[TABBED_TEST_FINDINGS.md](TABBED_TEST_FINDINGS.md).

## Optional interaction benchmark

Run this check locally with no simultaneous builds or compositor captures.
It is disabled by default and in CI. Set `BETTERTILE_PERF_BENCH=tab-drag` to
measure completed drag frames, or `all` to include refresh and divider paths.
The output goes to stdout. `BETTERTILE_PERF_OUT` optionally appends the same
report to a chosen file.

```sh
BETTERTILE_PERF_BENCH=tab-drag \
  swift test --scratch-path /tmp/bettertile-benchmark-build \
  --filter interactionBenchmark
```

The tab scenario has four panes and 16 tabs. Each of 400 samples sends one
mouse event and fires the production display-tick callback, including edge
scrolling. The report excludes 20 warm-up samples. Checks after each sample
verify the lifted tab's position and the source strip's provisional order.
This prevents measuring only the cost of queuing a mouse event.

The phases report controller work, Core Animation commits, and pending AppKit
drawing. They do not measure final WindowServer compositing, physical pointer
latency, or real applications accepting Accessibility writes. Compare the
median mean and median p95 of three serial runs on the same Mac. The drag-frame
targets are a mean at or below 1 ms and p95 at or below 3 ms.

Run `nativeTabDragPreviews` separately with
`BETTERTILE_NATIVE_GLASS_PREVIEW_DIR` set to an output directory. It places the
actual production views over one synthetic backdrop after a completed tick,
then captures that test window in light and dark appearance. This shows
reordering, a provisional tab in an empty strip, and a split target. It does not establish
real-application stacking or the feel of physical input. For that check, drag
quickly with at least 16 tabs, hold both strip edges to scroll, cancel with
Escape, and release over a different destination before the next display tick.

## Fixed snap checks

- With the Layout Wheel and the keyboard, snap a pane with several tabs to an
  occupied exact region and to an empty exact region. The two panes swap, and
  every pane keeps its tabs.
- From 2×2 Grid, snap one pane to Right Half. The other three panes keep
  their tabs in the left remainder, and no empty pane appears. Undo restores
  the previous arrangement.
- From Single Pane, snap to Left Half. The pane keeps all its tabs, and the right
  half becomes one empty pane.
- Drag one tab's window by its title bar to an occupied exact snap zone and to
  an empty one. Other tabs stay in their groups, and the destination selects
  the moved window.
- The wheel keeps its captured window after focus changes.
- Keep a native drag within one fixed snap zone. Unchanged preview outlines
  continue their animation without restarting. Leaving the zone removes them;
  a competing pane-center drop takes over only after its hover delay.
- Exclude an app while its window still belongs to a pane. Keyboard, wheel,
  and native snaps must not move it as a free window. A user-floated window
  keeps ordinary snapping after exclusion.
- Try a selected window whose minimum cannot fit the exact snap. Verify that
  neither its group nor the fixed target silently changes. A rejected native
  drag returns to its pre-drag frame and group.
- Move a user-floated window, snap it into a pane, then Undo. Its current
  pre-snap floating frame returns; unrelated floats stay put.
- Switch Space or mode while a placement is pending. No restoration should
  move windows on the departed desktop.
