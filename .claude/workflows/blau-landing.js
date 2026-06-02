export const meta = {
  name: 'blau-landing',
  description: 'Stripe-grade landing page for blau: research tools + codebase truth, synthesize a design system, build sections',
  phases: [
    { title: 'Research', detail: 'codebase truth + per-tool deep dives + premium design teardown' },
    { title: 'Design', detail: 'one lead designer synthesizes design system, IA, and finalized copy' },
    { title: 'Build', detail: 'one builder per section, sharing global design tokens' },
    { title: 'Polish', detail: 'design critic + technical-accuracy critic review the assembled spec' },
  ],
}

// ---------- Schemas ----------

const TRUTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['apps', 'features', 'frameworks', 'corrections', 'narrative'],
  properties: {
    apps: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'platform', 'oneLiner', 'capabilities'],
        properties: {
          name: { type: 'string' },
          platform: { type: 'string' },
          oneLiner: { type: 'string' },
          capabilities: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    features: {
      type: 'array',
      description: 'Verified end-user features with the file that proves each exists',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'detail', 'evidenceFile'],
        properties: {
          title: { type: 'string' },
          detail: { type: 'string' },
          evidenceFile: { type: 'string' },
        },
      },
    },
    frameworks: {
      type: 'array',
      description: 'Every framework/tool actually used, with how it is used',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'usedFor', 'verified'],
        properties: {
          name: { type: 'string' },
          usedFor: { type: 'string' },
          verified: { type: 'boolean' },
        },
      },
    },
    corrections: {
      type: 'array',
      description: 'Claims on the current landing page that are wrong vs the real code',
      items: { type: 'string' },
    },
    narrative: { type: 'string', description: 'The single most accurate sentence describing what blau IS' },
  },
}

const TOOL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['tool', 'whatItIs', 'whyItMatters', 'creditLine', 'copyAngles', 'accurateFacts'],
  properties: {
    tool: { type: 'string' },
    whatItIs: { type: 'string' },
    whyItMatters: { type: 'string', description: 'Why this choice signals engineering quality on a landing page' },
    creditLine: { type: 'string', description: 'A short, factually-correct one-liner suitable for a "Built on" strip' },
    copyAngles: { type: 'array', items: { type: 'string' }, description: '2-4 marketing angles grounded in fact' },
    accurateFacts: { type: 'array', items: { type: 'string' }, description: 'Facts safe to state publicly' },
  },
}

const DESIGN_REF_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['principles', 'typography', 'color', 'motion', 'layoutMoves', 'antiPatterns'],
  properties: {
    principles: { type: 'array', items: { type: 'string' }, description: 'What makes Stripe/Linear/Vercel/Raycast feel premium' },
    typography: { type: 'array', items: { type: 'string' } },
    color: { type: 'array', items: { type: 'string' } },
    motion: { type: 'array', items: { type: 'string' } },
    layoutMoves: { type: 'array', items: { type: 'string' }, description: 'Specific reusable layout devices (e.g. asymmetric feature rows, bento, sticky scroll narratives)' },
    antiPatterns: { type: 'array', items: { type: 'string' }, description: 'AI-slop / generic-SaaS patterns to avoid' },
  },
}

const DESIGN_SYSTEM_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['concept', 'tokensCss', 'globalCss', 'sections'],
  properties: {
    concept: { type: 'string', description: 'The art direction in 2-3 sentences: the feeling, the through-line' },
    tokensCss: { type: 'string', description: 'Complete :root CSS custom properties block (color, type scale, spacing, radius, shadow, easing). Production-ready.' },
    globalCss: { type: 'string', description: 'Global resets + base element styles + shared utility/primitive classes (.container, buttons, .eyebrow, gradient text, glass, etc). Production-ready CSS.' },
    sections: {
      type: 'array',
      description: 'Ordered sections of the page',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['id', 'name', 'goal', 'copy', 'layoutBrief', 'cssClassPrefix'],
        properties: {
          id: { type: 'string', description: 'kebab id, also the section CSS namespace' },
          name: { type: 'string' },
          goal: { type: 'string' },
          copy: { type: 'string', description: 'All finalized headlines, subheads, body, list items, labels for this section. Verbatim, ready to place.' },
          layoutBrief: { type: 'string', description: 'Precise layout + interaction direction the builder must follow' },
          cssClassPrefix: { type: 'string' },
          asset: { type: 'string', description: 'screenshot asset to use, or "none"' },
        },
      },
    },
  },
}

