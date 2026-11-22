# BetterTile website

This branch holds the website at https://lmc-karma.github.io/BetterTile/. The
app lives on `main`. The two branches have separate histories. Do not merge
`gh-pages` into `main`.

Node.js 22 or later. No packages to install.

```sh
npm run release   # refresh release.json from GitHub's public releases
npm run build     # render the pages, check them, and export to dist/
npm run dev       # preview at http://127.0.0.1:4188/
```

- Page text and facts: `content.mjs`. Markup: `render.mjs`.
- Generated files (`index.html`, `brand.html`, `404.html`,
  `acknowledgements.html`, `sitemap.xml`, `robots.txt`, identity SVGs) are
  committed, because Pages serves the branch root. Do not edit them by hand.
  Do not commit `dist/`.
- After each app release, run `npm run release` and `npm run build`, then commit
  the result. The Website checks workflow fails when `release.json` is behind
  the latest GitHub release.
- Pages publishes with **Deploy from a branch**, `gh-pages`, `/ (root)`. Keep
  `.nojekyll`.

The site has no analytics and loads no third-party resources. See
[acknowledgements](https://lmc-karma.github.io/BetterTile/acknowledgements.html)
for credits and licenses.
