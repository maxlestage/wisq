#!/usr/bin/env bash
#
# Builds the site on Heroku, from the repository root.
#
# Heroku's official Node.js buildpack runs this through `heroku-postbuild`, and
# that is the whole reason there is a `package.json` at the root of a repository
# that is otherwise Swift and Rust: it is what makes Heroku pick the buildpack
# it maintains itself.
#
# The alternative was a community Bun buildpack. Four were checked: one URL is a
# 404, one detects a Bun app by a `bun.lockb` at the root — this repository's
# lockfile is `site/bun.lock`, a different name in a different directory, so it
# would not detect — and one is at v0.0.2. Deploying from a phone means nobody
# can open a laptop when a build breaks, so the dependency chain is kept to
# things this repository can read: the official buildpack, and Bun's own
# installer pinned by an environment variable.
#
# Bun is fetched on every build rather than cached. It costs about thirty
# seconds and removes a class of "it worked yesterday" from a deployment nobody
# can debug on the move.
set -euo pipefail

cd "$(dirname "$0")/.."

# Where the site's canonical URLs, sitemap and social card links point.
#
# This used to refuse to build without it, on the reasoning that a wrong
# canonical link is invisible in a browser and wrong in every sitemap entry.
# That much was true; stopping the build was the wrong conclusion. Deploying
# from a phone means nobody can open a laptop to add a config var, and three
# builds in a row failed here rather than shipping a site.
#
# The address is resolved where it is actually known now: `site/scripts/serve.ts`
# sees the host every request arrives on, and puts it into the pages, the
# sitemap and robots.txt as it serves them. Setting SITE_URL still pins the
# address, which is what a custom domain wants.
if [ -z "${SITE_URL:-}" ]; then
  echo "==> SITE_URL n'est pas défini : le serveur utilisera l'adresse de chaque requête."
  echo "    Pour l'épingler (domaine personnalisé) : Settings → Config Vars →"
  echo "    SITE_URL = https://<nom-de-l-app>.herokuapp.com/"
fi

export BUN_INSTALL="$PWD/.heroku-bun"
export PATH="$BUN_INSTALL/bin:$PATH"

if [ ! -x "$BUN_INSTALL/bin/bun" ]; then
  echo "==> Installation de Bun${BUN_VERSION:+ ($BUN_VERSION)}"
  if [ -n "${BUN_VERSION:-}" ]; then
    curl -fsSL https://bun.sh/install | bash -s "bun-v${BUN_VERSION}"
  else
    curl -fsSL https://bun.sh/install | bash
  fi
fi

echo "==> Bun $(bun --version)"

cd site
echo "==> Dépendances du site"
bun install --frozen-lockfile

# A bare apostrophe inside `${...:-...}` opens a quote as far as bash is
# concerned, so the fallback is built before it is printed.
destination="${SITE_URL:-}"
[ -n "$destination" ] || destination="l'adresse de chaque requête"
echo "==> Construction du site pour $destination"
bun run build

# The build is the deployable artifact; a slug that shipped an empty `dist`
# would start, answer 404 to everything, and look like a routing problem.
if [ ! -f dist/index.html ]; then
  echo "la construction n'a pas produit dist/index.html" >&2
  exit 1
fi

echo "==> Site construit dans site/dist"
