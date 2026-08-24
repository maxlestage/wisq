#!/usr/bin/env bash
#
# The text-level rules SwiftLint enforces, checked without SwiftLint.
#
# This exists because of a round trip it saves. SwiftLint is a Homebrew
# formula: on a Linux box — the container this is mostly developed in — there
# is no way to run the CI lint job locally, so a stray blank line at the end of
# a file is not discovered until a pull request turns red ten minutes later.
# That is exactly what happened, and these three rules are pure text.
#
# Not a replacement for `swiftlint lint --strict`, which verify.sh still runs
# wherever it is installed. A floor, not a ceiling.
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0
report() {
  echo "$1" >&2
  failures=$((failures + 1))
}

while IFS= read -r file; do
  [ -s "$file" ] || continue

  # trailing_newline: exactly one newline at the end, no more and no less.
  if [ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != "\n" ]; then
    report "$file : pas de saut de ligne final (trailing_newline)"
  elif [ "$(tail -c 2 "$file" | od -An -c | tr -d ' ')" = "\n\n" ]; then
    report "$file : plusieurs sauts de ligne finaux (trailing_newline)"
  fi

  # trailing_whitespace
  if grep -n '[[:space:]]$' "$file" > /dev/null; then
    report "$file : espaces en fin de ligne (trailing_whitespace) — $(grep -c '[[:space:]]$' "$file") ligne(s)"
  fi

  # vertical_whitespace: at most one blank line in a row.
  if awk 'BEGIN { blank = 0 }
          /^[[:space:]]*$/ { blank++; if (blank > 1) { print NR; exit } }
          !/^[[:space:]]*$/ { blank = 0 }' "$file" | grep -q .; then
    report "$file : deux lignes vides consécutives (vertical_whitespace)"
  fi
# The same scope as .swiftlint.yml's `included`. Package.swift is outside it
# on purpose: the manifest is not application code and SwiftLint never sees it,
# so flagging it here would report a violation CI does not have.
#
# `--others` matters: a file written but not yet committed is precisely the one
# about to be pushed, and listing only tracked files would wave it through.
done < <(git ls-files --cached --others --exclude-standard \
  'Sources/**/*.swift' 'Tests/**/*.swift' 'App/**/*.swift')

if [ "$failures" -gt 0 ]; then
  echo "$failures fichier(s) à corriger." >&2
  exit 1
fi

echo "Mise en forme : rien à signaler."
