import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';

gsap.registerPlugin(ScrollTrigger);

const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const reveals = Array.from(document.querySelectorAll<HTMLElement>('.reveal, .reveal-stagger'));

if (reduced) {
  // No choreography: everything visible, immediately.
  reveals.forEach((el) => el.classList.add('is-visible'));
} else {
  // Hero plays on load; everything else reveals as it scrolls into view.
  document.querySelectorAll('#hero .reveal').forEach((el) => el.classList.add('is-visible'));

  reveals
    .filter((el) => !el.closest('#hero'))
    .forEach((el) => {
      ScrollTrigger.create({
        trigger: el,
        start: 'top 82%',
        once: true,
        onEnter: () => el.classList.add('is-visible'),
      });
    });

  // Hero centerpiece: a slow drift against the scroll, like instruments settling.
  gsap.to('.hero__stage', {
    y: -28,
    ease: 'none',
    scrollTrigger: {
      trigger: '.hero__stage',
      start: 'top bottom',
      end: 'bottom top',
      scrub: true,
    },
  });

  // Mirror pipeline: draw the chain node by node when it enters.
  // The stagger lives in CSS transition-delays; this only flips the class.
  const pipe = document.querySelector('.mirror__pipe');
  if (pipe) {
    ScrollTrigger.create({
      trigger: pipe,
      start: 'top 80%',
      once: true,
      onEnter: () => pipe.classList.add('is-visible'),
    });
  }

  // Control stage: phone and watch part slightly as you scroll past — one
  // subtle depth cue on the page's single layered composition.
  if (window.matchMedia('(min-width: 1025px)').matches) {
    gsap.to('.control__watch', {
      y: -20,
      ease: 'none',
      scrollTrigger: {
        trigger: '.control__stage',
        start: 'top bottom',
        end: 'bottom top',
        scrub: true,
      },
    });
  }
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
