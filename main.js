(() => {
  'use strict';

  const clamp = (value) => Math.max(25, Math.min(75, Math.round(value)));
  const keyMove = (x, y, key, shiftKey = false) => {
    const step = shiftKey ? 10 : 2;
    const moves = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step], Home: [50 - x, 50 - y] };
    return moves[key] ? [clamp(x + moves[key][0]), clamp(y + moves[key][1])] : null;
  };
  const demoPages = {
    general: 'General permission accessibility appearance dark system shortcuts update keyboard drag snapping',
    layout: 'Window Layout native bento resize linked divider keyboard single window placement default mode',
    snap: 'Snap Zones drag edge corner title bar double click maximize',
    menu: 'Menu Bar actions order visibility reorder',
    wheel: 'Layout Wheel radial ring sector hub control option shift middle click activation',
    apps: 'Per-App Rules application exclude ignore bento exception manage normally'
  };
  function matchingPages(query) {
    const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return Object.keys(demoPages).filter(name => terms.every(term => demoPages[name].toLowerCase().includes(term)));
  }
  if (typeof module !== 'undefined') module.exports = { clamp, keyMove, matchingPages };
  if (typeof document === 'undefined') return;

  const themeToggle = document.querySelector('.theme-toggle');
  const systemTheme = matchMedia('(prefers-color-scheme: dark)');
  let savedTheme;
  try { savedTheme = localStorage.getItem('bettertile-theme'); } catch {}
  function setTheme(dark) {
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    themeToggle.setAttribute('aria-pressed', String(dark));
    themeToggle.title = dark ? 'Switch to light mode' : 'Switch to dark mode';
    document.querySelector('meta[name="theme-color"]').content = dark ? '#171a21' : '#f6f7fb';
  }
  setTheme(savedTheme ? savedTheme === 'dark' : systemTheme.matches);
  themeToggle.addEventListener('click', () => {
    savedTheme = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    setTheme(savedTheme === 'dark');
    try { localStorage.setItem('bettertile-theme', savedTheme); } catch {}
  });
  systemTheme.addEventListener('change', () => { if (!savedTheme) setTheme(systemTheme.matches); });

  const demo = document.querySelector('[data-product-demo]');
  if (!demo) return;

  const panels = [...demo.querySelectorAll('[data-page-panel]')];
  const pageButtons = [...demo.querySelectorAll('[data-demo-page]')];
  const content = (name) => demo.querySelector(`[data-native-page-content="${name}"]`);
  const { actionIcon, wheelMarkup, placements: actionPlacements } = window.BetterTileVisuals;
  const navIcons = {
    general: '<path d="m9 3 1-2h4l1 2 3 1 2-1 2 3-1 2v3l2 2-2 3-2-1-3 2v2h-4l-1-2-3-1-2 1-2-3 1-2V9L2 7l2-3 2 1Z"/><circle cx="12" cy="10" r="3"/>',
    layout: '<rect x="2" y="3" width="12" height="7" rx="1.5"/><rect x="2" y="14" width="8" height="7" rx="1.5"/><rect x="14" y="7" width="8" height="14" rx="1.5"/>',
    snap: '<rect x="2" y="3" width="20" height="18" rx="2"/><path d="M9 3v18 M15 3v18 M2 9h20 M2 15h20"/>',
    menu: '<path d="M3 6h18 M3 12h18 M3 18h18"/>',
    wheel: [0, 1, 2, 3, 4, 5].map(i => `<circle cx="${12 + Math.sin(i * Math.PI / 3) * 8}" cy="${12 + Math.cos(i * Math.PI / 3) * 8}" r="2.5"/>`).join('') + '<circle cx="12" cy="12" r="2"/>',
    apps: '<path d="M12 21H6a4 4 0 0 1-4-4V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4v6"/><circle cx="18" cy="18" r="5"/><path d="m15 18 2 2 4-4"/>'
  };
  demo.querySelectorAll('[data-demo-page]').forEach(button => {
    button.querySelector('i').outerHTML = `<svg class="sidebar-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${navIcons[button.dataset.demoPage || 'apps']}</svg>`;
  });
  const zoneNames = ['Top left corner', 'Top edge', 'Top right corner', 'Left edge', 'Right edge', 'Bottom left corner', 'Bottom edge', 'Bottom right corner'];
  const defaultZoneActions = ['Top Left Quarter', 'Almost Maximize', 'Top Right Quarter', 'Left Half', 'Right Half', 'Bottom Left Quarter', 'Disabled', 'Bottom Right Quarter'];
  let zoneActions = [...defaultZoneActions];
  let selectedZone = 0;
  const actions = ['Left Half', 'Right Half', 'Top Half', 'Bottom Half', 'Left Third', 'Center Third', 'Right Third', 'Maximize'];
  let selectedActions = actions.slice(0, 6);

  content('snap').innerHTML = `
    <div class="snap-heading"><h4>Screen edge actions</h4><button type="button" class="native-quiet" data-reset-snap>Restore Defaults</button></div>
    <div class="native-card snap-card">
      <div class="snap-map">
        ${['Top left', 'Top', 'Top right', 'Left', 'Right', 'Bottom left', 'Bottom', 'Bottom right'].map((name, index) => `<button type="button" data-snap-zone="${index}" aria-pressed="${index === 0}">${actionIcon(zoneActions[index])}<span>${name}<small>${zoneActions[index]}</small></span></button>`).join('')}
        <div class="snap-monitor" aria-hidden="true"><div class="snap-screen"><div class="snap-placement">${actionIcon(zoneActions[0])}</div></div><i class="snap-edge-marker" data-edge="0"></i></div>
      </div>
      <div class="snap-legend"><span>↖ &nbsp; Drag here</span><span>▱ &nbsp; Window placement</span></div>
      <div class="native-row"><span><strong data-snap-name>Top left corner</strong><small data-snap-action>Window placement: Top Left Quarter</small></span><label class="snap-assignment"><span class="visually-hidden">Action for selected snap zone</span><select data-snap-assignment>${[...Object.keys(actionPlacements), 'Disabled'].map(action => `<option ${action === zoneActions[0] ? 'selected' : ''}>${action}</option>`).join('')}</select></label></div>
    </div>
    <h4>Window Top</h4><div class="native-card"><div class="native-row"><span><strong>Double-click to maximize or restore</strong><small>Works alongside the matching macOS setting.</small></span><button type="button" class="native-switch on" role="switch" aria-checked="true" aria-label="Double-click to maximize or restore"><span></span></button></div></div>`;

  function renderMenu() {
    content('menu').innerHTML = `
      <div class="native-callout"><strong>Your menu, your order</strong><span>Choose actions on the left. The preview updates immediately.</span><small>34 actions available</small></div>
      <div class="menu-demo-grid"><div class="native-card action-catalog"><h4>Available actions</h4>${actions.map((action) => `<label><input type="checkbox" data-menu-action="${action}" ${selectedActions.includes(action) ? 'checked' : ''}><span class="window-glyph" aria-hidden="true"></span>${action}</label>`).join('')}</div>
      <div><h4>Your menu</h4><div class="menu-panel"><div class="menu-panel-brand"><span class="window-glyph" aria-hidden="true"></span><strong>BetterTile</strong><small>Bento</small></div><div class="menu-controls"><span>Window mode</span><strong>Native&nbsp;&nbsp; Bento</strong><small>Active display · 4 visible windows</small><span>Drag snapping</span><span class="native-switch on" aria-hidden="true"><span></span></span><b>Repair Current Bento Layout</b></div><div class="menu-actions"><small>Window actions</small>${selectedActions.length ? selectedActions.map((action) => `<button type="button"><span class="window-glyph" aria-hidden="true"></span>${action}</button>`).join('') : '<p>No window actions<br><small>Choose actions on the left.</small></p>'}</div><div class="menu-panel-foot"><span>Settings</span><span>Quit</span></div></div></div></div>`;
  }

  content('wheel').innerHTML = `
    <h4>Activation</h4><div class="native-card"><div class="native-row"><span><strong>Hold Control + Option + Shift</strong><small>Move to a sector, then release to place the focused window.</small></span><button type="button" class="native-switch on" role="switch" aria-checked="true" aria-label="Enable Layout Wheel"><span></span></button></div></div>
    <h4>Wheel Preview</h4><div class="wheel-demo">${wheelMarkup(true)}<p aria-live="polite"><strong data-wheel-output>Top Half</strong><span>Selected action</span><small>Choose a sector on either ring.<br>The center cancels the selection.</small></p></div>`;

  content('general').innerHTML = `
    <h4>Permissions</h4><div class="native-card"><div class="native-row"><span><strong>Ready to arrange your windows</strong><small>Accessibility access is enabled.</small></span><b class="enabled-state">Enabled</b></div></div>
    <h4>BetterTile Features</h4><div class="native-card"><div class="native-row"><span><strong>BetterTile Keyboard Shortcuts</strong><small>Turning these off keeps every shortcut you set.</small></span><button type="button" class="native-switch on" role="switch" aria-checked="true" aria-label="Enable BetterTile Keyboard Shortcuts"><span></span></button></div><div class="native-row"><span><strong>BetterTile Drag Snapping</strong><small>Turn this off if you prefer macOS edge tiling.</small></span><button type="button" class="native-switch on" role="switch" aria-checked="true" aria-label="Enable BetterTile Drag Snapping"><span></span></button></div></div>
    <h4>Appearance</h4><div class="native-card"><div class="native-row"><span><strong>Appearance</strong><small>System follows the current macOS appearance.</small></span><div class="native-segment"><button type="button" data-appearance="System" aria-pressed="false">System</button><button type="button" data-appearance="Dark" aria-pressed="true">Dark</button></div></div></div>`;

  renderMenu();

  let activePage = 'layout';
  function showPage(name) {
    if (name) activePage = name;
    panels.forEach((panel) => panel.classList.toggle('active', panel.dataset.pagePanel === name));
    pageButtons.forEach((button) => {
      const active = button.dataset.demoPage === name;
      button.classList.toggle('active', active);
      button.setAttribute('aria-pressed', String(active));
    });
  }

  const search = demo.querySelector('[data-demo-search]');
  const empty = demo.querySelector('[data-search-empty]');
  function filterPages() {
    const matches = matchingPages(search.value);
    pageButtons.forEach(button => { button.hidden = !matches.includes(button.dataset.demoPage); });
    demo.querySelectorAll('.native-sidebar > p').forEach(label => { label.hidden = Boolean(search.value.trim()); });
    empty.hidden = matches.length > 0;
    showPage(matches.includes(activePage) ? activePage : matches[0]);
  }
  search.addEventListener('input', filterPages);
  function clearSearch() { search.value = ''; filterPages(); search.focus(); }
  search.addEventListener('keydown', event => { if (event.key === 'Escape') clearSearch(); });
  demo.querySelector('[data-clear-search]').addEventListener('click', clearSearch);
  pageButtons.forEach((button) => button.addEventListener('click', () => showPage(button.dataset.demoPage)));

  const singlePlacement = demo.querySelector('[data-single-placement]');
  singlePlacement.innerHTML = ['Leave Unchanged', ...Object.keys(actionPlacements)].map(action => `<option ${action === 'Maximize' ? 'selected' : ''}>${action}</option>`).join('');
  function updateSingleWindow() {
    const rectangle = actionPlacements[singlePlacement.value] || [.15, .15, .6, .65];
    const [left, top, width, height] = rectangle.map(value => `${value * 100}%`);
    Object.assign(demo.querySelector('[data-single-window]').style, { left, top, width, height });
    demo.querySelector('[data-single-output]').textContent = singlePlacement.value === 'Leave Unchanged' ? 'Notes keeps its existing size and position.' : `Notes uses ${singlePlacement.value} when it becomes the only window.`;
  }
  singlePlacement.addEventListener('change', updateSingleWindow);
  updateSingleWindow();
  demo.querySelector('#default-mode').addEventListener('change', event => {
    demo.querySelector('[data-default-help]').textContent = `New desktops start in ${event.target.value} mode.`;
  });
  function updateLinkedResize() {
    const native = demo.querySelector('[data-mode="Native"]').getAttribute('aria-pressed') === 'true';
    const linked = demo.querySelector('[data-linked-resize]').getAttribute('aria-checked') === 'true';
    demo.querySelector('[data-linked-help]').textContent = native
      ? linked ? 'Native windows resize with their neighbors.' : 'Native windows resize independently.'
      : 'Saved for Native mode. Bento manages its own shared boundaries.';
  }

  demo.addEventListener('click', (event) => {
    const mode = event.target.closest('[data-mode]');
    if (mode) {
      demo.querySelectorAll('[data-mode]').forEach((button) => {
        const active = button === mode;
        button.classList.toggle('selected', active);
        button.setAttribute('aria-pressed', String(active));
      });
      demo.querySelector('[data-context-output]').textContent = `Active display · ${mode.dataset.mode === 'Native' ? 2 : 4} visible windows`;
      demo.querySelector('[data-divider-preview]').dataset.layoutMode = mode.dataset.mode.toLowerCase();
      demo.querySelector('[data-divider]').setAttribute('aria-label', mode.dataset.mode === 'Native' ? 'Linked resize divider' : 'Bento divider');
      setDivider(x, mode.dataset.mode === 'Native' ? 50 : y);
      updateLinkedResize();
    }

    const feedback = event.target.closest('[data-feedback]');
    if (feedback) {
      demo.querySelectorAll('[data-feedback]').forEach((button) => button.setAttribute('aria-pressed', String(button === feedback)));
      demo.querySelector('[data-feedback-output]').textContent = feedback.dataset.feedback === 'ghost' ? 'Ghost Preview' : 'Live Resize';
    }

    const appearance = event.target.closest('[data-appearance]');
    if (appearance) demo.querySelectorAll('[data-appearance]').forEach((button) => button.setAttribute('aria-pressed', String(button === appearance)));

    const zone = event.target.closest('[data-snap-zone]');
    if (zone) selectZone(Number(zone.dataset.snapZone));
    if (event.target.closest('[data-reset-snap]')) {
      zoneActions = [...defaultZoneActions];
      demo.querySelectorAll('[data-snap-zone]').forEach((button, index) => updateZoneButton(button, index));
      selectZone(0);
    }

    const wheel = event.target.closest('[data-wheel-action]');
    if (wheel) {
      demo.querySelectorAll('[data-wheel-action]').forEach((button) => {
        button.setAttribute('aria-pressed', String(button === wheel));
        button.classList.toggle('selected', button === wheel);
      });
      demo.querySelector('[data-wheel-output]').textContent = wheel.dataset.wheelAction;
    }

    const toggle = event.target.closest('.native-switch[role="switch"]');
    if (toggle) {
      const on = toggle.getAttribute('aria-checked') !== 'true';
      toggle.setAttribute('aria-checked', String(on));
      toggle.classList.toggle('on', on);
      if (toggle.matches('[data-linked-resize]')) updateLinkedResize();
    }
  });

  demo.addEventListener('change', (event) => {
    if (event.target.matches('[data-snap-assignment]')) {
      zoneActions[selectedZone] = event.target.value;
      updateZoneButton(demo.querySelector(`[data-snap-zone="${selectedZone}"]`), selectedZone);
      selectZone(selectedZone);
    }
    if (event.target.matches('[data-menu-action]')) {
      selectedActions = event.target.checked ? [...selectedActions, event.target.dataset.menuAction] : selectedActions.filter((action) => action !== event.target.dataset.menuAction);
      renderMenu();
    }
  });

  demo.addEventListener('keydown', event => {
    const sector = event.target.closest('[data-wheel-action]');
    if (sector && ['Enter', ' '].includes(event.key)) {
      event.preventDefault();
      sector.dispatchEvent(new MouseEvent('click', { bubbles: true }));
    }
  });
  function updateZoneButton(button, index) {
    button.querySelector('.app-glyph').outerHTML = actionIcon(zoneActions[index]);
    button.querySelector('small').textContent = zoneActions[index];
  }
  function selectZone(index) {
    selectedZone = index;
    demo.querySelectorAll('[data-snap-zone]').forEach((button, item) => button.setAttribute('aria-pressed', String(item === index)));
    demo.querySelector('[data-snap-name]').textContent = zoneNames[index];
    demo.querySelector('[data-snap-action]').textContent = zoneActions[index] === 'Disabled' ? 'Snapping is disabled here.' : `Window placement: ${zoneActions[index]}`;
    demo.querySelector('[data-snap-assignment]').value = zoneActions[index];
    demo.querySelector('.snap-edge-marker').dataset.edge = index;
    demo.querySelector('.snap-placement').innerHTML = actionIcon(zoneActions[index]);
    const [left, top, width, height] = (actionPlacements[zoneActions[index]] || [0, 0, 0, 0]).map(n => `${n * 100}%`);
    Object.assign(demo.querySelector('.snap-placement').style, { left, top, width, height, opacity: zoneActions[index] === 'Disabled' ? '0' : '1' });
  }
  selectZone(0);

  const width = demo.querySelector('#divider-width');
  const widthOutput = demo.querySelector('output[for="divider-width"]');
  width.addEventListener('input', () => {
    demo.style.setProperty('--divider-width', `${width.value}px`);
    widthOutput.textContent = `${width.value} pt`;
  });

  const preview = demo.querySelector('[data-divider-preview]');
  const divider = demo.querySelector('[data-divider]');
  let x = 50;
  let y = 50;
  let dragStart = null;
  for (const pane of preview.querySelectorAll('.preview-window')) {
    const committed = pane.cloneNode(true);
    committed.classList.add('committed');
    committed.setAttribute('aria-hidden', 'true');
    preview.insertBefore(committed, divider);
  }
  function setDivider(nextX, nextY) {
    x = clamp(nextX);
    y = clamp(nextY);
    preview.style.setProperty('--x', `${x}%`);
    preview.style.setProperty('--y', `${y}%`);
    divider.setAttribute('aria-valuenow', String(x));
    divider.setAttribute('aria-valuetext', preview.dataset.layoutMode === 'native' ? `Native divider: ${x}% across` : `Bento divider: ${x}% across, ${y}% down`);
  }
  demo.querySelector('[data-reset-divider]').addEventListener('click', () => setDivider(50, 50));
  setDivider(x, y);
  function moveDivider(event) {
    const bounds = preview.getBoundingClientRect();
    setDivider(((event.clientX - bounds.left) / bounds.width) * 100, preview.dataset.layoutMode === 'native' ? 50 : ((event.clientY - bounds.top) / bounds.height) * 100);
  }
  divider.addEventListener('pointerdown', (event) => {
    if (!event.isPrimary || event.button !== 0) return;
    event.preventDefault();
    divider.focus({ preventScroll: true });
    dragStart = [x, y];
    preview.style.setProperty('--committed-x', `${x}%`);
    preview.style.setProperty('--committed-y', `${y}%`);
    preview.classList.toggle('ghost-drag', demo.querySelector('[data-feedback="ghost"]').getAttribute('aria-pressed') === 'true');
    divider.setPointerCapture(event.pointerId);
    divider.classList.add('dragging');
    moveDivider(event);
  });
  divider.addEventListener('pointermove', (event) => {
    if (dragStart && divider.hasPointerCapture(event.pointerId)) moveDivider(event);
  });
  function release(event) {
    if (dragStart && event.type !== 'pointerup') setDivider(...dragStart);
    dragStart = null;
    preview.classList.remove('ghost-drag');
    divider.classList.remove('dragging');
    if (event.pointerId !== undefined && divider.hasPointerCapture(event.pointerId)) divider.releasePointerCapture(event.pointerId);
  }
  divider.addEventListener('pointerup', release);
  divider.addEventListener('pointercancel', release);
  divider.addEventListener('lostpointercapture', release);
  divider.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && dragStart) { event.preventDefault(); release(event); return; }
    if (preview.dataset.layoutMode === 'native' && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) return;
    const next = keyMove(x, y, event.key, event.shiftKey);
    if (!next) return;
    event.preventDefault();
    setDivider(next[0], preview.dataset.layoutMode === 'native' ? 50 : next[1]);
  });
})();
