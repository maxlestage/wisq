#!/usr/bin/env bash
#
# **Construire l'émetteur de la page** : `crates/wisq-page`, en
# `wasm32-unknown-unknown`, sous le profil `release` du workspace.
#
#     scripts/build-page-emitter.sh [racine]
#
# Il imprime **un seul chemin sur la sortie standard** — celui du module
# construit — et tout le reste sur la sortie d'erreur. C'est ce qui permet à
# ses deux appelants de le lancer tels quels : `crates/wisq-page/tests/page.rs`
# (la porte jugée sous Bun) et `examples/kernel-entry.rs` (le démarrage d'un
# vrai noyau avec le traducteur dans la page). Ni l'un ni l'autre ne garde de
# copie de la commande cargo, et aucun des deux ne peut donc juger un module
# périmé : cargo reconstruit ce qui a changé, et ne fait rien sinon.
#
# **Un dossier de construction à part, `target/page`.** Les tests qui appellent
# ce script tournent *sous* un `cargo test` ; partager son dossier les ferait
# attendre un verrou que le `cargo test` parent tient. Et le dossier à part
# garde la bibliothèque native (`target/release/libwisq_vm.a`, que Swift lie)
# hors de portée de cette construction-ci.
#
# **Le profil `release`, pas `wasm-release`.** Celui du site optimise pour la
# taille, parce que chaque visiteur télécharge son module. Celui-ci est chargé
# une fois par l'application, depuis le paquet, et il est sur le chemin de
# chaque région : c'est sa vitesse qui compte. Mesuré le jour de son arrivée,
# les deux tailles et les deux vitesses sont au JOURNAL.
#
# **La cible doit être installée** : `rustup target add wasm32-unknown-unknown`.
# Le job « Rust » de la CI le fait dans son étape « Toolchain », et
# `scripts/install-wasm-toolchain.sh` le fait déjà pour le site.
set -euo pipefail

root="${1:-$(dirname "$0")/..}"
cd "$root"

if command -v rustup >/dev/null 2>&1 &&
  ! rustup target list --installed 2>/dev/null | grep -qx wasm32-unknown-unknown; then
  echo "la cible wasm32-unknown-unknown n'est pas installée : rustup target add wasm32-unknown-unknown" >&2
  exit 1
fi

# `CARGO` est posé par cargo pour les tests qu'il lance : le même cargo, la
# même chaîne. Sinon, celui du PATH.
"${CARGO:-cargo}" build --release --target wasm32-unknown-unknown -p wisq-page \
  --target-dir "$PWD/target/page" >&2

module="$PWD/target/page/wasm32-unknown-unknown/release/wisq_page.wasm"
if [ ! -f "$module" ]; then
  echo "cargo a fini sans rendre $module" >&2
  exit 1
fi
echo "$module"
