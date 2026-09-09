#!/usr/bin/env bash
#
# Ce que le workflow TestFlight a le droit de faire d'une clé privée.
#
# **D'où ça vient.** L'envoi n° 28 a échoué sur « Your account has reached the
# maximum number of certificates ». Le dessin d'origine était délibéré et
# écrit : `-allowProvisioningUpdates` avec la clé App Store Connect fabrique le
# profil, « c'est ce qui évite d'avoir à transporter un certificat dans un
# secret ». Vingt-sept envois ont marché ainsi. Le vingt-huitième a buté sur le
# quota d'Apple, parce que chaque exécution sans certificat dans son trousseau
# en demandait un nouveau.
#
# Le certificat arrive donc maintenant par un secret, et deux règles du dépôt
# cessent d'être seulement écrites :
#
#   * un secret ne s'écrit jamais dans le dépôt — seulement sous `RUNNER_TEMP`,
#     qui part avec le runner ;
#   * un secret ne s'imprime jamais, et un journal d'exécution publique est
#     exactement l'endroit où ça ne se rattrape pas.
#
# La troisième règle est du confort, mais elle a un coût mesuré : un secret
# absent doit se voir dans l'étape de refus précoce, en une ligne, plutôt que
# quinze minutes plus tard dans une erreur de signature. La liste des secrets
# n'est pas recopiée ici — elle est **lue du workflow**, sinon cette garde
# aurait à son tour besoin d'une garde.
#
# **Il prend une racine, et c'est ce qui le rend éprouvable.** Sans argument il
# vérifie ce dépôt, ce que fait `verify.sh`. Avec un répertoire il vérifie
# celui-là, et c'est ainsi que `site/tests/signing-secrets.test.ts` le regarde
# refuser. Une garde qui n'a jamais refusé est une garde que personne n'a
# vérifiée.
set -euo pipefail

root="${1:-.}"
flow="$root/.github/workflows/testflight.yml"

if [ ! -f "$flow" ]; then
  echo "introuvable : $flow" >&2
  exit 1
fi

failed=0
grief() {
  echo "$1" >&2
  failed=1
}

# Les secrets que le workflow emploie, lus chez lui.
secrets=$(grep -oE 'secrets\.[A-Z0-9_]+' "$flow" | cut -d. -f2 | sort -u)

# **Les alias, parce que c'est sous eux que les secrets circulent.** Un bloc
# `env:` écrit `KEY_P8: ${{ secrets.ASC_KEY_P8 }}`, et le `run:` ne connaît que
# `$KEY_P8`. Chercher le nom du secret dans les commandes ne trouve donc rien —
# un premier jet de cette garde le faisait, et trois sabotages sur quatre lui
# ont échappé. C'est l'alias qu'il faut suivre.
alias_of() {
  grep -oE "[A-Z0-9_]+: \\$\\{\\{ secrets\\.$1 \\}\\}" "$flow" |
    cut -d: -f1 | sort -u
}

# L'étape de refus précoce : de son nom jusqu'à l'étape suivante.
early=$(awk '
  /- name: Refuser tôt/ { inside = 1; next }
  inside && /^      - / { exit }
  inside { print }
' "$flow")
if [ -z "$early" ]; then
  grief "l'étape « Refuser tôt » a disparu : un secret manquant échouerait dans xcodebuild"
fi

# **Le contexte `secrets` n'existe pas dans un `if:`.** GitHub ne le dit qu'au
# lancement — « Unrecognized named-value: 'secrets' » — et jamais avant : la CI
# ne parse pas ce fichier, il n'est lu que par un `workflow_dispatch`. Un
# workflow qu'on ne lance qu'à la main peut donc rester cassé aussi longtemps
# qu'on n'envoie rien, et le seul moment où on le découvre est celui où l'on
# voulait envoyer. C'est arrivé ici, en conditionnant l'étape du trousseau par
# `if: ${{ secrets.APPLE_CERT_P12 != '' }}`.
#
# La condition se pose sur une **sortie d'étape** : le refus précoce lit le
# secret dans son `env:`, où le contexte existe, et écrit oui ou non.
#
# **Et `steps.secrets.outputs.…` n'est pas le contexte `secrets`.** L'étape de
# refus porte l'identifiant `secrets`, exprès : le dépôt est ainsi son propre
# témoin que la garde distingue les deux. Chercher `secrets\.` sans regarder ce
# qui précède refuserait la correction elle-même — c'est arrivé, à la première
# écriture de ce bloc.
while IFS= read -r line; do
  grief "un « if » lit un secret, que GitHub refuse au lancement :$(printf '%s' "$line" | sed 's/^ *//')"
done < <(grep -E '^[[:space:]]*if:' "$flow" | grep -E '(^|[^.[:alnum:]_])secrets\.' || true)

for secret in $secrets; do
  # **Nommé ne suffit pas : il faut qu'il soit éprouvé.** Un secret peut
  # apparaître dans le bloc `env:` de l'étape sans qu'aucune ligne ne vérifie
  # qu'il est là — c'est exactement ce qu'un sabotage a montré en survivant.
  # Ce qui compte est la ligne qui le déclare manquant, ou celle qui le dit
  # explicitement facultatif.
  if ! printf '%s\n' "$early" | grep -qE "missing=.*$secret|$secret absent"; then
    grief "$secret n'est pas éprouvé dans « Refuser tôt » : son absence ne se verrait qu'à la signature"
  fi
done

# **Ce qui porte de la matière privée.** Un identifiant d'équipe ou de clé n'en
# est pas ; une clé, un certificat et un mot de passe, si. Le nom suffit à les
# distinguer, et se tromper du côté strict ne coûte rien.
private=$(printf '%s\n' $secrets | grep -E 'P12|P8|PASSWORD|CERT' || true)

for secret in $private; do
  for name in $(alias_of "$secret") "$secret"; do
    [ -n "$name" ] || continue
    # **Un seul endroit lui est permis : un fichier sous RUNNER_TEMP.** Tout
    # le reste est soit la sortie — et un journal public ne se rattrape pas —
    # soit un chemin qui survit à l'exécution. Les deux se disent ensemble,
    # parce que c'est la même règle : un message qui parle d'autre chose que
    # du défaut n'est pas une détection.
    if grep -nE "(echo|cat|printf|tee)[^>]*\\\$\\{?$name\\b" "$flow" |
       grep -qvE '>[[:space:]]*"?\$\{?RUNNER_TEMP'; then
      grief "$secret ($name) va ailleurs que dans un fichier sous RUNNER_TEMP : sortie, ou chemin qui survit"
    fi
    # Et aucune écriture ailleurs que dans le temporaire du runner, qui est
    # jeté avec lui. Jamais dans l'arbre du dépôt.
    while IFS= read -r line; do
      case "$line" in
        *'>'*'$RUNNER_TEMP'*|*'>'*'${RUNNER_TEMP}'*) ;;
        *'>'*) grief "$secret ($name) est écrit hors de RUNNER_TEMP :$(printf '%s' "$line" | sed 's/^ *//')" ;;
      esac
    done < <(grep -E "\\\$\\{?$name\\b" "$flow" | grep -E '>' || true)
  done
done

if [ "$failed" -eq 0 ]; then
  echo "Secrets de signature : rien à signaler."
fi
exit "$failed"
