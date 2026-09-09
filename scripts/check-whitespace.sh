#!/usr/bin/env bash
#
# The text-level rules SwiftLint enforces, checked without SwiftLint.
#
# This exists because of a round trip it saves. SwiftLint is a Homebrew
# formula: on a Linux box — the container this is mostly developed in — there
# is no way to run the CI lint job locally, so a stray blank line at the end of
# a file is not discovered until a pull request turns red ten minutes later.
# That is exactly what happened, and these rules are pure text.
#
# Not a replacement for `swiftlint lint --strict`, which verify.sh still runs
# wherever it is installed. A floor, not a ceiling.
#
# **It takes a root, and that is what makes it testable.** Run with no argument
# it checks this repository, which is what `verify.sh` does. Given a directory
# it checks that one, which is how `site/tests/whitespace-guard.test.ts` gets to
# watch it refuse — until that test existed it had only ever been run against a
# tree with nothing wrong in it, so none of the six rules below had ever
# reported anything.
#
# **Un seul processus lit les quatre cent treize fichiers, et c'est le sujet
# de la tranche qui a réécrit ce fichier.** La boucle d'avant ouvrait onze
# sous-processus par fichier — `tail`, `od`, `tr`, quatre `grep`, deux `awk` —
# soit plus de quatre mille cinq cents pour un passage. Mesuré : 4,9 s à chaud,
# 25,6 s à froid, sur un dépôt où rien n'est fautif. Le coût ne venait pas du
# texte, qui tient en deux mégaoctets : il venait du nombre de `fork`.
#
# Et ce n'était pas qu'une lenteur. `site/tests/whitespace-guard.test.ts` avait
# dû monter son délai à vingt secondes parce que la garde s'en approchait sous
# charge, et un contrôle dont le verdict dépend de la charge de la machine est
# un chronomètre, pas une garde — c'est écrit dans ce test, et ça restait vrai.
#
# **Pourquoi perl et pas awk.** Cinq des six règles sont lignes à lignes et
# `awk` les ferait. La sixième — exactement un saut de ligne à la fin — demande
# de voir le dernier octet du fichier, et `awk` ne distingue pas un dernier
# enregistrement terminé par un saut de ligne d'un qui ne l'est pas. C'est la
# règle qui coûtait trois sous-processus par fichier à elle seule.
set -euo pipefail

cd "${1:-$(dirname "$0")/..}"

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
#
# `-z` et `perl -0` ensemble : un nom de fichier peut contenir n'importe quoi
# sauf l'octet nul, et une liste séparée par des sauts de ligne se ferait
# couper au premier nom bizarre.
# **Le programme arrive par un heredoc, pas entre apostrophes.** Écrit
# `perl -0 -ne '"'"'…'"'"'`, la première apostrophe française du commentaire ferme la
# chaîne et bash lit la suite comme des mots à lui. Ce fichier en a mangé
# quelques-unes avant que ça se voie : « n\'a » était devenu « na ». Un
# heredoc entre apostrophes ne cite rien et n\'interprète rien.
programme=$(cat <<'PERL'
BEGIN {
  $failures = 0;

  # **Ce qui compte comme un blanc, écrit une fois et sans locale.**
  #
  # La version d'avant demandait `[[:space:]]` à `grep`, et `grep` répond
  # selon la locale : sur ce conteneur, un séparateur de ligne Unicode
  # (U+2028, `e2 80 a8`) en fin de ligne était compté comme un espace en
  # trafic UTF-8 et ignoré en C. Le même fichier, deux verdicts, selon une
  # variable d'environnement — c'est la forme même du défaut que ce dépôt
  # traque ailleurs.
  #
  # La règle est donc énoncée : espace, tabulation, retour chariot, tabulation
  # verticale, saut de page. C'est aussi, exactement, ce que la règle
  # `trailing_whitespace` de SwiftLint regarde — et cette garde est son
  # plancher, pas une règle de plus. Un U+2028 en fin de ligne n'est plus
  # signalé ; SwiftLint ne le signalait pas non plus.
  $BLANC = qr/[ \t\r\f\x0b]/;
  # Un seul endroit qui compte et qui parle : le compte final doit être celui
  # des lignes émises, sans quoi le message de fin mentirait.
  sub report { print STDERR "$_[0]\n"; $failures++ }
}

chomp(my $file = $_);
next unless $file =~ /\.swift$/;

open(my $fh, "<", $file) or next;
my $text = do { local $/; <$fh> };
close $fh;
next unless defined $text && length $text;   # [ -s ] : un fichier vide n'a pas de dernier octet

# Les lignes telles que `grep` et `awk` les voyaient : le saut de ligne final
# ne crée pas une ligne vide de plus, et un fichier qui n'en a pas garde sa
# dernière ligne entière.
my @lines = split(/\n/, $text, -1);
pop @lines if @lines && $lines[-1] eq "";

# trailing_newline: exactly one newline at the end, no more and no less.
if ($text !~ /\n\z/) {
  report("$file : pas de saut de ligne final (trailing_newline)");
} elsif ($text =~ /\n\n\z/) {
  report("$file : plusieurs sauts de ligne finaux (trailing_newline)");
}

# trailing_whitespace
my $spaces = grep { /$BLANC\z/ } @lines;
report("$file : espaces en fin de ligne (trailing_whitespace) — $spaces ligne(s)") if $spaces;

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
for my $i (0 .. $#lines) {
  next unless $lines[$i] =~ /^$BLANC*\{$BLANC*\z/;
  report("$file : accolade ouvrante seule sur sa ligne (opening_brace) — ligne " . ($i + 1));
  last;
}

# A platform guard must cover the whole file.
#
# Not a SwiftLint rule at all, and here for the same reason as the rest: it
# is a defect that Linux cannot see. A file that opens with
# `#if canImport(Glibc)` and closes its guard early compiles perfectly here —
# everything is inside it — and fails on Apple, where the imports vanish and
# whatever sits after the `#endif` is left looking for `XCTestCase`.
#
# It has happened once, to RDPLiveHandshakeTests: two suites appended after
# the `#endif` rather than before it. Ten minutes of CI to learn it, and
# nothing local could have said so.
#
# Ce qui distingue une garde de fichier entier d'un simple `#if` autour d'un
# import, c'est qu'elle est la **première chose** du fichier, commentaires de
# tête mis à part. Une garde d'import arrive après d'autres lignes, et se
# referme aussitôt : elle est correcte, et ce contrôle ne doit pas la voir.
if ($text =~ /^#if canImport/m) {
  my ($first) = grep { !/^$BLANC*\z/ && !/^$BLANC*\/\// } @lines;
  if (defined $first && $first =~ /^#if canImport/ && $lines[-1] ne "#endif") {
    report("$file : la garde de plateforme ne couvre pas la fin du fichier");
  }
}

# vertical_whitespace: at most one blank line in a row.
my $blank = 0;
for my $line (@lines) {
  if ($line =~ /^$BLANC*\z/) {
    if (++$blank > 1) {
      report("$file : deux lignes vides consécutives (vertical_whitespace)");
      last;
    }
  } else {
    $blank = 0;
  }
}

END {
  if ($failures > 0) {
    print STDERR "$failures fichier(s) à corriger.\n";
    exit 1;
  }
  print "Mise en forme : rien à signaler.\n";
}
PERL
)

git ls-files -z --cached --others --exclude-standard Sources Tests App |
  perl -0 -ne "$programme"
