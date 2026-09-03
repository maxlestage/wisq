#!/usr/bin/env python3
"""Fabrique le verdict du **vrai processeur** sur l'arithmétique x86-64.

La tranche 3 du lot 7 fait exécuter des instructions ; la seule référence qui
vaille pour ça n'est ni un document ni un autre émulateur, c'est le processeur.
Ce script assemble des instructions, les fait exécuter par le harnais de
`scripts/x86-oracle/` avec des états d'entrée choisis, et écrit ce que la
machine a répondu dans `Tests/Fixtures/x86-oracle.tsv`.

    scripts/build-x86-oracle.py Tests/Fixtures/x86-oracle.tsv

**La division a ses propres états.** Une division par zéro ou dont le quotient
déborde lève une exception, et le harnais mourrait au lieu de répondre. Plutôt
que d'écarter la division — ce qui laisserait le seul endroit du cœur qui
*refuse* sans aucune preuve — ce script calcule d'avance, pour chaque cas, si
le processeur lèverait, et n'envoie que ceux qui aboutissent. Les deux refus,
eux, sont tenus par des tests écrits à la main dans `X86CoreTests`.

**Ce que le fichier porte.** Seuls RAX, RCX, RDX et les drapeaux varient : les
instructions à l'essai ne touchent à rien d'autre, et ce script le **vérifie**
avant d'écrire — les douze autres registres partent d'une valeur reconnaissable
et doivent revenir identiques. RSP est écarté : le harnais lui donne une pile
propre pour que l'instruction à l'essai ne puisse pas l'écraser, donc sa valeur
change d'une exécution à l'autre.

**Les drapeaux sont réduits aux six de l'arithmétique** (CF, PF, AF, ZF, SF,
OF). Le reste — IF, les bits réservés — appartient au harnais, pas à
l'instruction.

**Là où le manuel dit « indéfini », ce fichier ne dit rien.** Après un MUL,
après un décalage de plusieurs bits, après un BSF, certains drapeaux n'ont
aucune valeur garantie par l'architecture. Le processeur en pose une quand
même — et la première version de ce script la figeait. C'était une faute :
elle aurait fait de ce fichier le portrait d'**une** machine, celle qui l'a
produit, et un cœur qui s'y conformerait serait faux sur un autre processeur
tout aussi conforme. Chaque instruction porte donc un **masque** des drapeaux
que l'architecture définit pour elle, et seuls ceux-là sont comparés.

« Non affecté » n'est pas « indéfini » : un drapeau qu'une instruction laisse
tranquille a une valeur parfaitement prévisible — celle d'avant — et reste
donc dans le masque. C'est ce qui permet de vérifier que `ROL` ne touche pas au
zéro, ou qu'`INC` ne touche pas à la retenue.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# L'ordre de l'encodage, qui est aussi celui du fichier d'état.
REGISTERS = [
    "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
]

# Les valeurs qui font basculer quelque chose : zéro, un, les bornes de signe
# à chaque largeur, tout à un, et deux motifs quelconques pour que la parité et
# la retenue auxiliaire aient de quoi varier.
VALUES = [
    0x0000000000000000,
    0x0000000000000001,
    0x000000000000007F,
    0x0000000000000080,
    0x00000000000000FF,
    0x0000000000007FFF,
    0x0000000000008000,
    0x000000000000FFFF,
    0x000000007FFFFFFF,
    0x0000000080000000,
    0x00000000FFFFFFFF,
    0x7FFFFFFFFFFFFFFF,
    0x8000000000000000,
    0xFFFFFFFFFFFFFFFF,
    0x0123456789ABCDEF,
    0xF0F0F0F0F0F0F0F0,
]

# Les drapeaux d'entrée : rien, puis la retenue seule — ADC, SBB, RCL et RCR en
# dépendent, et un cœur qui l'ignorerait passerait tous les autres cas.
IN_FLAGS = [0x002, 0x003]

# Les six drapeaux de l'arithmétique : CF, PF, AF, ZF, SF, OF.
CF, PF, AF, ZF, SF, OF = 0x001, 0x004, 0x010, 0x040, 0x080, 0x800
ARITHMETIC_FLAGS = CF | PF | AF | ZF | SF | OF


def defined_flags(text):
    """Les drapeaux que l'architecture garantit pour cette instruction.

    Tout ce qui n'est pas là-dedans, le manuel le dit indéfini : le processeur
    y pose bien quelque chose, mais un autre processeur aurait le droit d'y
    poser autre chose."""
    name = text.split()[0]
    # Le suffixe de largeur est **un** caractère, pas un ensemble : `rstrip`
    # ferait de « mulb » un « mu » et de « rclq » un « rc », et aucune règle
    # ci-dessous ne s'appliquerait plus. La faute a existé, et elle était
    # silencieuse — le fichier gardait simplement tous les drapeaux.
    root = name[:-1] if len(name) > 2 and name[-1] in "bwlq" else name

    # MUL et IMUL : seuls la retenue et le débordement disent quelque chose, et
    # ils disent la même chose — « le résultat ne tenait pas ».
    if root in ("mul", "imul"):
        return CF | OF
    # BSF et BSR : seul le zéro est défini, et il parle de la *source*.
    if root in ("bsf", "bsr"):
        return ZF
    # DIV et IDIV : les six drapeaux sont indéfinis. Seuls le quotient et le
    # reste sont prouvés — ce qui est tout ce qui compte.
    if root in ("div", "idiv"):
        return 0
    # Les bits : seule la retenue, qui porte le bit lu.
    if root in ("bt", "bts", "btr", "btc"):
        return CF
    # ET, OU, OU exclusif : la retenue auxiliaire est indéfinie.
    if root in ("and", "or", "xor", "test"):
        return ARITHMETIC_FLAGS & ~AF
    # Décalages : la retenue auxiliaire est toujours indéfinie, et le
    # débordement ne l'est pas seulement quand le compte vaut un — ce qui n'est
    # sûr que dans la forme littérale « $1 ».
    if root in ("shl", "shr", "sar", "sal", "shld", "shrd"):
        kept = ARITHMETIC_FLAGS & ~AF
        return kept if " $1," in text else kept & ~OF
    # Rotations : elles ne touchent qu'à la retenue et au débordement, donc les
    # quatre autres sont « non affectés », ce qui se vérifie. Le débordement,
    # lui, n'est défini que pour un compte de un.
    if root in ("rol", "ror", "rcl", "rcr"):
        kept = ARITHMETIC_FLAGS
        return kept if (" $1," in text or "," not in text) else kept & ~OF
    return ARITHMETIC_FLAGS

# Les instructions à l'essai. Deux registres suffisent à couvrir la sémantique :
# l'identité du registre ne change rien à ce que l'opération calcule, et les
# encodages sont déjà tenus par le différentiel de la tranche 2.
def snippets():
    binary = ["add", "or", "adc", "sbb", "and", "sub", "xor", "cmp"]
    for op in binary:
        # Les quatre largeurs, registre à registre.
        yield f"{op}b %cl, %al"
        yield f"{op}w %cx, %ax"
        yield f"{op}l %ecx, %eax"
        yield f"{op}q %rcx, %rax"
        # L'autre sens de l'opcode, qui n'est pas symétrique pour sub et cmp.
        yield f"{op}q %rax, %rcx"
        # Immédiat large, et immédiat d'un octet étendu au signe.
        yield f"{op}q $0x12345678, %rax"
        yield f"{op}q $-1, %rax"
        yield f"{op}l $0x12345678, %eax"
        yield f"{op}w $0x1234, %ax"
        yield f"{op}b $0x12, %al"

    for op in ["inc", "dec", "neg", "not"]:
        for suffix, register in [("b", "%al"), ("w", "%ax"), ("l", "%eax"), ("q", "%rax")]:
            yield f"{op}{suffix} {register}"

    yield "testq %rcx, %rax"
    yield "testl %ecx, %eax"
    yield "testb %cl, %al"
    yield "testq $0x12345678, %rax"

    # Multiplication : les deux moitiés du résultat, et les trois formes
    # d'IMUL, dont les drapeaux ne disent pas la même chose que ceux d'ADD.
    for suffix in ["b", "w", "l", "q"]:
        yield f"mul{suffix} %{'cl' if suffix == 'b' else ('cx' if suffix == 'w' else ('ecx' if suffix == 'l' else 'rcx'))}"
        yield f"imul{suffix} %{'cl' if suffix == 'b' else ('cx' if suffix == 'w' else ('ecx' if suffix == 'l' else 'rcx'))}"
    yield "imulq %rcx, %rax"
    yield "imull %ecx, %eax"
    yield "imulq $0x12345678, %rcx, %rax"
    yield "imulq $0x12, %rcx, %rax"

    # Décalages et rotations. Par un, par CL, par un immédiat — les trois
    # encodages ne posent pas les drapeaux de la même façon.
    for op in ["shl", "shr", "sar", "rol", "ror", "rcl", "rcr"]:
        for suffix, register in [("b", "%al"), ("w", "%ax"), ("l", "%eax"), ("q", "%rax")]:
            yield f"{op}{suffix} {register}"
            yield f"{op}{suffix} %cl, {register}"
            yield f"{op}{suffix} $1, {register}"
            yield f"{op}{suffix} $7, {register}"
            yield f"{op}{suffix} $31, {register}"

    # Décalages à double précision : leur compte vient d'ailleurs.
    yield "shldq $7, %rcx, %rax"
    yield "shrdq $7, %rcx, %rax"
    yield "shldl %cl, %ecx, %eax"

    # Mouvements et extensions. Le zéro-remplissage d'une écriture 32 bits est
    # la règle que tout le monde oublie, et elle se voit ici.
    yield "movq %rcx, %rax"
    yield "movl %ecx, %eax"
    yield "movw %cx, %ax"
    yield "movb %cl, %al"
    yield "movzbq %cl, %rax"
    yield "movzwq %cx, %rax"
    yield "movzbl %cl, %eax"
    yield "movsbq %cl, %rax"
    yield "movswq %cx, %rax"
    yield "movslq %ecx, %rax"
    yield "movsbl %cl, %eax"
    yield "xchgq %rcx, %rax"
    yield "xchgl %ecx, %eax"
    yield "leaq 8(%rcx), %rax"
    yield "leaq (%rcx,%rdx,4), %rax"

    # L'extension du signe dans DX, qui ne ressemble à rien d'autre.
    yield "cwtl"
    yield "cltq"
    yield "cqto"
    yield "cltd"
    yield "cwtd"

    # Les seize conditions, dans les deux instructions qui les lisent.
    conditions = ["o", "no", "b", "ae", "e", "ne", "be", "a",
                  "s", "ns", "p", "np", "l", "ge", "le", "g"]
    for condition in conditions:
        yield f"set{condition} %al"
        yield f"cmov{condition}q %rcx, %rax"

    # Bits : lus, posés, effacés, inversés, et cherchés.
    for op in ["bt", "bts", "btr", "btc"]:
        yield f"{op}q $7, %rax"
        yield f"{op}q %rcx, %rax"
    yield "bsfq %rcx, %rax"
    yield "bsrq %rcx, %rax"
    yield "bsfl %ecx, %eax"
    yield "popcntq %rcx, %rax"

    # Les octets **hauts** : sans REX, les index 4 à 7 désignent AH, CH, DH et
    # BH plutôt que SPL, BPL, SIL et DIL. Le même champ de trois bits nomme deux
    # choses selon un octet qui se trouve ailleurs dans l'instruction, et rien
    # d'autre dans cette liste n'y touche.
    yield "addb %ch, %ah"
    yield "subb %ah, %ch"
    yield "movb %ch, %ah"
    yield "incb %ah"
    yield "xorb %ah, %al"
    yield "cmpb %ah, %ch"

    # Les drapeaux eux-mêmes.
    yield "clc"
    yield "stc"
    yield "cmc"


# Les divisions, avec la largeur et le signe qu'il faut connaître pour savoir
# d'avance si le processeur lèverait une exception.
DIVISIONS = [
    ("divb %cl", 1, False), ("divw %cx", 2, False),
    ("divl %ecx", 4, False), ("divq %rcx", 8, False),
    ("idivb %cl", 1, True), ("idivw %cx", 2, True),
    ("idivl %ecx", 4, True), ("idivq %rcx", 8, True),
]

# Des dividendes et des diviseurs qui touchent les bords sans les franchir.
DIVIDENDS = [0, 1, 7, 0x7F, 0x80, 0xFF, 0x1234, 0x7FFF_FFFF,
             0x8000_0000, 0x0123_4567_89AB_CDEF, 0xFFFF_FFFF_FFFF_FFFF]
DIVISORS = [1, 2, 3, 7, 0x10, 0x7F, 0x80, 0xFF, 0xFFFF, 0xFFFF_FFFF]

# Les adresses fixes du harnais. Fixes exprès : une adresse rendue par mmap
# changerait à chaque exécution, et le fichier ne se reproduirait pas.
DATA = 0x30001000
STACK = 0x30003000
WINDOW = 64
# Le motif dont la fenêtre part : 0x10, 0x11, 0x12… Reconnaissable exprès.
PRISTINE = "".join("%02x" % (0x10 + i) for i in range(WINDOW))

# Des **programmes**, pas des instructions isolées. Un branchement, une pile,
# un appel ne se prouvent pas sur une instruction seule : il faut plusieurs
# instructions et regarder où on atterrit. Le harnais exécute tout ce qu'on lui
# donne jusqu'au saut de retour qu'il ajoute derrière.
PROGRAMS = [
    ("une boucle qui additionne", [
        "xorl %eax, %eax", "movl $10, %ecx",
        "1: addq %rcx, %rax", "loop 1b"]),
    ("un saut conditionnel court, pris", [
        "movq $1, %rdx", "cmpq %rcx, %rax", "jne 1f", "movq $2, %rdx", "1: incq %rdx"]),
    ("un saut conditionnel long", [
        "cmpq %rcx, %rax", "jne 1f", "movq $7, %rdx", ".fill 200, 1, 0x90", "1: incq %rdx"]),
    ("un appel et son retour", [
        "call 1f", "jmp 2f", "1: movq $0x42, %rdx", "ret", "2: incq %rdx"]),
    ("empiler puis dépiler dans l'autre ordre", [
        "pushq %rax", "pushq %rcx", "popq %rdx", "popq %rcx"]),
    ("écrire puis relire la mémoire", [
        "movq %rax, (%rsi)", "movq %rcx, 8(%rsi)", "movq (%rsi), %rdx",
        "addq 8(%rsi), %rdx"]),
    ("les largeurs en mémoire", [
        "movb %al, (%rsi)", "movw %cx, 2(%rsi)", "movl %eax, 4(%rsi)",
        "movzbq (%rsi), %rdx", "movswq 2(%rsi), %rcx"]),
    ("un cadre de pile complet", [
        "pushq %rbp", "movq %rsp, %rbp", "subq $16, %rsp",
        "movq %rax, -8(%rbp)", "movq -8(%rbp), %rdx", "leave"]),
    ("une adresse à échelle", [
        "andq $3, %rcx", "movq %rax, (%rsi,%rcx,8)", "leaq (%rsi,%rcx,4), %rdx"]),
    ("lire, modifier, réécrire au même endroit", [
        "addq %rax, (%rsi)", "xorq %rcx, 8(%rsi)", "incq 16(%rsi)"]),
    ("un saut indirect par registre", [
        "leaq 1f(%rip), %rdx", "jmp *%rdx", "movq $0, %rax", "1: incq %rdx"]),
    ("une boucle qui parcourt la mémoire", [
        "movl $4, %ecx", "xorq %rdx, %rdx",
        "1: addq (%rsi), %rdx", "addq $8, %rsi", "decl %ecx", "jnz 1b"]),
]


def division_state(dividend, divisor, size, signed):
    """L'état d'entrée d'une division, ou None si le processeur lèverait.

    Le dividende occupe deux registres ; on met le haut à zéro — ou au signe du
    bas quand la division est signée — pour que le quotient tienne toujours.
    Reste à écarter le diviseur nul et le seul débordement possible."""
    mask = (1 << (8 * size)) - 1
    low = dividend & mask
    if divisor & mask == 0:
        return None
    if signed:
        negative = low & (1 << (8 * size - 1))
        high = mask if negative else 0
        value = low - (1 << (8 * size)) if negative else low
        by = divisor & mask
        by = by - (1 << (8 * size)) if by & (1 << (8 * size - 1)) else by
        if by == 0:
            return None
        quotient = int(value / by) if value * by < 0 else value // by
        limit = 1 << (8 * size - 1)
        if quotient < -limit or quotient > limit - 1:
            return None
    else:
        high = 0
        if low // (divisor & mask) > mask:
            return None
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    # Pour une division d'un octet, le haut du dividende est AH : il vit dans
    # RAX, pas dans RDX.
    if size == 1:
        fixed[0] = (high & 0xFF) << 8 | low
        fixed[2] = 0
    else:
        fixed[0] = low
        fixed[2] = high
    fixed[1] = divisor & mask
    return fixed + [0x002]


def assemble(texts):
    """Les octets de chaque instruction, par l'assembleur puis objdump.

    Assembler d'un coup et redécouper est plus sûr que de faire confiance à une
    table : c'est `as` qui choisit l'encodage, et `objdump` qui le relit.
    """
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "cases.s"
        obj = Path(directory) / "cases.o"
        with open(source, "w") as out:
            out.write(".text\n")
            for text in texts:
                out.write(f"    {text}\n")
        subprocess.run(["as", "--64", "-o", str(obj), str(source)], check=True)
        listing = subprocess.run(
            ["objdump", "-d", str(obj)], capture_output=True, text=True, check=True).stdout

    line = re.compile(r"^\s*[0-9a-f]+:\t([0-9a-f]{2}(?: [0-9a-f]{2})*) *\t(.*)$")
    encoded = []
    for row in listing.splitlines():
        match = line.match(row)
        if match:
            encoded.append("".join(match.group(1).split()))
    if len(encoded) != len(texts):
        raise SystemExit(f"{len(texts)} instructions demandées, {len(encoded)} relues")
    return encoded


def assemble_program(lines):
    """Les octets d'un programme entier, d'un bloc — les étiquettes locales
    d'un saut n'ont de sens que si tout est assemblé ensemble."""
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "p.s"
        obj = Path(directory) / "p.o"
        binary = Path(directory) / "p.bin"
        with open(source, "w") as out:
            out.write(".text\n" + "".join(f"    {line}\n" for line in lines))
        subprocess.run(["as", "--64", "-o", str(obj), str(source)], check=True)
        subprocess.run(["objcopy", "-O", "binary", "-j", ".text",
                        str(obj), str(binary)], check=True)
        return open(binary, "rb").read().hex()


def states():
    """Les états d'entrée : un **étalement**, pas un début de produit cartésien.

    La première version prenait les premiers états du produit croisé, et les
    vingt-quatre premiers avaient tous RAX à zéro : le fichier n'aurait éprouvé
    que la moitié de chaque opération. Ici chaque valeur de la liste passe une
    fois par RAX, appariée à une autre, et les deux états de retenue alternent.

    Le reste des registres part d'une valeur reconnaissable et n'est pas censé
    bouger — c'est ce que le script vérifie avant d'écrire."""
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    count = len(VALUES)
    pairs = [(i, count - 1 - i) for i in range(count)]
    pairs += [(i, (i * 5 + 2) % count) for i in range(0, count, 2)]
    for index, (first, second) in enumerate(pairs):
        state = list(fixed)
        state[0] = VALUES[first]   # rax
        state[1] = VALUES[second]  # rcx
        state[2] = VALUES[second]  # rdx, pour cqto et les décalages doubles
        state[6] = DATA            # rsi pointe la fenêtre de données
        yield state + [IN_FLAGS[index % len(IN_FLAGS)]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output")
    parser.add_argument("--oracle", default="scripts/x86-oracle/oracle")
    parser.add_argument("--per-instruction", type=int, default=24,
                        help="combien d'états par instruction (les premiers de la liste)")
    arguments = parser.parse_args()

    texts = list(snippets())
    encoded = assemble(texts)
    chosen = [state for _, state in zip(range(arguments.per_instruction), states())]

    cases = []
    for instruction, hexadecimal in enumerate(encoded):
        for index, state in enumerate(chosen):
            cases.append((instruction, hexadecimal, index, state))

    # Les divisions viennent après, avec leurs propres états — et seulement ceux
    # dont on a calculé qu'ils n'allaient pas lever.
    divisionTexts = [text for text, _, _ in DIVISIONS]
    divisionEncoded = assemble(divisionTexts)
    for offset, ((text, size, signed), hexadecimal) in enumerate(
            zip(DIVISIONS, divisionEncoded)):
        instruction = len(texts) + offset
        for dividend in DIVIDENDS:
            for divisor in DIVISORS:
                state = division_state(dividend, divisor, size, signed)
                if state is None:
                    continue
                index = len(chosen)
                chosen.append(state)
                cases.append((instruction, hexadecimal, index, state))
    texts = texts + divisionTexts
    encoded = encoded + divisionEncoded

    # Les programmes : mêmes états que le reste, mais plusieurs instructions.
    for name, lines in PROGRAMS:
        hexadecimal = assemble_program(lines)
        instruction = len(texts)
        texts.append(name)
        encoded.append(hexadecimal)
        for index, state in enumerate(chosen[:24]):
            cases.append((instruction, hexadecimal, index, state))

    request = "".join(
        hexadecimal + "\t" + "\t".join(f"{value:x}" for value in state) + "\n"
        for _, hexadecimal, _, state in cases)
    answer = subprocess.run([arguments.oracle], input=request, capture_output=True,
                            text=True, check=True).stdout.splitlines()
    if len(answer) != len(cases):
        raise SystemExit(f"{len(cases)} cas envoyés, {len(answer)} verdicts reçus")

    with open(arguments.output, "w") as out:
        out.write("# Ce que le vrai processeur répond. Voir scripts/build-x86-oracle.py.\n")
        out.write("# état\t<indice>\t<rax>\t<rcx>\t<rdx>\t<drapeaux>   — un état d'entrée\n")
        out.write("# instr\t<indice>\t<octets>\t<masque>\t<mnémonique>  — une instruction,\n")
        out.write("#   et le masque des drapeaux que l'architecture définit pour elle\n")
        out.write("# cas\t<instr>\t<état>\t<rax>\t<rcx>\t<rdx>\t<drapeaux>\t<mémoire>\n")
        out.write("#   la mémoire est la fenêtre de 64 octets à 0x30001000, où pointe RSI ;\n")
        out.write("#   la pile de l'invité descend depuis 0x30003000\n")
        for index, state in enumerate(chosen):
            out.write("état\t%d\t%x\t%x\t%x\t%x\n"
                      % (index, state[0], state[1], state[2], state[16] & ARITHMETIC_FLAGS))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            out.write("instr\t%d\t%s\t%x\t%s\n"
                      % (index, hexadecimal, defined_flags(text), text))
        for (instruction, _, index, state), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            after = [int(value, 16) for value in fields[18:]]
            # Ce qui n'était pas censé bouger n'a pas bougé : la vérification
            # qui autorise à ne garder que trois registres dans le fichier.
            # RBP et RSP sont exclus : les programmes qui posent un cadre de
            # pile s'en servent, et c'est justement ce qu'ils prouvent.
            for register in [3] + list(range(8, 16)):
                if after[register] != state[register]:
                    raise SystemExit(
                        f"{texts[instruction]} a écrit dans {REGISTERS[register]} : "
                        f"{state[register]:x} devenu {after[register]:x}")
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%s\n"
                      % (instruction, index,
                         after[0], after[1], after[2], after[16] & ARITHMETIC_FLAGS,
                         # « - » quand la fenêtre est restée telle qu'on l'avait
                         # posée : la plupart des instructions ne touchent pas à
                         # la mémoire, et écrire cent vingt-huit caractères pour
                         # dire « rien » quadruplerait le fichier.
                         "-" if fields[35] == PRISTINE else fields[35]))

    print(f"{len(texts)} instructions, {len(cases)} cas", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
