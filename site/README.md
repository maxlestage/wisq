# wisq.dev — the landing page

React 19 on Bun, no framework and no CSS library: a landing page should not
need a build pipeline bigger than the thing it advertises.

```sh
bun install
bun run dev      # http://localhost:3000, hot reload
bun run build    # dist/, pre-rendered
bun test         # rendering, content integrity, and the built artefact
```

## Two decisions worth knowing

**Mobile-first, literally.** Every base rule in `styles.css` targets a phone;
the two breakpoints (`40em`, `64em`) only ever add space and columns. Tap
targets clear 48 px, the comparison table scrolls inside its own box rather
than making the page scroll sideways, and the notch is handled with
`env(safe-area-inset-*)`.

**Pre-rendered at build time.** `build.tsx` renders the page to HTML and
injects it into the shell, then React hydrates it. The content paints on the
first response instead of after 400 KB of JavaScript — which is the entire
point on a phone — and the page still reads if the script never arrives.
Because the pre-render is English, the first client render must be English
too; a French browser is switched over one effect later, which is why `App`
does not read `navigator.language` during render.

## Content

All copy lives in `src/content.ts`, typed and bilingual. A missing translation
is a type error; an empty one fails `tests/render.test.tsx`. Numbers claimed on
the page (test count, CI gates) are checked against the repository itself in
`tests/claims.test.ts` — landing-page statistics rot silently otherwise.
