<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://lmc-karma.github.io/BetterTile/assets/identity/app-icon-native-dark-256.png">
      <img src="https://lmc-karma.github.io/BetterTile/assets/identity/app-icon-native-light-256.png" alt="BetterTile app icon" width="160" height="160">
    </picture>
  </a>
</p>

<h1 align="center" id="bettertile">BetterTile</h1>

<p align="center"><strong>Your windows. Working together.</strong></p>

<p align="center">
  A free, native macOS window manager.<br>
  Snap windows into place, resize neighbours together, and let Bento adapt as your work grows.
</p>

<p align="center">
  <a href="https://github.com/LMC-Karma/BetterTile/releases/latest"><strong>Download the latest beta</strong></a>
  · <a href="https://lmc-karma.github.io/BetterTile/">Website</a>
  · <a href="#everything-it-does">Features</a>
  · <a href="#install">Install</a>
  · <a href="#private-by-default">Privacy</a>
  · <a href="#documentation">Documentation</a>
</p>

<p align="center">
  <a href="https://github.com/LMC-Karma/BetterTile/actions/workflows/ci.yml"><img src="https://github.com/LMC-Karma/BetterTile/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="#what-you-need"><img src="https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg" alt="macOS 26 or later"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg" alt="License: GPL v3 or later"></a>
  <a href="#bettertile-is-free"><img src="https://img.shields.io/badge/price-free%20forever-brightgreen.svg" alt="Free forever"></a>
</p>

<p align="center">
  Requires macOS 26 or later and Accessibility permission.<br>
  The public beta is self-signed and not notarized. Read the <a href="#install">installation steps</a> before first launch.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#overview">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/overview.jpg" alt="Watch the full BetterTile tour: snapping, linked resizing, Bento, Tabbed, and the Layout Wheel" width="800" height="450">
  </a>
  <br>
  <a href="https://lmc-karma.github.io/BetterTile/#overview"><strong>Watch the full tour · 25 seconds</strong></a>
</p>

<h2 align="center" id="everything-it-does">Everything it does</h2>

<p align="center">
  Feature demonstrations. For videos with playback controls, <a href="https://lmc-karma.github.io/BetterTile/#features">visit the website</a>.
</p>

<!-- Rendered product demonstrations, exported at 800 × 450 and 20 fps. GitHub attachments keep the GIFs out of Git history. -->

<h3 align="center" id="resize-neighbours-together">Resize neighbours together</h3>

<p align="center">
  Drag the shared boundary between adjacent windows. Both windows resize together.<br>
  Choose a <strong>live</strong> resize or a <strong>ghost</strong> preview that applies when you release.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#linked">
    <img src="https://github.com/user-attachments/assets/9352bbca-5a8a-49e1-8193-b9abe254a527" alt="Linked resizing demonstration: moving a shared boundary resizes neighbouring windows together" width="800" height="450">
  </a>
</p>

<h3 align="center" id="bento-tiling-that-adapts">Bento tiling that adapts</h3>

<p align="center">
  Open a window. Bento makes room in the layout while keeping movement and resizing to a minimum.<br>
  Swap windows, adjust the layout, or float a window out when it needs its own space.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#bento">
    <img src="https://github.com/user-attachments/assets/3fe57264-071c-4e88-af05-c57aa665a299" alt="Bento demonstration: the layout adjusts as new windows open" width="800" height="450">
  </a>
</p>

<h3 align="center" id="tabbed-panes">Tabbed panes</h3>

<p align="center">
  Group windows into resizable panes. Select a tab to bring its window forward.<br>
  Drag tabs between panes or float a window out. The other windows stay open behind it.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#tabbed">
    <img src="https://github.com/user-attachments/assets/8be13f8a-705e-4d1f-8d72-f625acd41308" alt="Tabbed demonstration: selecting tabs changes the visible window, and tabs move between panes" width="800" height="450">
  </a>
</p>

<p align="center">
  Turn off Stage Manager for Tabbed. Pane assignments last for the current app session.<br>
  Cross-display tab dragging is unavailable.
</p>

<h3 align="center" id="more-ways-to-arrange-your-windows">More ways to arrange your windows</h3>

<p align="center">
  <strong>Drag snapping</strong><br>
  Drag a title bar toward an edge or corner. Preview the placement before you release.
</p>

<p align="center">
  <strong>Layout Wheel</strong><br>
  Hold Control + Option + Shift, choose a sector, and release.<br>
  Configure the trigger, actions, and one or two levels in Settings. The center or Escape cancels.
</p>

<p align="center">
  <strong>Keyboard shortcuts and undo</strong><br>
  Place windows with global shortcuts, with duplicate checks for BetterTile actions.<br>
  Undo a placement to restore an earlier window frame.
</p>

<p align="center">
  The optional Middle Click trigger reserves unmodified middle-click system-wide while enabled.<br>
  Other apps receive that button again when you turn the option off.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#snapping">Watch drag snapping</a>
  · <a href="https://lmc-karma.github.io/BetterTile/#wheel">Watch the Layout Wheel</a>
  · <a href="https://lmc-karma.github.io/BetterTile/#keyboard">Watch shortcuts and undo</a>
</p>

---

## What you need

- macOS 26 or later.
- Accessibility permission. This is the only macOS permission BetterTile requests.
- To build from source: Xcode 26 / Swift 6.3 or later. See [Development setup](docs/DEVELOPMENT.md).