const SECTION_BUILD_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['id', 'astroMarkup', 'css'],
  properties: {
    id: { type: 'string' },
    astroMarkup: { type: 'string', description: 'The complete HTML/Astro markup for this <section>, using the shared tokens & utilities. No <style> tags.' },
    css: { type: 'string', description: 'All section-scoped CSS (namespaced by the section prefix). Mobile-first + responsive. No :root redefinitions.' },
    notes: { type: 'string' },
  },
}

const CRITIQUE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['score', 'mustFix', 'shouldFix'],
  properties: {
    score: { type: 'number', description: '0-100 how close to top-tier (Stripe) quality' },
    mustFix: { type: 'array', items: { type: 'string' } },
    shouldFix: { type: 'array', items: { type: 'string' } },
  },
}

// ---------- Shared context ----------

const REPO = '/Users/joeblau/Developer/joeblau/src/blau'
const ASSETS = [
  'src/assets/screenshots/pilot.png (wide macOS app)',
  'src/assets/screenshots/copilot.png (iPhone portrait)',
  'src/assets/screenshots/wingman.png (watch)',
  'public/screenshots/copilot/01-workspaces.png',
  'public/screenshots/plotter/01-mirror.png (iPad mirror)',
  'public/screenshots/wingman/01-wingman.png',
]

// ---------- Phase 1: Research ----------
phase('Research')

const truthP = agent(
  `You are a senior engineer auditing the blau repo at ${REPO} to extract GROUND TRUTH for a landing page.
Read the real Swift sources under apple/Sources/ — especially:
 - Pilot/*.swift (WorkspaceView, GhosttyTerminal, Browser/*, Device/*, GitCommitStore, GitHubTasksStore, NotesView, InkOverlay, ScreenMirror, IDELauncher, MouseBridge, HeadphoneDetector)
 - Shared/PeerSyncService.swift, Shared/FrameLink.swift, Shared/FrameProtocol.swift, Shared/TranscriptionService.swift, Shared/SyncMessages.swift
 - Plotter/*.swift, PlotterShared/*, PlotterWidgets/*
 - Copilot/*.swift, Wingman/**/*.swift
Also read web/src/pages/index.astro and web/src/layouts/Layout.astro (the CURRENT landing page).

Determine precisely: what each app does, what end-user features really exist (cite the file proving each), which frameworks are actually used and for what. IMPORTANT KNOWN ISSUE: the current page credits "MultipeerConnectivity" but the code imports Network.framework — verify which is real and list every wrong claim in 'corrections'. Be ruthless about accuracy; do not invent features. Return the schema.`,
  { label: 'codebase-truth', schema: TRUTH_SCHEMA }
)

const TOOLS = [
  { k: 'ghostty', q: 'Ghostty terminal + libghostty/GhosttyKit embedding, and tmux persistent sessions. Why a GPU-accelerated native terminal embedded in an IDE is notable.' },
  { k: 'whisperkit', q: 'WhisperKit (argmaxinc) on-device speech transcription on Apple Silicon / CoreML. Privacy + on-device angle.' },
  { k: 'p2p', q: 'Apple Network.framework (NWListener/NWBrowser, Bonjour/DNS-SD over TCP/UDP, TLS), peer-to-peer local discovery WITHOUT servers or accounts. Contrast with MultipeerConnectivity. Why serverless P2P is a strong story.' },
  { k: 'streaming', q: 'ScreenCaptureKit + VideoToolbox HEVC hardware encode/decode for low-latency screen mirroring Mac->iPad. Why hardware HEVC + AWDL local link is impressive.' },
  { k: 'platform', q: 'Swift 6 strict concurrency, SwiftUI + SwiftData, XcodeGen project generation, ActivityKit/WidgetKit Live Activities, PencilKit annotation, WatchConnectivity. Why this native-Apple stack signals craft.' },
]

