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

// One click switches appearance. The preference never leaves this browser.
const root = document.documentElement, themeToggle = $('.theme-toggle');
function applyAppearance() {
  const light = root.dataset.theme === 'light';
  themeToggle.setAttribute('aria-label', `Switch to ${light ? 'dark' : 'light'} mode`);
  themeToggle.title = themeToggle.getAttribute('aria-label');
  $('meta[name="theme-color"]').content = light ? '#f6f8fc' : '#07090d';
  try { localStorage.setItem('bettertile-appearance', JSON.stringify({theme: light ? 'light' : 'dark'})); } catch {}
}
themeToggle.addEventListener('click', () => {
  root.dataset.theme = root.dataset.theme === 'light' ? 'dark' : 'light';
  applyAppearance();
});
applyAppearance();

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
