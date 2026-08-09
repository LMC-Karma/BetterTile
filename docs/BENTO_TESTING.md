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
- During and immediately after each operation, confirm windows do not twitch,
  drift, or restore twice.
