(() => {
  'use strict';
  const innerActions = ['Top Half', 'Top Right Quarter', 'Right Half', 'Bottom Right Quarter', 'Bottom Half', 'Bottom Left Quarter', 'Left Half', 'Top Left Quarter'];
  const outerActions = ['Maximize', 'Almost Maximize', 'Next Display', 'Center Resize', 'Restore', 'Center', 'Previous Display', 'Repair Bento'];
  const placements = {
    'Top Half': [0, 0, 1, .5], 'Bottom Half': [0, .5, 1, .5],
    'Left Half': [0, 0, .5, 1], 'Right Half': [.5, 0, .5, 1],
    'Top Left Quarter': [0, 0, .5, .5], 'Top Right Quarter': [.5, 0, .5, .5],
    'Bottom Left Quarter': [0, .5, .5, .5], 'Bottom Right Quarter': [.5, .5, .5, .5],
    'Left Third': [0, 0, 1 / 3, 1], 'Center Third': [1 / 3, 0, 1 / 3, 1], 'Right Third': [2 / 3, 0, 1 / 3, 1],
    'Almost Maximize': [.07, .07, .86, .86], 'Maximize': [0, 0, 1, 1]
  };
  function actionIcon(action) {
    const rect = (x, y, w, h, fill = 'none') => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="1.4" fill="${fill}"/>`;
    let content;
    if (placements[action] && action !== 'Maximize') {
      const [x, y, w, h] = placements[action];
      const half = action.endsWith('Half');
      const inset = action === 'Almost Maximize';
      content = `<rect x="${inset ? 7 : (half ? 3 : 4) + x * (half ? 18 : 16)}" y="${inset ? 8 : (half ? 6 : 7) + y * (half ? 13 : 11)}" width="${inset ? 10 : w * (half ? 18 : 16)}" height="${inset ? 9 : h * (half ? 13 : 11)}" rx=".6" fill="currentColor" stroke="none"/>` + rect(2, 5, 20, 15);
    } else {
      const paths = {
        Maximize: 'M9 3H3v6 M3 3l7 7 M15 21h6v-6 M21 21l-7-7',
        'Center Resize': 'M3 3l7 7 M4 10h6V4 M21 21l-7-7 M14 20v-6h6',
        Restore: 'M9 4 3 10l6 6 M3 10h12a6 6 0 0 1 0 12h-3',
        'Repair Bento': 'M3 10a9 9 0 0 1 16-5l2 3 M17 8h4V4 M21 14A9 9 0 0 1 5 19l-2-3 M7 16H3v4',
        Disabled: 'M8 12h8', Cancel: 'M6 6l12 12 M18 6 6 18'
      };
      if (action === 'Center') content = rect(3, 3, 18, 18, 'currentColor') + '<circle cx="12" cy="12" r="3" fill="var(--wheel-hub,#1c1e1f)" stroke="none"/>';
      else if (action.endsWith('Display')) content = rect(3, 3, 18, 18) + `<path d="M7 12h10 M12 7l5 5-5 5" transform="${action === 'Previous Display' ? 'rotate(180 12 12)' : ''}"/>`;
      else content = (action === 'Disabled' ? rect(2, 5, 20, 15) : '') + `<path d="${paths[action] || paths.Disabled}"/>`;
    }
    return `<svg class="app-glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${content}</svg>`;
  }

  // Port of LayoutWheelSectorShape in Sources/BetterTileMacOS/LayoutWheelView.swift.
  // Native radii: hub 23, inner 68, outer visual inner 73, outer 110; 5pt gaps, 3pt corners.
  function sectorPath(inner, outer, index) {
    const center = (-90 + index * 45) * Math.PI / 180;
    const half = Math.PI / 8, depth = 3;
    const os = center - half + 2.5 / outer, oe = center + half - 2.5 / outer;
    const is = center - half + 2.5 / inner, ie = center + half - 2.5 / inner;
    const point = (r, a) => [Math.cos(a) * r, Math.sin(a) * r];
    const inset = (p, q) => {
      const amount = Math.min(depth / Math.hypot(q[0] - p[0], q[1] - p[1]), .5);
      return p.map((n, i) => n + (q[i] - n) * amount);
    };
    const a = point(outer, os), b = point(outer, oe), c = point(inner, ie), d = point(inner, is);
    const f = p => p.map(n => n.toFixed(3)).join(' ');
    return `M${f(inset(a, d))} Q${f(a)} ${f(point(outer, os + depth / outer))} A${outer} ${outer} 0 0 1 ${f(point(outer, oe - depth / outer))} Q${f(b)} ${f(inset(b, c))} L${f(inset(c, b))} Q${f(c)} ${f(point(inner, ie - depth / inner))} A${inner} ${inner} 0 0 0 ${f(point(inner, is + depth / inner))} Q${f(d)} ${f(inset(d, a))} Z`;
  }
  function wheelMarkup(interactive = false) {
    const sectors = [innerActions, outerActions].map((actions, ring) => actions.map((action, index) => {
      const radius = ring ? 93 : 45.5, angle = (-90 + index * 45) * Math.PI / 180;
      const size = ring ? 20 : 18;
      const control = interactive ? `role="button" tabindex="0" data-wheel-action="${action}" aria-label="${ring ? 'Outer' : 'Inner'} ring: ${action}" aria-pressed="${ring === 0 && index === 0}"` : '';
      return `<g class="app-wheel-sector ${!ring && !index ? 'selected' : ''}" ${control}><path class="sector-surface" d="${sectorPath(ring ? 73 : 23, ring ? 110 : 68, index)}"/><g transform="translate(${Math.cos(angle) * radius - size / 2} ${Math.sin(angle) * radius - size / 2})">${actionIcon(action).replace('class="app-glyph"', `width="${size}" height="${size}"`)}</g></g>`;
    }).join('')).join('');
    return `<svg class="app-wheel" viewBox="-128 -128 256 256" ${interactive ? 'role="group" aria-label="Layout Wheel actions"' : 'aria-hidden="true"'}><circle class="wheel-backdrop" r="110"/>${sectors}<g class="app-wheel-cancel" ${interactive ? 'role="button" tabindex="0" data-wheel-action="Cancel" aria-label="Cancel selection" aria-pressed="false"' : ''}><circle r="23"/><path d="M-5-5 5 5 M5-5-5 5"/></g></svg>`;
  }
  const api = { actionIcon, sectorPath, wheelMarkup, innerActions, outerActions, placements };
  if (typeof module !== 'undefined') module.exports = api;
  if (typeof window !== 'undefined') window.BetterTileVisuals = api;
})();
