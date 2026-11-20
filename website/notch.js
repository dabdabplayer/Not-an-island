const live = document.querySelector('.live');
const island = live.querySelector('.island');
const bubble = live.querySelector('.bubble');

let closeTimer;
let momentTimer;

function open(view) {
  clearTimeout(closeTimer);
  delete live.dataset.moment;
  live.dataset.open = view;
}

function close(delay = 250) {
  clearTimeout(closeTimer);
  closeTimer = setTimeout(() => delete live.dataset.open, delay);
}

function showMoment() {
  if (live.dataset.open) return;
  clearTimeout(momentTimer);
  live.dataset.moment = 'charging';
  momentTimer = setTimeout(() => delete live.dataset.moment, 3200);
}

// A mouse opens it like the real notch; a tap toggles it.
island.addEventListener('pointerenter', e => { if (e.pointerType === 'mouse') open('music'); });
bubble.addEventListener('pointerenter', e => { if (e.pointerType === 'mouse') open('timer'); });
live.addEventListener('pointerleave', e => { if (e.pointerType === 'mouse') close(); });
live.addEventListener('click', e => {
  if (e.pointerType === 'mouse') return;
  if (live.dataset.open) close(0);
  else open(e.target.closest('.bubble') ? 'timer' : 'music');
});

// The section in the middle of the window decides what the notch shows.
const sceneObserver = new IntersectionObserver(entries => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const scene = entry.target.dataset.scene;
    if (scene === 'charging') {
      showMoment();
    } else if (scene !== live.dataset.scene) {
      live.dataset.scene = scene;
    }
  }
}, { rootMargin: '-45% 0px -45% 0px' });
document.querySelectorAll('[data-scene]:not(.live)').forEach(el => sceneObserver.observe(el));

// The Timer extension in the bubble counts down from four minutes, then starts again.
const timerText = live.querySelector('[data-timer]');
const ring = live.querySelector('.ring');
const total = 240;
let remaining = total;
setInterval(() => {
  remaining = remaining > 0 ? remaining - 1 : total;
  timerText.textContent = `${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, '0')}`;
  ring.style.setProperty('--elapsed', (1 - remaining / total) * 100);
}, 1000);

// Open once on arrival so people see what it does.
const prefersReducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
if (!prefersReducedMotion) {
  setTimeout(() => {
    if (live.dataset.open || live.dataset.moment) return;
    open('music');
    close(2400);
  }, 900);
}

fetch('https://api.github.com/repos/dabdabplayer/Not-an-island/releases/latest')
  .then(response => (response.ok ? response.json() : null))
  .then(release => {
    if (!release?.tag_name) return;
    const version = document.querySelector('.version');
    version.textContent = ` Version ${release.tag_name.replace(/^v/, '')}.`;
    version.hidden = false;
  })
  .catch(() => {});
