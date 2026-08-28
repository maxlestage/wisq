# Heroku runs this. The server is `site/scripts/serve.ts` — the same one
# `bun run preview` uses, and the same one `site/tests/serve.test.ts` puts
# requests through, so what Heroku serves is what the tests hold.
#
# Which Bun it uses is a question with two possible answers and a crash loop for
# a wrong one, so it is answered in a script rather than on this line:
# `.heroku-bun` from our own build first, a buildpack's Bun on PATH as a
# fallback, and a one-line explanation instead of a stack of restarts if there
# is neither.
web: ./scripts/heroku-web.sh
