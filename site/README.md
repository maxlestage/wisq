# The wisq site

React 19 on Bun, no framework and no CSS library: a project site should not
need a build pipeline bigger than the thing it documents.

```sh
bun install
bun run dev      # writing the site, with hot reload
bun run build    # dist/, every page pre-rendered, plus the PWA assets
bun run preview  # serves dist/ the way a real host would — see below
bun test         # rendering, content integrity, and the built artefact
```

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

## Every path is relative

The site is served from `/wisq/` on GitHub Pages today and from the root of a
domain the day it moves; an absolute `/asset.js` works in exactly one of those.
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

## Claims are checked against the repository

Numbers on the site — the test count, the CI gate count, the versions the
releases page describes — are verified against the actual repository in
`tests/claims.test.ts`. Site statistics rot silently otherwise, and a page that
says something untrue about the code is worse than a page that says nothing.
