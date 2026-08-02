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

Three platform-safety boundaries are permanent:

- use public Apple APIs rather than private frameworks or SkyLight symbols
- do not inject code into other processes
- do not bypass System Integrity Protection

Other implementation choices may evolve when the user benefit justifies them.
Changes are evaluated against security, privacy, transparency,
maintainability, and user benefit rather than a blanket technology ban.

## Network disclosure

BetterTile contacts `raw.githubusercontent.com` over HTTPS to fetch the public
Sparkle appcast and `github.com` over HTTPS when the user chooses to download a
release archive. These requests necessarily expose ordinary connection metadata
such as the requesting IP address to GitHub. Automatic checks default to once
per day and can be disabled in Settings. Sparkle system profiling is disabled.

Any future network feature must serve a documented user-facing purpose,
minimize transmitted data, use secure transport, and document its endpoints
and payload purpose here before release. Optional diagnostics require a
separate design decision, informed opt-in, documented retention, and a clear
off switch.

## Permissions and dependencies

Accessibility is currently the only required macOS permission. A new
permission or privileged component requires an explicit design review,
least-privilege justification, repository documentation, and an in-product
explanation before the system prompt appears.

Runtime dependencies are allowed after reviewing necessity, maintenance,
security history, license compatibility, update strategy, and removal cost.
Approved dependencies are pinned and recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Adapted code must have clear
provenance, compatible licensing, and attribution.

Sparkle is the sole current runtime dependency. It verifies BetterTile update
archives with an EdDSA signature. Its private signing key remains outside the
repository and GitHub Actions.

## Change disclosure

Pull requests must call out changes to networking, permissions, privileged
components, dependencies, user-data handling, distribution, updates, or
architecture. Intentional architecture changes are permitted when their
rationale, documentation, migration impact, and tests are included.
