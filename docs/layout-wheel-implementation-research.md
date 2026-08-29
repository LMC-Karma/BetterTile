# Layout Wheel implementation research

Date: 2026-08-28

> This is supporting evidence, not the implementation source of truth. Follow
> [LAYOUT_WHEEL_PLAN.md](LAYOUT_WHEEL_PLAN.md) for settled decisions and status.

This is a fact report for the implementation plan. It records what the
reference projects and Apple APIs actually provide, then states the resulting
constraints for BetterTile. It does not copy code or artwork.

## Direct answers

### Two levels

- Loop implements one radial action list. Its source separates the layout,
  view model, panel controller, and configurable action records. The model is
  explicitly reused for both the runtime wheel and the settings preview.
  [Loop view model](https://github.com/mrkai77/Loop/blob/develop/Loop/Window%20Action%20Indicators/Radial%20Menu/RadialMenuViewModel.swift),
  [panel controller](https://github.com/mrkai77/Loop/blob/develop/Loop/Window%20Action%20Indicators/Radial%20Menu/RadialMenuController.swift)
- Vorssaint's public documentation describes one wheel with nested menus. Its
  source keeps a stack of item lists and replaces the current list when a
  submenu opens; it does not establish a second concentric actionable ring.
  [Vorssaint radial feature](https://github.com/vorssaintapp/vorssaint-utils#everything-it-does),
  [radial support source](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Services/RadialMenu/RadialMenuSupport.swift)
- Therefore BetterTile's two-level wheel is a product design extension, not a
  behavior to lift from either project. Treat it as two independently indexed
  rings with an explicit ring-selection rule, rather than assuming a second
  ring is automatically safe or legible.

### Configuration UI

The settings page should use the same wheel renderer as the live overlay. Each
slot needs an action picker, derived icon/label preview, and a visible
ring/sector identity. A simple list of 16 rows would not test the actual
interaction or density.

Recommended editor behavior:

1. Choose **One level** or **Two levels**.
2. Show a centered wheel editor matching the selected mode.
3. Select a sector in the wheel or a clearly paired inspector row.
4. Assign Empty, a BetterTile action, a Custom Zone, or Repair Bento. Derive
   the label and icon from the assigned command.

The configuration model should store ordered slot records, not screen
coordinates. Persist the level count, per-slot command identity, trigger
settings, and feature enablement in BetterTile's versioned configuration
envelope. Duplicate and Empty sectors are valid. Add a migration and
round-trip tests.

### Hold shortcut and middle click

Loop documents the desired hold interaction: hold the trigger, move toward a
direction, and release to apply; it also supports an optional preview.
[Loop README](https://github.com/mrkai77/Loop#features)

Vorssaint documents both a held shortcut and extra mouse buttons, and its
feature source supports press/hold activation modes. AppKit exposes tertiary
mouse events as `otherMouseDown`, `otherMouseDragged`, and `otherMouseUp`, so a
middle-button trigger is representable with public `NSEvent` APIs.
[Vorssaint README](https://github.com/vorssaintapp/vorssaint-utils#everything-it-does),
[Apple NSEvent.EventType](https://developer.apple.com/documentation/appkit/nsevent/eventtype)

For BetterTile, the default should be `Control + Option + Shift`, which avoids
the existing `Control + Option` action shortcuts. Hold the chord while moving
the pointer. The middle-button option should be opt-in and should preserve the
same press/move/release state machine. A
middle-button trigger must identify the physical button and consume or pass
through events deliberately so it does not break applications that use the
button. Test both local and global monitor paths.

BetterTile's current shared event tap is intentionally limited to left-button
ordering. Extending event monitoring to middle-button events changes the
documented scope and requires a security review. A public AppKit global monitor
receives only a copy, so it cannot meet the settled requirement to reserve and
consume middle-click. Use a dedicated public event tap only while the opt-in
trigger is enabled; fail closed if it cannot start.
[Apple NSEvent monitoring](https://developer.apple.com/documentation/appkit/nsevent)

### Frosted and Liquid Glass-like presentation

The compatibility baseline is an `NSPanel` with a clear background and an
`NSVisualEffectView` using a behind-window material. Apple documents that this
provides translucency, blur, and vibrancy, while the exact material appearance
changes with system settings; the wheel must not depend on a fixed apparent
color.
[NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)

On systems that provide it, `NSGlassEffectView` is Apple's public custom-view
API for interactive glass behavior. It is marked Beta in the current
documentation, so it should be an optional visual enhancement with the
`NSVisualEffectView` path as the fallback. Do not make the release build
depend on an undocumented class or private symbol.
[NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview),
[AppKit updates](https://developer.apple.com/documentation/updates/appkit)

Use a glass background only behind the wheel. Keep sector separators,
highlight shape, labels, and the center cancel affordance high contrast. With
Reduce Transparency enabled, use an opaque surface. With Reduce Motion
enabled, remove scale/slide effects and retain a short fade or no animation.
Those are product requirements to verify on hardware, not assumptions about a
single material.

## Vorssaint Superkey settings

Vorssaint places Super key in a searchable, System Settings-style
`NavigationSplitView`. The sidebar is grouped into named categories; Super key
appears under Utilities with an icon that changes to match the selected source
key. One `SettingsDirectory` supplies the sidebar pages, icons, localized
search keywords, and command-bar destinations, so the same page stays
discoverable from every navigation surface.
[SettingsView.swift](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/UI/Settings/SettingsView.swift),
[SettingsDirectory.swift](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/UI/Settings/SettingsDirectory.swift)

The Super key detail page is a grouped `Form` with three levels of disclosure:

1. The main section contains the enable toggle, source-key picker, short usage
   caption, a System Settings compatibility note, a visual key mapping, and
   one inline status message. The status is either an orange mapping failure
   with the concrete reason or a green active indicator.
2. The mapping is shown as a small diagram: the source keycap and a **Hold**
   hint, an arrow, then four clickable keycaps for Shift, Control, Option, and
   Command. Selected modifiers use accent color plus a stronger border. Each
   keycap also has a help label and accessibility selected state. The full
   diagram dims while the feature is disabled.
3. A separate **Tap alone** section uses a radio group for the no-chord action,
   followed by a one-sentence caption. The section is disabled with the main
   toggle. A third Permission Required section appears only when the feature is
   enabled without Accessibility.

These details are implemented directly in
[SuperKeySettings.swift](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/UI/Settings/SuperKeySettings.swift).
The failure model distinguishes a conflicting foreign mapping from a system
write refusal, so the page can explain what stopped activation instead of
silently switching off.
[SuperKeySupport.swift](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/Services/SuperKey/SuperKeySupport.swift)

The Super key page does **not** use a free-form shortcut recorder. It chooses a
source key with a picker and chooses output modifiers with keycap buttons.
Vorssaint's separate shortcut recorder is an AppKit button embedded in SwiftUI:
clicking enters a stable-width listening state, Escape cancels, Delete can
clear when permitted, invalid or conflicting chords produce an inline warning,
and every exit path restores suspended shortcuts.
[ShortcutRecorderButton.swift](https://github.com/vorssaintapp/vorssaint-utils/blob/main/Sources/Vorssaint/UI/ShortcutRecorderButton.swift)

Reusable interaction patterns for BetterTile's **Layout Wheel** settings are:

- One searchable sidebar destination and one grouped detail page.
- A top-level enable control followed immediately by the trigger control and a
  compact explanation of the hold interaction.
- A live structural diagram that is also the editor. For BetterTile, replace
  keycaps with the real one- or two-level wheel renderer and make each sector
  selectable.
- Separate sections for **Wheel layout**, **Activation**, **Appearance**, and
  **Accessibility**, with dependent controls disabled rather than removed.
- One inline status or warning beside the control that caused it. A failed
  shortcut registration, unsupported middle button, invalid duplicate slot,
  or permission problem must state the concrete cause.
- Use a recorder only for a full shortcut chord. Modifier-only activation such
  as the default Control + Option + Shift hold should use explicit modifier
  keycaps so its press/release semantics are visible and cannot be confused
  with a one-shot keyboard shortcut.

Do not reproduce Vorssaint's exact keycap styling, sidebar composition,
wording, icon selection, colors, spacing, screenshots, name, or trade dress.
The reusable parts are the information hierarchy, state disclosure, and input
semantics. Vorssaint's trademark file explicitly reserves its name, logo,
icon, bundle identity, trade dress, and official branding even though the
source code is GPL-3.0-or-later.
[TRADEMARKS.md](https://github.com/vorssaintapp/vorssaint-utils/blob/main/TRADEMARKS.md)

## BetterTile implementation implications

### Proposed layers

- `BetterTileCore`: pure `LayoutWheelGeometry` for one or two rings. It maps a
  pointer vector to `(ring, sector)` or `deadZone`, handles angular wraparound,
  and has no AppKit imports.
- `BetterTileMacOS`: one `LayoutWheelController` owns the nonactivating panel,
  keyboard/mouse monitors, display clamping, pointer threshold, and preview
  state. The controller returns a selected slot; it does not mutate windows.
- `BetterTileApp`: add a **Layout Wheel** settings destination and wire slot selection to
  the existing model action path. Keep all permission checks, application
  rules, Bento policy, transactions, rollback, and settlement verification in
  `BetterTileModel`/`WindowCoordinator`.

### Two-ring interaction contract

Use a large, stable inner ring for the eight primary placements. Use the outer
ring for secondary actions only when Two levels is enabled. The outer ring
must not steal pointer ownership from the inner ring: determine ring from
radial distance, apply a dead band between rings, and show the selected ring
and action label in the hub. Release in the dead zone cancels. Escape always
cancels. Keyboard arrows should move through the active ring; Return commits.

The settled default two-level mapping is window-focused:

- Inner: top half, top-right quarter, right half, bottom-right quarter,
  bottom half, bottom-left quarter, left half, top-left quarter.
- Outer clockwise from top: maximize, almost maximize, next display, center and
  resize, restore, center, previous display, Repair Bento.

Do not use the current shortcut cycling resolver for hover or commit. The
radial slot must resolve to an exact action. Add a non-mutating preview path;
the existing `WindowCoordinator.plan(_:)` advances left/right cycle state and
would make merely hovering change behavior.

### Suggested delivery phases

1. Add the pure one/two-ring geometry and tests.
2. Add versioned configuration and migration tests for level, slots,
   appearance, and trigger settings.
3. Build the settings tab with the shared wheel preview and slot editor.
4. Build the keyboard-triggered AppKit panel with exact preview, cancel, and
   commit behavior.
5. Add the opt-in middle-button monitor and test pass-through, modifiers,
   cancellation, and event ordering.
6. Add glass/fallback rendering, accessibility labels, Reduce Transparency and
   Reduce Motion behavior.
7. Integrate model routing, then run focused tests and manual multi-display,
   Spaces, notch-edge, trackpad, VoiceOver, and Accessibility-refusal checks.

Each phase should leave the repository buildable and should record the current
phase number in the pull request or handoff note.

## Licensing and provenance

Loop is GPL-3.0; Vorssaint is GPL-3.0-or-later; BetterTile is GPL-3.0. The
licenses are compatible in principle, but copying implementation code still
requires preserving the applicable notices and recording provenance. The
lowest-risk approach is to reimplement the behavior using BetterTile's
existing architecture and cite the reference projects in documentation.
Vorssaint separately protects its name, logo, and look; BetterStage's source
and visual identity are not open-source materials and must not be copied.
[Loop license](https://github.com/mrkai77/Loop/blob/develop/LICENSE),
[Vorssaint license and trademarks](https://github.com/vorssaintapp/vorssaint-utils#license),
[BetterStage repository](https://github.com/terrytz/betterstage)
