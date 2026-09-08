(() => {
  'use strict';

  // Percent rectangles: x, y, width, height, opacity. Studio, Notes, then Music.
  const layouts = [
    [[29, 23, 65, 67, 1], [7, 7, 49, 77, 1], [65, 75, 33, 30, 0]],
    [[51, 3, 47, 94, 1], [2, 3, 47, 94, 1], [65, 75, 33, 30, 0]],
    [[65, 3, 33, 94, 1], [2, 3, 61, 94, 1], [65, 75, 33, 30, 0]],
    [[65, 3, 33, 54, 1], [2, 3, 61, 94, 1], [65, 59, 33, 38, 1]],
    [[65, 3, 33, 54, 1], [2, 3, 61, 94, 1], [65, 59, 33, 38, 1]]
  ];
  function storyFrame(progress) {
    const value = Math.max(0, Math.min(4, progress));
    const start = Math.floor(value);
    const fraction = value - start;
    const eased = fraction * fraction * (3 - 2 * fraction);
    return layouts[start].map((rect, window) => rect.map((n, dimension) =>
      n + (layouts[Math.min(4, start + 1)][window][dimension] - n) * eased));
  }
  if (typeof module !== 'undefined') module.exports = { storyFrame };
  if (typeof document === 'undefined') return;

  const story = document.querySelector('.desktop-story');
  if (!story) return;
  const desktop = story.querySelector('[data-desktop]');
  const windows = [...story.querySelectorAll('[data-story-window]')];
  const chapters = [...story.querySelectorAll('.story-chapter')];
  const buttons = [...story.querySelectorAll('[data-story-step]')];
  const compact = matchMedia('(max-width: 760px), (max-height: 600px)');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const statuses = ['Your desktop. A little more together.', 'Drag. Preview. Snap into place.', 'Make room. Both sides resize together.', 'A new window. A natural fit.', 'Control + Option + Shift. Your next move.'];
  const descriptions = ['Overlapping Notes and Studio windows', 'Notes and Studio snapped into adjacent halves', 'Notes expanded while Studio narrows along their shared boundary', 'Bento makes room for Music beneath Studio, with Notes on the left', 'Layout Wheel at the pointer over Notes, with Top Half highlighted'];
  const seam = story.querySelector('.story-seam');
  const pointer = story.querySelector('.story-pointer');
  const wheel = story.querySelector('.story-wheel');
  wheel.innerHTML = window.BetterTileVisuals.wheelMarkup();
  const snap = story.querySelector('.snap-outline');
  let selected = 0;
  let pending = false;

  function render(progress) {
    const value = reduced.matches ? Math.round(progress) : progress;
    const frame = storyFrame(value);
    windows.forEach((element, index) => {
      const [left, top, width, height, opacity] = frame[index];
      Object.assign(element.style, { left: `${left}%`, top: `${top}%`, width: `${width}%`, height: `${height}%`, opacity });
    });
    const step = Math.round(value);
    desktop.dataset.step = step;
    selected = step;
    chapters.forEach((chapter, index) => chapter.classList.toggle('active', index === step));
    buttons.forEach((button, index) => button.setAttribute('aria-pressed', String(index === step)));
    story.querySelector('[data-story-status]').textContent = statuses[step];
    desktop.setAttribute('aria-label', `Illustrative desktop: ${descriptions[step]}.`);
    snap.style.opacity = value > .1 && value < .9 ? String(Math.sin(value * Math.PI) * .8) : '0';
    seam.style.left = `${frame[1][0] + frame[1][2] + 1}%`;
    seam.style.opacity = value >= 1.2 && value < 2.7 ? '1' : '0';
    wheel.style.opacity = value > 3.5 ? String((value - 3.5) * 2) : '0';
    Object.assign(pointer.style, {
      left: value > 3.5 ? '35%' : value > 1.2 ? seam.style.left : `${frame[1][0] + 25}%`,
      top: value > 3.5 ? '33%' : value > 1.2 ? '52%' : `${frame[1][1] + 3}%`,
      opacity: value > .1 && value < 2.7 || value > 3.5 ? '1' : '0'
    });
  }

  function update() {
    pending = false;
    if (compact.matches) return render(selected);
    const centers = chapters.map(chapter => {
      const rect = chapter.getBoundingClientRect();
      return rect.top + rect.height / 2;
    });
    const focus = innerHeight / 2;
    let progress = 0;
    for (let index = 0; index < centers.length - 1; index++) {
      if (focus >= centers[index]) progress = index + Math.min(1, (focus - centers[index]) / (centers[index + 1] - centers[index]));
    }
    render(progress);
  }
  function schedule() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(update);
  }
  buttons.forEach((button, index) => button.addEventListener('click', () => {
    if (compact.matches) render(index);
    else chapters[index].scrollIntoView({ block: 'center', behavior: reduced.matches ? 'instant' : 'smooth' });
  }));
  story.classList.add('enhanced');
  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', schedule);
  compact.addEventListener('change', schedule);
  reduced.addEventListener('change', schedule);
  update();
})();