const toolPs = TOOLS.map((t) =>
  agent(
    `Research "${t.q}" using web search. Goal: equip a top-tier landing page with FACTUALLY ACCURATE, non-hyperbolic copy that makes the engineering choice resonate with technical readers. Avoid anything you cannot stand behind. Return the schema for tool key "${t.k}".`,
    { label: `tool:${t.k}`, schema: TOOL_SCHEMA }
  )
)

const designRefP = agent(
  `You are a design researcher. Study the best developer-product landing pages of the last few years: Stripe, Linear, Vercel, Raycast, Rivet, Resend, Arc, Ghostty's own site. Use web search to refresh specifics. Extract the concrete, reusable craft that makes them read as premium (NOT generic SaaS): grid/layout devices, typographic systems, restrained color + gradient/glow usage on dark UIs, micro-motion and scroll choreography, device/screenshot framing, and the AI-slop patterns to avoid. Be specific and actionable for an implementer. Return the schema.`,
  { label: 'design-teardown', schema: DESIGN_REF_SCHEMA }
)

const [truth, tools, designRef] = await Promise.all([
  truthP,
  Promise.all(toolPs),
  designRefP,
])

const research = {
  truth,
  tools: tools.filter(Boolean),
  designRef,
}

// ---------- Phase 2: Design synthesis ----------
phase('Design')

const designSystem = await agent(
  `You are a top product designer (think Stripe design team lead). Design a COMPLETE, cohesive, production-ready landing page system for "blau" — a vertically integrated native-Apple developer cockpit.

THE ONE-LINE TRUTH: ${truth?.narrative || 'A vertically integrated developer cockpit across Mac, iPhone, iPad, and Apple Watch.'}

GROUND TRUTH (only claim what is here — do not invent, and FIX these wrong claims: ${JSON.stringify(truth?.corrections || [])}):
${JSON.stringify(truth, null, 2)}

TOOL RESEARCH (use for an accurate, impressive "Built on" story and feature copy):
${JSON.stringify(research.tools, null, 2)}

PREMIUM DESIGN PRINCIPLES to embody (and anti-patterns to avoid):
${JSON.stringify(designRef, null, 2)}

AVAILABLE SCREENSHOT ASSETS (use real ones; if a section needs none, set asset "none"):
${ASSETS.map((a) => '- ' + a).join('\n')}

REQUIREMENTS:
- Dark, confident, engineering-forward art direction. Restrained palette with ONE signature accent + tasteful glow/gradient. No rainbow, no generic purple SaaS gradient.
- Typography: strong display scale, tight tracking on headings, comfortable body. Real type scale in tokens.
- Cover the full story: hero (the cockpit thesis), the four+web platforms, Pilot as the core cockpit with its real panes (terminal/browser/device/git/notes/annotations), screen-mirroring + HEVC streaming, on-device speech (WhisperKit), serverless P2P architecture (Network.framework — NOT MultipeerConnectivity), and a "Built on" engineering strip. End with a GitHub CTA + footer.
- Provide finalized, specific copy for every section (no lorem, no placeholders). Voice: precise, technical, quietly confident. Short. No buzzword slop.
- tokensCss + globalCss must be complete and production-ready. Section builders will reuse these utilities, so define a clean primitive set (.container, .eyebrow, .btn/.btn-primary/.btn-ghost, gradient-text, .glass, .pane/card, etc.).
- Keep it buildable as a single Astro page importing the screenshots from src/assets and referencing public/ images by URL.

Return the DESIGN_SYSTEM schema with an ordered 'sections' array (aim for 7-9 sections including nav/hero and footer/CTA).`,
  { label: 'design-system', schema: DESIGN_SYSTEM_SCHEMA }
)

