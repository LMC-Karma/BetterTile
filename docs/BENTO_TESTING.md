# Bento validation

Run this checklist for changes to Bento event handling, placement transactions,
session reconciliation, or recovery.

## Automated checks

```sh
swift test
swift build
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Manual checks

Keep Console filtered to the `bento` category while testing. One user action
should produce one settlement path. Repeating `settlement branch:` messages for
one action indicate an event-ownership or fixed-point failure even when the
windows look correct.

- Tile, resize, Repair, and remove windows from Finder, Safari, Terminal, Xcode,
  and a Chromium or Electron application.
- Repeat on one display and two displays. A failure on one display must not stop
  Bento on the other.
- Change Dock position and visibility, then confirm every pane remains inside
  the new work area.
- Enter and leave focus mode, including with a minimum-size window.
- Switch Spaces and sleep/wake the Mac, then confirm the first stable observation
  produces at most one reflow.
- Repeat Space switching with “Displays have separate Spaces” enabled and
  disabled. Confirm each display and Space restores its own Bento tree.
- Keep one window on multiple Spaces and confirm Bento leaves it floating.
- Enter a native fullscreen Space and confirm BetterTile shows no divider and
  performs no ambient placement.
- With Stage Manager enabled, drag single-window and multi-window thumbnails.
  Confirm BetterTile selects only the frontmost real member, never adds a
  thumbnail artifact as a pane, and leaves every other group member untouched.
- Repeat the Stage Manager checks with its Accessibility hierarchy unavailable
  or `disablePrivateAPIs` enabled. Confirm ordinary hit-testing still works.
- Exercise drag snapping and linked resizing with the shared gesture event tap
  active. Confirm down/drag/up ordering matches the `NSEvent` fallback, Escape
  still cancels drag snapping, and one gesture produces one settlement path.
- Disable the event tap during an active gesture and confirm it recovers or both
  consumers switch to `NSEvent` without a duplicate drag or resize. Confirm no
  Input Monitoring prompt appears.
- Measure gesture delivery latency on both sources and confirm the shared event
  tap p95 does not regress by more than 10% against the `NSEvent` monitors. Drag
  a window for about a minute on each source, then read the signposts:

  ```sh
  p95() {
    log show --last 10m --signpost --style compact \
      --predicate 'subsystem == "com.lmckarma.BetterTile" AND category == "GestureEvents"' \
    | sed -n "s/.*source=$1 .*latencyNanoseconds=\([0-9]*\).*/\1/p" \
    | sort -n \
    | awk '{a[NR]=$1} END {if(NR==0){print "no samples";exit} i=int(NR*0.95); if(i<1)i=1; printf "n=%d p95=%.2f ms\n", NR, a[i]/1000000}'
  }
  p95 eventTap
  p95 nsEvent
  ```

  Take the `nsEvent` baseline first. Quit BetterTile, run `defaults write
  com.lmckarma.BetterTile disableSharedGestureEvents -bool true`, and reopen it.
  Restore the tap with `defaults delete com.lmckarma.BetterTile
  disableSharedGestureEvents` and reopen again for the `eventTap` sample.

  Record both values and both sample counts in the pull request. Fewer than 200
  samples on either source is not a measurement.
- Measure window observation latency and confirm a frame-only event refreshes
  only the affected windows. Exercise focus changes, drags, and window
  open/close for a few minutes, then read the interval signposts:

  ```sh
  interval_p95() {
    log show --last 30m --signpost --style compact \
      --predicate 'subsystem == "com.lmckarma.BetterTile" AND category == "Accessibility"' \
    | awk -v want="$1" '
        { t=$2; gsub(/:/," ",t); split(t,h," "); s=h[1]*3600+h[2]*60+h[3]; name=$NF }
        /begin\]/ { if (name==want) b=s; next }
        /end\]/   { if (name==want && b>0) { printf "%.3f\n", (s-b)*1000; b=0 } }
      ' \
    | sort -n \
    | awk '{a[NR]=$1} END {if(NR==0){print "no samples";exit} i=int(NR*0.95); if(i<1)i=1; printf "n=%d p95=%.2f ms\n", NR, a[i]}'
  }
  for name in completeSweep targetedRefresh dragResolution focusedWindow; do
    printf '%-18s ' "$name"; interval_p95 "$name"
  done
  ```

  `targetedRefresh` must be substantially cheaper than `completeSweep`, and a
  session of ordinary window movement must produce far more targeted refreshes
  than complete sweeps. Both counts near zero mean the trace did not exercise
  the path.

  `log show` reports whole milliseconds, so a p95 near or below 1 ms cannot be
  compared at 10% resolution. Use Instruments with the os_signpost instrument
  when a measurement lands that low. This pairing also assumes begin and end
  stay ordered on the main actor, and it does not survive a midnight rollover.
- Repeat the Space, fullscreen, and display checks after running
  `defaults write com.lmckarma.BetterTile disablePrivateAPIs -bool true` and
  reopening BetterTile. Restore normal behavior with
  `defaults delete com.lmckarma.BetterTile disablePrivateAPIs`.
- During and immediately after each operation, confirm windows do not twitch,
  drift, or restore twice.
