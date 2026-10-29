#!/usr/bin/env bash
#
# Compare le temps natif de deux commits sur le démarrage d'un vrai noyau,
# **en croisant les copies**.
#
# Pourquoi croiser. Deux copies du dépôt ne donnent pas le même binaire : les
# chemins entrent dans les informations de débogage, et l'alignement du code
# en dépend. Mesuré le 29 octobre 2026 : le même commit, construit dans deux
# copies, rendait 10,68 s dans l'une et 10,24 s dans l'autre. Une comparaison
# qui met toujours la branche dans la même copie mesure la copie autant que la
# branche — c'est ainsi que deux gains de 7 et 8 % avaient été annoncés pour
# des changements qui n'en valaient pas 1 (voir docs/JOURNAL.md).
#
# Ce que fait le script : deux copies jetables (`git worktree`), A dans la
# première et B dans la seconde, N courses alternées ; puis l'inverse, N
# courses encore. Il rend la moyenne de chaque commit sur les deux copies, et
# l'écart des copies elles-mêmes, pour qu'on voie ce que vaut le bruit.
#
# Usage : WISQ_PC_KERNEL=… WISQ_PC_INITRD=… scripts/compare-native.sh A B [N]
#   A, B  deux commits ou branches ;
#   N     courses par copie et par passe (3 par défaut).
# WISQ_PC_BUDGET (600 millions par défaut) borne chaque course. Le cœur 2 est
# réservé par `taskset` quand il existe.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage : $0 <commit A> <commit B> [courses]" >&2
  exit 2
fi
if [ -z "${WISQ_PC_KERNEL:-}" ] || [ -z "${WISQ_PC_INITRD:-}" ]; then
  echo "WISQ_PC_KERNEL et WISQ_PC_INITRD doivent désigner un noyau et son initramfs." >&2
  exit 2
fi
a=$1
b=$2
runs=${3:-3}
budget=${WISQ_PC_BUDGET:-600000000}
root=$(git rev-parse --show-toplevel)
git -C "$root" rev-parse --verify --quiet "$a^{commit}" >/dev/null || { echo "commit inconnu : $a" >&2; exit 2; }
git -C "$root" rev-parse --verify --quiet "$b^{commit}" >/dev/null || { echo "commit inconnu : $b" >&2; exit 2; }

work=$(mktemp -d)
cleanup() {
  git -C "$root" worktree remove --force "$work/un" 2>/dev/null || true
  git -C "$root" worktree remove --force "$work/deux" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
git -C "$root" worktree add --quiet --detach "$work/un" "$a"
git -C "$root" worktree add --quiet --detach "$work/deux" "$b"

pin=()
if command -v taskset >/dev/null && taskset -c 2 true 2>/dev/null; then pin=(taskset -c 2); fi

build() {
  (cd "$1" && git checkout --quiet --detach "$2" \
    && cargo build --release -p wisq-vm >/dev/null 2>&1 \
    && swift build -c release --build-tests -Xswiftc -enable-testing >/dev/null 2>&1)
}

# Le temps écoulé d'une course, en secondes.
run() {
  local start end
  start=$(date +%s.%N)
  (cd "$1" && env WISQ_PC_BUDGET="$budget" "${pin[@]}" .build/release/WisqPackageTests.xctest \
    WisqVMTests.X86BootAttemptTests/testHowFarARealKernelGets >/dev/null 2>&1)
  end=$(date +%s.%N)
  echo "$end - $start" | bc
}

declare -A total=([A]=0 [B]=0)
declare -A slot=([un]=0 [deux]=0)
for pass in 1 2; do
  if [ $pass = 1 ]; then ca=un; cb=deux; else ca=deux; cb=un; fi
  build "$work/$ca" "$a"
  build "$work/$cb" "$b"
  for _ in $(seq "$runs"); do
    ta=$(run "$work/$ca"); tb=$(run "$work/$cb")
    echo "passe $pass : A ($ca) $ta s, B ($cb) $tb s"
    total[A]=$(echo "${total[A]} + $ta" | bc); total[B]=$(echo "${total[B]} + $tb" | bc)
    slot[$ca]=$(echo "${slot[$ca]} + $ta" | bc); slot[$cb]=$(echo "${slot[$cb]} + $tb" | bc)
  done
done

n=$((2 * runs))
ma=$(echo "scale=3; ${total[A]} / $n" | bc)
mb=$(echo "scale=3; ${total[B]} / $n" | bc)
echo "A $a : $ma s en moyenne"
echo "B $b : $mb s en moyenne"
echo "écart B/A : $(echo "scale=2; ($mb - $ma) * 100 / $ma" | bc) %"
echo "écart des copies (bruit de disposition) : $(echo "scale=2; (${slot[deux]} - ${slot[un]}) * 100 / ${slot[un]}" | bc) %"
