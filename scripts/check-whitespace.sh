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
#
# **It takes a root, and that is what makes it testable.** Run with no argument
# it checks this repository, which is what `verify.sh` does. Given a directory
# it checks that one, which is how `site/tests/whitespace-guard.test.ts` gets to
# watch it refuse — until that test existed it had only ever been run against a
# tree with nothing wrong in it, so none of the five rules below had ever
# reported anything.
set -euo pipefail

cd "${1:-$(dirname "$0")/..}"

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

  # opening_brace: a line whose entire content is `{` is a brace that was put
  # on its own line, which SwiftLint refuses.
  #
  # Here because it has now cost two pull requests, both mine, both for the
  # same reason: a signature too long to sit on one line, wrapped out of a
  # habit from codebases that limit line length. This one does not —
  # `line_length` is disabled in .swiftlint.yml — so the fix is always to put
  # the signature back on one line, or to name the return type.
  #
  # A whole-line `{` is not the only shape SwiftLint catches, so this is a
  # floor like the rest of the file. It is the shape that actually happens
  # here: the rest of the repository has none.
  if grep -n '^[[:space:]]*{[[:space:]]*$' "$file" > /dev/null; then
    report "$file : accolade ouvrante seule sur sa ligne (opening_brace) — ligne $(grep -n '^[[:space:]]*{[[:space:]]*$' "$file" | head -1 | cut -d: -f1)"
  fi

  # vertical_whitespace: at most one blank line in a row.
  if awk 'BEGIN { blank = 0 }
          /^[[:space:]]*$/ { blank++; if (blank > 1) { print NR; exit } }
          !/^[[:space:]]*$/ { blank = 0 }' "$file" | grep -q .; then
    report "$file : deux lignes vides consécutives (vertical_whitespace)"
  fi
# The same scope as .swiftlint.yml's `included`: the three directories, every
# Swift file under them at any depth. Package.swift is outside it on purpose —
# the manifest is not application code and SwiftLint never sees it, so flagging
# it here would report a violation CI does not have.
#
# `--others` matters: a file written but not yet committed is precisely the one
# about to be pushed, and listing only tracked files would wave it through.
#
# The pathspecs used to be `'Sources/**/*.swift' 'Tests/**/*.swift'
# 'App/**/*.swift'`, and the third one matched **nothing**: `**/` requires at
# least one directory level, and `App/` holds exactly one Swift file, at its
# top. So `App/WisqApp.swift` — which SwiftLint does check, since
# `.swiftlint.yml` lists `App` — was the one file this floor never saw. Naming
# the directories and filtering by extension has no such edge.
done < <(git ls-files --cached --others --exclude-standard Sources Tests App \
  | grep '\.swift$' || true)

if [ "$failures" -gt 0 ]; then
  echo "$failures fichier(s) à corriger." >&2
  exit 1
fi

echo "Mise en forme : rien à signaler."
