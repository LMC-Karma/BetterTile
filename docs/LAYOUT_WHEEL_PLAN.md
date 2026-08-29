# Layout Wheel implementation plan

Status: approved design; implementation may begin

Current step: **5 — Layout Wheel settings destination**

Last completed step: **4 — Shared glass wheel renderer**

Branch: `feat/layout-wheel`

Last updated: 2026-08-28

## Handoff

An agent continuing this work must:

1. Read `AGENTS.md`, `CONTEXT.md`, this plan, and the working-tree diff.
2. Start at the **Current step** above. Do not repeat a completed step.
3. Keep the repository buildable at every step.
4. Change a step to complete only after its completion criteria pass.
5. Update **Current step**, **Last completed step**, the checklist, and the work
   log before ending a session.
6. Preserve unrelated work and stage explicit files only.

The supporting evidence is in
[Layout Wheel research](layout-wheel-research.md) and
[implementation research](layout-wheel-implementation-research.md). Those
files contain source citations; this file is the implementation source of
truth.

## Settled product contract

- The user-facing term is **Layout Wheel**.
- The wheel supports **One Level** and **Two Levels**. Two Levels is the
  default. Changing the level count hides or reveals the outer ring without
  deleting either ring's assignments.
- Each ring has eight aligned sectors. Pointer angle chooses a sector and
  radial distance chooses a ring. A dead band separates the rings.
- The center hub is always Cancel. Escape also cancels.
- The focused eligible window is captured when the wheel opens. Losing that
  target cancels the gesture instead of changing targets.
- Pressing the configured modifiers starts a 220 ms hold threshold. The
  default is Control + Option. Pressing any non-modifier key cancels wheel
  activation so existing Control + Option shortcuts continue normally.
- The modifier trigger is configurable from Control, Option, Shift, and
  Command. At least two modifiers are required.
- Middle-click activation is available independently and disabled by default.
  Enabling it reserves and consumes unmodified middle-click globally. Settings
  must explain that browsers, design tools, and other apps will no longer
  receive middle-click while it is enabled.
- Both triggers use press, move, preview, and release. Releasing in the hub,
  dead band, or an Empty sector cancels.
- A sector can contain Empty, any exact `WindowAction`, a `CustomZone`, or
  Repair Bento. Duplicates and Empty sectors are valid.
- Labels and SF Symbols are derived from commands. Version one has no custom
  labels, icons, wheel size, tint, opacity, or blur controls.
- A deleted Custom Zone leaves every referencing sector Empty.
- An unavailable command never substitutes another command. Release cancels
  and the existing result pill explains why. Repair Bento is unavailable
  unless the captured display is currently in Bento mode.
- All window placements use the active Manual or Bento policy. A Layout Wheel
  sector is exact and never participates in the two-second keyboard shortcut
  cycle.
- The wheel uses public macOS 26 glass/material APIs, semantic colors, and
  native SF Symbols. Reduce Transparency uses an opaque surface. Reduce Motion
  removes scale and movement.

### Default assignments

| Direction | Inner ring | Outer ring |
| --- | --- | --- |
| Top | Top Half | Maximize |
| Top-right | Top Right Quarter | Almost Maximize |
| Right | Right Half | Next Display |
| Bottom-right | Bottom Right Quarter | Center and Resize |
| Bottom | Bottom Half | Restore |
| Bottom-left | Bottom Left Quarter | Center |
| Left | Left Half | Previous Display |
| Top-left | Top Left Quarter | Repair Bento |

## Architecture

The feature uses three deep modules:

1. `LayoutWheelGeometry` in `BetterTileCore` owns deterministic one/two-ring
   hit testing. Its interface returns a sector identity or cancellation.
2. `LayoutWheelController` in `BetterTileMacOS` owns the runtime gesture:
   modifier and pointer monitoring, the activation timer, the nonactivating
   panel, target lifetime, preview presentation, and dismissal. Its interface
   emits preview, commit, cancel, or unavailable intent; it never mutates a
   window.
