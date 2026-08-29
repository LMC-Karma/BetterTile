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

The tap can be turned off before launch, which returns both gesture consumers to
their `NSEvent` monitors:

```sh
defaults write com.lmckarma.BetterTile disableSharedGestureEvents -bool true
```

Quit and reopen BetterTile after changing the default. Restore the tap with
`defaults delete com.lmckarma.BetterTile disableSharedGestureEvents`.

When Layout Wheel's keyboard trigger is enabled, BetterTile uses an
observation-only AppKit monitor for modifier changes. A key monitor exists only
from the start of the activation hold through the end of that gesture. A
pointer monitor exists only while the keyboard-triggered wheel is open. These
monitors do not change or retain system events. They forward only the modifier
set, key code, or pointer position needed by the gesture state machine.

Layout Wheel also has an independent, disabled-by-default Middle Click trigger.
The user benefit is one-handed wheel activation. While the option is enabled,
BetterTile creates a dedicated public session `CGEventTap` for
`otherMouseDown`, `otherMouseDragged`, and `otherMouseUp`. It suppresses only
unmodified physical button 2. It passes modified middle-clicks and every other
mouse button unchanged. The tap forwards only scalar position, button,
modifier, timestamp, and event-kind values. It does not retain the system
event.

If the middle-click tap cannot start or recover, BetterTile tears it down,
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

The maintainer design and least-privilege review is recorded in
[pull request #36](https://github.com/LMC-Karma/BetterTile/pull/36). Validation
on macOS 26.5.2 confirmed that a personally signed build with Accessibility
granted created the tap without an Input Monitoring prompt and did not appear
in the Input Monitoring application list. Validation on macOS 26.6.2 confirmed
the same behavior for the suppressing middle-click tap. Middle-button events
reached a browser canvas before enablement, were reserved while enabled, and
reached the canvas again immediately after disablement. The Setup Assistant
and Settings explain the observed event scope before the Accessibility request.

Runtime dependencies are allowed after reviewing necessity, maintenance,
security history, license compatibility, update strategy, and removal cost.
Approved dependencies are pinned and recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Adapted code must have clear
provenance, compatible licensing, and attribution.

Sparkle is the sole current runtime dependency. It verifies BetterTile update
archives with an EdDSA signature. Its private signing key remains outside the
repository and GitHub Actions.

## Distribution

Public beta builds are signed with the maintainer-held, self-signed
`BetterTile Beta` certificate. Its stable certificate requirement is intended
to let macOS recognize successive betas as the same application for
Accessibility. The 0.4.1 to 0.4.2 public update will validate that behavior. It
does not provide Apple developer attestation or notarization, so first launch
still requires **Open Anyway** in System Settings → Privacy & Security. The
first stable-signed release changes from the old ad-hoc identity and requires
one final Accessibility grant.

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

## Change disclosure

Pull requests must call out changes to networking, permissions, privileged
components, dependencies, user-data handling, distribution, updates, private
APIs, or architecture. Intentional architecture changes are permitted when
their rationale, documentation, migration impact, and tests are included.
