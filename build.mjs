import './render.mjs';
import { mkdir, copyFile, cp, rm } from 'node:fs/promises';
await rm('dist', { recursive: true, force: true });
await mkdir('dist', { recursive: true });
const files=['index.html','redesign.css','redesign.js','brand.html','brand-base.css','brand.css','LICENSE','export.html','export-assets.js','.nojekyll','README.md','BRAND-GUIDE.md','OUTLINE.md','COPY.md','VALIDATION.md','ACKNOWLEDGEMENTS.md','CAPTURE-PLAN.md'];
for(const file of files) await copyFile(file,`dist/${file}`);
await cp('assets','dist/assets',{recursive:true});
await cp('research','dist/research',{recursive:true});
console.log('Built website in dist/. Commit the generated root files for GitHub Pages.');
