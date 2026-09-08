import { mkdir, copyFile, cp } from 'node:fs/promises';
await mkdir('dist/assets', { recursive: true });
for (const file of ['index.html', 'styles.css', 'main.js', 'story.css', 'story.js', 'app-visuals.css', 'app-visuals.js', 'assets/app-icon.png']) {
  await copyFile(file, `dist/${file}`);
}
await cp('assets/fonts', 'dist/assets/fonts', { recursive: true });
console.log('Built the static website in dist/.');
