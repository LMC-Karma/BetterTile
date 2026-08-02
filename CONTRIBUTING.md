# Contributing

Thanks for your interest in BetterTile. Issues, discussion, and pull requests
are welcome.

New here? [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) walks through building,
signing, running, and testing on your own Mac.

Using an AI coding agent? Point it at [AGENTS.md](AGENTS.md) — same rules,
written for agents.

---

## Before you start

Open an issue describing the user-visible behavior and what "done" looks like.
For anything beyond a small fix, it's worth agreeing on the approach before you
write code — BetterTile has strict layer boundaries and a change in the wrong
layer is expensive to unwind.

---

## Workflow

1. Fetch `origin/main` and branch from it:

   ```sh
   git fetch origin
   git switch -c feat/short-description origin/main
   ```

   Use `feat/`, `fix/`, `docs/`, or `refactor/`. Never work directly on `main`.

2. Make the change. Keep layout policy deterministic and free of AppKit — see
   the architecture rules below.

3. Add tests for geometry, state transitions, migrations, and failure paths.

4. Validate:

   ```sh
   swift test
   swift build
   xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
     -configuration Debug CODE_SIGNING_ALLOWED=NO build
   ```

5. Stage the files you actually changed, then push and open a draft pull
   request against `main`:

   ```sh
   git push -u origin feat/short-description
   gh pr create --draft --base main
   ```

6. Wait for CI to pass and for review before marking it ready.

---

## Architecture rules

The dependency direction is strict:

```
BetterTileApp  →  BetterTileMacOS  →  BetterTileCore
   (SwiftUI)       (AppKit + AX)       (pure logic)
```

- **`BetterTileCore` imports no AppKit and no Accessibility.** It is pure,
  deterministic placement policy, and that is what makes it testable.
- **`BetterTileMacOS`** owns every side effect and all coordinate conversion.
  Core uses top-left logical points; AppKit's bottom-left coordinates are
  converted at this boundary and never leak inward.
- **All window mutations go through `WindowCoordinator`** so that multi-window
  operations can preflight and roll back.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the full detail.

---

## What will be rejected

- private macOS APIs, including private SkyLight symbols
- code copied from other window managers
- SIP workarounds or code injection
- third-party package dependencies
- a new system permission without an explicit design decision first

---

## License

By contributing, you agree that your contributions are licensed under the
[GNU General Public License v3.0 or later](LICENSE).
