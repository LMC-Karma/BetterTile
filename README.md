# BetterTile website

The product website for [BetterTile](https://github.com/LMC-Karma/BetterTile),
a free, open-source macOS window manager.

## Local preview

Use Node.js 22 or later. No npm dependencies are required.

```sh
npm run build
npm run dev
```

Open http://localhost:4175. The build checks the demo and creates `dist/`.
The interactive windows and Settings are browser simulations.

## GitHub Pages

This website lives on the `gh-pages` branch of
[LMC-Karma/BetterTile](https://github.com/LMC-Karma/BetterTile/tree/gh-pages).
The app stays on `main`. The two branches have separate histories; do not merge
`gh-pages` into `main`.

Live site: https://lmc-karma.github.io/BetterTile/

In repository **Settings → Pages**, use **Deploy from a branch**,
branch **gh-pages**, folder **/ (root)**. The `.nojekyll` file makes GitHub
serve the static files directly. The HTML, CSS, JavaScript and font files at
the branch root are the site; `dist/` is only a local build output.

For future changes, branch from `gh-pages`, run `npm run build`, and open a pull
request targeting `gh-pages`. The Website checks workflow validates pushes and
pull requests to that branch. Merging an approved change into `gh-pages`
publishes it automatically. No app build or release is involved.

This branch preserves the website history from `LMC-Karma/bettertile-website`,
including its native-control and typography/demo improvements. The migration
changes hosting only: no analytics, permissions, runtime dependencies, native
app behavior, or update distribution change. The earlier repository remains
available as migration history.

## Custom domain

Buy and verify ownership of the domain before directing its DNS to Pages.
Add the domain in **Settings → Pages → Custom domain**. Configure the records
specified by [GitHub's custom-domain guide](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site),
then enable **Enforce HTTPS** when GitHub's certificate is ready.
The free GitHub Pages address works before a custom domain is connected.

## Website data

The site has no analytics or third-party scripts. Its theme choice is saved
in the browser's local storage. Demo choices stay in memory. GitHub receives
ordinary web request metadata when it hosts the site. Download and source
links open the BetterTile GitHub repository.

## Visual provenance

The Layout Wheel sector geometry and default actions follow BetterTile's
`LayoutWheelView.swift` and `LayoutWheel.swift`. The browser draws SVG action
diagrams; it does not run the native app or control real windows.
The animated resize grip follows `DividerHandleView` in
`DividerOverlayController.swift`: a 56-point rounded bar that stretches to
168 points and uses the accent color during a drag.


Marketing headlines use self-hosted Inter and Instrument Serif Italic. Settings
and window simulations retain the platform system font. Font files and their
SIL Open Font Licenses are in `assets/fonts/`; see its README for provenance.
No request to a third-party font service is made.
