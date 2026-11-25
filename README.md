# BetterTile website

This branch holds the website at https://lmc-karma.github.io/BetterTile/. The
app lives on `main`. The two branches have separate histories. Do not merge
`gh-pages` into `main`.

Node.js 22 or later. No packages to install.

```sh
npm run build     # render the pages, check them, and export to dist/
npm run dev       # preview at http://127.0.0.1:4188/
```

- Home page: `index.html`, `styles.css` and `script.js`. They are written by
  hand. `acknowledgements.html` and `404.html` are hand-written too and use
  `styles.css`. `404.html` uses absolute URLs, because Pages serves it for any
  missing path.
- Product facts for the build: `content.mjs`. Brand page markup: `render.mjs`.
- Generated files (`brand.html`, `sitemap.xml`, `robots.txt`, identity SVGs)
  are committed, because Pages serves the branch root. Do not edit them by
  hand. Do not commit `dist/`.
- Every Download link opens `DOWNLOAD_URL` in `content.mjs`, so the site shows
  no version, date or size and needs no change for a new release. In the
  hand-written pages, mark each Download link with `data-download`. The build
  writes `DOWNLOAD_URL` into its `href` and rebuilds the home page's JSON-LD,
  so commit the pages after `npm run build`. The check fails if a Download
  link has another URL or no `data-download`. When a release uploads the
  fixed-name asset `BetterTile.dmg`, change that one constant to
  `.../releases/latest/download/BetterTile.dmg` and build.
- The check also fails if a local reference is missing or if a page,
  stylesheet or script loads anything from another origin.
- Pages publishes with **Deploy from a branch**, `gh-pages`, `/ (root)`. Keep
  `.nojekyll`.

The site has no analytics and loads no third-party resources. See
[acknowledgements](https://lmc-karma.github.io/BetterTile/acknowledgements.html)
for credits and licenses.
