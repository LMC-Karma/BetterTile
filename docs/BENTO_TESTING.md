# Bento validation

Product text uses **Adaptive** instead of Bento, **Manual** instead of Native, **Resize Preview** instead of Ghost Preview, and **Repair Layout** instead of Repair Bento or Repair Tabbed.

Run this checklist for changes to Bento event handling, placement transactions,
session reconciliation, or recovery.

## Automated checks

```sh
swift test
swift build
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`AdaptiveCompoundScenarioTests` combines arrivals with divider edits, overflow
admission, work-area changes during settlement, repeated Repair Layout, and
display round trips. These model checks use the injected clock, compare pane
order and ratios, and require a quiet interval with no later writes. Their
arrival bounds describe deterministic scheduling, not live application response
times.

## Manual checks

Choose the checks that match the changed behavior. This list is guidance, not a
requirement to repeat the full matrix for every pull request or release.

Keep Console filtered to the `bento` category while testing. One user action
should produce one settlement path. Repeating `settlement branch:` messages for
one action indicate an event-ownership or fixed-point failure even when the
windows look correct.

- Exercise tile, resize, Repair, and window removal in representative native and
  Electron applications.
- Check one and multiple displays when display ownership or work-area behavior
  changed.
- For Next Display and Previous Display between Adaptive desktops, start with two
  panes on each display. Destination panes must make room before the window
  arrives, and the source must close its gap within the command. Repeat in
  both directions, across different scales and Dock work areas, and with three
  displays, including wraparound. A full destination or minimum sizes that
  cannot fit must leave the arrival floating and explain the result. Manual
  sources must join an Adaptive destination without overlap. An Adaptive source must
  close its gap when the destination is Manual. Tabbed destinations retain their
  existing transfer behavior. If an application refuses a destination frame,
  the move must roll back both layouts. Incomplete rollback must stop automatic
  writes on both desktops.
- Check Space switching, fullscreen, sticky windows, or Stage Manager when the
  change touches those integrations.
- Check drag snapping and linked resizing on both the shared gesture source and
  its fallback when gesture routing changed.
- Exercise the public fallback when private observation behavior changed. Use
  the documented `disablePrivateAPIs` default for that comparison.
- Confirm each action settles once without twitching, drifting, duplicate
  placement, or a failure on one display stopping another.
- For Repair Layout settlement, use four and five native fixture windows with
  a small minimum size. Use a work area and pane gap that produce half-point
  row frames, with the full-height pane on the left. Repeat Repair Layout and
  confirm it reports success after settlement. A stable readback within
  2 logical points of each requested frame component is accepted when the
  actual frames also satisfy Bento's 2-point overlap allowance. A larger
  mismatch or overlap must still fail. The fake-window-system tests cover the
  measured 1.5-point height shortfall, rejection of a 3-point component mismatch,
  and combined component errors that overlap neighbours by 3.5 or 5 points.
- For new-window placement, rearrange the layout by hand, focus a wide pane,
  and open a window of another application in the background. The focused pane splits side by side. Repeat
  with a tall pane; it splits top and bottom. Repeat after a half-screen snap;
  the new window fills the empty slot instead of splitting a pane.
- For **Balance on new window**, turn the setting on and open a window. Each
  partition gives its panes equal shares. Repeat with an application that has
  a large minimum size, such as Calendar. That window keeps its minimum, its
  neighbours share the rest, and no failure pill or overlap remains.
- For minimum-size measuring, run `log stream --level debug --predicate
  'subsystem == "com.lmckarma.BetterTile" AND category == "Accessibility"'`.
  Open two windows of one application, one after the other. Each logs
  `probe measured a … window`, and each window shows a brief resize as it
  appears. After placement, no panes overlap. Quit the application; the log
  reports that its seed was dropped.
- For Tabbed arrivals and floats, run `log stream --level debug --predicate
  'subsystem == "com.lmckarma.BetterTile" AND category == "Tabbed"'`. Each
  window that joins, returns, or floats logs its frame, its resizability and
  minimum with their sources, and the result for each pane it tried. A window
  that no pane can show floats. Applying a preset, removing a pane, or a larger
  work area returns it when a pane can show it: as that pane's selected tab,
  or as a hidden tab when the pane shows the focused window. Repair
  Tabbed returns the windows Tabbed floated on its own and keeps the windows
  you floated.
- For launch discovery, launch an application in Adaptive and in Tabbed whose
  first window the launch sweep omits; with `-BetterTileArrivalTrace YES` the
  Debug trace logs `launch_discovery_started`. Its window must join within a
  few hundred milliseconds of showing, including when it shows 1 s or 3 s after
  launch with no creation callback. Also check a creation callback during
  discovery, another launch or a helper quitting during discovery, a menu-bar
  application, a background helper and a hidden launch (these start no
  discovery), and an application that never shows a window: nothing more is
  read after about 6 s.
- For a hung application, put a window of a test application, such as
  TextEdit, in a Bento layout. Stop it with `kill -STOP <pid>`. Drag dividers
  next to its pane, snap other windows, and drag windows by their title bars.
  BetterTile stays responsive after at most one short stall, and the stopped
  window keeps its pane. Resume it with `kill -CONT <pid>`; a divider drag
  next to it then works at once. Also switch from Manual to Adaptive while the
  application is stopped, then resume it without another action. Its window
  should rejoin within about 0.5 s after the current 2 s hold ends and the app
  answers. Repeat with a Space switch or a newer native snap before recovery;
  recovery must not place windows on the old Space or undo the snap. Snap the
  returning window before the hold expires and allow the normal 120 ms event
  debounce to complete; recovery must keep that snap too. Repeat when an
  ordinary topology sweep or the watchdog reads the app after hold expiry but
  before the recovery timer fires. Include direct application launch, termination,
  and wake refreshes. Reject one returning native snap write with a complete rollback. The same pass must keep
  its frame and evidence without probing it as an arrival. Change its frame and
  trigger an existing reconciliation; that pass must adopt the latest snap.
  Close or minimize a peer while a held window has an edge resize pending.
  Recovery must reduce the tree before divider fitting, remove the overlap, and
  write nothing to the removed peer. Repeat with an unrecognised relocation.
  Let native observation become unavailable and return while visible windows
  retain an overlap anchor. Keep the latest snap, current mode, and suspension.
  Include the first native observation through both Space stabilization and direct
  refresh, with Manual selected after the hold and with a degraded
  suspended layout. Require the same session, mode, suspension, and no new writes.
  Keep the recovery window held or off-screen when the first native observation
  arrives, with a responsive eligible overlap anchor still visible. Check the
  same state and frames before and after that window returns.
  Cover hold-only, pending-reconciliation-only, and retained-frame-only evidence.
  An established exact native session must remain authoritative. An unrelated
  desktop without overlap must get its own mode and suspension, including when a
  newer Space notification discards the first observation. Keep top-half snaps.
  Without a public overlap anchor, leave windows and evidence unchanged until a
  later current reconciliation. Change capability availability during preflight,
  including repeated changes across explicit reconciliations. No stale probe or
  placement may dispatch, and a quiet interval must start no recovery sweep.
  Include several returning identities and displays, with one rejected or
  deferred display and an unrelated arrival on another. Safe displays must
  continue. A failed rollback must still suspend its owner and report Repair Layout.
  Leave a retained identity off-screen after hold release. Unrelated callbacks
  must not repeatedly target it, and a quiet interval must start no extra work.
  During ordinary settlement, deliver another window's native snap, edge resize,
  or unrecognised move. Settlement must keep ownership and the event pass must
  add no writes or probes. Repeat with a recovery window visible on another
  display and with a visible sibling that shares the absent identity's PID.
  Include a foreground-application activation
  that reads the returned app to refresh dividers without reconciling it. Also
  release the hold during a frame-only inventory or its trailing divider read.
  A recovery generation guards writes; only an inventory whose caller reconciles
  arrivals may omit queuing a topology pass after hold release. With no callback
  or further action, the queued reconciliation must adopt the window.
  Repeat with two held apps on different Spaces. A sweep on one Space must not
  discard the other app's pending reconciliation. Switch away from the held window's Space
  and back before recovery; its retained snap must survive stabilization.
  Also let the app respond while away, process a topology event there, then
  return and process another topology event. The latest native snap must survive
  the completed hold and transition bookkeeping. Repeat with unknown native
  membership and with the public fallback's inferred session. Fail an inventory
  read and switch Space during native-snap preflight; later current reconciliation
  must classify the latest frame. Deliver a held frame callback during a gesture
  and finish the gesture while the app is still unreadable; recovery must keep it.
  Close a held window during stabilization or a gesture, including process exit
  with several windows. Its exact evidence must retire before buffering, and a
  replacement must inherit none.
  Switch Space during minimum-size or placement preflight reads. Count probe
  dispatches as mutations too; no new old-Space probe or placement may start.
  Repeat without a moved or resized callback, and with a newer mode action
  during preflight. Include delayed placement retries when an application
  ignores the first placement. Fail a placement and its rollback, then change
  the Space stabilization generation during rollback. The mixed layout must
  still report Repair Layout and suspend automatic writes. Select an actual different
  desktop session during initial placement, native snap, Focus, clamp correction,
  delayed correction, and retry rollback. The damaged session must be suspended;
  the new session must remain usable. Feedback must say when Repair Layout belongs to
  another desktop. Repeat when a minimum-size probe cannot restore its window. Leave the app stopped
  through three recovery attempts and confirm that automatic
  retries stop; the 10 s watchdog remains the fallback. Quit it while held and
  confirm that no recovery retry storm follows. Never stop a system process.

## Performance checks

Measure performance when a change touches a hot path or investigates a reported
regression. Compare before and after builds on the same Mac with the same
workload. The `GestureEvents` and `Accessibility` signposts provide delivery and
observation timings. Record the method and result when performance affects the
decision to merge or release; do not impose a universal sample count or
threshold on unrelated changes.
