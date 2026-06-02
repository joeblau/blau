const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

// ── Scroll reveal ─────────────────────────────────────────────
// Two conventions live on the page: `[data-reveal]` (toggles .is-in)
// and `.reveal` (toggles .visible). One observer drives both.
if (!prefersReducedMotion && 'IntersectionObserver' in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const el = entry.target as HTMLElement;
        el.classList.add('is-in', 'visible');
        observer.unobserve(el);
      }
    },
    { threshold: 0.12, rootMargin: '0px 0px -48px 0px' }
  );

  document
    .querySelectorAll<HTMLElement>('[data-reveal], .reveal')
    .forEach((el) => observer.observe(el));
} else {
  document
    .querySelectorAll<HTMLElement>('[data-reveal], .reveal')
    .forEach((el) => el.classList.add('is-in', 'visible'));
}

// ── Nav: stronger backdrop once scrolled ──────────────────────
const nav = document.querySelector<HTMLElement>('[data-nav]');
if (nav) {
  const onScroll = () => nav.classList.toggle('is-scrolled', window.scrollY > 8);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });
}

// ── Copy-to-clipboard chips (e.g. the install command) ────────
document.querySelectorAll<HTMLButtonElement>('[data-copy]').forEach((btn) => {
  btn.addEventListener('click', async () => {
    const text = btn.getAttribute('data-copy');
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      btn.classList.add('is-copied');
      const label = btn.querySelector('.cta__cmd');
      const original = label?.textContent ?? '';
      if (label) label.textContent = 'copied to clipboard';
      window.setTimeout(() => {
        btn.classList.remove('is-copied');
        if (label) label.textContent = original;
      }, 1400);
    } catch {
      /* clipboard unavailable — no-op */
    }
  });
});
