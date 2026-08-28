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

# Where the site's canonical URLs, sitemap and social card links point. There is
# no sensible default for it here: getting it wrong is invisible in the browser
# and wrong in every sitemap entry, so this refuses to build rather than publish
# a site that points somewhere else.
if [ -z "${SITE_URL:-}" ]; then
  cat >&2 <<'EOF'
SITE_URL n'est pas défini.

C'est l'adresse publique du site : elle part dans les URL canoniques, le
sitemap et la carte sociale. Une valeur fausse ne se voit pas dans le
navigateur et se voit partout ailleurs, donc la construction s'arrête ici
plutôt que de publier un site qui pointe à côté.

Sur Heroku : Settings → Config Vars → ajouter

  SITE_URL = https://<nom-de-l-app>.herokuapp.com/

puis relancer le déploiement.
EOF
  exit 1
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

echo "==> Construction du site pour $SITE_URL"
bun run build

# The build is the deployable artifact; a slug that shipped an empty `dist`
# would start, answer 404 to everything, and look like a routing problem.
if [ ! -f dist/index.html ]; then
  echo "la construction n'a pas produit dist/index.html" >&2
  exit 1
fi

echo "==> Site construit dans site/dist"
