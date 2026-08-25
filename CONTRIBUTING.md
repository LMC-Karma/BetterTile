# Contributing

Thanks for your interest in BetterTile. Issues, discussion, and pull requests
are welcome.

New here? [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) walks through building,
signing, running, and testing on your own Mac.

Using an AI coding agent? Point it at [AGENTS.md](AGENTS.md) — same rules,
written for agents.

---

## Before you start

Write down one clear goal before you change code. The goal can be in a
discussion, an issue, or the pull request. An issue is optional.

Agree on the approach first when the goal is unclear, the work needs more than
one pull request, or a project rule requires approval. Keep one topic in each
pull request.

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

4. Run focused checks while you work. Before opening a ready pull request, run:

   ```sh
   swift test
   xcodebuild -project BetterTile.xcodeproj -scheme BetterTile \
     -configuration Debug CODE_SIGNING_ALLOWED=NO build
   ```

5. Stage the files you changed. Push and open a ready pull request against
   `main`:

   ```sh
   git push -u origin feat/short-description
   gh pr create --base main
   ```

   Use `--draft` only when you want early feedback or the maintainer asks for a
   draft.

6. Check automated review comments against the code and project rules. Resolve
   every review thread. Merge only after CI passes and the maintainer approves
   the final pushed version. If automated review cannot run, report the failure
   and wait for a retry or a maintainer decision.

---

## Current architecture

The default dependency direction is:

```
BetterTileApp  →  BetterTileMacOS  →  BetterTileCore
   (SwiftUI)       (AppKit + AX)       (pure logic)
```

- **`BetterTileCore` imports no AppKit and no Accessibility.** It is pure,
  deterministic placement policy, and that is what makes it testable. It holds
  no updater API.
- **`BetterTileMacOS`** owns Accessibility, window-system integration, window
  mutations, and all coordinate conversion. Core uses top-left logical points;
  AppKit's bottom-left coordinates are converted at this boundary and never leak
  inward.
- **`BetterTileApp`** owns the application lifecycle and application-level UI
  integrations: menus, the status item, alerts, Sparkle's
  `SPUStandardUpdaterController`, and user-requested `NSWorkspace` actions.
- **All window mutations go through `WindowCoordinator`** so that multi-window
  operations can preflight and roll back.

Updates live in the app layer on purpose. The app delegate owns the Sparkle
updater controller and implements `SPUUpdaterDelegate`; please do not propose an
updater service or an updater API in `BetterTileCore`. The testable decisions
behind those integrations are extracted into
`BetterTileMacOS/ApplicationUpdatePresentation.swift`.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the full detail.

---

## Security and disclosure

Use public Apple APIs by default. Before implementing a private API, write a
design discussion that explains why public alternatives do not work and how
the proposal fits BetterTile. Cover scope, fallback behavior, compatibility
testing, security, privacy, distribution, and maintenance. Get maintainer
approval before implementation.

BetterTile accepts no SIP workaround or code injection. Changes to
dependencies, networking, permissions, privileged components, user data,
distribution, and architecture also need the review defined in `SECURITY.md`.
Record compatible licensing, provenance, and attribution for adapted code.

[SECURITY.md](SECURITY.md) is the canonical security and privacy policy.

---

## License

By contributing, you agree that your contributions are licensed under the
[GNU General Public License v3.0 or later](LICENSE).
