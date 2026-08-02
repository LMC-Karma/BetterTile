# AGENTS.md

Instructions for AI coding agents working in this repository. Vendor-neutral —
applies to Claude Code, Codex, Cursor, Copilot, or any other agent.

Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md) instead. It covers
the same rules in the form a person needs them.

---

## What this project is

BetterTile is a native macOS window manager: keyboard and drag snapping, linked
resizing of adjacent windows, and adaptive Bento tiling. Swift 6.3, SwiftUI,
AppKit, and the public Accessibility API. BetterTile is a free utility with no
advertising, behavioral tracking, or sale of user data. Read
[SECURITY.md](SECURITY.md) before changing networking, permissions,
dependencies, user-data handling, or distribution.

---

## Build and test

```sh
swift test              # unit and fake-system integration tests
swift build             # library build
```

Full application bundle:

```sh
xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run `swift test` and the `xcodebuild` bundle build before proposing any code
change. CI runs both on every pull request.

`Package.swift` deliberately exposes only libraries, not an executable. The
runnable app comes from `BetterTile.xcodeproj`. Do not add an executable
product to `Package.swift`.

---

## Fresh-machine setup

Before launching BetterTile on a contributor's Mac:

1. Confirm an Apple Development identity exists with
   `security find-identity -v -p codesigning`. If none exists, ask the user to
   add their Apple ID and create an Apple Development certificate in
   **Xcode → Settings → Accounts**. Never access or export a private key.
2. Copy `Config/LocalSigning.xcconfig.example` to
   `Config/LocalSigning.xcconfig`.
3. If exactly one Apple Development identity exists, use the 10-character Team
   ID shown in parentheses for `BETTERTILE_DEVELOPMENT_TEAM`. If multiple
   identities exist, ask the user which team to use.
4. Verify `git check-ignore Config/LocalSigning.xcconfig` succeeds. Never commit
   this local file, add a Team ID to `project.pbxproj`, or change the bundle
   identifier.
5. Open `BetterTile.xcodeproj`, run the shared **BetterTile** scheme, and guide
   the user through the one-time Accessibility grant.

If `swift test` reports `no such module 'Testing'`, the active developer
directory is Command Line Tools rather than full Xcode. Ask before running:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

---

## Architecture rules

The current design has three layers, and changes should preserve this
dependency direction unless an explicit architecture decision updates it:

```
BetterTileApp  →  BetterTileMacOS  →  BetterTileCore
   (SwiftUI)       (AppKit + AX)       (pure logic)
```

1. **`BetterTileCore` must not import AppKit, Accessibility, or any macOS UI
   framework.** It is deterministic placement policy: geometry, actions, Bento
   planning, linked resizing, frame history, configuration
   models, and migrations. If you find yourself reaching for `NSScreen` in
   Core, the boundary is in the wrong place.
2. **`BetterTileMacOS`** adapts public macOS APIs and owns all side effects.
3. **`BetterTileApp`** is SwiftUI scenes only.

**Coordinate model.** Core uses logical points with a **top-left** origin.
AppKit's bottom-left global coordinates are converted at the `BetterTileMacOS`
boundary by `CoordinateConverter`. Core code must never see a bottom-left
frame.

**Window mutations** all pass through the main-actor `WindowCoordinator`.
Multi-window operations preflight every participant, apply in deterministic
order, and roll back already-applied frames if a later Accessibility write
fails. Do not write window frames outside this path.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full picture.

---

## Security and product guardrails

The permanent platform-safety boundaries are:

- no private macOS APIs, including private SkyLight symbols
- no SIP workarounds
- no code injection

Dependencies, network features, permissions, privileged components, and
intentional architecture changes are reviewable design choices, not blanket
prohibitions. They require a concrete user benefit, security and maintenance
review, tests, and repository disclosure. New permissions also require an
in-product explanation before macOS prompts. Adapted code needs compatible
licensing, provenance, and attribution; undocumented copying is not allowed.

Follow the canonical policy and disclosure requirements in
[SECURITY.md](SECURITY.md). Sparkle is currently the only approved runtime
dependency.

---

## Testing expectations

Add tests for geometry, state transitions, configuration migrations, and
failure paths. `BetterTileCore` is pure and therefore directly testable — new
Core logic without a test is incomplete.

`BetterTileMacOS` is tested against a fake window system rather than live
Accessibility. Follow the existing pattern in `Tests/BetterTileMacOSTests/`.

---

## Git workflow

- Repository is `LMC-Karma/BetterTile`. Use local `git` and the `gh` CLI. Do not
  open a browser or run `gh auth login` unless an operation actually fails for
  want of authentication.
- Fetch `origin/main` before starting. Branch as `feat/<short-description>`,
  `fix/<short-description>`, `docs/<short-description>`, or
  `refactor/<short-description>`.
- **Never commit or push directly to `main`.**
- Preserve unrelated working-tree changes. Stage explicit files; do not use
  `git add -A`.
- Push with `git push -u origin <branch>`, then open a draft PR with
  `gh pr create --draft` targeting `main`.
- **Leave pull requests unmerged until the maintainer explicitly approves the
  tested version.** Use `gh pr merge` only after that approval.
- When abandoning work, close its PR and return the workspace to `origin/main`.
  Keep the branch unless asked to delete it.

---

## Xcode notes

**Accessibility permission across rebuilds.** macOS ties privacy grants to the
code-signing designated requirement. Xcode's ad-hoc *Sign to Run Locally*
identity changes on every rebuild, so the grant does not survive. Configure a
Personal Team in the gitignored `Config/LocalSigning.xcconfig`, keep the bundle
identifier stable, and always launch the Xcode app target rather than the Swift
package executable.

**Do not change the bundle identifier.** The Accessibility grant is attached to
it.

---

## Local-only files

`/Local/` is gitignored and holds private notes, research, and scratch work.
Never move its contents into a tracked path, quote it in a public file, or
reference it from documentation.
