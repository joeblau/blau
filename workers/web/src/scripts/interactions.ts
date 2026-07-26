/*
 * Landing page micro-interactions. Bundled by Astro into an external module
 * (CSP: script-src 'self'), so no inline code or style mutations — this file
 * only toggles classes, data attributes, and text content.
 */

const root = document.documentElement;
root.classList.add('js');

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

/* ----- Theme: system by default, explicit override persisted --------------- */

const THEME_KEY = 'blau-theme';
const themeToggle = document.querySelector<HTMLButtonElement>('[data-theme-toggle]');
const themeMetas = document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]');

type Theme = 'light' | 'dark';

function systemTheme(): Theme {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function effectiveTheme(): Theme {
  const explicit = root.dataset.theme;
  return explicit === 'light' || explicit === 'dark' ? explicit : systemTheme();
}

function applyTheme(theme: Theme, persist: boolean): void {
  root.dataset.theme = theme;
  if (persist) {
    try {
      localStorage.setItem(THEME_KEY, theme);
    } catch {
      // Private browsing may refuse storage; the override still applies now.
    }
  }
  const color = theme === 'dark' ? '#05070a' : '#f6f7fa';
  themeMetas.forEach((meta) => meta.setAttribute('content', color));
  themeToggle?.setAttribute('aria-pressed', String(theme === 'dark'));
  themeToggle?.setAttribute(
    'aria-label',
    theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode',
  );
}

try {
  const stored = localStorage.getItem(THEME_KEY);
  if (stored === 'light' || stored === 'dark') applyTheme(stored, false);
} catch {
  // No storage available; follow the system theme.
}

themeToggle?.addEventListener('click', () => {
  applyTheme(effectiveTheme() === 'dark' ? 'light' : 'dark', true);
});

// Keep the toggle's aria state honest when the system theme flips and no
// explicit override is active.
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (root.dataset.theme !== 'light' && root.dataset.theme !== 'dark') {
    applyTheme(systemTheme(), false);
    delete root.dataset.theme;
  }
});

/* ----- Nav: condense on scroll --------------------------------------------- */

const nav = document.querySelector<HTMLElement>('[data-nav]');

function syncNav(): void {
  nav?.classList.toggle('is-scrolled', window.scrollY > 8);
}

syncNav();
window.addEventListener('scroll', syncNav, { passive: true });

/* ----- Scroll reveals -------------------------------------------------------- */

const revealTargets = document.querySelectorAll<HTMLElement>('[data-reveal]');

if (reducedMotion.matches || !('IntersectionObserver' in window)) {
  revealTargets.forEach((el) => el.classList.add('is-visible'));
} else {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          observer.unobserve(entry.target);
        }
      }
    },
    { threshold: 0.15, rootMargin: '0px 0px -8% 0px' },
  );
  revealTargets.forEach((el) => observer.observe(el));
}

/* ----- Hero terminal: typing loop -------------------------------------------- */

interface TermBeat {
  cmd: string;
  out: string[];
}

const termBeats: TermBeat[] = [
  {
    cmd: 'agent run "refactor settings to Swift 6"',
    out: ['✓ plan drafted — 6 steps, 3 files', '✓ 42/42 tests passing', '→ pull request opened for review'],
  },
  {
    cmd: 'mirror pilot --to plotter --codec hevc',
    out: ['✓ FrameLink authenticated · pinned peer', '→ streaming 60 fps · annotation channel open'],
  },
  {
    cmd: 'wingman bind pinch "git push"',
    out: ['✓ gesture bound on watch', '→ relaying live via paired Copilot'],
  },
];

const typer = document.querySelector<HTMLElement>('[data-typer]');
const termOut = document.querySelector<HTMLElement>('[data-term-out]');

function renderBeatInstantly(beat: TermBeat): void {
  if (!typer || !termOut) return;
  typer.textContent = beat.cmd;
  termOut.replaceChildren();
  for (const line of beat.out) {
    const p = document.createElement('p');
    p.className = 'terminal__out-line';
    p.textContent = line;
    termOut.appendChild(p);
  }
}

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

async function runTerminal(): Promise<void> {
  if (!typer || !termOut) return;
  for (let i = 0; ; i += 1) {
    const beat = termBeats[i % termBeats.length];
    termOut.replaceChildren();
    typer.textContent = '';
    for (const char of beat.cmd) {
      typer.textContent += char;
      await sleep(24 + Math.random() * 42);
    }
    await sleep(350);
    for (const line of beat.out) {
      const p = document.createElement('p');
      p.className = 'terminal__out-line';
      p.textContent = line;
      termOut.appendChild(p);
      await sleep(340);
    }
    await sleep(2800);
  }
}

if (typer && termOut) {
  if (reducedMotion.matches) {
    renderBeatInstantly(termBeats[0]);
  } else {
    void runTerminal();
  }
}
