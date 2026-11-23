# BetterTile website

This branch holds the website at https://lmc-karma.github.io/BetterTile/. The
app lives on `main`. The two branches have separate histories. Do not merge
`gh-pages` into `main`.

Node.js 22 or later. No packages to install.

```sh
npm run build     # render the pages, check them, and export to dist/
npm run dev       # preview at http://127.0.0.1:4188/
```

- Page text and facts: `content.mjs`. Markup: `render.mjs`.
- Generated files (`index.html`, `brand.html`, `404.html`,
  `acknowledgements.html`, `sitemap.xml`, `robots.txt`, identity SVGs) are
  committed, because Pages serves the branch root. Do not edit them by hand.
  Do not commit `dist/`.
- Every Download button opens `DOWNLOAD_URL` in `content.mjs`, so the site
  shows no version, date or size and needs no change for a new release. When a
  release uploads the fixed-name asset `BetterTile.dmg`, change that one
  constant to `.../releases/latest/download/BetterTile.dmg`.
- Pages publishes with **Deploy from a branch**, `gh-pages`, `/ (root)`. Keep
  `.nojekyll`.

The site has no analytics and loads no third-party resources. See
[acknowledgements](https://lmc-karma.github.io/BetterTile/acknowledgements.html)
for credits and licenses.
