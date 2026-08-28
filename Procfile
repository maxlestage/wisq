# Heroku runs this. The server is `site/scripts/serve.ts` — the same one
# `bun run preview` uses, and the same one `site/tests/serve.test.ts` puts
# requests through, so what Heroku serves is what the tests hold.
#
# Bun lands in `.heroku-bun` at build time (scripts/heroku-build.sh) and travels
# in the slug; the path is spelled out rather than relying on PATH, which the
# build and the dyno do not share.
web: ./.heroku-bun/bin/bun site/scripts/serve.ts
