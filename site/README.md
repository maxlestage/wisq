# The wisq site

React 19 on Bun, no framework and no CSS library: a project site should not
need a build pipeline bigger than the thing it documents.

**React never reaches a visitor.** It is the authoring language and the
pre-renderer — `renderToString` at build time — and the browser gets HTML plus
about a kilobyte of plain DOM code. It used to hydrate the pre-rendered pages
for four behaviours (a redirect, a remembered language, the theme switch, the
install banner), and that cost 65 794 bytes gzipped on every page. Those four
live in `src/main.ts` now; `tests/build.test.ts` fails if React reappears in
the bundle, and `tests/behaviour.test.ts` drives each of them in a DOM so that
"small" cannot quietly become "does nothing".

The trade: anything genuinely interactive added later belongs in `main.ts` as
DOM code, or behind a dynamic import only the pages needing it pay for. It can
no longer be added by writing JSX.

```sh
bun install
bun run dev      # writing the site, with hot reload
bun run build    # dist/, every page pre-rendered, plus the PWA assets
bun run preview  # serves dist/ the way a real host would — see below
bun test         # rendering, content integrity, and the built artefact
```

## Where it is served, and how it gets there

Heroku, from `master`, through Heroku's own GitHub integration — no deploy
workflow, no API key in the repository, and nothing to run from a laptop. Three
files at the repository root make it work:

- `package.json` — minimal, and its only job is to make Heroku recognise the
  repository and pick the Node.js buildpack it maintains itself. A community Bun
  buildpack was the obvious alternative and did not survive checking: of four
  candidates, one URL was a 404, one detects a Bun app by a `bun.lockb` at the
  root (this repository's lockfile is `site/bun.lock` — a different name in a
  different directory, so it would not detect), and one is at v0.0.2.
- `scripts/heroku-build.sh` — installs Bun into `.heroku-bun`, then builds the
  site. It used to **refuse to build without `SITE_URL`**, on the reasoning that
  a wrong public address is invisible in the browser and wrong in every
  canonical link and sitemap entry. That much was true; stopping the build was
  the wrong conclusion, and three deployments in a row died there rather than
  shipping a site. The address is resolved where it is known instead — see
  below.
- `Procfile` — runs `site/scripts/serve.ts`, the same server `bun run preview`
  uses and `tests/serve.test.ts` holds. What Heroku serves is what the tests
  describe.

### The address the site gives for itself

The build stamps a sentinel — an unreachable `.invalid` host — wherever the
site's own address appears, and `site/scripts/serve.ts` replaces it with the
origin of the request it is answering. So the canonical links, the `hreflang`
alternates, the sitemap, `robots.txt` and the social card all name the host the
reader actually used, and moving the site somewhere else needs no rebuild.

Heroku terminates TLS at its router and forwards plain HTTP to the dyno, so
`X-Forwarded-Proto` is honoured — otherwise every canonical link on an `https`
site would say `http`. Only `http` and `https` are accepted from that header: it
is attacker-controlled on a host that does not set it.

`SITE_URL` still works and still pins the address, which is what a custom domain
wants; setting it leaves no sentinel for the server to replace.

Setting it up, once, entirely from the Heroku dashboard:

1. Create the app.
2. **Deploy → GitHub**: connect the repository, then enable automatic deploys
   from `master`. "Wait for CI to pass before deploy" is worth ticking: this
   repository's checks are the thing that would catch a bad build.

`.github/workflows/site.yml` publishes nothing. It typechecks, builds and tests
the site, and runs the Heroku build path on the same commit — so a break in the
deployment is a red check rather than a surprise on the next push.

## Multi-page, and every page is a real file

`src/routes.ts` is the only place that knows what pages exist. The build
pre-renders each one into its own directory — `docs/index.html`,
`protocol/index.html` — rather than shipping a client-side router. Three
things follow, and all three matter: the page arrives readable in the first
response, a search engine sees a real URL, and the service worker can cache a
document per address instead of one shell that has to boot before it knows
what it is showing.

Written pages are **data, not markup**. `src/doc.ts` defines a small block
model and `src/pages/*.ts` fills it in both languages; `components/Doc.tsx` is
the single renderer. A missing translation is a type error, an empty one fails
a test, and the two languages are checked block-for-block so a page cannot be
richer in English than in French.

## Light, dark, and neither

Three states, not a toggle: a two-way switch cannot say "follow my phone", and
that is the state most readers want. Light and dark set `data-theme` on the
root element; auto removes it and lets `prefers-color-scheme` decide.

Two details make it actually work. The dark palette is defined twice — once
under `@media (prefers-color-scheme: dark)` guarded by
`:root:not([data-theme="light"])`, once under `:root[data-theme="dark"]` — so a
choice beats the system in *both* directions; without the guard, choosing light
on a dark device silently does nothing. And the choice is applied by a small
inline script in the document head rather than by the main script, because
anything deferred runs after the page has painted: a reader who chose light on
a dark system would otherwise see a flash of dark on every navigation. What
`main.ts` does afterwards is the part nobody sees flash — the pressed state of
the three buttons, and the buttons themselves.

