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
  A free, open-source window manager for macOS.<br>
  Drag the edge between two windows and both resize together. Open a new window and Adaptive tiling makes room for it.<br>
  Add Tabbed panes, a Layout Wheel, and Saved Layouts that bring back a desktop's arrangement.
</p>

<p align="center">
  <a href="https://github.com/LMC-Karma/BetterTile/releases/latest"><strong>Download</strong></a>
  · <a href="https://lmc-karma.github.io/BetterTile/">Website</a>
  · <a href="#everything-it-does">Features</a>
  · <a href="#default-shortcuts">Shortcuts</a>
  · <a href="#install">Install</a>
  · <a href="#faq">FAQ</a>
  · <a href="#private-by-default">Privacy</a>
  · <a href="https://github.com/LMC-Karma/BetterTile/issues/new?template=bug.yml">Report a bug</a>
  · <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <a href="https://github.com/LMC-Karma/BetterTile/releases/latest"><img src="https://img.shields.io/github/v/release/LMC-Karma/BetterTile?include_prereleases&label=release" alt="Latest release"></a>
  <a href="https://github.com/LMC-Karma/BetterTile/actions/workflows/ci.yml"><img src="https://github.com/LMC-Karma/BetterTile/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="#what-you-need"><img src="https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg" alt="macOS 26 or later"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg" alt="License: GPL v3 or later"></a>
  <a href="#bettertile-is-free"><img src="https://img.shields.io/badge/price-free%20forever-brightgreen.svg" alt="Free forever"></a>
</p>

<p align="center">
  Requires an Apple silicon Mac, macOS 26 or later, and Accessibility permission.<br>
  The public beta is self-signed and not notarized. Read <a href="#install">Install</a> before first launch.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#overview">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/overview.jpg" alt="Watch the full BetterTile tour: snapping, linked resizing, Adaptive, Tabbed, the Layout Wheel, Saved Layouts, and multiple displays" width="800" height="450">
  </a>
  <br>
  <a href="https://lmc-karma.github.io/BetterTile/#overview"><strong>Watch the full tour · 38 seconds</strong></a>
</p>

<h2 align="center" id="everything-it-does">Everything it does</h2>

<p align="center">
  Feature demonstrations. For videos with playback controls, <a href="https://lmc-karma.github.io/BetterTile/#features">visit the website</a>.
</p>

<!-- Rendered product demonstrations of 0.6.0 (the interface has not changed since), exported at 800 × 450 and 20 fps. The GIFs are hosted with the website on GitHub Pages. -->

<h3 align="center" id="resize-neighbours-together">Resize neighbours together</h3>

<p align="center">
  Drag the shared boundary between adjacent windows. Both windows resize together.<br>
  Choose <strong>Live Resize</strong> or a <strong>Resize Preview</strong> that applies when you release.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#linked">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/gifs/bettertile-resize.gif" alt="Linked resizing demonstration: moving a shared boundary resizes neighbouring windows together" width="800" height="450">
  </a>
</p>

<h3 align="center" id="adaptive-tiling">Adaptive tiling</h3>

<p align="center">
  Open a window. Adaptive makes room in the layout while keeping movement and resizing to a minimum.<br>
  Swap windows, adjust the layout, or float a window out when it needs its own space.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#bento">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/gifs/bettertile-adaptive.gif" alt="Adaptive demonstration: each new window takes a pane and the layout makes room" width="800" height="450">
  </a>
</p>

<h3 align="center" id="tabbed-panes">Tabbed panes</h3>

<p align="center">
  Group windows into resizable panes. Select a tab to bring its window forward.<br>
  Drag tabs between panes, or drag a floating window onto a tab bar to add it as a tab.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#tabbed">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/gifs/bettertile-tabbed.gif" alt="Tabbed demonstration: tabs switch the visible window, a tab moves between panes, and a floating window joins a pane as a tab" width="800" height="450">
  </a>
</p>

<p align="center">
  <strong>Layout Gallery</strong> shows a picture of each pane layout and applies it to the whole display.<br>
  The <strong>+</strong> button opens an app straight into a pane. Tab bars can hide until you point at them.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#tabbed">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/gifs/bettertile-layout-gallery.gif" alt="Layout Gallery demonstration: the gallery opens from the tab bar menu, previews a 2 × 2 grid, and applies it" width="800" height="450">
  </a>
