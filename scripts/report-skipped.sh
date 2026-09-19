#!/usr/bin/env bash
#
# Ce qu'une exécution de `swift test` a SAUTÉ, nommé plutôt que compté.
#
# **Pourquoi ce relevé existe.** `ci.yml` récupère le noyau rv32 de test en
# « best effort » (`curl … || true`), et l'en-tête de cette étape l'assume : une
# image absente doit faire sauter un test, pas casser la construction. La
# conséquence, elle, n'était écrite nulle part : si ce téléchargement échoue,
# onze tests Swift sautent — dont les quatre différentiels et les deux qui
# comparent les instantanés des deux cœurs —, les tests Rust `boot.rs` et
# `snapshot.rs` sautent, le banc sort en `exit 0` et `test-rust-core.sh` se
# contente d'un `::warning::`. Le job reste **vert**, et rien ne le distingue
# d'une exécution où tout a tourné.
#
# **Ce que ce script est, et ce qu'il n'est pas.** Il n'est pas une garde : il
# ne refuse rien, il sort toujours avec zéro, et c'est délibéré. Faire rougir
# la CI parce qu'un serveur tiers n'a pas répondu est une décision de politique
# que cette tranche ne prend pas — elle rend la dégradation **visible**, ce qui
# est ce qui manquait. Ce qui tient le relevé lui-même est
# `site/tests/skipped-report.test.ts`, qui lui donne de vrais journaux et exige
# qu'il nomme.
#
# **Nommer, pas compter.** « 11 sautés » se lit aussi bien comme une panne
# réseau que comme une suite disparue du binaire. C'est la leçon que
# `scripts/test-app.sh` a déjà payée pour l'iPhone simulé, et ce script suit sa
# forme : extraire à la fin, nommer les suites, pousser dans le résumé du job.
set -euo pipefail

journal="${1:-}"
if [ -z "$journal" ] || [ ! -f "$journal" ]; then
  echo "usage : report-skipped.sh <journal de swift test>" >&2
  # Sortir en zéro même ici : un relevé qui casse le job qu'il observe est
  # exactement l'instrument de diagnostic qui abîme ce qu'il mesure.
  exit 0
fi

# La forme exacte que XCTest écrit, et rien qui lui ressemble : le verdict est
# « : Test skipped - », pas le mot « skipped » quelque part dans une ligne. Un
# test nommé `testSkippedFrames` ne doit pas entrer ici.
sautes=$(grep -oE "[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]* : Test skipped - .*" "$journal" || true)
total=$(grep -oE "Executed [0-9]+ tests?" "$journal" | grep -oE "[0-9]+" | tail -1 || true)

releve=$(mktemp)
trap 'rm -f "$releve"' EXIT

if [ -z "$sautes" ]; then
  {
    echo "### Tests sautés"
    echo ""
    echo "Aucun test sauté${total:+ : les $total ont tourné}."
  } > "$releve"
else
  compte=$(printf '%s\n' "$sautes" | wc -l | tr -d ' ')
  {
    echo "### Tests sautés"
    echo ""
    echo "**$compte sauté(s)${total:+ sur $total.}**"
    echo ""
    echo "Un test sauté ne mesure rien, et ce job est vert quand même. Ce qui"
    echo "suit dit lesquels, et pourquoi."
    echo ""
    echo '```'
    printf '%s\n' "$sautes"
    echo '```'
  } > "$releve"
fi

cat "$releve"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$releve" >> "$GITHUB_STEP_SUMMARY"
fi
