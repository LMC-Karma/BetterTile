# Security Policy

## Reporting a vulnerability

Report security or privacy concerns privately through
[GitHub Security Advisories](https://github.com/LMC-Karma/bettertile/security/advisories/new).
Please do not open a public issue containing sensitive details.

Include what you observed, how to reproduce it, and the macOS version you saw
it on. You can expect an initial response within a few days.

## Security model

BetterTile controls other applications' windows, so its boundaries are
deliberately narrow:

- **Public Apple APIs only.** No private frameworks, no private SkyLight
  symbols, no code injection, and no SIP workarounds.
- **One permission.** Accessibility is the sole mandatory permission. Every
  permission the app requests is explained in-product before it is requested.
- **No network.** BetterTile contains no networking, analytics, telemetry, or
  crash reporting. Window data never leaves the machine.
- **No dependencies.** There is no third-party package supply chain to
  compromise.

Changes that weaken any of the above will not be accepted.
