// BetterTile website: mobile menu and video playback. Nothing else. The tour autoplays in view;
// feature demos play only when pressed. Play measures its video on click, and the picture and its
// control both count as "in view".
(() => {
  // Menu
  const bar = document.querySelector('.bar-inner');
  const menuBtn = document.querySelector('.menu-btn');
  const nav = document.getElementById('site-nav');
  const setMenu = (open) => {
    bar.classList.toggle('open', open);
    menuBtn.setAttribute('aria-expanded', String(open));
    menuBtn.setAttribute('aria-label', open ? 'Close menu' : 'Menu');
  };
  // The nav sits before Download in the DOM (the desktop order), so on open focus moves to the first
  // link: Tab then walks the five links, Download and the Menu button. Escape returns to the button.
  menuBtn.addEventListener('click', () => {
    const open = menuBtn.getAttribute('aria-expanded') !== 'true';
    setMenu(open);
    if (open) nav.querySelector('a').focus();
  });
  nav.addEventListener('click', (e) => { if (e.target.closest('a')) setMenu(false); });
  // Focus that leaves the bar (Tab past the Menu button, Shift+Tab past the brand) closes the menu.
  bar.addEventListener('focusout', (e) => {
    if (e.relatedTarget && !bar.contains(e.relatedTarget) && menuBtn.getAttribute('aria-expanded') === 'true') setMenu(false);
  });
  // A tap or click outside the bar closes the menu too (a press on a non-focusable spot moves no focus).
  document.addEventListener('pointerdown', (e) => {
    if (menuBtn.getAttribute('aria-expanded') === 'true' && !bar.contains(e.target)) setMenu(false);
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && menuBtn.getAttribute('aria-expanded') === 'true') { setMenu(false); menuBtn.focus(); }
  });
  menuBtn.hidden = false; // shown only once its handler is attached

  // Videos. The markup carries native controls so videos play without JS; the script
  // swaps them for one quiet corner button per video. At most one video plays at a time.
  // The tour autoplays while it is mostly in view and loops. A feature demo plays only after
  // the visitor presses Play (on the button or the picture); it loops while any part of it or its
  // control is in view, pauses on its current frame when it leaves, and does not resume by itself.
  // A pressed demo pauses the tour, and the tour does not start over it. Reduced motion: the tour
  // also waits for Play. With preload="none", nothing but the tour loads before a press.
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  // Each control lives in its video's figure.
  const controlOf = (f) => f.closest('figure')?.querySelector('.play');
  const frames = [...document.querySelectorAll('.media-frame')].filter((f) => f.querySelector('video') && controlOf(f));
  const tour = frames.find((f) => f.closest('#tour')) || null;
  const seen = new Map(); // frame -> { ratio, area }
  const seenControl = new Map(); // frame -> ratio of its control
  let chosen = null;      // the frame the visitor pressed Play on; it plays only while some part is in view
  const hasIO = 'IntersectionObserver' in window;
  // A frame counts as in view while any part of it, or of its control, is on screen.
  const inView = (f) => !hasIO || (seen.get(f)?.ratio || 0) > 0 || (seenControl.get(f) || 0) > 0;
  // A click can arrive before the observer reports a video that just scrolled into view
  // (keyboard focus, a fast tap). Measure the frame and its control at once, so Play always
  // starts a video whose control shows, even when the picture itself has just left the screen.
  const ratioOf = (el) => {
    const r = el.getBoundingClientRect();
    const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    const total = r.width * r.height;
    return { ratio: total ? (w * h) / total : 0, area: w * h };
  };
  const measure = (f) => { seen.set(f, ratioOf(f)); seenControl.set(f, ratioOf(controlOf(f)).ratio); };

  const show = (btn, playing) => {
    btn.dataset.state = playing ? 'playing' : 'paused';
    btn.setAttribute('aria-label', playing ? (btn.dataset.labelPause || 'Pause video') : (btn.dataset.labelPlay || 'Play video'));
  };

  const update = () => {
    // A pressed video keeps priority only while in view. Once it leaves, it pauses and the flag clears.
    if (chosen && !inView(chosen)) chosen = null;
    let best = chosen && !chosen.userPaused ? chosen : null;
    // Only the tour starts by itself: mostly in view, not paused by hand, no reduced motion.
    if (!best && tour && !reduce.matches && !tour.userPaused && (seen.get(tour)?.ratio || 0) >= 0.45) best = tour;
    frames.forEach((f) => {
      const v = f.querySelector('video');
      const play = f === best && !document.hidden;
      if (play && v.paused) v.play().catch(() => {});
      else if (!play && !v.paused) v.pause();
    });
  };

  frames.forEach((frame) => {
    const video = frame.querySelector('video');
    const btn = controlOf(frame);
    frame.userPaused = false; // an explicit Pause; it always wins
    video.controls = false;
    show(btn, false);
    video.addEventListener('play', () => show(btn, true));
    video.addEventListener('pause', () => show(btn, false));
    const toggle = () => {
      if (video.paused) { frame.userPaused = false; chosen = frame; measure(frame); update(); }
      else { frame.userPaused = true; if (chosen === frame) chosen = null; video.pause(); update(); }
    };
    btn.addEventListener('click', toggle);
    // The picture is a pointer target too; keyboard users press the button.
    video.addEventListener('click', toggle);
    btn.hidden = false;
  });

  reduce.addEventListener('change', update);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) frames.forEach((f) => f.querySelector('video').pause());
    else update();
  });

  if (!hasIO) return;
  const frameOfControl = new Map(frames.map((f) => [controlOf(f), f]));
  const io = new IntersectionObserver((entries) => {
    entries.forEach(({ target, intersectionRatio, intersectionRect }) => {
      if (frameOfControl.has(target)) seenControl.set(frameOfControl.get(target), intersectionRatio);
      else seen.set(target, { ratio: intersectionRatio, area: intersectionRect.width * intersectionRect.height });
    });
    update();
  }, { threshold: [0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.75, 0.9, 1] });
  frames.forEach((f) => { io.observe(f); io.observe(controlOf(f)); });
})();
