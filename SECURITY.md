# Security Policy

## Reporting a vulnerability

Report security or privacy concerns privately through
[GitHub Security Advisories](https://github.com/LMC-Karma/BetterTile/security/advisories/new).
Please do not open a public issue containing sensitive details.

Include what you observed, how to reproduce it, and the macOS version you saw
it on. You can expect an initial response within a few days.

## Security and privacy commitments

BetterTile is a free utility. It has no paywall, subscription, advertising,
behavioral tracking, or sale of user data. BetterTile does not monetize window,
configuration, diagnostic, or usage data. Window geometry and configuration
stay on the Mac; update checks send no window data, configuration, analytics,
telemetry, crash reports, or system profile. Product behavior and material data
handling are disclosed in this repository.

If an existing configuration cannot be read, decoded, or validated, BetterTile
preserves the file and blocks all configuration saves for that session. Settings
explains the failure. Changes still apply for the session. To resume saving,
restore a valid configuration file, then quit and reopen BetterTile. Only a
confirmed missing file permits defaults with normal saving. BetterTile creates
no recovery copy and does not automatically retry a failed load.

Two platform-safety boundaries are permanent:

- do not inject code into other processes
- do not bypass System Integrity Protection

Public Apple APIs are the default. A private API may be considered only after
an explicit design discussion in an issue or draft pull request confirms that
it fits BetterTile's product goals and that no adequate public API provides the
same user benefit. The discussion must cover the API's scope, failure and
compatibility risks, security and privacy impact, distribution implications,
maintenance cost, testing plan, and a safe fallback when the API is unavailable
or changes. Adoption requires maintainer approval and repository disclosure.

Other implementation choices may evolve when the user benefit justifies them.
Changes are evaluated against security, privacy, transparency,
maintainability, and user benefit rather than a blanket technology ban.

## Debug arrival diagnostics

Debug builds can record local window-arrival timing when the maintainer enables
`BetterTileArrivalTrace` in the app's UserDefaults before launch. The default is
off. Release builds contain no arrival trace. The trace helps separate app
startup, unreadable windows, scheduling, minimum-size probes, and placement.
It adds no Accessibility reads, permissions, dependencies, or networking.

The JSONL file is `~/Library/Logs/BetterTile/arrival-trace.jsonl`. Records contain
monotonic timestamps, a random trace-run ID, process-local window IDs, PIDs,
opaque AX element hashes, logical-point frames, layout modes, and phase outcomes.
They contain no window titles, document paths, or app names. New files use owner
read/write permissions. Encoding and writes run on a serial utility queue.
The file is appended across runs and remains until the tester removes it.
There is no upload, rotation, or automatic purge. Enable it only for bounded
local trials; inspect the file before sharing it. Fake-system tests cover the
disabled path and phase ordering. Live capture and timing remain manual checks.

## Private window observations

[Design issue #32](https://github.com/LMC-Karma/BetterTile/issues/32) approves
the following read-only observations for macOS 26. BetterTile resolves private
symbols at runtime. A missing symbol or rejected value uses the public fallback
and never prevents launch.

| API or attribute | Purpose | Validation and fallback |
| --- | --- | --- |
| `_AXUIElementGetWindow` | Join an Accessibility window to its exact WindowServer ID. | Accept a nonzero ID only. Validate it against the same PID, layer zero, and on-screen WindowServer record. Fall back to PID and frame correlation. |
| `AXMinSize`, `AXMinimumSize` | Read an application's stated minimum window size. | Accept only finite, positive values no larger than the containing display. Merge accepted values with BetterTile's default and learned minimums by greatest dimension. Ignore malformed or unavailable values. |
| `SLSMainConnectionID`, `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows` | Observe display Spaces and window membership for runtime Bento sessions. | Require complete current-Space coverage and valid typed IDs and containers. Empty membership stays unknown, multi-Space windows float, and fullscreen Spaces suppress automatic writes and dividers. Fall back to inferred session matching when any symbol or topology is unavailable. |
| `AXWindowIDs` | Resolve a Stage Manager thumbnail to one real member window. | Follow only the bounded WindowManager group/list/button hierarchy. Validate IDs with targeted WindowServer records, reject WindowManager-owned, nonzero-layer, stale, and unknown-owner records, then select the frontmost valid member. Fall back to ordinary hit-testing when the hierarchy or value is unavailable. |

Exact identity and native Space identity stay process-local. BetterTile includes the owning PID and an
application launch generation in each identity record. It retains AX hashes
only to correlate observer callbacks. Logs contain capability availability and
one-time fallback reasons, never titles, AX identifiers, raw desktop topology,
or Stage Manager contents.

Tabbed reuses the approved exact window identity, with public APIs
only. AppKit orders BetterTile's own shared Tabbed curtains, tab strips, and empty
panes relative to selected windows. `CGWindowListCopyWindowInfo` supplies the
front-to-back order of on-screen normal-level windows, with their numbers,
owning PIDs, and bounds; BetterTile reads no window titles from it. When a
inactive tab is in front of any selected tab, the Accessibility raise
action restores the order without activating an application. The adapter
checks the owning PID, layer zero, and on-screen record before using a window
number. The shared curtain needs validated identities for every tab and
a verified order. If those checks fail, the display has no curtain; chrome
without an identity floats as before. Unsafe order repairs do not run.
This adds no private
symbols, permissions, screen capture, or stored window identifiers.

Divider coverage also reads the public on-screen window list. It uses only
window number, owner PID, layer, alpha, and bounds. These values determine
which foreign windows at or below the handle's floating level cover a layout
seam. It never reads window titles or captures pixels. Exact identities are
labelled only when the known owner PID matches. Coverage is transient, adds
no permission, and falls back to the existing obscuring frames if the read
fails or any requested layout member lacks a validated exact identity. This
also keeps dividers usable when private APIs are disabled. It does not guess
an identity from PID and frame. Known exact identities that are absent from
the on-screen list do not force this fallback. Hover caches the result for at
most 150 ms; an active drag retains its starting coverage until release.

BetterTile reads the Dock's `orientation` and `autohide` preferences. When
Leave space for Dock is on, which it is not by default, or when the Dock never
hides, it also reads the position and size of the Dock's Accessibility list,
at most once a second, through public APIs only. It reads no Dock item names.
It keeps the last measured thickness for each Dock edge in its own user
defaults, so a Dock not yet shown after login still gets its space. With the
setting off and the Dock hiding automatically, BetterTile does not read the
Dock list.

The `defaults` commands below use the public app's domain. For BetterTile Debug,
replace `com.lmckarma.BetterTile` with
`com.lmckarma.BetterTile.debug`; its preferences are intentionally separate.

All private capabilities can be disabled before launch with:

```sh
defaults write com.lmckarma.BetterTile disablePrivateAPIs -bool true
```

Quit and reopen BetterTile after changing the default. Restore automatic use
of validated private capabilities with:

```sh
defaults delete com.lmckarma.BetterTile disablePrivateAPIs
```

## Network disclosure

BetterTile contacts `github.com` over HTTPS to fetch the public Sparkle appcast
from `LMC-Karma/BetterTile/releases/latest/download/appcast.xml` and when the
user chooses to download a release archive. GitHub may redirect release assets
through its delivery infrastructure. These requests necessarily expose ordinary
connection metadata such as the requesting IP address to GitHub. Automatic
checks default to every four hours while BetterTile is running and can be
disabled in Settings. Sparkle system profiling is disabled.

BetterTile stores only the public display version and build number of a known
available update in local user defaults so its reminder survives a relaunch.
It clears that state after the update is installed, skipped, or no longer
available.

Update archives are authenticated by an EdDSA signature that Sparkle verifies
against the public key built into the application. That verification is
independent of the application's macOS code signature.

The Xcode Debug configuration builds **BetterTile Debug** with bundle identifier
`com.lmckarma.BetterTile.debug`. Sparkle remains embedded because Debug and
Release share one target, but Debug supplies no feed URL and does not create an
updater controller or show update controls. It therefore performs no update
network requests. Release keeps the public feed and updater behavior described
above.

### Send Feedback

The **Send Feedback…** menu item opens
`https://github.com/LMC-Karma/BetterTile/issues/new` in the user's default
browser. The URL carries exactly two query parameters:

- `template=bug.yml`, which selects the public bug report form
- `title`, a proposed issue title containing the BetterTile marketing version
  and build number, for example `[Bug] BetterTile 0.1.0 (2): `

Opening the page is itself a request to GitHub: it sends those two query
parameters, so GitHub receives the BetterTile version and build, along with the
ordinary connection metadata any web request carries, such as the requesting IP
address. No issue is created and no form body is submitted until the user fills
the form in and submits it themselves, and the user can edit or delete every
field first.

Beyond the version and build in the title, BetterTile places no window
information, layout or Bento state, configuration, shortcuts, diagnostics,
analytics, telemetry, crash reports, system profile, or any other user or
machine data in the URL. This is covered by an automated test.

Any future network feature must serve a documented user-facing purpose,
minimize transmitted data, use secure transport, and document its endpoints
and payload purpose here before release. Optional diagnostics require a
separate design decision, informed opt-in, documented retention, and a clear
off switch.

## Permissions and dependencies

The application picker reads names and bundle identifiers from running apps and
from application bundles in `/Applications`, `/System/Applications`, and
`~/Applications`, including Utilities. The installed list leaves out
background-only and agent apps and apps inside another app or a helper folder.
The installed-app catalog is cached in memory for five minutes. Browse uses the
system application-file picker and can still choose any app. These operations
request no new permission and send no data. Per-App Rules shows window titles
from the model's existing observations; it makes no additional Accessibility
reads and does not persist those titles or the app catalog.

The picker's **Recent** section stores the bundle identifiers of the last eight
apps chosen in any BetterTile app picker, newest first. It stores no app name,
path, window title, or time. The list is kept in BetterTile's own `UserDefaults`
under `recentApplicationBundleIdentifiers` (Debug and Release are separate), is
never uploaded, exported, or logged, and stays until a later choice pushes an
entry out. To clear it, quit BetterTile and run
`defaults delete com.lmckarma.BetterTile recentApplicationBundleIdentifiers`
(`com.lmckarma.BetterTile.debug` for Debug).

The Tabbed pane **Add App** picker uses that same catalog. Choosing an app
requests a new window first. A stopped app opens through public
`NSWorkspace.openApplication(at:configuration:)`, without activation, a new
process-instance flag, custom arguments, documents, URLs, or Apple events.
Launching an app does not guarantee a window. For a running app, the
coordinator first looks for an enabled **New Window** Accessibility menu item
with the public `AXPress` action. Otherwise it looks for Command-N using
`AXMenuItemCmdChar` (`N` or `n`) and `AXMenuItemCmdModifiers` equal to 0
(Command alone). Shift, Option, Control, missing modifier values, and the
NoCommand bit do not qualify. File is the first top-level menu after the
application menu, identified by position rather than the File title. The app's
localized name identifies its application menu even when Apple precedes it.
Bare Command-N qualifies only in this positional File menu. If that anchor is
unavailable, bare Command-N never qualifies. Complete window-title commands
retain their unique-match fallback across top-level menus. Without a safe
command, BetterTile uses reopen.
Discovery reads at most 32 menu-bar entries and 128 direct items per menu,
on a background task with a 0.5-second deadline. Before each read it sets the
public AX messaging timeout to at most 50 ms, bounded by the remaining budget;
it retains the existing hung-app gate. It opens no menu or submenu to discover lazy items. Disabled, ambiguous, missing,
or failed commands use the reopen or existing-window fallback. The selected command is
read and validated again before `AXPress`. No keyboard events are injected.

Choosing an app automatically requests a window without a consent question.
Exact **New Window** takes priority, then a recognized complete window title
(English **New Finder Window** / **New Viewer Window**, and the existing small
French, German, Spanish, Italian and Japanese **New Window** table), then a
allow-listed command-only ⌘N. Its title must be exactly **New**, **New Document**,
**New File**, or a recognized window title. The small generic-document table
also accepts French **Nouveau / Nouveau document / Nouveau fichier**, German
**Neu / Neues Dokument / Neue Datei**, Spanish **Nuevo / Nuevo documento /
Nuevo archivo**, Italian **Nuovo / Nuovo documento / Nuovo file**, and Japanese
**新規 / 新規書類 / 新規ファイル** in that system language. Every other title,
including **New Recording**, **New Event**, **New Card**, **New Note**, and
**New Message**, uses reopen, then **Use a window from this desktop** if no
eligible new window arrives. TextEdit's New Document can show an Open panel,
which is never auto-placed.

BetterTile stores no command answer. If no safe
menu command exists, BetterTile validates the selected process and bundle URL,
asks macOS to reopen the existing app through `NSWorkspace.openApplication`
at the running process's validated bundle URL, not a different installed or
browsed copy. The pane request disables activation and makes no preliminary
activation call. The request sends no custom arguments, documents, URLs or
Apple events, and does not request a new process instance. One request
dispatches at most one successful open operation: a dispatched command is never
followed by reopen. Reopening can restore a window or switch desktops; placement
cancels if the destination changes. A running app has 10 seconds to open a new eligible window; a cold launch has
30 seconds. Without an arrival, it offers **Use a window**.

Several instances use the active instance, then the frontmost instance in the
public on-screen window list. Without either, BetterTile offers explicit window
choices and reports **Several copies are running**. This reads process IDs and layers, never titles
or pixels. The pane publishes **Opening…** before asynchronous window inventory
or menu discovery. Automatic placement raises the new window only while the
user's request focus intent remains current. One MainActor-owned in-memory
record coordinates intent across all pending pane requests.
It knows their targets and expected launch, menu and reopen activations. Those
activations cannot become another request's user choice. Failed operations
clear their expectation; completion and cancellation unregister the request.
A genuine activation of another app suppresses raising, including if the user
later returns to the source app. The coordinator checks this after frame writes.

A fresh hit-tested mouse-down on any window, including a target, records the
latest user choice even when that app is already frontmost. The shared
listen-only event tap and its existing AppKit left-mouse-down fallback both
forward these choices. Observation remains enabled while any request is pending,
even with snapping and linked resizing off. The hit-tested window must contain
the point. The event must be within the request lifetime and no more than one
second old. Pointer
points and event timestamps remain transient.

After successful automatic pane placement, the shared record can restore the latest user app. The
coordinator sets the public Accessibility frontmost attribute on the chosen
process: the clicked window's process, or the process that activated. BetterTile
is inactive at that moment, and since macOS 14 a public
`NSRunningApplication.activate` request from an inactive app can be declined.
That request is only the fallback when Accessibility refuses. Without a known
process, only a single running copy of the app qualifies. A qualifying completed request keeps
its in-memory helper for at most two seconds after placement or the terminal
state, whichever is later. One expiry task releases it. A later target
activation can trigger the same one-shot restore during that window.
Restoration requires a requested target frontmost and a different latest user
choice. Explicit target clicks and newer app choices take precedence across
requests. Each genuine choice permits at most one restoration attempt across
all requests. The attempt is consumed before activation, and its activation is
expected rather than a new choice. A later target activation alone cannot
authorize another attempt.

The public keyboard-event counter (`CGEventSource.counterForEventType` with
`.combinedSessionState` and `.keyDown`) distinguishes newer keyboard switches to
a target and suppresses restoration after other newer keyboard input. Mouse
clicks, activation notifications and modifier-only events do not increment it.
Each recorded user choice takes a new baseline. BetterTile
reads only the aggregate count, not key codes, characters, event payloads or
text. Typing in Source can therefore conservatively leave a later self-activating
target frontmost. No keyboard event tap or repeated activation is added.
`request-focus` debug and info logs include the aggregate count, bundle IDs,
process IDs, request phase, choice source, restore reason and activation
result. They contain no window title, pointer point, key code, character or app
content. No intent or input history is persisted by
BetterTile. No permission, dependency, private API or network request is added.

The pane picker and Layout Gallery use BetterTile-owned nonactivating panels.
Showing or dismissing either panel does not activate BetterTile or restore a
previous app. Clicking a search field can give its panel keyboard focus without
activating BetterTile. The panels stay on their opening Space and close when
their pane, display, Space or Tabbed mode ends. For outside-click dismissal,
`SharedGestureEventMonitor` forwards the existing listen-only left mouse-down
point. If that tap is unavailable, `DragSnapController` forwards its existing
global NSEvent left-mouse-down monitor for other apps instead. Global AppKit
monitors do not receive BetterTile's own events. While either chooser is open,
its presenter also installs a local NSEvent left/right mouse-down monitor for
BetterTile windows and a global right-mouse-down monitor for other apps. The
local monitor observes synchronously before control dispatch and returns the
event unchanged. Dismissal removes both temporary monitors. The existing left
observation paths remain enabled even if snapping is off. Each path compares
only the transient screen point and timestamp with the panel frame and opening
time; inside clicks and delayed opener samples do not dismiss it. This adds no
permission, private API, saved pointer history or networking. Escape closes a
panel that has keyboard focus.

One in-memory request holds the chosen app's name, bundle identifier and bundle
URL; PID and launch date; destination display, pane, session, current Space and
generation; existing and arriving window identities and their request-local
arrival order; and a 10-second running-app or 30-second cold-launch deadline.
The public launch and menu APIs return no causal window identity. The user-approved
automatic policy accepts the first eligible new window ID in creation order
(or first-observed order without creation evidence) from the requested
process within the request deadline. Pane requests exclude every baseline
identity, other displays and desktops, multi-Space windows, dialogs, sheets and
fixed-size windows. For a running process, an exact creation callback or a resolved
creation-element token must identify the new ID after the request starts. A
restored pre-existing window cannot authorize automatic placement. After a new
process launch, its first eligible window can be placed without a callback.
Placement uses the existing coordinator transaction and brings the placed window
forward. This correlation is bounded policy, not proof that AXPress caused the
window; a concurrent new document of that same process can qualify.

Choosing an app closes the picker and shows progress in its pane. Existing or
unconfirmed windows retain explicit **Use here** / **Place window** choices.
The existing listen-only gesture stream can also confirm an unverified arrival
with hit-tested mouse-down, mouse-up within 4 points, and a focused-window read
250 ms later. Focus alone does not authorize that fallback choice. Points and
times stay only in memory. There is no new permission. With the shared tap off
or unavailable, the AppKit fallback also adds listen-only left-mouse drag and
mouse-up monitors while a request is pending, so that click can complete. The
picker
can expand current-desktop windows inline. Titles come from current observations
and are never saved. **Show App** activates the validated process. While choices
are offered, further arrivals remain reserved outside the layout.
Choices revalidate eligibility, app, current display and current-desktop membership through preflight and delayed placement. Picker
choices receive no cross-display drag exemption.

Cancel, owner loss, timeout and failed requests discard the destination. A
30-second in-memory guard retains the app identifier, PID/launch date when
known, and baseline window identities. On Tabbed desktops, newly observed windows of that request
stay floating, without measurement or frame writes, and another creation for
the same app waits for that guard to expire. The pane's explicit **Try Again**
action can repeat the request while retaining the earlier guard. Offering choices leaves this guard because the dispatched request may still
create another window. Successful automatic or explicit placement retains the
guard for further arrivals. After expiry, ordinary arrival
policy resumes; already observed floats remain floating. These records, titles and choices are never saved or logged.
Shutdown clears them. Cancelling does not quit the app or close its windows.
Placement and frame/layout Undo use the existing coordinator transactions;
Undo cannot reverse application launch or window creation.

**Launch at login** in General registers the BetterTile app itself as a login
item with the public `SMAppService.mainApp` API, only when the user turns the
switch on, and unregisters it when the switch is turned off. It adds no helper,
daemon, agent, privileged component or permission. macOS stores the state and
may ask the user to allow it in System Settings › General › Login Items; the
switch then offers that pane. BetterTile's configuration does not store it.

Accessibility is the only macOS permission BetterTile requests. A new
permission or privileged component requires an explicit design review,
least-privilege justification, repository documentation, and an in-product
explanation before the system prompt appears.

BetterTile attempts one public, listen-only session `CGEventTap` for global
left-button gesture ordering only after Accessibility access is present. It
never calls the API that requests Input Monitoring. If the existing grant is
insufficient, tap creation fails, or a disabled tap cannot be re-enabled, both
gesture consumers return to their public `NSEvent` monitors automatically.
The tap copies only scalar position, button, modifier, timestamp, and event-kind
values to the main actor. It neither changes nor retains system events.

The main actor uses public `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`
hit testing at mouse-down to keep BetterTile's AppKit controls out of native
window dragging and linked resizing. It compares the returned number only with
BetterTile's own windows and skips its click-through drawing. No foreign title,
geometry, or content is read. The number is discarded immediately; one Boolean
retains input ownership through release. Chooser and application-request
observations still receive those events. This adds no permission, private API,
dependency, log, persisted identity, or network use.

The tap can be turned off before launch, which returns both gesture consumers to
their `NSEvent` monitors:

```sh
defaults write com.lmckarma.BetterTile disableSharedGestureEvents -bool true
```

Quit and reopen BetterTile after changing the default. Restore the tap with
`defaults delete com.lmckarma.BetterTile disableSharedGestureEvents`.

When Layout Wheel's keyboard trigger is enabled, BetterTile uses matching local
and global AppKit monitors for modifier changes. The pair keeps the trigger
available whether BetterTile or another app receives the event. Matching key
monitors exist only from the start of the activation hold through the end of
that gesture. Matching pointer monitors exist only while the keyboard-triggered
wheel is open. A Right Control hold also installs local and global left/right
mouse-down monitors while pending or open. They use only the event kind and
cancel the hold so Control-click cannot apply a wheel command. They pass clicks
through and retain no events. Global monitors and the local modifier and pointer
monitors are observation-only. While the wheel is open, the local key monitor consumes only
Escape, Return, Tab, and arrow keys after the wheel handles them, so they do not
also activate BetterTile's own focused Settings controls. Other local keys pass
through, and no event delivered to another application is changed. The monitors
retain no system events and forward only the modifier set, key code, or pointer
position needed by the gesture state machine.

Layout Wheel activation diagnostics use the local unified log's `LayoutWheel`
category at debug level. Each hold records a process-local counter, scheduling
and deadline milestones, elapsed milliseconds, and one open, cancellation, or
skip outcome with a fixed reason. An open adds the wheel style, its size scale,
and whether a focused window was captured. An ignored trigger adds whether the
trigger is enabled, armed and idle. A release adds the number of pointer samples
received. These values distinguish delayed notifications and monitor failures
from a missed deadline. They contain no key codes, modifier values, pointer
positions or distances, selected commands, app or window identities, titles, or
event content. They add no
input monitoring, permission, file, upload, or persisted configuration.

Tabbed mode installs local and global AppKit key monitors while a tab drag or
pane divider resize is in progress. They are removed when the gesture ends,
is cancelled, or the pane overlay hides. Auto-hide tab bars also install a
local and global key-monitor pair while any bar is revealed, so Escape can
dismiss the bars while the selected app keeps focus. That pair is removed
when all bars collapse, the presentation changes, or the overlay hides.
Both pairs forward only the key code. Escape cancels the gesture or dismisses
the bars; global monitors only observe it, and local monitors consume Escape
and pass other keys through. No other keys are acted on or retained.
The Auto-hide local monitor passes Escape through while a Tabbed chooser is
key, so its field editor can cancel composition or clear search before closing.

While a Tabbed desktop uses Auto-hide, its overlay also installs a local and a
global AppKit pointer monitor for mouse-moved and left and right mouse-dragged
events. The pair exists the whole time Auto-hide is active, not only while a bar
is revealed, so it receives every pointer move in every app. Each display with an
Auto-hide desktop has its own pair. For each event, the overlay reads only the
current pointer location and compares it with the strip areas. It reads no other
event content, and it does not change or consume the event. It retains no event
and no pointer location; only the strip's revealed or hidden state remains. The
pair is removed when the presentation leaves Auto-hide, when the desktop's Space
becomes inactive, and when the overlay hides. The monitors add no permission and
no prompt.

Layout Wheel also has an independent, disabled-by-default Middle Click trigger.
The user benefit is one-handed wheel activation. While the option is enabled,
BetterTile creates a dedicated public session `CGEventTap` for
`otherMouseDown`, `otherMouseDragged`, and `otherMouseUp`. It suppresses only
physical button 2 with the selected modifier predicate: no ordinary modifiers
for Middle click, or Option alone for Option + Middle click. The latter keeps
plain middle-click available to other apps. Every other button and modifier
combination passes through. The choice is opt-in and mutually exclusive. The
tap captures ownership at button-down and reserves drag/up even if Option is
released during the gesture. Keyboard activation blocks new mouse reservations;
a reserved mouse gesture blocks keyboard activation through its button-up. The tap forwards only scalar position, button,
modifier, timestamp, and event-kind values. It does not retain the system
event.

A disabled middle-click tap is re-enabled when no mouse gesture is reserved.
If recovery fails, the tap cannot start, or input continuity is lost during a
reserved gesture, BetterTile tears it down,
cancels any gesture it owns, and reports the failure in Layout Wheel Settings.
Keyboard activation remains available. The saved Middle Click preference is
preserved so BetterTile can retry after a later lifecycle or configuration
refresh. The separate recovery switch below prevents the suppressing tap from
starting without changing the saved preference:

```sh
defaults write com.lmckarma.BetterTile disableLayoutWheelMiddleClick -bool true
```

Quit and reopen BetterTile after changing the default. Restore automatic use
with
`defaults delete com.lmckarma.BetterTile disableLayoutWheelMiddleClick`.

BetterTile does not call the API that requests Input Monitoring for either tap.
Both taps have the signed-build validation recorded below.

The maintainer approved the expanded trigger scope: Option + Middle click changes the middle-click tap's suppression predicate, and
Right Control retains the virtual key code and raw side-specific flags.
It uses the public
`IOKit/hidsystem/IOLLEvent.h` masks and AppKit flags-changed events. Ambiguous
side identity cancels; it never falls back to either Control key. Right Control
remains hidden behind a validation flag until the actual keyboard and Jump
Desktop client have been checked. No additional event tap, permission, raw HID
access, network operation, or dependency is introduced.

The Option + Middle click extension has fake-system tests for the down-time
predicate, ownership through modifier changes, competing triggers, and failure
cancellation. On macOS 27.0.1, a signed Debug build applied Top Half in five
Option + Middle click trials and five Control + Option + Command trials with
a foreground fixture on the test display. Plain middle-click reached the fixture.
Mouse-first and keyboard-first ownership checks also passed. These trials used
synthetic system events; they do not validate physical Right Control identity or
Jump Desktop delivery. The approved scope covers Option + Middle click and
Right Control; physical keyboard and Jump Desktop validation remain required
before exposing Right Control without its validation flag.

Each tap has its own maintainer design and least-privilege review. The
left-button gesture tap is recorded in
[pull request #36](https://github.com/LMC-Karma/BetterTile/pull/36). The
suppressing middle-click tap is recorded in
[pull request #56](https://github.com/LMC-Karma/BetterTile/pull/56); pull
request #36 predates that tap and does not cover it.

Validation on macOS 26.5.2 confirmed that a personally signed build with
Accessibility granted created the left-button tap without an Input Monitoring
prompt and did not appear in the Input Monitoring application list. Validation
on macOS 26.6.2 confirmed the same behavior for the suppressing middle-click
tap. Middle-button events reached a browser canvas before enablement, were
reserved while enabled, and reached the canvas again immediately after
disablement. The Setup Assistant and Settings explain the observed event scope
before the Accessibility request.

Runtime dependencies are allowed after reviewing necessity, maintenance,
security history, license compatibility, update strategy, and removal cost.
Approved dependencies are pinned and recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Adapted code must have clear
provenance, compatible licensing, and attribution.

Sparkle is the sole current runtime dependency. It verifies BetterTile update
archives with an EdDSA signature. Its private signing key remains outside the
repository and GitHub Actions.

## Build-time Metal Toolchain

The Layout Wheel compiles its shader with Apple's Metal Toolchain, an Xcode
component. CI checks the selected Xcode first and installs it (download or
cached import) only when it is missing. It uses
`xcodebuild -downloadComponent MetalToolchain` and a SHA-pinned `actions/cache`
dependency. Exported components are keyed by Xcode version, runner OS and
architecture. Cache entries are branch-scoped. Only Apple's developer
tool downloads and GitHub Actions cache storage are used. No user data or
release signing credentials are involved. This is a build dependency under
Xcode's license, not an additional runtime package or app permission.

The setup fails if download or import fails. Shell regression tests cover cache
misses, reuse, invalid exports and command failures; Debug and Release builds
check shader compilation. Removing the CI cache only causes a fresh download.

## App icon customization

The App icon picker saves a local `BetterTileAppIcon` preference and changes
BetterTile's Dock and Finder icons through public AppKit APIs. A Finder
override writes generated icon data and Finder metadata at the running app
bundle's root. It requires a writable app and never requests elevation. A
failed write is reported in Settings when the user selects an icon, or resets
Startup to its default while an icon choice is saved; the saved choice remains
available for the Dock and for the next launch. A fresh install, and a reset
without a saved choice, do not replace a custom icon the user set outside
BetterTile.

This operation does not change the executable, Info.plist, signed resources,
or signing identity, and does not re-sign the app. Ordinary signature
verification passes in the isolated integration test. Strict signature
verification rejects the Finder metadata while a custom icon is active;
selecting the default Dark icon clears the override and restores strict
verification. Release packaging retains its existing strict checks. No
permission, private API, dependency, telemetry, or network request is added.
See [icon validation and limits](docs/icon-composer/README.md#finder-metadata-and-signature-checks).

## Distribution

Public beta builds are signed with the maintainer-held, self-signed
`BetterTile Beta` certificate. Its stable certificate requirement is intended
to let macOS recognize successive betas as the same application for
Accessibility. The 0.4.1 beta was the transition from the old ad-hoc identity;
later releases continue using the stable certificate unless it changes. The
certificate does not provide Apple developer attestation or notarization, so
first launch still requires **Open Anyway** in System Settings → Privacy &
Security. The transition release required one final Accessibility grant.

Sparkle independently authenticates update archives with the EdDSA key built
into the application. The self-signed code-signing certificate and its private
key are not stored in the repository or CI. Certificate rotation, loss,
compromise, or expiry breaks the stable application identity and requires a
warning and focused release tests.

The unsigned `CODE_SIGNING_ALLOWED=NO` builds produced by CI and by the release
script's internal build step are validation builds only and are never
distributed. The distributed signature is applied solely by
`Tools/release-beta.sh`; see [docs/RELEASING.md](docs/RELEASING.md).

Release signing credentials and their recovery details stay outside this
repository and CI. Publishing requires an authorized release environment and is
never automatic.

Release builds contain only arm64 code for BetterTile and require macOS 26.0
or later. Sparkle's appcast hardware requirement keeps Intel installations on
the last compatible universal release. Sparkle's embedded helpers remain
universal. The release executable is stripped before signing. Its matching
dSYM stays beside the local release artifacts, outside the app and DMG; it
contains full symbols and source paths and is not uploaded by the script.
Dry runs use a disposable EdDSA key file and a temporary app public key,
without reading the release signing key or changing tracked key material.

## Change disclosure

Pull requests must call out changes to networking, permissions, privileged
components, dependencies, user-data handling, distribution, updates, private
APIs, or architecture. Intentional architecture changes are permitted when
their rationale, documentation, migration impact, and tests are included.