</p>

<p align="center">
  Turn off Stage Manager for Tabbed. Pane assignments last for the current app session.<br>
  Cross-display tab dragging is unavailable.
</p>

<h3 align="center" id="saved-layouts">Saved Layouts</h3>

<p align="center">
  Save a desktop's arrangement and bring it back with one click. <strong>Undo Apply</strong> puts the windows back.<br>
  Each pane can prefer apps or an <strong>App Group</strong>. Bind a layout to a set of displays to apply it when they connect.<br>
  Apply never opens an app or takes a window from another desktop.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#saved-layouts">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/gifs/bettertile-saved-layouts.gif" alt="Saved Layouts demonstration: a layout applied from the menu bar panel arranges three windows, then Undo puts them back" width="800" height="450">
  </a>
</p>

<h3 align="center" id="layout-wheel">Layout Wheel</h3>

<p align="center">
  Hold Control + Option + Shift, choose a sector, and release. The center or Escape cancels.<br>
  The default wheel places windows and has <strong>Repair Layout</strong> at the bottom.<br>
  The <strong>Grouped</strong> style fans out groups such as Size, Thirds, Displays, Mode, and Choose Layout.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#wheel">
    <img src="https://lmc-karma.github.io/BetterTile/assets/media/gifs/bettertile-wheel.gif" alt="Layout Wheel demonstration: the wheel opens at the pointer, places a window on the right half, then Repair Layout arranges the desktop" width="800" height="450">
  </a>
</p>

<p align="center">
  Configure the style, trigger, size, and actions on the Layout Wheel Settings page.<br>
  The optional Middle Click trigger reserves unmodified middle-click system-wide while enabled.<br>
  Other apps receive that button again when you turn the option off.
</p>

<h3 align="center" id="more-ways-to-arrange-your-windows">More ways to arrange your windows</h3>

<p align="center">
  <strong>Drag snapping</strong><br>
  Drag a title bar toward an edge or corner. Preview the placement before you release.
</p>

<p align="center">
  <strong>Repair Layout</strong><br>
  Rebuild the current desktop's layout from its visible windows, with equal shares and no gaps.
</p>

<p align="center">
  <strong>Multiple displays</strong><br>
  <strong>Next Display</strong> and <strong>Previous Display</strong> make room on the destination and close the gap on the source.
</p>

<p align="center">
  <strong>Keyboard shortcuts and undo</strong><br>
  Place windows with <a href="#default-shortcuts">global shortcuts</a>, with duplicate checks for BetterTile actions.<br>
  Undo a placement to restore an earlier window frame.
</p>

<p align="center">
  <a href="https://lmc-karma.github.io/BetterTile/#snapping">Watch drag snapping</a>
  · <a href="https://lmc-karma.github.io/BetterTile/#more">Watch Repair Layout and multiple displays</a>
  · <a href="https://lmc-karma.github.io/BetterTile/#keyboard">Watch shortcuts and undo</a>
</p>

---

## Default shortcuts

These bindings are on in a new installation. Change or clear any of them in
**Settings → Shortcuts**. Drag snapping and the Layout Wheel have their own
Settings pages. In the table, ⌃ is Control, ⌥ is Option, and ⌘ is Command.

| Action | Shortcut |
| --- | --- |
| Left, right, top, or bottom half | ⌃⌥ with ← → ↑ ↓ |
| Top left, top right, bottom left, or bottom right quarter | ⌃⌥ with U, I, J, K |
| Left third, center third, right third | ⌃⌥ with D, F, G |
| Left two thirds, right two thirds | ⌃⌥ with E, T |
| Maximize | ⌃⌥↩ |
| Restore the previous size | ⌃⌥⌫ |
| Center | ⌃⌥C |
| Grow or shrink width | ⌃⌥= and ⌃⌥- |
| Next display, previous display | ⌃⌥⌘→ and ⌃⌥⌘← |
| Open the Layout Wheel (hold, pick a sector, release) | ⌃⌥⇧ |

Other actions, such as the sixths, Almost Maximize, Tabbed tab commands, and
height changes, have no default key. Assign them on the Shortcuts page.

Drag snapping is also on by default. Drag a title bar to an edge or corner:
left and right edges give halves, corners give quarters, and the top edge gives
Almost Maximize. Hold Option while dragging to skip snapping. A double-click on
a title bar maximizes the window.