// ---------- Phase 3: Build sections in parallel ----------
phase('Build')

const sharedCtx = `SHARED DESIGN TOKENS (already defined globally — USE these vars, never redefine :root):
${designSystem.tokensCss}

SHARED GLOBAL/UTILITY CSS (reuse these classes; do not duplicate them):
${designSystem.globalCss}

ART DIRECTION: ${designSystem.concept}

AVAILABLE ASSETS: ${ASSETS.join(' | ')}
Astro note: images in src/assets are imported and rendered with <Image/> by the assembler — in your markup use a plain <img> with a data-asset="<filename>" attribute (e.g. data-asset="pilot.png") and the assembler will swap it. For public/ images use a normal <img src="/screenshots/..."/>.`

const built = await parallel(
  designSystem.sections.map((s) => () =>
    agent(
      `You are an elite front-end engineer implementing ONE section of a Stripe-grade landing page. Implement it pixel-carefully, fully responsive (mobile-first), accessible, with tasteful micro-interactions using CSS (and reveal-on-scroll via a class "reveal" + optional style="--delay:..."; the page already has an IntersectionObserver for .reveal).

SECTION:
${JSON.stringify(s, null, 2)}

${sharedCtx}

Rules:
- Output a single <section id="${s.id}" class="${s.cssClassPrefix}"> ... </section> (or <nav>/<footer> if this section is nav/footer).
- Use the finalized copy verbatim. Do not invent features beyond the brief.
- CSS must be namespaced under the section prefix ".${s.cssClassPrefix}" to avoid collisions, use the shared tokens, and look genuinely premium (real spacing rhythm, hover states, focus-visible). No <style> tags in markup.
- No external JS libs. SVG icons inline if needed.
Return the SECTION_BUILD schema for id "${s.id}".`,
      { label: `build:${s.id}`, phase: 'Build', schema: SECTION_BUILD_SCHEMA }
    )
  )
)

const sections = built.filter(Boolean)

// ---------- Phase 4: Critique the assembled spec ----------
phase('Polish')

const assembled = sections.map((b) => `<!-- ${b.id} -->\n${b.astroMarkup}`).join('\n\n')
const allCss = designSystem.tokensCss + '\n\n' + designSystem.globalCss + '\n\n' + sections.map((b) => b.css).join('\n\n')

const [designCrit, techCrit] = await parallel([
  () =>
    agent(
      `You are a famously exacting design director. Critique this assembled landing page (markup + CSS) for blau against TOP-TIER (Stripe/Linear) quality. Look for: weak hierarchy, inconsistent spacing rhythm, timid type scale, gradient/glow misuse, generic AI-slop, poor responsive behavior, low contrast, missing hover/focus states, visual monotony between sections. Be specific and reference section ids/classes. Return CRITIQUE schema.\n\nMARKUP:\n${assembled}\n\nCSS:\n${allCss}`,
      { label: 'critic:design', phase: 'Polish', schema: CRITIQUE_SCHEMA }
    ),
  () =>
    agent(
      `You are a technical fact-checker. Cross-check every claim in this landing page markup against GROUND TRUTH below. Flag any feature/framework that is NOT verified, any remaining "MultipeerConnectivity" mention (should be Network.framework / Bonjour), and any over-claim. Also flag broken-looking asset references. Return CRITIQUE schema (mustFix = inaccuracies).\n\nGROUND TRUTH:\n${JSON.stringify(truth, null, 2)}\n\nMARKUP:\n${assembled}`,
      { label: 'critic:accuracy', phase: 'Polish', schema: CRITIQUE_SCHEMA }
    ),
])

return {
  concept: designSystem.concept,
  narrative: truth?.narrative,
  corrections: truth?.corrections,
  tokensCss: designSystem.tokensCss,
  globalCss: designSystem.globalCss,
  sectionsMeta: designSystem.sections,
  sections,
  critiques: { design: designCrit, accuracy: techCrit },
  assets: ASSETS,
}
