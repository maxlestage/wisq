# Les pixels de `miZeroLine`, depuis la référence

`zeroline.py` transcrit le tracé de ligne d'épaisseur nulle de spice-common
(`common/lines.c` : `miZeroLine`, `CalcLineDeltas`, `FIXUP_ERROR`,
`DEFAULTZEROLINEBIAS`) et imprime les pixels exacts pour un jeu de lignes
choisies parce que leur pente met Bresenham à égalité.

## Pourquoi ce harnais existe

`SpiceStrokeRasterTests` vérifie d'abord une propriété : une ligne tracée à
l'envers allume les mêmes pixels. C'est ce à quoi sert le biais d'octant, et
c'est une bonne propriété — elle teste toute la table plutôt qu'une entrée.

Mais elle ne suffit pas. Un sabotage qui **échange les rôles de x et de y** dans
l'indice d'octant produit une table différente qui biaise toujours exactement un
membre de chaque paire de directions inverses. Elle reste donc parfaitement
réversible, et elle survivait à la suite entière.

Ce que ce script apporte est l'autre moitié : les coordonnées elles-mêmes.
L'asymétrie qui les distingue est visible à l'œil nu dans sa sortie —
`(0,0)→(8,4)` avance en y dès le premier pas, `(0,0)→(-8,4)` attend un pas de
plus. Une table échangée inverse exactement cela.

## Reconstruire le gabarit

    python3 scripts/spice-zero-line/zeroline.py

La sortie est recopiée dans `SpiceStrokeRasterTests.testTheTiePixelsMatchTheReference`.
Rien n'est généré à la compilation : le gabarit est du texte dans un test, et ce
script est ce qui permet de le refaire si la référence bouge.
