import './render.mjs';
import { mkdir, copyFile, cp, rm } from 'node:fs/promises';
await rm('dist', { recursive: true, force: true });
await mkdir('dist', { recursive: true });
// Only site files are copied. Build tooling and branch notes (README.md) stay out of the local export.
const files=['index.html','404.html','acknowledgements.html','privacy.html','brand.html','export.html','styles.css','script.js','brand-base.css','brand.css','export-assets.js','favicon.ico','sitemap.xml','robots.txt','LICENSE','.nojekyll'];
for(const file of files) await copyFile(file,`dist/${file}`);
await cp('assets','dist/assets',{recursive:true});
console.log('Built website in dist/. Commit the generated root files for GitHub Pages.');
