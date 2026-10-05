// Run in the local preview: await (await import('./browser-checks.js')).runChecks()
export async function runChecks() {
  const $ = s => document.querySelector(s), results = [];
  const check = (name, pass) => { results.push({name, pass: Boolean(pass)}); if (!pass) throw Error(name); };
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const until = async test => { for (let i = 0; i < 100; i++) { if (test()) return; await wait(100); } throw Error('Timed out waiting for video'); };
  const videos = [...document.querySelectorAll('video')];
  check('Seven matching product videos', videos.length === 7);
  check('Overview occupies the opening', $('#overview video').dataset.videoSrc === 'assets/media/overview.mp4');
  check('No old simulation, recording or replay buttons', !$('#shared-edge') && !$('[data-replay]') && !videos.some(v => v.dataset.videoSrc === 'assets/demo.mp4'));
  check('All videos are silent inline loops without native toolbars', videos.every(v => v.muted && v.defaultMuted && v.loop && v.playsInline && !v.controls));
  check('No missing-capture placeholders', !$('.is-pending'));
  const startTheme = document.documentElement.dataset.theme;
  $('.theme-toggle').click();
  check('Theme switches in one click', document.documentElement.dataset.theme !== startTheme && !$('.appearance-picker'));
  check('Theme persists locally', JSON.parse(localStorage.getItem('bettertile-appearance')).theme === document.documentElement.dataset.theme);
  const light = document.documentElement.dataset.theme === 'light';
  check('Theme button names its next action', $('.theme-toggle').getAttribute('aria-label') === `Switch to ${light ? 'dark' : 'light'} mode`);
  check('Current native icon matches the theme', getComputedStyle($(light ? '.logo-light' : '.logo-dark')).display !== 'none' && $(light ? '.logo-light' : '.logo-dark').src.includes('app-icon-native-'));
  $('.theme-toggle').click();
  const hero = $('#video-overview'), heroButton = $('#overview .video-toggle');
  hero.scrollIntoView({behavior: 'instant', block: 'center'});
  await until(() => hero.readyState >= 2);
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) heroButton.click();
  await until(() => !hero.paused);
  const t = hero.currentTime; await wait(350);
  check('Visible overview plays', hero.currentTime > t);
  heroButton.click(); const pausedAt = hero.currentTime; await wait(250);
  check('Pause stops the video', hero.paused && Math.abs(hero.currentTime - pausedAt) < .06);
  $('#video-bento').scrollIntoView({behavior: 'instant', block: 'center'}); await wait(300);
  hero.scrollIntoView({behavior: 'instant', block: 'center'}); await wait(300);
  check('Manual pause survives leaving and returning', hero.paused);
  heroButton.click(); await until(() => !hero.paused);
  hero.currentTime = hero.duration - .18;
  await until(() => hero.currentTime < 2);
  check('Overview loops through its end', !hero.paused && hero.currentTime < 2);
  for (const video of videos.slice(1)) {
    video.scrollIntoView({behavior: 'instant', block: 'center'});
    await until(() => video.readyState >= 2);
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) video.closest('figure').querySelector('button').click();
    await until(() => !video.paused);
    check(`${video.id} loads at 1080p`, video.videoWidth === 1920 && video.videoHeight === 1080 && !video.error);
    video.currentTime = video.duration - .12;
    await until(() => video.currentTime < 2);
    check(`${video.id} loops`, !video.paused);
  }
  check('Offscreen overview pauses', hero.paused);
  const faq = $('.faq-list details'); faq.open = false; faq.querySelector('summary').click();
  check('FAQ remains usable', faq.open); faq.open = false;
  $('.menu-toggle').click(); check('Mobile menu opens', !$('#mobile-menu').hidden);
  $('#mobile-menu a').click(); check('Mobile navigation closes after selection', $('#mobile-menu').hidden);
  check('No document overflow', document.documentElement.scrollWidth <= innerWidth);
  check('Unique IDs', new Set([...document.querySelectorAll('[id]')].map(el => el.id)).size === document.querySelectorAll('[id]').length);
  scrollTo({top: 0, behavior: 'instant'});
  return results;
}