---

## What you need

- An Apple silicon Mac with macOS 26 or later. Intel Macs are not supported by current releases.
- Accessibility permission. This is the only macOS permission BetterTile requests.
- To build from source: Xcode 26 with the Swift 6.3 toolchain or later. The package declares Swift tools 6.2, and the app builds in Swift 6 language mode. See [Development setup](docs/DEVELOPMENT.md).

## Install

1. [Download the latest beta](https://github.com/LMC-Karma/BetterTile/releases/latest).
   Open the `BetterTile-*-beta.dmg` and drag BetterTile into **Applications**.
2. Launch BetterTile. The beta is signed with the stable, self-signed
   **BetterTile Beta** certificate. It is **not signed with an Apple Developer ID
   and is not notarized**. After the first launch attempt, open **System Settings →
   Privacy & Security** and choose **Open Anyway** after confirming the download
   came from this repository. To check the download first, see
   [How do I verify the download?](#how-do-i-verify-the-download)
3. Follow BetterTile's explanation to grant **Accessibility** permission.
   BetterTile runs in the menu bar. Its Dock icon is optional and off by default.
4. Choose a starting mode: **Manual**, **Adaptive**, or **Tabbed**. Setup shows a
   short clip of each. You can change the mode later from the menu bar.

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
suggested title; it submits no issue automatically. **Copy Diagnostics** puts a
plain-text report of versions, displays, layout modes, window counts, and
settings on the pasteboard for a bug report. It contains no window titles, app
names, or file paths, and BetterTile sends nothing.

Read [Security and privacy](SECURITY.md) for the policy and vulnerability
reporting, and [Security disclosures](docs/SECURITY_DISCLOSURES.md) for the
input scope, network disclosure, private observations, and fallback behavior.

## Known limits

- **No cross-Space window movement.** BetterTile does not move windows between
  macOS desktops.
- **Stage Manager groups stay single-window.** A thumbnail drag selects one
  validated frontmost member. BetterTile does not move or synchronize the other
  windows in that Stage group.
- **Tabbed needs Stage Manager off.** Pane assignments, followed Saved Layouts,
  and placement undo history last for the current app session. Cross-display tab
  dragging is unavailable.
- **Some apps restrict window sizes.** Broader real-app stacking,
  multi-display, and Space-switch behavior remains under validation. Read the
  [latest release notes](docs/releases/0.6.2-beta.md), or browse
  [all releases](https://github.com/LMC-Karma/BetterTile/releases).

## How it compares

BetterTile is not the right tool for everyone. This is a short guide. Each
description comes from the other app's own public page as of November 2026, so
check that page for current details.

- **[Rectangle](https://github.com/rxhanson/Rectangle).** Keyboard shortcuts and
  drag snap areas for halves, quarters, and thirds, from a mature open-source
  project. It supports macOS 14 and later and installs with Homebrew. Pick it for
  simple, proven snapping or an older macOS. Pick BetterTile when you want
  linked resizing, Adaptive tiling, Tabbed panes, or Saved Layouts.
- **[Loop](https://github.com/MrKai77/Loop).** A radial menu triggered by a key
  press, with cycles, a resize preview, and stashing windows at the screen edge.
  It supports macOS 13 and later. BetterTile's Layout Wheel is similar. Pick
  Loop for an older macOS, cycles, or stashing. Pick BetterTile for the layout
  modes around the wheel.
- **[AeroSpace](https://github.com/nikitabobko/AeroSpace).** An i3-like tiling
  window manager. It uses its own virtual workspaces, not macOS Spaces, and a
  plain-text configuration and command line. Pick it for keyboard-first tiling
  that you script. BetterTile works with native Spaces, uses a menu-bar app
  and Settings, and does not move windows between desktops.
- **[Magnet](https://magnet.crowdcafe.com/) and [Moom](https://manytricks.com/moom/).**
  Magnet snaps windows into tiles by dragging, shortcuts, or the menu bar, and it
  is on the Mac App Store. Moom offers a pop-up palette, custom actions, and
  saved window layouts. Pick them if you prefer their approach. BetterTile's
  Saved Layouts and linked resizing cover similar ground.

BetterTile needs an Apple silicon Mac and macOS 26 or later. Its beta is not
notarized, and its Tabbed mode needs Stage Manager off. If one of those blocks
you, pick one of the tools above.

## FAQ

### Why is the beta self-signed and not notarized? How do I open it?

BetterTile's public beta is signed with a stable, self-signed **BetterTile Beta**
certificate. It is not an Apple Developer ID certificate, so Apple has not
notarized it. The stable certificate lets macOS keep your Accessibility
permission across normal updates. Sparkle also checks each update's EdDSA
signature against a public key built into the app.

To open it the first time:

1. Open the `.dmg` and drag BetterTile into **Applications**.
2. Open BetterTile. macOS blocks it.
3. Open **System Settings → Privacy & Security**, scroll to the message about
   BetterTile, and choose **Open Anyway**.
4. Grant **Accessibility** permission when BetterTile asks.

### How do I verify the download?

Every release has a `.sha256` file beside the `.dmg`. Download both into one
folder, then run this in that folder:

```sh
shasum -a 256 -c BetterTile-0.6.2-beta.dmg.sha256
```

Use the file name of the version you downloaded. The command prints `OK` when the
file matches. The checksum comes from the same release page as the download, so
it detects a damaged download. It does not prove who built the file.

### Does it run on an Intel Mac or on macOS before 26?

No current release does. Releases from 0.6.0 run only on Apple silicon Macs with
macOS 26 or later. The last release for Intel Macs is
[0.5.2](https://github.com/LMC-Karma/BetterTile/releases/tag/v0.5.2-beta). It
also needs macOS 26, and Intel Macs are not offered newer updates. No release
supports macOS before 26.

### What data leaves my Mac?

Only update checks and downloads contact a server, and that server is GitHub.
They send no window data, configuration, analytics, telemetry, crash reports,
or system profile. **Send Feedback** opens a GitHub form in your browser and
submits nothing by itself. Read [Private by default](#private-by-default) and [Security and privacy](SECURITY.md).

### Can I turn off the private APIs?

Yes. BetterTile uses a small set of reviewed, read-only private observations,
each with a public fallback. They are described in
[Private window observations](docs/SECURITY_DISCLOSURES.md#private-window-observations).
To turn all of them off, quit BetterTile and run:

```sh
defaults write com.lmckarma.BetterTile disablePrivateAPIs -bool true
```

Then open BetterTile again. The affected behavior uses the public fallbacks.
To turn them back on:

```sh
defaults delete com.lmckarma.BetterTile disablePrivateAPIs
```

### Where are my settings stored?

- Configuration: `~/Library/Application Support/BetterTile/configuration.json`.
- Saved Layouts, App Groups, and display bindings: other files in
  `~/Library/Application Support/BetterTile/`.
- Some preferences: the `com.lmckarma.BetterTile` defaults domain, in
  `~/Library/Preferences/com.lmckarma.BetterTile.plist`.

A Debug build uses separate copies with `.debug` and `BetterTile Debug` names.
None of these files is uploaded.

### How do I uninstall BetterTile and reset its Accessibility permission?

1. Quit BetterTile from its menu bar icon.
2. If you turned on **Launch at login**, turn it off in **System Settings →
   General → Login Items**.
3. Delete BetterTile from **Applications**.
4. To remove its data, delete the `BetterTile` folder in
   `~/Library/Application Support/` and run
   `defaults delete com.lmckarma.BetterTile`.
5. To remove its Accessibility permission, run:

```sh
tccutil reset Accessibility com.lmckarma.BetterTile
```

To reset the permission without uninstalling, run the same command, then open
BetterTile and grant permission again.

### Where do I get help or report a bug?

Report bugs and request features on
[GitHub Issues](https://github.com/LMC-Karma/BetterTile/issues/new/choose).
Report security problems as [SECURITY.md](SECURITY.md) describes, not in a
public issue.

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
- [Architecture](docs/ARCHITECTURE.md) — layers, coordinates, window mutations, and Adaptive.
- [Domain glossary](CONTEXT.md) — shared BetterTile terms.
- [Release notes](docs/releases/0.6.2-beta.md) — what changed in the latest beta. [All releases](https://github.com/LMC-Karma/BetterTile/releases).
- [Beta releases](docs/RELEASING.md) — version, validate, sign, and publish an update.
- [Security and privacy](SECURITY.md) — permissions, networking, and reporting policy.
- [Security disclosures](docs/SECURITY_DISCLOSURES.md) — per-feature privacy and security records.
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
