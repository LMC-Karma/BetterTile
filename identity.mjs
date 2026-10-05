import { writeFile, mkdir, readFile } from 'node:fs/promises';
import { brand } from './content.mjs';

export const rail = (frame = '#4e78ff', edge = '#63dec0') => `<g fill="none" stroke="${frame}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"><path d="M23 14H12v36h11M41 14h11v36H41"/></g><rect x="29" y="5" width="6" height="54" rx="3" fill="${edge}"/>`;
export const frame = `<g fill="none" stroke="currentColor" stroke-width="5" stroke-linejoin="round"><path d="M8 10h32v18h16v26H24V36H8Z"/><path d="M24 36h16V28"/></g>`;
export const typeMark = `<g fill="none" stroke="currentColor" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"><path d="M10 10v44h15q12 0 12-11T25 32H10h13q12 0 12-11T23 10H10M41 10h15M49 10v44"/></g>`;
export const mark = (kind='rail', label='') => `<svg viewBox="0 0 64 64" ${label ? `role="img" aria-label="${label}"` : 'aria-hidden="true"'}>${kind==='frame'?frame:kind==='type'?typeMark:rail('currentColor','currentColor')}</svg>`;

export async function buildIdentity() {
  const dir='assets/identity'; await mkdir(dir,{recursive:true});
  const svg=(body,w=64,h=64)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${body}</svg>`;
  const small=(color)=>`<path fill="${color}" d="M1 4h4v2H3v4h2v2H1zm10 0h4v8h-4v-2h2V6h-2zM7 1h2v14H7z"/>`;
  const name=brand.name.replaceAll('&','&amp;').replaceAll('<','&lt;');
  const appIcon=(await readFile(brand.assets.icon)).toString('base64');
  const word=(fill)=>`<text x="0" y="51" fill="${fill}" font-family="Inter,Arial,sans-serif" font-weight="600" font-size="51" letter-spacing="-2">${name}</text>`;
  const assets={
    'symbol.svg':svg(rail()), 'symbol-mono.svg':svg(rail('#111722','#111722')),
    'symbol-reversed.svg':svg(rail('#eff4ff','#63dec0')),
    'symbol-white.svg':svg(rail('#fff','#fff')),
    'symbol-small.svg':svg(small('#eff4ff'),16,16),
    'menu-bar.svg':svg(small('#000'),16,16),
    'favicon.svg':svg(`<rect width="32" height="32" rx="8" fill="#111722"/><g transform="translate(8 8)">${small('#63dec0')}</g>`,32,32),
    'concept-frame.svg':svg(`<g color="#405be8">${frame}</g>`),
    'concept-type.svg':svg(`<g color="#e9eef5">${typeMark}</g>`),
    'wordmark.svg':svg(word('#111722'),320,64),
    'wordmark-reversed.svg':svg(word('#eff4ff'),320,64),
    'lockup.svg':svg(`${rail()}<g transform="translate(83 0)">${word('#111722')}</g>`,420,64),
    'lockup-reversed.svg':svg(`${rail('#eff4ff','#63dec0')}<g transform="translate(83 0)">${word('#eff4ff')}</g>`,420,64),
    'app-icon-concept.svg':svg(`<defs><linearGradient id="b" x2=".9" y2="1"><stop stop-color="#2f61ff"/><stop offset="1" stop-color="#163eac"/></linearGradient><linearGradient id="s" x2="0" y2="1"><stop stop-color="#fff" stop-opacity=".35"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient></defs><rect x="64" y="64" width="896" height="896" rx="206" fill="url(#b)"/><rect x="66" y="66" width="892" height="892" rx="204" fill="none" stroke="url(#s)" stroke-width="4"/><g transform="translate(192 192) scale(10)">${rail('#f4f8ff','#77e0b5')}</g>`,1024,1024),
    'social-preview.svg':svg(`<rect width="1200" height="630" fill="#000000"/><g transform="translate(66 52) scale(.7)">${rail('#eff4ff','#63dec0')}</g><text x="126" y="87" font-family="Inter,Arial,sans-serif" font-size="32" font-weight="600" fill="#eff4ff">${name}</text><text x="68" y="253" font-family="Inter,Arial,sans-serif" font-size="82" font-weight="600" letter-spacing="-4" fill="#eff4ff">${brand.headline[0]}</text><text x="68" y="342" font-family="Inter,Arial,sans-serif" font-size="82" font-weight="600" letter-spacing="-4" fill="#93adff">${brand.headline[1]}</text><text x="72" y="454" font-family="Inter,Arial,sans-serif" font-size="26" fill="#b3bdcb">Windows that resize together.</text><text x="72" y="550" font-family="Inter,Arial,sans-serif" font-size="20" fill="#b3bdcb">Free forever · Native macOS · Open source</text><rect x="818" y="173" width="120" height="296" rx="12" fill="#e4eaf1"/><rect x="958" y="173" width="177" height="296" rx="12" fill="#243047"/><rect x="944" y="204" width="8" height="230" rx="4" fill="#63dec0"/><path d="m929 316-14 0m0 0 5-5m-5 5 5 5m47-5h14m0 0-5-5m5 5-5 5" fill="none" stroke="#63dec0" stroke-width="3"/>`,1200,630),
  };
  assets['social-preview.svg']=assets['social-preview.svg'].replace(`<g transform="translate(66 52) scale(.7)">${rail('#eff4ff','#63dec0')}</g>`, `<image x="66" y="47" width="48" height="48" href="data:image/png;base64,${appIcon}"/>`);
  for(const [file,body] of Object.entries(assets)) await writeFile(`${dir}/${file}`,body+'\n');
  for(const size of [16,24,32,64,128]) await writeFile(`${dir}/symbol-${size}.svg`, size===16?svg(small('#eff4ff'),16,16):svg(`<g transform="scale(${size/64})">${rail('#eff4ff','#63dec0')}</g>`,size,size));
}
