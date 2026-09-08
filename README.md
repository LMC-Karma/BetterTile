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

1. In the website repository, open **Settings → Pages**.
2. Set **Build and deployment → Source** to **GitHub Actions**.
3. Push to `main`, or run **Website checks and GitHub Pages** from **Actions**.
4. Open the deployment URL reported by the workflow.

Pull requests run the build checks. Only `main` publishes. The workflow uploads
`dist/`, which contains only the site's HTML, CSS, JavaScript, and app icon.
GitHub Actions uses its short-lived repository token; no custom secret is needed.

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