Verified by driving a browser with the system set each way in turn, checking
the computed background, the `theme-color` metas, that the attribute is already
present at `domcontentloaded` on the next page, and that returning to auto
leaves nothing behind.

## Two languages, two sets of addresses

English is served from the site root, French from `fr/`. Every page exists
twice and each one is pre-rendered in its own language, with its own
`<html lang>`, title, description, canonical and `hreflang` alternates.

This is not how the site started, and the reason it changed is worth keeping.
The copy was bilingual from the first commit, but the *build* rendered every
page in English and let the browser swap the language after hydration. That
reads fine in `bun run dev` and is broken everywhere it matters: a French
reader's first paint was English, a shared link opened in the sender's
language rather than the reader's, a reader with no JavaScript never saw
French, and a search engine indexed half the site. A language a URL cannot
express is a language the web cannot see.

So the URL is the language. The switch in the header is two links — real
addresses, openable in a new tab, followable with no JavaScript — pointing at
the same page in the other language. The one piece of cleverness left is a
redirect from the English home page to the French one for a French-speaking
browser that has never chosen; it is scoped to the home page so a deep link
somebody deliberately shared in English is never hijacked, and choosing a
language explicitly ends it.

Tests hold the French pages to the same standard as the English ones rather
than exempting them: the footer check reads its expectations out of
`content.ts` per language, titles and descriptions must be unique *within* a
language (across languages they may legitimately collide — "Architecture" is
the same word in French), and a French page whose title and description both
match its English counterpart fails as untranslated.

## Every path is relative

The site was served from `/wisq/` on GitHub Pages and is served from the root
on Heroku; an absolute `/asset.js` works in exactly one of those, which is why
the move needed no rewriting here.
The build computes each page's depth and writes `./` or `../` accordingly, and
a test resolves every reference in every built page against its own directory
and fails if the file is not there. That test is what catches a subdirectory
page saying `./chunk.js` — which builds fine, deploys fine, and 404s in the
browser.

## The progressive web app

`bun run build` also emits a manifest, four PNG icons, a social card, a service
worker, a sitemap, `robots.txt` and a 404 page.

The icons are **drawn and encoded at build time**, not committed. The artwork
is four rectangles and a pixel wordmark, and a PNG is a header, one deflated
block and a checksum — `scripts/icons.ts` does both in about a hundred lines.
A committed binary is a thing nobody can diff and everybody has to trust. They
are PNG rather than SVG because iOS will not put an SVG on the Home Screen, and
this is a project about iPhones.

The service worker takes navigations from the network first and everything else
from the cache first: documentation that is quietly a week stale is worse than
a spinner, while a hashed asset name can never be stale. All pages are
precached at install, so the whole site works on a plane after one visit.

**Test the PWA with `bun run preview`, never with `bun run dev`.** The service
worker and manifest only exist in the build, and a browser refuses to install a
service worker that arrives without a JavaScript content type — a preview
server that omits it reports a broken PWA when the deployed site is fine. That
is not hypothetical: it cost a debugging session here, and the second one cost
another, because `Cache.addAll` rejects the entire list when two entries
resolve to the same URL and leaves no worker at all. Both are now covered by
tests, but neither was findable without driving a real browser.

## Two logos, one mark

The header carries the wordmark on every page. The landing page also carries
the full mark, which is what `▚` means when there is room to draw it: the
upper-left quadrant is a window on a machine somewhere else, the lower-right
one is the phone in your hand, and the gap between them holds the link. In the
character the quadrants touch at a point; here they stand apart, because what
is between them is the product.

The Home Screen icon stays the simplified version — two quadrants, no detail —
because at 60 px anything more becomes mush. That is a logo system rather than
two drawings, so `scripts/icons.ts` and `src/components/Logo.tsx` share the
same proportions and a test asserts the full mark appears on the landing page
and on no other.

It is inline SVG rather than a file: the hero paints in the first response with
no second request, and the artwork stays something you can diff.

## The footer, and what gets checked in a browser

The footer is on every page and carries what the header cannot: three groups —
use it, understand it, contribute to it — the version the site was built from,
the licence, the privacy page. Tests assert every page carries the whole
footer, that each project link points at a file that actually exists in this
repository, and that the version shown equals the newest dated section of
`CHANGELOG.md`, so the footer cannot quietly describe a release that never
happened.

Layout and target sizes are checked by driving a real browser at 390 px and
1280 px, because a stylesheet cannot tell you what it renders as. That check
is what caught the wordmark being a 20 px-tall link — comfortably below the
24 px minimum — in both the header and the footer, and the missing
`:focus-visible` rule that made keyboard navigation invisible. Neither was
visible in the markup or in a test that only reads HTML.

## Claims are checked against the repository

Numbers on the site — the test count, the CI gate count, the versions the
releases page describes — are verified against the actual repository in
`tests/claims.test.ts`. Site statistics rot silently otherwise, and a page that
says something untrue about the code is worse than a page that says nothing.
