// Scroll choreography driver. Reveals and the pipeline draw are CSS
// transitions toggled by a single IntersectionObserver; the hero and watch
// parallax are CSS scroll-driven animations (see sections.css) — no
// animation library in the bundle.

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const reveals = Array.from(document.querySelectorAll<HTMLElement>('.reveal, .reveal-stagger'));
const pipe = document.querySelector('.mirror__pipe');

if (reduced || !('IntersectionObserver' in window)) {
  // No choreography: everything visible, immediately.
  reveals.forEach((el) => el.classList.add('is-visible'));
  pipe?.classList.add('is-visible');
} else {
  // Hero plays on load; everything else reveals as it scrolls into view.
  document.querySelectorAll('#hero .reveal').forEach((el) => el.classList.add('is-visible'));

  const pending = new Set<Element>(reveals.filter((el) => !el.closest('#hero')));
  if (pipe) pending.add(pipe);

  const show = (el: Element) => {
    el.classList.add('is-visible');
    pending.delete(el);
    io.unobserve(el);
  };

  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) show(entry.target);
      }
    },
    // reveal once the element clears the bottom ~18% of the viewport
    { rootMargin: '0px 0px -18% 0px' }
  );
  pending.forEach((el) => io.observe(el));

  // An instant jump (anchor load, find-in-page) can skip elements straight
  // past the viewport without an IO notification — sweep those on scroll.
  let sweepQueued = false;
  const sweep = () => {
    sweepQueued = false;
    pending.forEach((el) => {
      if (el.getBoundingClientRect().bottom < 0) show(el);
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
    { passive: true }
  );
}

// ---- mobile nav disclosure (motion-independent) ----
const nav = document.getElementById('nav');
const burger = nav?.querySelector<HTMLButtonElement>('.nav__burger');
if (nav && burger) {
  const setOpen = (open: boolean) => {
    nav.classList.toggle('is-open', open);
    burger.setAttribute('aria-expanded', String(open));
    burger.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  };
  burger.addEventListener('click', () => setOpen(!nav.classList.contains('is-open')));
  nav.querySelectorAll('.nav__menu a').forEach((a) => a.addEventListener('click', () => setOpen(false)));
  window.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && nav.classList.contains('is-open')) setOpen(false);
  });
}