3. `BetterTileModel` in `BetterTileApp` resolves a `LayoutWheelCommand`,
   enforces permission and application rules, calculates exact Manual or Bento
   previews, and commits through the existing coordinator and transaction
   paths. It owns result-pill feedback.

The shared SwiftUI `LayoutWheelView` belongs in `BetterTileMacOS`, beside
the panel that presents it. The settings destination uses the same renderer
with editable selection state. Avoid an `isPreview` behavior switch: rendering
accepts wheel state and an optional sector-selection closure; the settings
caller edits, while the runtime caller supplies live state.

All Core coordinates remain top-left logical points. AppKit conversion stays
inside `BetterTileMacOS`. No new dependency or private API is permitted.

## Security decision

Keyboard modifier monitoring is observation-only. The optional middle-click
trigger has a stronger invariant: the underlying app must not receive the
reserved click. An `NSEvent` global monitor cannot enforce that invariant
because it only receives a copy.

Implement middle-click with a dedicated public `CGEventTap` that:

- exists only while the option is enabled;
- observes only `otherMouseDown`, `otherMouseDragged`, and
  `otherMouseUp`;
- suppresses only physical button 2 and passes every other event unchanged;
- retains only scalar position, button, modifiers, timestamp, and event kind;
- disables middle-click activation and reports the failure if the tap cannot
  start or recover;
- never falls back to double-handling the click through an `NSEvent` monitor.

This broadens BetterTile's documented event scope and changes a listen-only
assumption for this optional path. Before Step 7 is merged, update
`SECURITY.md`, the Setup Assistant disclosure, and Settings. Record the
benefit, scope, failure behavior, permission behavior, disable switch, and
manual validation in the pull request. Confirm on a signed build that enabling
the option does not request Input Monitoring. Maintainer approval of the final
pushed implementation is still required.

## Implementation checklist

- [x] Step 0 — Research and product decisions
- [x] Step 1 — Core selection geometry
- [x] Step 2 — Commands and configuration migration
- [x] Step 3 — Exact preview and commit planning
- [x] Step 4 — Shared glass wheel renderer
- [ ] Step 5 — Layout Wheel settings destination
- [ ] Step 6 — Modifier gesture and runtime panel
- [ ] Step 7 — Opt-in middle-click reservation
- [ ] Step 8 — App lifecycle integration and accessibility
- [ ] Step 9 — Full verification, documentation, and pull request

## Step 0 — Research and product decisions

Status: **complete**

Work:

- Compared Loop, Vorssaint, BetterStage's public behavior, and the supplied
  images.
- Inspected BetterTile's actions, configuration, settings, event monitors,
  coordinator, Bento routing, previews, and result pill.
- Settled the product contract through three decision rounds.
- Added **Layout Wheel** to `CONTEXT.md`.

Completion criteria:

- The product contract above has no unresolved user decision.
- Primary-source claims have citations in the research files.
- This plan names every implementation step and its completion criteria.

## Step 1 — Core selection geometry

Status: **complete**

Files:

- Add `Sources/BetterTileCore/LayoutWheel.swift`.
- Add `Tests/BetterTileCoreTests/LayoutWheelGeometryTests.swift`.

Work:

- Add `LayoutWheelLevelCount` with One Level and Two Levels.
- Add stable ring and eight-sector identities. Sector zero is Top and indexes
  proceed clockwise.
- Add `LayoutWheelGeometry` that maps a pointer vector to center cancellation,
  inner sector, inter-ring dead band, or outer sector.
- Keep radii explicit and validated. In One Level, every point beyond the hub
  selects the inner ring, including overshoot. In Two Levels, outer overshoot
  stays on the outer ring.
- Define exact behavior at every angular and radial boundary so selection never
  flickers because of an unspecified comparison.

Tests:

