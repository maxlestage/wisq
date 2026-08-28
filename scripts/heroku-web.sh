#!/usr/bin/env bash
#
# What the dyno runs. It exists to answer one question — *which* Bun — because
# there can be two, and the wrong answer is a crash loop rather than a message.
#
# `scripts/heroku-build.sh` installs one into `.heroku-bun`, inside the
# application directory, precisely so it travels in the slug: a buildpack's own
# Bun lives under the build's temporary directory, which the dyno never sees.
# That is the one to prefer, and normally the only one there is.
#
# The fallback is for the case this cannot be checked from a laptop: if the slug
# did not keep `.heroku-bun`, a buildpack that exports its Bun through
# `.profile.d` has put one on PATH, and using it beats refusing to boot. If
# neither exists, say so in one line rather than let the dyno fail with "no such
# file or directory" and leave someone reading a stack of restarts on a phone.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -x ".heroku-bun/bin/bun" ]; then
  exec ./.heroku-bun/bin/bun site/scripts/serve.ts
fi

if command -v bun >/dev/null 2>&1; then
  echo "note : .heroku-bun est absent du slug, on utilise le bun du PATH" >&2
  exec bun site/scripts/serve.ts
fi

echo "aucun bun disponible : ni .heroku-bun/bin/bun, ni un bun sur le PATH." >&2
echo "la construction (scripts/heroku-build.sh) n'a pas laissé Bun dans le slug." >&2
exit 1
