import { ArrowUpRight, Braces, Clapperboard, Flag, Pencil, Radio, ScanLine } from 'lucide-react';
import { buttonVariants } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

const sections = [
  {
    id: 'developer-tools',
    title: 'Developer Tools',
    products: [
      { name: 'MADE', description: 'Multimodal Agentic Development Environment', icon: Braces, href: '/made' },
    ],
  },
  {
    id: 'marketing-tools',
    title: 'Marketing Tools',
    products: [
      { name: 'Previral', description: 'Attention Scanner', icon: ScanLine, href: '/previral' },
      { name: 'ShortReel', description: 'Control your social media via agents', icon: Clapperboard, href: '/shotreel' },
    ],
  },
  {
    id: 'entertainment',
    title: 'Entertainment',
    products: [
      { name: 'Stint', description: 'Formula 1 Replay', icon: Flag, href: '/stint' },
      { name: 'Stream', description: 'Screen sharing from your Apple devices', icon: Radio, href: '/stream' },
      { name: 'Doodle', description: 'Drawing pad', icon: Pencil },
    ],
  },
];

export default function Home() {
  return (
    <main className="mx-auto max-w-4xl px-6 py-12 sm:px-10 sm:py-20">
      <header className="mb-12 border-b pb-10 sm:mb-14">
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
          blau<span className="text-primary">.</span>app
        </h1>
        <p className="mt-4 text-base leading-relaxed text-muted-foreground sm:text-lg">
          Tools to build, share, and play.
        </p>
      </header>

      <div className="space-y-10 sm:space-y-12">
        {sections.map((section, index) => (
          <section key={section.id} aria-labelledby={section.id}>
            <div className="mb-4 flex items-center gap-3">
              <span aria-hidden="true" className="font-mono text-xs text-muted-foreground">
                {String(index + 1).padStart(2, '0')}
              </span>
              <h2 id={section.id} className="text-sm font-medium tracking-tight">
                {section.title}
              </h2>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              {section.products.map((product) => (
                <Card key={product.name} className={section.products.length === 1 ? 'sm:col-span-2' : ''}>
                  <CardContent className={`flex h-full flex-col gap-5 p-2 px-6 ${section.products.length === 1 ? 'sm:flex-row sm:items-center' : ''}`}>
                    <div className="flex min-w-0 flex-1 items-start gap-4">
                      <div className="flex size-10 shrink-0 items-center justify-center rounded-lg bg-primary/5 text-primary">
                        <product.icon className="size-5" strokeWidth={1.5} aria-hidden="true" />
                      </div>
                      <div className="min-w-0 pt-0.5">
                        <h3 className="text-base font-semibold tracking-tight">{product.name}</h3>
                        <p className="mt-1 text-sm leading-relaxed text-muted-foreground">
                          {product.description}
                        </p>
                      </div>
                    </div>
                    {'href' in product && product.href && (
                      <a href={product.href} className={buttonVariants({ variant: 'outline', className: `self-start ${section.products.length === 1 ? 'sm:self-center' : ''}` })}>
                        Explore {product.name}
                        <ArrowUpRight aria-hidden="true" />
                      </a>
                    )}
                  </CardContent>
                </Card>
              ))}
            </div>
          </section>
        ))}
      </div>

      <footer className="mt-12 border-t pt-6 text-xs text-muted-foreground sm:mt-16">
        blau.app
      </footer>
    </main>
  );
}