## Install

1. [Download the latest beta](https://github.com/LMC-Karma/BetterTile/releases/latest).
   Open the `BetterTile-*-beta.dmg` and drag BetterTile into **Applications**.
2. Launch BetterTile. The beta is signed with the stable, self-signed
   **BetterTile Beta** certificate. It is **not signed with an Apple Developer ID
   and is not notarized**. After the first launch attempt, open **System Settings →
   Privacy & Security** and choose **Open Anyway** after confirming the download
   came from this repository. You can check it against the `.sha256` file beside
   the release download.
3. Follow BetterTile's explanation to grant **Accessibility** permission.
   BetterTile runs in the menu bar. Its Dock icon is optional and off by default.

### Updates

BetterTile checks its GitHub-hosted update feed every four hours by default.
It shows release notes and asks before downloading or installing. Turn automatic
checks off in General Settings, or use **Check for Updates…** at any time.

Sparkle verifies each update's EdDSA signature against a public key built into
the app. This is separate from the beta's macOS code signature. Public betas
since 0.4.1 use the same self-signed certificate to preserve Accessibility
permission across normal updates. If that identity changes, the release notes
will explain the one-time permission steps.

### Build from source

Follow [Development setup](docs/DEVELOPMENT.md) to configure your free Personal
Team, open `BetterTile.xcodeproj`, and run the shared **BetterTile** scheme.
The Debug app has its own configuration and Accessibility grant, separate from
the public beta. `Package.swift` exposes supporting libraries only; the runnable
app comes from the Xcode project.

### Keeping Accessibility permission across rebuilds

Use your Personal Team in the gitignored `Config/LocalSigning.xcconfig` and keep
the bundle identifier unchanged. Ad-hoc signing changes the app's identity on
each rebuild. See [the signing guide](docs/DEVELOPMENT.md#2-sign-the-app-with-your-own-free-personal-team)
for setup and the one-time permission reset.

## Private by default

Window geometry and configuration stay on your Mac. BetterTile has no
advertising, behavioral tracking, or sale of user data. It explains
Accessibility permission before requesting it.

Public Apple APIs move and resize windows. A small, documented set of reviewed,
read-only private observations improves window identity, minimum-size handling,
Spaces, and Stage Manager behavior. Each observation is validated and has a
public fallback. BetterTile uses no code injection or SIP workaround.

BetterTile observes limited pointer and keyboard input for snapping, resizing,
and the Layout Wheel. **Update checks and downloads contact GitHub**, which
receives ordinary connection metadata. These requests send no window data,
configuration, analytics, telemetry, crash reports, or system profile.
**Send Feedback** opens a GitHub form with the app version and build in its
suggested title; it submits no issue automatically.

Read [Security and privacy](SECURITY.md) for the input scope, network disclosure,
private observations, fallback behavior, and vulnerability reporting.

## Known limits

- **No cross-Space window movement.** BetterTile does not move windows between
  macOS desktops.
- **Stage Manager groups stay single-window.** A thumbnail drag selects one
  validated frontmost member. BetterTile does not move or synchronize the other
  windows in that Stage group.
- **Tabbed needs Stage Manager off.** Pane assignments and placement undo history
  last for the current app session. Cross-display tab dragging is unavailable.
- **Some apps restrict window sizes.** Broader real-app stacking,
  multi-display, and Space-switch behavior remains under validation. Read the
  [beta notes](docs/releases/0.5.1-beta.md).

<h2 align="center" id="bettertile-is-free">BetterTile is free</h2>

<p align="center">
  Free forever. No paid tier, subscription, trial, or features held behind a purchase.<br>
  Open source under the <a href="LICENSE">GNU GPL v3 or later</a>.<br>
  Use it, read it, fork it, and share modified versions under the same license.
</p>

<p align="center">
  <a href="https://github.com/LMC-Karma/BetterTile/releases/latest"><strong>Download BetterTile</strong></a>
  · <a href="https://lmc-karma.github.io/BetterTile/">Explore the website</a>
</p>

## Documentation

- [Development setup](docs/DEVELOPMENT.md) — build, sign, run, and test on your Mac.
- [Contributing](CONTRIBUTING.md) — branch, test, and pull-request workflow.
- [Architecture](docs/ARCHITECTURE.md) — layers, coordinates, window mutations, and Bento.
- [Domain glossary](CONTEXT.md) — shared BetterTile terms.
- [Beta releases](docs/RELEASING.md) — version, validate, sign, and publish an update.
- [Security and privacy](SECURITY.md) — permissions, networking, and reporting policy.
- [Third-party notices](THIRD_PARTY_NOTICES.md) — upstream code, attribution, and terms.
- [Agent instructions](AGENTS.md) — build, test, and convention rules for coding agents.

## Acknowledgements

- **[Vorssaint](https://github.com/vorssaint/vorssaint-utils)** — BetterTile includes
  adapted settings and menu-panel presentation code from Vorssaint. Its
  demand-based service ownership shaped BetterTile's runtime lifecycle.
  See [Third-party notices](THIRD_PARTY_NOTICES.md) for attribution and terms.
- **[Rectangle](https://github.com/rxhanson/Rectangle)** — a reference for
  event-driven window management on macOS.

<p align="center">Made by <a href="https://github.com/LMC-Karma">@LMC-Karma</a></p>
