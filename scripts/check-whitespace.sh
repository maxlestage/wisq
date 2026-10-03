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
# tree with nothing wrong in it, so none of the eight rules below had ever
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
# **Pourquoi perl et pas awk.** Sept des huit règles sont lignes à lignes et
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

# **Un `await` dans l'autoclosure d'une assertion XCTest.**
#
# Pas une règle de SwiftLint, et ici pour la raison qui a fait écrire ce
# fichier : un défaut que Linux ne voit pas. `XCTAssertEqual` et ses voisines
# prennent leurs arguments en **autoclosure**, qui accepte `try` mais pas
# `await` — « 'async' call in an autoclosure that does not support
# concurrency ». Le correctif est toujours le même : hisser l'appel hors de
# l'assertion dans un `let`.
#
# Ce qui rend ça invisible d'ici est la portée de `swift build` :
# `Tests/WisqHostedTests` n'appartient qu'au projet Xcode, pas au paquet, donc
# rien sur cette machine ne compile ces fichiers. Seule la vérification
# « App iOS » les voit, quinze minutes plus tard.
#
# **Et la leçon était déjà écrite en commentaire** dans `LocalDesktopTests.swift`
# — « `XCTAssertEqual` prend une autoclosure, qui accepte `try` mais **pas**
# `await` » — ce qui ne l'a pas empêchée de coûter un aller-retour de plus. Un
# commentaire n'est pas une garde.
#
# La portée de l'appel est trouvée en équilibrant les parenthèses, chaînes
# littérales retirées d'abord : un `"("` dans un message d'assertion
# déséquilibrerait le compte. Bornée à vingt lignes, parce qu'une assertion plus
# longue que ça n'existe pas ici et qu'un compte qui ne retombe jamais à zéro ne
# doit pas emporter la fin du fichier.
for my $i (0 .. $#lines) {
  next unless $lines[$i] =~ /\bXCT(?:Assert\w*|Unwrap)\s*\(/;
  my $depth = 0;
  my $found = 0;
  for my $j ($i .. ($i + 19 > $#lines ? $#lines : $i + 19)) {
    my $code = $lines[$j];
    $code =~ s/"(?:\\.|[^"\\])*"//g;   # les chaînes littérales ne comptent pas
    $found = 1 if $code =~ /\bawait\b/;
    $depth += ($code =~ tr/(//) - ($code =~ tr/)//);
    last if $depth <= 0 && $j > $i - 1;
  }
  next unless $found;
  report("$file : `await` dans l'autoclosure d'une assertion XCTest — ligne "
         . ($i + 1) . " (hisse l'appel dans un `let`)");
  last;
}

# **Du code après une boucle `while true` qui ne rompt jamais.**
#
# Pas une règle de SwiftLint non plus, et celle-ci a coûté trois tranches. Une
# boucle `while true` dont chaque sortie est un `return` ou un `throw` ne tombe
# jamais à travers : tout ce qui est écrit après elle, dans la même fonction,
# est **inatteignable**. C'est arrivé à `LocalDesktop.settle` — le dépôt de la
# page zéro ajouté par #310 était sous une telle boucle, et n'a jamais été
# exécuté. #310, #311 et #312 l'ont tous crue posée.
#
# **Et le compilateur Swift est muet là-dessus.** Mesuré, pas supposé :
# `swiftc -typecheck` sur la forme minimale ne rend rien, ni en typage ni en
# compilation complète. Un `-warnings-as-errors` ne l'aurait pas attrapé. Il
# n'existe donc rien d'autre que ceci.
#
# **La règle ne peut pas rendre de faux positif.** Elle ne parle que des
# boucles qui ne contiennent **aucun** `break` : le code qui les suit est
# inatteignable, toujours. Elle est en revanche conservatrice dans l'autre
# sens — un `break` qui appartient à un `switch` imbriqué la fait taire — et
# c'est le bon sens à rater, parce qu'une garde qui refuse du code correct est
# désactivée dans la journée.
for my $i (0 .. $#lines) {
  next unless $lines[$i] =~ /^$BLANC*while$BLANC+true$BLANC*\{$BLANC*\z/;
  my $depth = 0;
  my $end;
  my $breaks = 0;
  for my $j ($i .. $#lines) {
    my $code = $lines[$j];
    $code =~ s/"(?:\\.|[^"\\])*"//g;
    $code =~ s{//.*$}{};
    $breaks = 1 if $j > $i && $code =~ /\bbreak\b/;
    $depth += ($code =~ tr/{//) - ($code =~ tr/}//);
    if ($depth <= 0) { $end = $j; last }
  }
  next if $breaks;
  next unless defined $end;
  # La première ligne qui compte après la boucle. Une accolade fermante veut
  # dire que rien ne la suit dans cette portée, ce qui est le cas correct.
  my $after;
  for my $j ($end + 1 .. $#lines) {
    next if $lines[$j] =~ /^$BLANC*\z/ || $lines[$j] =~ /^$BLANC*\/\//;
    $after = $lines[$j];
    last;
  }
  next unless defined $after;
  next if $after =~ /^$BLANC*\}/;
  report("$file : code inatteignable après une boucle `while true` sans `break` — ligne "
         . ($end + 2) . " (le compilateur Swift ne le dit pas)");
  last;
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
