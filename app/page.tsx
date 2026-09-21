import Link from 'next/link';
import { ArrowUpRight } from 'lucide-react';

type Project = {
  name: string;
  description: string;
  href?: string;
};

type Section = {
  id: string;
  title: string;
  projects: Project[];
};

const sections: Section[] = [
  {
    id: 'developer-tools',
    title: 'Developer Tools',
    projects: [
      { name: 'MADE', description: 'Multimodal Agentic Development Environment', href: '/made' },
    ],
  },
  {
    id: 'marketing-tools',
    title: 'Marketing Tools',
    projects: [
      { name: 'Previral', description: 'Attention scanner', href: '/previral' },
      { name: 'ShortReel', description: 'Control your social media via agents', href: '/shotreel' },
    ],
  },
  {
    id: 'entertainment',
    title: 'Entertainment',
    projects: [
      { name: 'Stint', description: 'Formula 1 replay', href: '/stint' },
      { name: 'Stream', description: 'Screen sharing from your Apple devices', href: '/stream' },
      { name: 'Doodle', description: 'Drawing pad', href: 'https://doodle.app' },
    ],
  },
];

const stats = [
  { value: '06', label: 'Projects' },
  { value: '03', label: 'Categories' },
  { value: '01', label: 'Studio' },
];

export default function Home() {
  let projectIndex = 0;

  return (
    <main className="relative min-h-svh overflow-hidden bg-[oklch(0.115_0.015_264)] text-[oklch(0.96_0_0)] selection:bg-cyan-400/30 selection:text-white">
      {/* ambient background */}
      <div aria-hidden="true" className="pointer-events-none absolute inset-0">
        <div className="absolute inset-0 bg-[linear-gradient(to_right,oklch(1_0_0/0.035)_1px,transparent_1px),linear-gradient(to_bottom,oklch(1_0_0/0.035)_1px,transparent_1px)] bg-[size:72px_72px] [mask-image:radial-gradient(ellipse_80%_60%_at_50%_0%,black_15%,transparent_100%)]" />
        <div className="absolute -top-48 left-1/2 h-[560px] w-[920px] -translate-x-1/2 rounded-full bg-[radial-gradient(closest-side,oklch(0.55_0.2_255/0.4),transparent)] blur-3xl" />
        <div className="absolute top-1/3 -right-48 h-[420px] w-[420px] rounded-full bg-[radial-gradient(closest-side,oklch(0.75_0.14_195/0.2),transparent)] blur-3xl" />
      </div>

      {/* nav */}
      <header className="relative z-10 mx-auto flex max-w-6xl items-center justify-between px-6 py-6 sm:px-10">
        <a href="/" className="font-mono text-sm tracking-[0.25em] uppercase">
          blau<span className="text-cyan-300">.</span>app
        </a>
        <div className="flex items-center gap-2.5 font-mono text-[11px] tracking-[0.2em] text-white/50 uppercase">
          <span className="relative flex size-2">
            <span className="absolute inline-flex size-full animate-ping rounded-full bg-emerald-400 opacity-60" />
            <span className="relative inline-flex size-2 rounded-full bg-emerald-400" />
          </span>
          Systems online
        </div>
      </header>

      {/* hero */}
      <section className="relative z-10 mx-auto max-w-6xl px-6 pt-16 pb-20 sm:px-10 sm:pt-24 sm:pb-28">
        <p className="font-mono text-xs tracking-[0.35em] text-cyan-300/80 uppercase">
          {'//'} Independent studio — 2026
        </p>
        <h1 className="mt-6 max-w-4xl text-[clamp(2.75rem,8vw,6.5rem)] leading-[0.95] font-semibold tracking-[-0.04em]">
          Tools to{' '}
          <span className="bg-gradient-to-r from-cyan-300 via-sky-400 to-indigo-400 bg-clip-text text-transparent">
            build
          </span>
          , share, and play.
        </h1>
        <p className="mt-8 max-w-xl text-base leading-relaxed text-white/50 sm:text-lg">
          blau.app is a small studio shipping software across developer tools, marketing, and
          entertainment — designed for speed, built for the future.
        </p>
        <dl className="mt-14 flex flex-wrap gap-x-12 gap-y-6">
          {stats.map((stat) => (
            <div key={stat.label} className="flex items-baseline gap-3">
              <dd className="text-3xl font-semibold tracking-tight text-white">{stat.value}</dd>
              <dt className="font-mono text-[11px] tracking-[0.25em] text-white/40 uppercase">
                {stat.label}
              </dt>
            </div>
          ))}
        </dl>
      </section>

      {/* project index */}
      <div className="relative z-10 mx-auto max-w-6xl space-y-16 px-6 pb-24 sm:px-10 sm:space-y-20">
        {sections.map((section, sectionIndex) => (
          <section key={section.id} aria-labelledby={section.id}>
            <div className="mb-6 flex items-end justify-between">
              <div className="flex items-baseline gap-4">
                <span aria-hidden="true" className="font-mono text-xs text-cyan-300/70">
                  {String(sectionIndex + 1).padStart(2, '0')}
                </span>
                <h2
                  id={section.id}
                  className="font-mono text-xs tracking-[0.35em] text-white/40 uppercase"
                >
                  {section.title}
                </h2>
              </div>
              <span className="font-mono text-xs text-white/30">
                {String(projectIndex + 1).padStart(3, '0')} —{' '}
                {String(projectIndex + section.projects.length).padStart(3, '0')}
              </span>
            </div>
            <div className="border-b border-white/10">
              {section.projects.map((project) => {
                projectIndex += 1;
                const index = projectIndex;
                const inner = (
                  <>
                    <span
                      aria-hidden="true"
                      className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-cyan-300/70 to-transparent opacity-0 transition-opacity duration-500 group-hover:opacity-100"
                    />
                    <span className="font-mono text-xs text-white/30 transition-colors duration-300 group-hover:text-cyan-300">
                      {String(index).padStart(2, '0')}
                    </span>
                    <div className="min-w-0">
                      <h3 className="text-2xl font-semibold tracking-tight sm:text-3xl">
                        {project.name}
                      </h3>
                      <p className="mt-1.5 text-sm text-white/45">{project.description}</p>
                    </div>
                    <div className="flex items-center justify-end">
                      {project.href ? (
                        <ArrowUpRight
                          aria-hidden="true"
                          className="size-5 text-white/30 transition-all duration-300 group-hover:translate-x-0.5 group-hover:-translate-y-0.5 group-hover:text-cyan-300"
                        />
                      ) : (
                        <span className="rounded-full border border-white/10 px-3 py-1 font-mono text-[10px] tracking-[0.25em] text-white/35 uppercase">
                          Soon
                        </span>
                      )}
                    </div>
                  </>
                );
                const rowClass =
                  'group relative grid grid-cols-[2.5rem_1fr_auto] items-center gap-4 border-t border-white/10 px-2 py-7 transition-colors duration-300 hover:bg-white/[0.02] sm:gap-6 sm:py-9';
                return project.href?.startsWith('http') ? (
                  <a
                    key={project.name}
                    href={project.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    className={rowClass}
                  >
                    {inner}
                  </a>
                ) : project.href ? (
                  <Link key={project.name} href={project.href} className={rowClass}>
                    {inner}
                  </Link>
                ) : (
                  <div key={project.name} className={`${rowClass} opacity-60`}>
                    {inner}
                  </div>
                );
              })}
            </div>
          </section>
        ))}
      </div>

      {/* marquee */}
      <div aria-hidden="true" className="relative z-10 overflow-hidden border-y border-white/10 py-4">
        <div className="flex w-max motion-safe:animate-marquee">
          {[0, 1].map((half) => (
            <div key={half} className="flex items-center gap-10 pr-10">
              {sections.flatMap((section) => section.projects).map((project) => (
                <span
                  key={project.name}
                  className="flex items-center gap-10 font-mono text-xs tracking-[0.35em] text-white/25 uppercase"
                >
                  {project.name}
                  <span className="text-cyan-300/50">{'//'}</span>
                </span>
              ))}
            </div>
          ))}
        </div>
      </div>

      {/* footer */}
      <footer className="relative z-10 mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-4 px-6 py-10 font-mono text-[11px] tracking-[0.2em] text-white/35 uppercase sm:px-10">
        <span>© 2026 blau.app</span>
        <span>Built for the future</span>
      </footer>
    </main>
  );
}
