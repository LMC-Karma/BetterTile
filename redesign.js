const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];

const menu = $('.menu-toggle');
function closeMenu() { menu.setAttribute('aria-expanded', 'false'); $('#mobile-menu').hidden = true; }
menu.addEventListener('click', () => {
  const open = menu.getAttribute('aria-expanded') !== 'true';
  menu.setAttribute('aria-expanded', String(open));
  $('#mobile-menu').hidden = !open;
});
$$('#mobile-menu a').forEach(link => link.addEventListener('click', closeMenu));
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && !$('#mobile-menu').hidden) { closeMenu(); menu.focus(); }
});

// Silent loops run only in view. An explicit pause survives scrolling away and back.
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const states = new Map();
$$('video[data-video-src]').forEach(video => {
  const figure = video.closest('figure'), button = figure.querySelector('.video-toggle');
  const error = figure.querySelector('.video-error');
  const caption = figure.querySelector('figcaption').textContent;
  const state = {visible: false, choice: null};
  states.set(video, state);
  video.muted = true;
  video.autoplay = false; // Start through visibility/reduced-motion policy, not the browser race.
  button.hidden = false;
  const update = () => {
    button.dataset.paused = String(video.paused);
    button.setAttribute('aria-label', `${video.paused ? 'Play' : 'Pause'} ${caption} video`);
    button.title = video.paused ? 'Play video' : 'Pause video';
  };
  video.addEventListener('play', update);
  video.addEventListener('pause', update);
  video.addEventListener('error', () => { error.hidden = false; update(); });
  button.addEventListener('click', () => {
    state.choice = video.paused;
    if (video.error) { video.load(); error.hidden = true; }
    sync(video);
  });
});
function sync(video) {
  const state = states.get(video);
  const play = state.visible && !document.hidden && (state.choice ?? !reduced.matches);
  if (!play) { video.pause(); return; }
  if (!video.getAttribute('src')) video.src = video.dataset.videoSrc;
  video.play().catch(() => {
    // Autoplay can be refused; the visible Play control remains usable.
    const button = video.closest('figure').querySelector('.video-toggle');
    button.dataset.paused = 'true';
  });
}
if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      states.get(entry.target).visible = entry.isIntersecting && entry.intersectionRatio >= .2;
      sync(entry.target);
    });
  }, {threshold: [0, .2]});
  states.forEach((_, video) => observer.observe(video));
} else states.forEach((state, video) => { state.visible = true; sync(video); });
document.addEventListener('visibilitychange', () => states.forEach((_, video) => sync(video)));
reduced.addEventListener('change', () => {
  states.forEach((state, video) => { state.choice = null; sync(video); });
});
$$('.feature-index a').forEach(link => link.addEventListener('click', () => {
  $$('.feature-index a').forEach(item => item.classList.toggle('is-active', item === link));
}));

// The ownership tiles share one edge. Drag it, or use the arrow keys, and both sides resize together.
const tiles = $('[data-tiles]'), seam = tiles?.querySelector('.tile-seam');
if (seam) {
  const min = Number(seam.getAttribute('aria-valuemin')), max = Number(seam.getAttribute('aria-valuemax'));
  const setSplit = value => {
    const split = Math.round(Math.min(max, Math.max(min, value)));
    tiles.style.setProperty('--split', split);
    seam.setAttribute('aria-valuenow', String(split));
    seam.setAttribute('aria-valuetext', `Left panes ${split}% wide`);
  };
  const splitAt = clientX => {
    const box = tiles.getBoundingClientRect();
    return (clientX - box.left) / box.width * 100;
  };
  seam.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    seam.setPointerCapture(event.pointerId);
    tiles.classList.add('is-dragging');
    setSplit(splitAt(event.clientX));
  });
  seam.addEventListener('pointermove', event => {
    if (seam.hasPointerCapture(event.pointerId)) setSplit(splitAt(event.clientX));
  });
  const release = event => {
    if (seam.hasPointerCapture(event.pointerId)) seam.releasePointerCapture(event.pointerId);
    tiles.classList.remove('is-dragging');
  };
  seam.addEventListener('pointerup', release);
  seam.addEventListener('pointercancel', release);
  seam.addEventListener('keydown', event => {
    const now = Number(seam.getAttribute('aria-valuenow'));
    const step = {ArrowLeft: -4, ArrowRight: 4, Home: min - now, End: max - now}[event.key];
    if (step === undefined) return;
    event.preventDefault();
    setSplit(now + step);
  });
  setSplit(Number(seam.getAttribute('aria-valuenow')));
}

// The header frosts once the page moves under it.
const header = $('.site-header');
let ticking = false;
const frost = () => { header.classList.toggle('is-scrolled', scrollY > 8); ticking = false; };
addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(frost); } }, {passive: true});
frost();

// Media and panels rise into place once, as they enter the viewport.
const revealable = $$('.media-section .feature-media, .feature-card .feature-media, .tile, .compare-table, .step-visual, .release-strip');
if ('IntersectionObserver' in window && !reduced.matches) {
  const revealer = new IntersectionObserver(entries => entries.forEach(entry => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('is-in');
    revealer.unobserve(entry.target);
  }), {rootMargin: '0px 0px -8% 0px', threshold: .12});
  revealable.forEach(el => { el.classList.add('reveal'); revealer.observe(el); });
}
