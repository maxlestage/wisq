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

# **Deux XCTest, deux formes**, et le relevé l'a appris en mentant. Le même
# `swift test` n'écrit pas la même ligne des deux côtés :
#
#     Linux  LinuxBootTests.testFoo : Test skipped - image absente
#     Apple  /chemin/F.swift:26: -[Mod.LinuxBootTests testFoo] : Test skipped - …
#
# Le premier motif exigeait `NOM.NOM` immédiatement avant « : », ce qu'un `]`
# n'est pas. Sur le job Apple il ne correspondait à rien, et le relevé a écrit
# « Aucun test sauté » sur une exécution qui en sautait trente-six.
#
# **Et deux façons de sauter, trouvées par la comparaison ci-dessous** — pas en
# relisant. `XCTSkip("raison")` écrit « : Test skipped - raison » ;
# `XCTSkipIf(cond, "raison")` écrit « : Test skipped: required false value but
# got true - raison ». Le second existait depuis toujours et n'était pas compté :
# `JPEGTests.testQualityIsClampedIntoTheSpecRange`, le seul des vingt-six.
#
# Ce qui reste commun à toutes les formes, et sur quoi le motif s'appuie : le
# nom du test, puis « : Test skipped », puis l'un des deux séparateurs. Le mot
# « skipped » seul ne suffit toujours pas — un test nommé `testSkippedFrames`
# ne doit pas entrer ici.
sautes=$(grep -oE "(-\[[A-Za-z_][A-Za-z0-9_.]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\]|[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*) : Test skipped( -|:) .*" "$journal" || true)
total=$(grep -oE "Executed [0-9]+ tests?" "$journal" | grep -oE "[0-9]+" | tail -1 || true)

# **Le nombre que XCTest compte lui-même**, à confronter au nôtre.
#
# C'est la méthode qui a trouvé le défaut ci-dessus, cette fois posée dans
# l'outil : deux nombres qui doivent s'accorder. Tant qu'ils s'accordent, la
# liste est complète. Quand ils divergent, le lecteur ne comprend pas ce
# journal — et ce qu'il faut alors dire n'est pas « aucun test sauté », c'est
# que le relevé est aveugle. Un instrument qui ne sait pas reconnaître son
# ignorance est pire que pas d'instrument.
#
# Absent d'un journal sans aucun saut : XCTest n'écrit « with N tests skipped »
# que lorsqu'il y en a. D'où le zéro par défaut.
# Une mise en garde, mesurée en écrivant ceci : donner à ce script la
# transcription ENTIÈRE de `verify.sh` fait crier le désaccord pour rien — elle
# porte deux exécutions de `swift test` et, en prime, la sortie de ce relevé
# lui-même. Ce n'est pas le contrat : la CI comme `verify.sh` lui passent le
# journal **d'une seule** exécution, `tee` à part.
annonce=$(grep -oE "with [0-9]+ tests? skipped" "$journal" | grep -oE "[0-9]+" | tail -1 || true)
annonce="${annonce:-0}"

if [ -z "$sautes" ]; then
  compte=0
else
  compte=$(printf '%s\n' "$sautes" | wc -l | tr -d ' ')
fi

releve=$(mktemp)
trap 'rm -f "$releve"' EXIT

{
  echo "### Tests sautés"
  echo ""
  if [ "$compte" -eq 0 ] && [ "$annonce" -eq 0 ]; then
    echo "Aucun test sauté${total:+ : les $total ont tourné}."
  elif [ "$compte" -eq 0 ]; then
    echo "**$annonce sauté(s)${total:+ sur $total}, et le relevé n'a pu en nommer aucun.**"
  else
    echo "**$compte sauté(s)${total:+ sur $total.}**"
    echo ""
    echo "Un test sauté ne mesure rien, et ce job est vert quand même. Ce qui"
    echo "suit dit lesquels, et pourquoi."
    echo ""
    echo '```'
    printf '%s\n' "$sautes"
    echo '```'
  fi
  if [ "$compte" -ne "$annonce" ]; then
    echo ""
    echo "> **Le relevé et XCTest ne sont pas d'accord.** XCTest annonce"
    echo "> **$annonce** test(s) sauté(s) ; ce relevé en a nommé **$compte**."
    echo "> Le lecteur ne reconnaît pas la forme de ce journal : ce qui manque"
    echo "> n'est pas dans la liste ci-dessus, et c'est"
    echo "> \`scripts/report-skipped.sh\` qu'il faut corriger, pas la liste qu'il"
    echo "> faut croire."
  fi
} > "$releve"

cat "$releve"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$releve" >> "$GITHUB_STEP_SUMMARY"
fi
