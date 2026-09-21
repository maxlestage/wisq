#!/usr/bin/env bash
#
# Relève ce que l'iPhone simulé a mesuré, et **refuse** si une suite déclarée
# n'a rendu aucun verdict.
#
# `xcodebuild` écrit des dizaines de milliers de lignes ; les quelques-unes qui
# portent une mesure — le débit de WebKit, le coût du pont — s'y noient, et une
# mesure qu'on ne retrouve pas est une mesure qu'on refait. Elles sont donc
# extraites à la fin et poussées dans le résumé du job quand il y en a un.
#
# **Nommer ne suffisait pas.** #278 a posé la règle « nommer, pas compter » :
# un nombre seul se lit aussi bien comme une réussite que comme une suite
# disparue du binaire. Nommer les suites qui ont tourné répond à la première
# moitié de cette phrase, pas à la seconde — une suite retirée de
# `project.yml`, un fichier sorti de `sources`, une classe renommée, et le
# relevé serait simplement **plus court**, le job vert. Ce qui manquait est la
# comparaison que ce dépôt fait partout ailleurs : deux listes qui devraient
# s'accorder. Les suites **déclarées** d'un côté, celles qui ont rendu un
# verdict de l'autre.
#
# **Et ce relevé perdait une suite sur douze pour une autre raison.** Mesuré
# sur le journal réel du job « App iOS » 106133490635 :
# `OversizedKernelRefusalTests` y rend son verdict sans sa ligne de compte,
# seule des douze. Elle n'a qu'un test, et XCTest écrit alors `Executed 1 test`
# — au singulier. Le motif exigeait `tests`. `report-skipped.sh` écrivait déjà
# `tests?` ; celui-ci non.
#
# **Ce script refuse, là où `report-skipped.sh` se contente de montrer.** La
# différence n'est pas d'humeur : un test qui saute parce qu'un serveur tiers
# n'a pas répondu n'est pas un défaut du dépôt, tandis qu'une suite déclarée
# qui ne rend aucun verdict en est un à tous les coups.
#
# Usage : report-app-suites.sh <journal de xcodebuild> [code de sortie de xcodebuild]
set -euo pipefail

cd "$(dirname "$0")/.."

journal="${1:?usage: report-app-suites.sh <journal> [code de sortie de xcodebuild]}"
issue="${2:-0}"

# **Le motif, et ce qu'il accepte maintenant.** `tests?` pour le singulier ;
# `[A-Za-z_][A-Za-z0-9_]*` pour les noms de classe qui portent un chiffre
# (`SHA256Tests` en est un ailleurs dans ce dépôt) — l'ancien `[A-Za-z]+` les
# aurait tus. Les suites de niveau bundle (`WisqUITests.xctest`) et la suite
# racine (`All tests`) restent hors du motif : le point et l'espace les en
# écartent, et ce sont les classes qu'on veut nommer.
motif="^(WebKit|pont|Metal|bureau) [^:]*: |Executed [0-9]+ tests?|Test Suite '[A-Za-z_][A-Za-z0-9_]*' (passed|failed)"

# **Pas de `tail` ici, et c'est le sujet de ce script.** L'ancienne extraction
# coupait aux quarante dernières lignes ; sur le journal de #416 elle en
# produisait trente-quatre, soit trois suites de marge avant de se mettre à
# couper **par la tête**, en silence. Un relevé qui perd des noms quand la
# suite grandit est exactement ce que ce script existe pour empêcher.
mesures=$(grep -E "$motif" "$journal" || true)

mesuresFichier="${RUNNER_TEMP:-/tmp}/wisq-mesures-app.txt"
if [ -n "$mesures" ]; then
  echo "==> Mesures"
  echo "$mesures"
  printf '%s\n' "$mesures" > "$mesuresFichier"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Ce que l'iPhone simulé a mesuré"
      echo ""
      echo '```'
      echo "$mesures"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