- Center and zero-length vectors cancel.
- Cardinal and diagonal vectors map to all eight indexes.
- Angles immediately on both sides of every sector boundary are deterministic.
- Angle wraparound at `-π`/`π` is deterministic.
- Inner ring, dead band, outer ring, and outer overshoot map correctly.
- One Level ignores outer-ring distance.
- Invalid or non-finite geometry inputs cancel safely.

Completion criteria:

- Focused Core tests pass through XcodeBuildMCP's Swift package test workflow.
- The complete Swift package test suite passes.
- No AppKit import appears in `BetterTileCore`.
- Update this plan to make Step 2 current.

## Step 2 — Commands and configuration migration

Status: **complete**

Files:

- Update `Sources/BetterTileCore/Configuration.swift`.
- Update `Tests/BetterTileCoreTests/ConfigurationTests.swift`.
- Extend `Sources/BetterTileCore/LayoutWheel.swift`.

Work:

- Add `LayoutWheelCommand`: exact `WindowAction`, Custom Zone ID, or Repair
  Bento. An optional command represents Empty.
- Add `LayoutWheelConfiguration` with master enablement, level count, eight
  inner slots, eight outer slots, keyboard enablement, modifier set, and
  middle-click enablement.
- Use the settled two-level defaults. Keep keyboard activation on and
  middle-click off.
- Validate exactly eight slots per ring and at least two supported keyboard
  modifiers. Normalize malformed input to safe defaults during migration.
- Increase the configuration schema from 9 to 10. A version-9 file receives
  the defaults without changing unrelated preferences.
- When Custom Zones change, normalize dangling sector references to Empty.
  Preserve duplicate and Empty assignments.

Tests:

- Version 1 through 9 migrations still reach the current schema.
- Version 9 receives exact Layout Wheel defaults.
- One/two-level and trigger settings round-trip.
- Invalid slot counts and modifier bits cannot enter runtime state.
- Removing a Custom Zone clears all matching sectors and nothing else.
- Duplicate assignments survive validation and encoding.

Completion criteria:

- Configuration and complete package tests pass.
- Existing user settings migrate without unrelated diffs.
- Update this plan to make Step 3 current.

## Step 3 — Exact preview and commit planning

Status: **complete**

Progress:

- [x] Add captured-window exact action and Custom Zone plans in
  `WindowCoordinator`.
- [x] Prove exact previews do not cycle, record history, or mutate frames.
- [x] Add the model preview result and Manual/Bento placement calculation.
- [x] Add exact model commit routing and result-pill failures.

Files:

- Update `Sources/BetterTileMacOS/WindowCoordinator.swift`.
- Update `Tests/BetterTileMacOSTests/WindowCoordinatorTests.swift`.
- Update `Sources/BetterTileApp/BetterTileModel.swift`.
- Reuse the existing Bento planner tests; add focused cases only when a new
  pure decision is introduced.

Work:

- Extract the common coordinator planner so keyboard shortcuts can keep
  cycling while Layout Wheel requests an exact action for a captured
  `WindowID`.
- Add a non-mutating exact preview path. Preview must not change shortcut-cycle
  state, history, configuration, Layout Sessions, or real frames.
- Revalidate the captured window and display on every preview and commit.
- Build Manual previews from the exact action or Custom Zone.
- Build Bento previews with the existing `BentoDropPlanner`, including all
  affected placements, without committing its proposed state.
- Add one model command entry point that routes exact actions and Custom Zones
  through existing permission, application-rule, Manual/Bento transaction,
  rollback, settlement, and result-pill behavior.
- Route Repair Bento to the existing repair implementation only when the
  captured display's active mode is Bento. Otherwise publish the pill error.

Tests:

- Exact Left always means Left Half and never advances the shortcut cycle.
- Hover followed by cancel leaves history, session state, and frames unchanged.
- A captured window can be previewed by ID and a missing target becomes
  unavailable.
- Manual preview matches the committed target.
- Bento preview reports every proposed placement but does not commit state.
- Ignored applications, absent permission, invalid zones, and unavailable
  Repair Bento fail before mutation.

