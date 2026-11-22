#!/usr/bin/env bash
#
# **L'index des bureaux prêts déjà publié**, pour que `wisq-fabrique index
# --garder` en reprenne les entrées d'un autre cœur ou d'un autre niveau de
# machine (`ReadyDesktop.Index.merged`). Appelé par `.github/workflows/bureaux.yml`.
#
#   bureaux-ancien-index.sh <adresse> <fichier>
#
#   - HTTP 200 : l'index est écrit dans <fichier>, code 0 ;
#   - HTTP 404 : rien n'a encore été publié (la toute première fabrication) :
#     aucun fichier, code 0, et l'index neuf part de rien ;
#   - tout le reste : code 1, aucun fichier.
#
# **Seul un 404 constaté veut dire « absent ».** L'étape d'avant faisait
# `if curl -f …; then garder; fi` : le code 22 de `curl -f` est le même pour
# un 404, un 500 après les essais ou un 403 de limite de débit, et une panne
# DNS ou réseau tombait dans la même branche. Le job publiait alors, code 0,
# un index sans les entrées du niveau d'avant, et les applications de ce
# niveau perdaient leur bureau sans un mot. Ici, une panne arrête le job :
# rien n'est publié, et on relance.
#
# Le nombre d'essais se règle par `BUREAUX_ESSAIS` (3 par défaut), pour que
# `site/tests/bureaux-ancien-index.test.ts` ne passe pas ses secondes à
# attendre un serveur qu'il fait tomber exprès.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage : $0 <adresse> <fichier>" >&2; exit 2; }
url=$1
out=$2
essais=${BUREAUX_ESSAIS:-3}
part="$out.part"

# Un fichier d'un essai précédent ne doit jamais passer pour la réponse de
# celui-ci : en cas de panne, il ne reste rien à donner à `--garder`.
rm -f -- "$out" "$part"

# Sans `-f` : le code HTTP est lu, pas deviné. `-L` suit la redirection de
# GitHub vers son stockage ; le code est celui de la réponse finale.
status=0
code=$(curl -sS -L --retry "$essais" --connect-timeout 30 -o "$part" -w '%{http_code}' -- "$url") || status=$?

case "$status:$code" in
  0:200)
    mv -- "$part" "$out"
    echo "index publié repris : $url"
    ;;
  0:404)
    rm -f -- "$part"
    echo "aucun index publié à $url (404) : l'index neuf part de rien"
    ;;
  *)
    rm -f -- "$part"
    echo "::error::l'index publié ne s'est pas laissé lire (curl $status, HTTP $code) : rien n'est publié, pour ne pas perdre ses entrées" >&2
    exit 1
    ;;
esac