# **Ce qui aurait dû tourner, lu de la spec et non écrit en dur.** La scheme de
# l'application nomme ses cibles de test ; chaque cible nomme ses répertoires
# de sources ; chaque source porte ses classes. Une liste écrite en dur ici
# vieillirait au premier ajout, et une garde qui vieillit est une garde qu'on
# apprend à ignorer.
#
# L'hypothèse, énoncée pour qu'on la relise le jour où elle tombe : toutes ces
# classes tournent sur un iPhone simulé. C'est vrai aujourd'hui — les seules
# gardes de compilation dans ces deux répertoires sont `#if os(iOS)`,
# `#if canImport(WebKit)` et `#if canImport(Metal)`, vraies toutes les trois
# sur un simulateur. Une classe posée derrière une garde fausse serait accusée
# à tort, et il faudrait alors apprendre les gardes à ce script.
attendues=$(python3 - <<'PY'
import pathlib
import re
import sys

spec = pathlib.Path("project.yml").read_text(encoding="utf-8")

bloc = re.search(r"^      testTargets:\n((?:^        - .+\n)+)", spec, re.M)
if bloc is None:
    sys.exit("project.yml : aucune liste « testTargets » sous la scheme")
cibles = [ligne.strip().lstrip("-").strip() for ligne in bloc.group(1).splitlines()]

chemins: list[str] = []
for cible in cibles:
    corps = re.search(r"^  %s:\n(.*?)(?=^  \S|\Z)" % re.escape(cible), spec, re.M | re.S)
    if corps is None:
        sys.exit(f"project.yml : la scheme nomme « {cible} », que les targets ne déclarent pas")
    sources = re.findall(r"^      - path: (.+)$", corps.group(1), re.M)
    if not sources:
        sys.exit(f"project.yml : la cible « {cible} » ne déclare aucune source")
    chemins += [source.strip() for source in sources]

classes: set[str] = set()
for chemin in chemins:
    racine = pathlib.Path(chemin)
    if not racine.is_dir():
        sys.exit(f"project.yml : « {chemin} » n'est pas un répertoire de ce dépôt")
    for fichier in sorted(racine.rglob("*.swift")):
        texte = fichier.read_text(encoding="utf-8")
        classes.update(re.findall(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b", texte))

print("\n".join(sorted(classes)))
PY
)

# **La prémisse, gardée.** Une liste attendue vide acquitterait n'importe quel
# journal, y compris un journal vide — la forme d'échec que ce dépôt a payée le
# plus souvent. Elle ne peut pas l'être par construction ci-dessus, mais une
# garde qui ne peut pas échouer est précisément ce qu'on ne veut plus écrire.
if [ -z "$attendues" ]; then
  echo "::error::aucune suite déclarée n'a été lue depuis project.yml — cette garde ne garderait rien." >&2
  exit 1
fi

compte=$(printf '%s\n' "$attendues" | wc -l | tr -d ' ')
echo "==> Suites déclarées ($compte) : $(printf '%s\n' "$attendues" | tr '\n' ' ')"

vues=$(printf '%s\n' "$mesures" \
  | grep -oE "Test Suite '[A-Za-z_][A-Za-z0-9_]*' (passed|failed)" \
  | sed -E "s/^Test Suite '([^']*)'.*/\1/" \
  | sort -u || true)

manquantes=$(comm -23 <(printf '%s\n' "$attendues" | sort -u) <(printf '%s\n' "$vues" | sed '/^$/d'))

# **Un journal partiel n'accuse personne.** Quand `xcodebuild` a échoué, les
# suites qui n'ont pas eu le temps de tourner ne sont pas des suites disparues ;
# c'est le job qui porte l'échec, et ajouter un faux coupable à un rouge rend
# le vrai plus difficile à lire.
if [ "$issue" -ne 0 ]; then
  echo "==> xcodebuild a rendu $issue : le journal est partiel, les suites absentes ne sont pas jugées."
  exit 0
fi

if [ -n "$manquantes" ]; then
  echo "::error::des suites déclarées n'ont rendu aucun verdict — elles ont disparu du bundle, ou n'ont pas été lancées." >&2
  while IFS= read -r suite; do
    [ -n "$suite" ] || continue
    echo "::error::$suite n'a rendu aucun verdict." >&2
  done <<< "$manquantes"
  echo "::error::vérifier « scheme.testTargets » et les « sources » de project.yml, puis « xcodegen generate »." >&2
  exit 1
fi

echo "==> Les $compte suites déclarées ont toutes rendu un verdict."