Completion criteria:

- Coordinator and Bento-focused tests pass with the fake window system.
- No Layout Wheel caller writes a frame directly.
- Update this plan to make Step 4 current.

## Step 4 — Shared glass wheel renderer

Status: **complete**

Files:

- Add `Sources/BetterTileMacOS/LayoutWheelView.swift`.
- Add renderer-focused tests where geometry or accessibility state can be
  asserted without snapshot fragility.

Work:

- Render the one- or two-ring wheel from configuration and current selection.
- Use one source of ring geometry for drawing and hit testing.
- Use macOS 26 public Liquid Glass where it behaves correctly in a transparent
  nonactivating panel. Keep an `NSVisualEffectView` material fallback for any
  documented glass limitation found during validation. Reduce Transparency
  uses an opaque semantic surface instead of either effect.
- Derive concise labels and consistent SF Symbols from commands.
- Keep the center Cancel affordance and current command label legible against
  arbitrary desktop content.
- Distinguish selected, unavailable, Empty, keyboard-focused, and normal states
  with shape/contrast as well as color.
- Support light, dark, Increase Contrast, Reduce Transparency, and Reduce
  Motion from the first renderer.

Completion criteria:

- The same renderer can be hosted by Settings and a transparent `NSPanel`.
- One- and two-level SwiftUI previews render without clipping at the minimum
  Settings window size.
- VoiceOver exposes a label, position, availability, and assigned command for
  every sector.
- Update this plan to make Step 5 current.

## Step 5 — Layout Wheel settings destination

Status: **current**

Files:

- Update `Sources/BetterTileApp/SettingsView.swift`.
- Add `Sources/BetterTileApp/LayoutWheelSettings.swift`.
- Add the new app source to `BetterTile.xcodeproj/project.pbxproj`.

Work:

- Add **Layout Wheel** under Window Management with complete search keywords.
- Use a grouped `Form` informed by Vorssaint's Superkey information
  hierarchy, without copying its wording, styling, icons, spacing, or trade
  dress.
- Put enablement and a short hold-move-release explanation first.
- Show the actual wheel renderer as the editor. Clicking a sector selects it;
  an adjacent inspector assigns Empty, grouped `WindowAction`, Custom Zone,
  or Repair Bento.
- Add the One Level/Two Levels control. Hide rather than delete outer settings.
- Add selectable modifier keycaps for Control, Option, Shift, and Command.
  Keep the last two selected modifiers enabled so the saved state is valid.
- Add the opt-in Middle Click toggle and this warning before enablement:
  “When enabled, BetterTile reserves middle-click system-wide. Other apps will
  not receive middle-click until you turn this off.”
- Show concrete inline registration or permission failures beside Activation.
- Add Restore Defaults for Layout Wheel only.

Completion criteria:

- Every setting is keyboard and VoiceOver operable.
- The editor never executes a window command.
- Configuration persists immediately through the existing model path.
- Search finds the destination for wheel, layout, radial, middle click,
  Control Option, trigger, and shortcut queries.
- Settings is visually checked at minimum size, light/dark appearance, Increase
  Contrast, and Reduce Transparency.
- Update this plan to make Step 6 current.

## Step 6 — Modifier gesture and runtime panel

Status: **pending**

Files:

- Add `Sources/BetterTileMacOS/LayoutWheelController.swift`.
- Add `Tests/BetterTileMacOSTests/LayoutWheelControllerTests.swift`.
- Update app lifecycle wiring in `Sources/BetterTileApp/BetterTileApp.swift`.

Work:

- Monitor configured modifier transitions and pointer movement with public
  APIs. Do not register a fake ordinary hot key for a modifier-only trigger.
- Start a cancelable 220 ms activation task. Any non-modifier key cancels it
  and leaves existing shortcuts untouched.
- Capture the focused eligible window and pointer anchor when activation
  succeeds.
