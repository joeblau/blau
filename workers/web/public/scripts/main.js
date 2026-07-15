// Scroll choreography driver. Reveals and the pipeline draw are CSS
// transitions toggled by a single IntersectionObserver; hero and watch
// parallax are CSS scroll-driven animations.
const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const reveals = Array.from(document.querySelectorAll('.reveal, .reveal-stagger'));
const pipe = document.querySelector('.mirror__pipe');

if (reduced || !('IntersectionObserver' in window)) {
  reveals.forEach((element) => element.classList.add('is-visible'));
  pipe?.classList.add('is-visible');
} else {
  document.querySelectorAll('#hero .reveal').forEach((element) =>
    element.classList.add('is-visible'),
  );

  const pending = new Set(reveals.filter((element) => !element.closest('#hero')));
  if (pipe) pending.add(pipe);

  const show = (element) => {
    element.classList.add('is-visible');
    pending.delete(element);
    observer.unobserve(element);
  };

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) show(entry.target);
      }
    },
    { rootMargin: '0px 0px -18% 0px' },
  );
  pending.forEach((element) => observer.observe(element));

  let sweepQueued = false;
  const sweep = () => {
    sweepQueued = false;
    pending.forEach((element) => {
      if (element.getBoundingClientRect().bottom < 0) show(element);
    });
  };
  window.addEventListener(
    'scroll',
    () => {
      if (!sweepQueued && pending.size > 0) {
        sweepQueued = true;
        requestAnimationFrame(sweep);
      }
    },
    { passive: true },
  );
}

const nav = document.getElementById('nav');
const burger = nav?.querySelector('.nav__burger');
if (nav && burger) {
  const setOpen = (open) => {
    nav.classList.toggle('is-open', open);
    burger.setAttribute('aria-expanded', String(open));
    burger.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  };
  burger.addEventListener('click', () =>
    setOpen(!nav.classList.contains('is-open')),
  );
  nav.querySelectorAll('.nav__menu a').forEach((anchor) =>
    anchor.addEventListener('click', () => setOpen(false)),
  );
  window.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && nav.classList.contains('is-open')) {
      setOpen(false);
    }
  });
}

// Desktop scroll-spy: highlight the mock pane matching the row in view.
const cockpit = document.getElementById('cockpit');
if (
  cockpit &&
  'IntersectionObserver' in window &&
  window.matchMedia('(min-width: 1025px)').matches
) {
  const panes = cockpit.querySelectorAll('.cockpit__pane[data-pane-target]');
  const setActivePane = (name) => {
    panes.forEach((pane) =>
      pane.classList.toggle('is-active', pane.dataset.paneTarget === name),
    );
  };
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          setActivePane(entry.target.dataset.pane || 'none');
        }
      });
    },
    { rootMargin: '-42% 0px -42% 0px', threshold: 0 },
  );
  cockpit
    .querySelectorAll('.cockpit__row[data-pane]')
    .forEach((row) => observer.observe(row));
}
