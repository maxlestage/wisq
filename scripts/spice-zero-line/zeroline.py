#!/usr/bin/env python3
"""Les pixels que `miZeroLine` allume, depuis la référence.

Pourquoi ce script existe : la propriété que les tests Swift vérifient d'abord —
une ligne tracée à l'envers allume les mêmes pixels — ne fixe pas *quel* membre
de chaque paire d'octants inverses porte le biais. Un sabotage qui échange les
rôles de x et de y dans l'indice d'octant produit une autre table, tout aussi
réversible, et survivait à toute la suite.

Ce que ce script produit est donc l'autre moitié de la preuve : les coordonnées
exactes, dérivées de `common/lines.c` de spice-common, pour des lignes choisies
parce qu'elles tombent sur des égalités. Le tableau qu'il imprime est recopié
dans `SpiceStrokeRasterTests` et sert de gabarit.

  python3 scripts/spice-zero-line/zeroline.py

Transcrit de : miZeroLine, CalcLineDeltas, FIXUP_ERROR et DEFAULTZEROLINEBIAS.
Le clipping n'est pas transcrit : les lignes ci-dessous tiennent dans la surface,
et le chemin de clipping de la référence recalcule les mêmes termes d'erreur.
"""

XDECREASING, YDECREASING, YMAJOR = 4, 2, 1
OCTANT = {
    1: 1 << YDECREASING,
    2: 1 << (YDECREASING | YMAJOR),
    3: 1 << (XDECREASING | YDECREASING | YMAJOR),
    4: 1 << (XDECREASING | YDECREASING),
    5: 1 << XDECREASING,
    6: 1 << (XDECREASING | YMAJOR),
    7: 1 << YMAJOR,
    8: 1 << 0,
}
DEFAULTZEROLINEBIAS = OCTANT[2] | OCTANT[3] | OCTANT[4] | OCTANT[5]


def zero_line(x1, y1, x2, y2):
    """Un segment, capuchon CapNotLast : le point final n'est pas rendu."""
    octant = 0
    signdx, signdy = 1, 1
    adx = x2 - x1
    if adx < 0:
        adx, signdx, octant = -adx, -1, octant | XDECREASING
    ady = y2 - y1
    if ady < 0:
        ady, signdy, octant = -ady, -1, octant | YDECREASING

    # `if (adx > ady) { x-major } else { y-major }` : l'égalité est y-majeure.
    if adx > ady:
        e1, major, minor = ady << 1, adx, ady
    else:
        octant |= YMAJOR
        e1, major, minor = adx << 1, ady, adx
    e2 = e1 - (major << 1)
    e = e1 - major
    e -= (DEFAULTZEROLINEBIAS >> octant) & 1

    e3 = e2 - e1
    e -= e1

    out = []
    x, y = x1, y1
    for _ in range(major):
        out.append((x, y))
        e += e1
        if e >= 0:
            if octant & YMAJOR:
                x += signdx
            else:
                y += signdy
            e += e3
        if octant & YMAJOR:
            y += signdy
        else:
            x += signdx
    return out


# Des lignes dont la pente met Bresenham à égalité : le mineur vaut la moitié du
# majeur, ou son quart, donc la ligne idéale passe exactement entre deux pixels.
CASES = [
    (0, 0, 8, 4), (8, 4, 0, 0),
    (0, 0, 4, 8), (4, 8, 0, 0),
    (0, 0, 8, -4), (8, -4, 0, 0),
    (0, 0, -8, 4), (-8, 4, 0, 0),
    (0, 0, -8, -4), (-8, -4, 0, 0),
    (0, 0, -4, 8), (-4, 8, 0, 0),
    (0, 0, 12, 6), (0, 0, 6, 12),
    (0, 0, 16, 4), (0, 0, 4, 16),
]

if __name__ == "__main__":
    print(f"DEFAULTZEROLINEBIAS = {DEFAULTZEROLINEBIAS} = {DEFAULTZEROLINEBIAS:#010b}")
    for x1, y1, x2, y2 in CASES:
        points = zero_line(x1, y1, x2, y2)
        flat = ", ".join(f"{x},{y}" for x, y in points)
        print(f"({x1},{y1})->({x2},{y2}): {flat}")