- Present a borderless, nonactivating panel without stealing application focus.
- Clamp the visible wheel to the active display while retaining the original
  pointer as its selection anchor.
- Apply a small pointer-ownership threshold, then use the Core geometry for
  sector selection.
- Show non-mutating placement previews. Release commits exactly once; hub,
  dead band, Empty, Escape, target loss, deactivation, or trigger
  reconfiguration cancels.
- Arrow keys move through the active ring, Tab switches rings, Return commits,
  and Escape cancels.

Tests:

- Pending activation, early release, conflicting key, successful hold, pointer
  jitter, ring changes, commit, and every cancellation path.
- Exactly-once commit despite duplicate release/deactivation events.
- Existing Control + Option action shortcuts still execute without a wheel
  flash.
- Multi-display clamping does not change the angular anchor.
- Target destruction or loss never applies to a replacement window.

Completion criteria:

- Keyboard-triggered Layout Wheel works end-to-end in Manual and Bento modes.
- Existing shortcuts, drag snapping, and linked resize focused tests pass.
- Update this plan to make Step 7 current.

## Step 7 — Opt-in middle-click reservation

Status: **pending; security approval gate**

Files:

- Add the smallest dedicated middle-button event-tap implementation beside
  `LayoutWheelController`.
- Add focused tests under `Tests/BetterTileMacOSTests/`.
- Update `SECURITY.md`, `Sources/BetterTileApp/SetupAssistantView.swift`,
  and the Settings permission disclosure.

Work:

- Implement the Security decision above with public `CGEventTap`.
- Reuse the keyboard gesture state machine after translating middle-button
  down/drag/up into the same semantic press/move/release events.
- Add an independent disable user default for recovery and document it.
- If creation or recovery fails, turn off runtime middle-click activation,
  preserve the user's preference for a later retry, and show a result-pill or
  inline Settings failure. Do not let the source app receive a click that also
  triggered a Layout Wheel command.
- Measure delivery latency and verify left-button consumers remain unchanged.

Tests:

- Button 2 is consumed only while enabled.
- Other extra buttons and every left/right event pass through unchanged.
- Failure and timeout recovery leave no half-active gesture.
- Keyboard activation remains available when the middle-button tap fails.
- Disabling the option tears down the tap and restores ordinary middle-click.

Completion criteria:

- The written security review and disclosures match the implementation.
- A signed-build manual check confirms the option needs no Input Monitoring
  prompt and appears in no new privacy list.
- Browser tab opening/closing and a canvas application's middle-button behavior
  work normally before enablement and are predictably reserved after it.
- Maintainer approves the final event scope.
- Update this plan to make Step 8 current.

## Step 8 — App lifecycle integration and accessibility

Status: **pending**

Files:

- Update `Sources/BetterTileApp/BetterTileApp.swift` and focused UI files.
- Update architecture documentation only if the implemented seam differs from
  the approved design above.

Work:

- Start, update, suspend, and stop Layout Wheel monitors with application
  lifecycle, shortcut recording, configuration changes, permission changes,
  and sibling-app exclusion.
- Reuse the existing placement preview and result-pill visual language. Extract
  shared preview code only now that there are two real callers.
- Verify Reduce Motion removes scale/movement, Reduce Transparency is opaque,
  Increase Contrast strengthens separators, and unavailable state does not rely
  on color.
- Ensure VoiceOver and keyboard users can configure and operate every
  non-pointer path.
- Ensure the wheel joins appropriate Spaces without appearing in screenshots or
  apps where BetterTile is inactive.

Completion criteria:

- No monitor survives feature disablement or app shutdown.
- No preview survives cancel, commit, target loss, Space change, or display
  removal.
- Accessibility and lifecycle manual checks are recorded in the work log.
- Update this plan to make Step 9 current.

## Step 9 — Full verification, documentation, and pull request

Status: **pending**

Work:

- Run XcodeBuildMCP `session_show_defaults` before the first Apple build/test
  action. Configure `BetterTile.xcodeproj` and scheme `BetterTile` only if
  defaults are missing or wrong.
- Run the complete Swift package tests with XcodeBuildMCP.
- Run an unsigned Debug macOS build with XcodeBuildMCP and
  `CODE_SIGNING_ALLOWED=NO`.
- Build and run the signed Debug app for manual behavior only when the local
  signing context is available.
- Manually verify one/two levels, every trigger, every cancellation path,
  Manual/Bento previews, all display edges, Spaces, target loss, light/dark,
  Increase Contrast, Reduce Motion, Reduce Transparency, VoiceOver, keyboard
  operation, and the middle-click security checks.
- Update screenshots or user documentation only if the repository already has
  a maintained destination for them.
- Run a standards-and-spec review against `origin/main`. Fix confirmed faults.
- Push `feat/layout-wheel` and open a ready pull request with complete checks,
  skipped checks, security disclosure, provenance, and manual evidence.

Completion criteria:

- All required automated checks pass.
- Every manual check is recorded as passed or explicitly skipped with a reason.
- The working tree contains only intended files.
- CI passes, automated review is handled, and the ready pull request URL is
  recorded below. Merge still requires maintainer approval.

## Work log

### 2026-08-28

- Completed primary-source and repository research with a Luna research pass
  and Sol verification.
- Settled the product contract with the maintainer.
- Chose Layout Wheel as the canonical term and updated `CONTEXT.md`.
- Corrected the middle-click design: a passive AppKit monitor cannot meet the
  consume invariant; Step 7 uses an opt-in suppressing public event tap.
- Created this resumable plan and branch `feat/layout-wheel`.
- Completed Step 1. Added deterministic one/two-level geometry and six focused
  tests. XcodeBuildMCP reported 6 focused tests and all 429 package tests
  passing.
- Completed Step 2. Added the schema-10 Layout Wheel configuration, defaults,
  safe normalization, dangling-zone cleanup, runtime change classification,
  and migration/round-trip tests. XcodeBuildMCP reported 31 configuration
  tests and all 433 package tests passing.
- Started Step 3. `WindowCoordinator` now plans exact actions and Custom Zones
  for a captured window ID without touching shortcut cycling or history. Four
  focused tests cover capture, cancel-safe preview, Custom Zone preview/commit,
  and target loss.
- Completed Step 3. `BetterTileModel` now returns non-mutating exact Manual or
  Bento previews and replans captured-window commands before commit. Manual,
  Bento, Custom Zone, and captured-display Repair Bento commands reuse the
  coordinator, Bento planner, rollback, settlement, and result-pill paths.
  Known Layout Wheel failures now receive concise result-pill messages. All
  437 package tests pass, and the unsigned Debug macOS app builds successfully
  through XcodeBuildMCP.
- Completed Step 4. `LayoutWheelView` in `BetterTileMacOS` renders one or two
  rings from configuration and current selection. `LayoutWheelMetrics` holds
  the radii once and exposes the Core `LayoutWheelGeometry`, so drawing and hit
  testing cannot drift apart. Sectors distinguish selected, unavailable, Empty,
  keyboard-focused, and normal states by fill, stroke weight, and dash pattern
  as well as colour, and every sector speaks its direction, ring, command, and
  availability. Reduce Transparency swaps glass for opaque semantic surfaces
  and Reduce Motion removes the selection scale. Passing `onSelect` makes
  sectors focusable buttons for Settings; the runtime panel omits it. Nine
  focused tests cover symbol resolution, slot derivation, accessibility text,
  drawing-to-hit-testing agreement, and hosting in both an `NSHostingView` and
  a transparent nonactivating `NSPanel`. All 446 package tests pass and the
  unsigned Debug macOS app builds.
- Deferred the `NSVisualEffectView` fallback. Step 4 found no glass limitation
  to work around; Step 6 validates glass in the live panel and adds the
  fallback only if that validation finds one.
