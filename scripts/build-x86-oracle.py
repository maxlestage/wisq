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

# Les drapeaux d'entrée. Les deux premiers : rien, puis la retenue seule — ADC,
# SBB, RCL et RCR en dépendent, et un cœur qui l'ignorerait passerait tous les
# autres cas.
#
# **Les deux suivants existent parce que les deux premiers ne pouvaient pas
# juger une préservation.** PF, AF, ZF et SF valaient zéro à l'entrée de chaque
# cas du corpus. Or `not`, `mov`, `movzx`, `movsx` et les rotations déclarent
# les préserver, et un décalage de compte nul aussi : un cœur qui les remettait
# tous à zéro rendait exactement la même chose qu'un cœur qui les gardait. Un
# sabotage l'a montré — écraser les quatre ne faisait tomber aucun cas.
# Maintenant ils entrent à un, avec et sans retenue, et la préservation se
# vérifie comme le reste : contre le silicium.
IN_FLAGS = [0x002, 0x003, 0x8D6, 0x8D7]

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
    # Les bits : la retenue porte le bit lu, et le **zéro n'est pas touché**.
    # Le manuel le dit explicitement, contrairement aux quatre autres qu'il
    # laisse indéfinis — et depuis que les états d'entrée portent ZF à un, cette
    # préservation-là se vérifie. Elle ne se vérifiait pas avant, et un sabotage
    # qui écrasait les cinq autres drapeaux ne faisait donc tomber aucun cas.
    if root in ("bt", "bts", "btr", "btc"):
        return CF | ZF
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


# Les instructions qui ne touchent à **aucun** drapeau arithmétique. Elles ne
# comptent donc pas pour dire ce qu'un programme définit en sortie.
NO_FLAGS = (
    "mov", "movb", "movw", "movl", "movq",
    "movzbl", "movzbq", "movzwq", "movswq", "movslq", "movsbl", "movsbq",
    "lea", "leab", "leaw", "leal", "leaq",
    "push", "pushq", "pop", "popq", "leave", "nop",
    "jmp", "call", "ret", "loop",
    "je", "jne", "jz", "jnz", "jg", "jge", "jl", "jle", "ja", "jae", "jb",
    "jbe", "js", "jns", "jo", "jno", "jp", "jnp",
    # `setcc` et `cmovcc` **lisent** les drapeaux et n'en écrivent aucun. Le
    # dire ici évite de reprocher plus tard à un cœur les drapeaux d'une
    # instruction qui n'y touche pas : le programme « un tableau de bits »
    # finit sur `setc`, et ce qu'il définit vient du `btq` d'avant, où seule la
    # retenue est définie.
    "seta", "setae", "setb", "setbe", "sete", "setg", "setge", "setl",
    "setle", "setne", "setno", "setnp", "setns", "seto", "setp", "sets",
    "setc", "setnc", "setz", "setnz",
    "cmova", "cmovae", "cmovb", "cmovbe", "cmove", "cmovg", "cmovge",
    "cmovl", "cmovle", "cmovne", "cmovno", "cmovnp", "cmovns", "cmovo",
    "cmovp", "cmovs",
    "cmovaq", "cmovaeq", "cmovbq", "cmovbeq", "cmoveq", "cmovgq", "cmovgeq",
    "cmovlq", "cmovleq", "cmovneq", "cmovnoq", "cmovnpq", "cmovnsq",
    "cmovoq", "cmovpq", "cmovsq",
    "bswap", "bswapl", "bswapq", "xchg", "xchgl", "xchgq",
)


def program_defined_flags(lines):
    """Ce qu'un **programme** définit en sortie : ce que définit sa dernière
    instruction à drapeaux.

    Sans ça le masque tombait dans le cas par défaut — « les six » — parce que
    le premier mot d'un nom français n'est aucun mnémonique connu. Le programme
    « une adresse à échelle » finit sur un `andq`, qui laisse la demi-retenue
    **indéfinie** : le corpus la comparait quand même, et le premier cœur à
    savoir décoder ces instructions se faisait reprocher un bit que le manuel
    n'accorde à personne. Ça ne s'était pas vu parce que tous les programmes
    étaient refusés, faute d'opérande mémoire."""
    for line in reversed(lines):
        text = line.strip()
        # Une étiquette locale colle à l'instruction : « 1: incq %rdx ».
        if ":" in text.split(" ")[0]:
            text = text.split(":", 1)[1].strip()
        if not text or text.startswith("."):
            continue
        if text.split()[0] in NO_FLAGS:
            continue
        return defined_flags(text)
    # Aucune instruction à drapeaux : ils traversent le programme intacts, et
    # les six se comparent donc légitimement.
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
    # **La forme que le corpus n'avait pas : le compte variable en soixante-
    # quatre bits.** C'est celle qu'un noyau emploie, et c'est la seule où la
    # règle « un compte nul ne décale rien » s'observe. En trente-deux bits le
    # terme complémentaire vaut un décalage de trente-deux, que la source
    # masquée rend nul de toute façon ; en soixante-quatre il vaut soixante-
    # quatre, que WebAssembly ramène à zéro — et le résultat serait la source
    # ajoutée à la destination. Un sabotage l'a montré : retirer la garde du
    # compte nul ne faisait tomber aucun cas.
    yield "shldq %cl, %rcx, %rax"
    yield "shrdq %cl, %rcx, %rax"
    yield "shrdl %cl, %ecx, %eax"
    # Pas de forme à compte variable en seize bits : le compte y est masqué à
    # trente et un, donc il peut dépasser la largeur, et le manuel déclare le
    # résultat **indéfini** dans ce cas. Le relever le figerait sur ce
    # processeur-ci.
    yield "shrdw $3, %cx, %ax"

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
    # Les deux primitives dont toutes les serrures d'un noyau sont faites.
    # L'ordre AT&T est « source, destination » : la destination est l'opérande
    # r/m, et l'accumulateur est le troisième opérande implicite de CMPXCHG.
    for suffix, source, destination in [
        ("q", "%rcx", "%rdx"), ("l", "%ecx", "%edx"),
        ("w", "%cx", "%dx"), ("b", "%cl", "%dl"),
    ]:
        yield f"cmpxchg{suffix} {source}, {destination}"
        yield f"xadd{suffix} {source}, {destination}"

    for register in ["%rax", "%rcx", "%rdx"]:
        yield f"bswapq {register}"
    for register in ["%eax", "%ecx", "%edx"]:
        yield f"bswapl {register}"

    yield "xchgq %rcx, %rax"
    yield "xchgl %ecx, %eax"
    # **`lea` est le banc d'essai du calcul d'adresse**, et le seul possible
    # sans mémoire : elle rend l'adresse au lieu d'y toucher. Deux formes n'en
    # éprouvaient qu'une fraction — un déplacement positif d'un octet et une
    # échelle de quatre. Les suivantes couvrent le reste du codage : les quatre
    # échelles, un déplacement négatif, un déplacement de quatre octets, le SIB
    # sans base, un index qui demande REX.X, et une destination de 32 bits qui
    # doit effacer la moitié haute.
    yield "leaq 8(%rcx), %rax"
    yield "leaq (%rcx,%rdx,4), %rax"
    yield "leaq -8(%rcx), %rax"
    yield "leaq -1(%rdx), %rax"
    yield "leaq 0x12345678(%rcx), %rax"
    yield "leaq -0x12345678(%rdx), %rax"
    yield "leaq (%rcx,%rdx,1), %rax"
    yield "leaq (%rcx,%rdx,2), %rax"
    yield "leaq (%rcx,%rdx,8), %rax"
    yield "leaq 16(%rcx,%rdx,8), %rax"
    yield "leaq -16(%rdx,%rcx,2), %rax"
    # Pas de base : le SIB le dit par « base 101 » avec mod nul, et un
    # déplacement de quatre octets suit obligatoirement.
    yield "leaq (,%rcx,8), %rax"
    yield "leaq 32(,%rdx,4), %rax"
    # Un index au-delà du huitième registre : c'est REX.X qui le dit, et c'est
    # le même champ qui, à quatre et sans REX.X, veut dire « aucun index ».
    yield "leaq (%rcx,%r12,8), %rax"
    yield "leaq (%r13,%rdx,2), %rax"
    # Une base qui est justement le registre dont le numéro annonce un SIB.
    yield "leaq 8(%rsp), %rax"
    yield "leaq 8(%rbp), %rax"
    # Destination de 32 bits : l'adresse est calculée sur soixante-quatre bits
    # puis **tronquée**, et l'écriture efface la moitié haute.
    yield "leal 8(%rcx), %eax"
    yield "leal (%rcx,%rdx,4), %eax"
    # Et la largeur de mot, qui n'est pas une curiosité : c'est la seule où
    # l'écriture **fusionne** au lieu d'effacer, et un sabotage a montré que
    # rien ne la tenait.
    yield "leaw 8(%rcx), %ax"

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

    # **Les largeurs de `cmov`, et la règle qui ne se voit qu'à trente-deux.**
    #
    # En soixante-quatre bits, « ne pas écrire » et « réécrire l'ancienne
    # valeur » rendent la même chose : rien ne les distingue, et un sabotage
    # l'a montré — un cœur qui sortait sans écrire passait tous les cas. En
    # trente-deux bits, l'écriture a lieu **même quand le déplacement n'a pas
    # lieu**, et elle efface la moitié haute ; en seize, elle a lieu aussi et
    # ne l'efface pas. Deux conditions suffisent, à condition d'en prendre une
    # qui tient et une qui ne tient pas dans les mêmes états.
    for condition in ["e", "ne"]:
        yield f"cmov{condition}l %ecx, %eax"
        yield f"cmov{condition}w %cx, %ax"

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

    # Et les mêmes octets hauts **lus par une instruction plus large qu'eux**.
    # C'est le trou par lequel un vrai noyau est passé : une instruction peut
    # avoir deux largeurs — MOVZX et MOVSX lisent un octet et écrivent quatre
    # ou huit — et un cœur qui décide « octet haut » avec la largeur du
    # destinataire lit le mauvais registre. `movzbl %ch,%edi` rendait BPL.
    # Aucune des lignes ci-dessus ne l'attrapait, parce que toutes ont leurs
    # deux opérandes de la même largeur.
    #
    # Pas de destination de soixante-quatre bits ici : elle demanderait REX.W,
    # et REX est justement ce qui change AH en SPL. `movzbq %ah, %rax` n'est
    # pas encodable, et l'assembleur le refuse — ce qui est la meilleure preuve
    # que les deux noms ne peuvent pas coexister dans une instruction.
    for source in ["ah", "ch", "dh", "bh"]:
        for destination in ["eax", "ecx", "edx"]:
            yield f"movzbl %{source}, %{destination}"
            yield f"movsbl %{source}, %{destination}"

    # **La mémoire, une instruction à la fois.** RSI pointe la fenêtre de
    # soixante-quatre octets, dont le motif — 0x10, 0x11, 0x12… — est
    # reconnaissable : une lecture au mauvais décalage se voit à l'œil nu.
    # Tous les déplacements restent dans la fenêtre, largeur comprise.
    #
    # Jusqu'ici le décodeur refusait **tout** opérande mémoire, et le corpus ne
    # le lui reprochait pas : aucune instruction isolée n'en portait. Les
    # quinze programmes en portent, mais ils demandent aussi des sauts, donc
    # leur refus avait une autre cause et couvrait celle-ci.
    for suffix, source, destination in [
            ("b", "%al", "%al"), ("w", "%ax", "%ax"),
            ("l", "%eax", "%eax"), ("q", "%rax", "%rax")]:
        yield f"mov{suffix} (%rsi), {destination}"
        yield f"mov{suffix} {source}, (%rsi)"
        yield f"mov{suffix} 8(%rsi), {destination}"
        yield f"mov{suffix} {source}, 8(%rsi)"
        # Lire et écrire au même endroit, avec les drapeaux au passage.
        yield f"add{suffix} (%rsi), {destination}"
        yield f"add{suffix} {source}, (%rsi)"
        yield f"sub{suffix} 4(%rsi), {destination}"
        yield f"xor{suffix} {source}, 4(%rsi)"
        yield f"cmp{suffix} (%rsi), {destination}"
    # Un opérande mémoire **seul** : le groupe 3 et les incréments.
    yield "notq (%rsi)"
    yield "negl 8(%rsi)"
    yield "incb 3(%rsi)"
    yield "decw 6(%rsi)"
    # **Le préfixe de verrouillage**, qu'un noyau met sur tout compteur
    # partagé. Il n'y a qu'un fil ici, donc il ne change rien à ce que
    # l'instruction calcule — mais le refuser rejetait chaque verrou du noyau,
    # et rien ne tenait le fait qu'il soit bien consommé. Un sabotage l'a
    # montré : ne pas avancer d'un octet après lui ne faisait tomber aucun cas.
    yield "lock incq (%rsi)"
    yield "lock addq %rax, 8(%rsi)"
    yield "lock xaddq %rcx, 16(%rsi)"
    yield "lock cmpxchgq %rcx, 24(%rsi)"
    # **`endbr64`.** La cible de branchement indirect que le processeur exige
    # quand la protection de flot est armée. Elle ne fait rien — et un noyau
    # moderne en pose une en tête de chaque fonction. Sans ce cas, rien ne
    # tenait sa longueur : un sabotage qui lui faisait manger un octet de trop
    # passait.
    yield "endbr64"
    # Un immédiat vers la mémoire, les deux formes du groupe 1.
    yield "addq $1, (%rsi)"
    yield "andl $0x12345678, 8(%rsi)"
    yield "orb $0x42, 2(%rsi)"
    yield "testq $0x12345678, (%rsi)"
    # Un décalage et une rotation dont la destination est en mémoire.
    yield "shlq $3, (%rsi)"
    yield "sarl %cl, 8(%rsi)"
    yield "rolw $7, 4(%rsi)"
    # Une extension depuis la mémoire : deux largeurs, dont une seule est lue.
    yield "movzbl (%rsi), %eax"
    yield "movsbl 1(%rsi), %eax"
    yield "movzwq 2(%rsi), %rax"
    yield "movslq 8(%rsi), %rax"
    # **Le préfixe de segment GS**, par où un noyau x86-64 atteint tout ce qui
    # est propre à un cœur : la tâche courante, la pile d'interruption, le
    # compteur de préemption. La forme est toujours la même — pas de base, pas
    # d'index, un déplacement — parce que c'est un décalage dans une structure
    # dont la base est dans un registre caché.
    #
    # L'oracle pose cette base sur la fenêtre de données par `arch_prctl`, donc
    # `%gs:0x10` désigne le même octet que `0x10(%rsi)`. Ce n'est pas une
    # coïncidence commode : c'est ce qui permet de juger le préfixe avec la
    # fenêtre que le corpus sait déjà lire.
    #
    # **FS n'est pas là**, et ne peut pas y être : c'est le segment des
    # variables de fil de la glibc, le canari de pile vit à `%fs:0x28`, et
    # déplacer sa base ferait planter le pilote avant qu'il ait jugé un seul
    # cas. Les deux cœurs refusent donc ce préfixe.
    yield "movq %gs:0x10, %rax"
    yield "movl %gs:0x8, %eax"
    yield "movb %gs:0x3, %al"
    yield "movq %rax, %gs:0x18"
    yield "movl %eax, %gs:0x20"
    yield "addq %gs:0x0, %rax"
    yield "subl %gs:0x4, %eax"
    yield "cmpq %gs:0x10, %rax"
    yield "addq %rax, %gs:0x28"
    yield "incq %gs:0x30"
    yield "andl $0x0F0F0F0F, %gs:0x8"
    yield "movzbl %gs:0x2, %eax"
    yield "movslq %gs:0x8, %rax"
    # **Les quatre segments que le mode 64 bits a vidés.** CS, SS, DS et ES ont
    # une base forcée à zéro : le préfixe se lit, se compte dans la longueur, et
    # ne change rien. Ce n'est pas une supposition confortable — c'est ce que le
    # silicium rend, et le corpus le grave en mettant le préfixe devant des
    # instructions dont il connaît déjà la réponse nue.
    #
    # Les refuser rejetait le NOP d'alignement du noyau : `66 2e 0f 1f 84 00 …`
    # apparaît dix-huit mille fois dans un noyau Alpine, et chaque occurrence
    # coupait une région en deux.
    #
    # **Deux syntaxes, parce que l'assembleur n'en accepte qu'une par
    # segment.** `%ss:` et `%es:` s'écrivent devant l'opérande — la forme
    # préfixe seule est refusée en 64 bits — tandis que `%ds:` est effacé par
    # l'assembleur, qui le tient pour le segment par défaut, et ne s'obtient
    # qu'en écrivant `ds` devant l'instruction.
    yield "movq %cs:8(%rsi), %rax"
    yield "movl %ss:4(%rsi), %eax"
    yield "ds addq (%rsi), %rax"
    yield "movb %es:3(%rsi), %al"
    yield "addq $1, %cs:(%rsi)"
    yield "ds incq (%rsi)"
    # Un préfixe de segment sur une instruction **sans** opérande mémoire : il
    # est légal, et le processeur ne s'en plaint pas.
    yield "cs addq %rcx, %rax"
    # **Le NOP d'alignement du noyau, dans les formes qu'il prend.** Le ModRM
    # entier compte dans la longueur ; un octet mal consommé décale tout ce qui
    # suit, et le corpus le voit parce que le programme continue après.
    yield "nopw %cs:0x0(%rax,%rax,1)"
    yield "nopl 0x0(%rax)"
    yield "nopw 0x0(%rax,%rax,1)"
    # **Le segment ET le pointeur d'instruction, ensemble.** Personne n'écrit
    # ça — un noyau atteint ses variables par cœur par un déplacement absolu —
    # mais les deux mécanismes se rencontrent dans le code des deux cœurs, et
    # sans ce cas rien ne dit lequel gagne. Un sabotage l'a montré : faire
    # perdre le segment au figeage de l'adresse relative ne faisait tomber
    # aucun test, et l'interpréteur, lui, sortait **avant** d'ajouter la base.
    # Les deux cœurs auraient divergé en silence sur la première occurrence.
    #
    # Le déplacement est calculé pour retomber dans la fenêtre : le processeur
    # ajoute la base du segment à une adresse déjà relative, donc l'adresse
    # nue vaut deux fois l'arène. Huit octets, c'est la longueur de
    # `65 48 8b 05 <disp32>`, mesurée sur l'assembleur et pas devinée.
    yield f"movq %gs:{0x10 - (CODE + 8)}(%rip), %rax"
    # **`lea` ignore le préfixe** : elle ne touche pas la mémoire, donc ne
    # traverse pas l'unité de segmentation. L'assembleur avertit que le préfixe
    # est sans effet ; le silicium le confirme, et c'est ce qu'on grave ici. Un
    # émetteur qui ajouterait la base rendrait une adresse décalée de 0x1000 —
    # plausible, et fausse.
    yield "leaq %gs:0x10, %rax"
    # Pas d'index à échelle ici : RCX et RDX prennent des valeurs qui sortent
    # de la fenêtre, et le corpus ne juge pas ce qu'il fait planter. Une base
    # et un déplacement suffisent à éprouver le chemin d'accès ; l'échelle est
    # déjà tenue par `lea`, qui la calcule sans y toucher.
    yield "movq 16(%rsi), %rax"
    yield "movq %rax, 16(%rsi)"

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

# **Les échanges, avec des états choisis.** `cmpxchg` a deux issues, et la
# différence entre les deux ne se voit qu'à une condition précise : que
# l'égalité tienne **et** que l'accumulateur porte des bits hors de la largeur.
# Le manuel dit qu'en cas de succès l'accumulateur n'est pas écrit ; le réécrire
# avec sa propre valeur serait indiscernable en huit et seize bits — qui
# préservent le reste du registre — et visible en trente-deux, qui l'effacent.
# Les états ordinaires ne mettent jamais RAX et RDX d'accord sur leur moitié
# basse, donc aucun d'eux ne pose la question. Un sabotage l'a montré : faire
# écrire l'accumulateur en cas de succès ne faisait tomber aucun cas.
EXCHANGES = [
    ("cmpxchgb %cl, %dl", 1), ("cmpxchgw %cx, %dx", 2),
    ("cmpxchgl %ecx, %edx", 4), ("cmpxchgq %rcx, %rdx", 8),
]


def exchange_state(size, matching):
    """L'état d'un `cmpxchg` : l'accumulateur et la destination égaux sur la
    largeur ou non, et RAX toujours porteur de bits au-delà."""
    mask = (1 << (8 * size)) - 1
    fixed = [0xAAAAAAAAAAAAAAAA + i for i in range(16)]
    fixed[6] = DATA
    low = 0xF0F0F0F0F0F0F0F0 & mask
    fixed[0] = 0x1234567890ABCDEF & ~mask | low
    fixed[2] = low if matching else (low ^ 1)
    fixed[1] = 0x0F0F0F0F0F0F0F0F
    return fixed + [0x002]


# Les adresses fixes du harnais. Fixes exprès : une adresse rendue par mmap
# changerait à chaque exécution, et le fichier ne se reproduirait pas.
CODE = 0x30000000
DATA = 0x30001000
STACK = 0x30003000
WINDOW = 64
# Le motif dont la fenêtre part : 0x10, 0x11, 0x12… Reconnaissable exprès.
PRISTINE = "".join("%02x" % (0x10 + i) for i in range(WINDOW))
# La pile, des deux côtés du sommet : soixante-quatre octets **sous** le
# pointeur — là où un `push` écrit — et soixante-quatre au-dessus. Motifs
# distincts pour que l'un ne puisse pas passer pour l'autre.
STACK_WINDOW = STACK - WINDOW
STACK_PRISTINE = ("".join("%02x" % (0xB0 + i) for i in range(WINDOW))
                  + "".join("%02x" % (0x40 + i) for i in range(WINDOW)))

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
    # **Les `nop` d'alignement, les deux formes.** Le remplissage des programmes
    # ci-dessous n'émet que la forme d'un octet ; celle à plusieurs octets — que
    # tout compilateur produit pour aligner une cible de saut sans perdre de
    # cycles — n'était exercée par rien. Un sabotage l'a montré : lui faire
    # consommer un octet de trop ne faisait tomber aucun cas.
    ("des nop d'alignement, courts et longs", [
        "incq %rdx", "nop", "nopl (%rax)", "nopw 0(%rax,%rax,1)",
        "nopl 0x12345678(%rax)", "incq %rdx"]),
    # **La branche que le corpus n'éprouvait pas.** Les états ne mettent jamais
    # RAX égal à RCX, donc le `jne` du programme précédent est *toujours* pris —
    # son nom le dit. Un sabotage l'a montré : oublier la suite d'un saut
    # conditionnel dans la découverte des blocs ne faisait tomber aucun cas,
    # parce que cette suite n'était jamais atteinte. `cmpq %rax, %rax` force
    # l'égalité, et l'autre branche existe enfin.
    ("un saut conditionnel court, non pris", [
        "movq $1, %rdx", "cmpq %rax, %rax", "jne 1f", "movq $2, %rdx", "1: incq %rdx"]),
    ("un saut conditionnel long, non pris", [
        "cmpq %rax, %rax", "jne 1f", "movq $7, %rdx", ".fill 200, 1, 0x90", "1: incq %rdx"]),
    ("un saut conditionnel long", [
        "cmpq %rcx, %rax", "jne 1f", "movq $7, %rdx", ".fill 200, 1, 0x90", "1: incq %rdx"]),
    # **Une fonction telle qu'un noyau les écrit.** `endbr64` en tête, et le
    # reste derrière. Seule dans un extrait, elle ne peut rien prouver : ne rien
    # faire sur quatre octets ou sur cinq laisse le même état, et le harnais
    # s'arrête au bout du tampon dans les deux cas. Il faut quelque chose
    # **après** elle pour que sa longueur compte — un sabotage l'a montré, qui
    # lui faisait manger un octet de trop sans faire tomber aucun cas. Avec ce
    # programme, l'octet de trop décale le `incq` d'après et le transforme en un
    # `inc` de trente-deux bits, qui efface la moitié haute de RDX.
    ("une fonction qui commence comme celles d'un noyau", [
        "endbr64", "incq %rdx", "endbr64", "addq %rax, %rdx"]),
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
    # Les chaînes de bits. C'est la forme que le manuel appelle « bit string » :
    # quand la destination est en mémoire, le numéro n'est **pas** réduit au
    # modulo, il est signé, et le processeur va chercher le mot qui contient ce
    # bit-là. Le noyau de Linux tient ses vecteurs d'interruption réservés dans
    # un tableau de 256 bits qu'il pose comme ça ; un cœur qui replie tous les
    # numéros dans le premier mot lui fait croire que l'horloge est déjà prise.
    ("un tableau de bits, au-delà du premier mot", [
        "andl $0x1ff, %ecx", "btsq %rcx, (%rsi)",
        "movq %rcx, %rdx", "addq $64, %rdx", "andl $0x1ff, %edx",
        "btrq %rdx, (%rsi)", "btq %rcx, (%rsi)", "setc %al"]),
    ("un tableau de bits, avec un numéro négatif", [
        "andl $0xff, %ecx", "subl $128, %ecx", "movslq %ecx, %rcx",
        "leaq 32(%rsi), %rax", "btsq %rcx, (%rax)", "btq %rcx, (%rax)", "setc %dl"]),
    ("un tableau de bits en trente-deux bits", [
        "andl $0xff, %ecx", "btsl %ecx, (%rsi)", "btcl %ecx, 4(%rsi)",
        "btl %ecx, (%rsi)", "setc %dl"]),
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
    # **RSI pointe la fenêtre de données, ici comme partout ailleurs.** Le
    # fichier ne porte que RAX, RCX et RDX par état, et affirme, par ses
    # enregistrements « fixe », que les treize autres valent la même chose pour
    # tous les cas. Les états de division l'ignoraient : ils laissaient RSI à
    # 0xAAAA…B0 pendant que les autres le mettaient à 0x30001000. Ça n'a jamais
    # compté tant que les divisions étaient refusées ; le premier cœur à savoir
    # les décoder s'est fait reprocher un RSI qu'il avait posé comme le fichier
    # le lui disait.
    fixed[6] = DATA
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
        # **`--insn-width` n'est pas du confort d'affichage.** Sans lui objdump
        # renvoie à la ligne au-delà de sept octets, et la continuation ne
        # porte pas de mnémonique : la regex ci-dessous ne la voit pas, et
        # l'instruction est **tronquée en silence**. Le compte d'instructions
        # reste juste, donc rien ne le signale. `leaq (,%rcx,8), %rax` fait
        # huit octets et arrivait sur sept — un ModRM suivi de trois octets de
        # déplacement au lieu de quatre, que le processeur a exécuté comme il
        # a pu, jusqu'à la faute de segmentation.
        listing = subprocess.run(
            ["objdump", "-d", "--insn-width=16", str(obj)],
            capture_output=True, text=True, check=True).stdout

    line = re.compile(r"^\s*[0-9a-f]+:\t([0-9a-f]{2}(?: [0-9a-f]{2})*) *\t(.*)$")
    encoded = []
    for row in listing.splitlines():
        match = line.match(row)
        if match:
            encoded.append("".join(match.group(1).split()))
    if len(encoded) != len(texts):
        raise SystemExit(f"{len(texts)} instructions demandées, {len(encoded)} relues")
    # Et la garde qui manquait : la somme des longueurs doit faire la taille de
    # la section. Une instruction tronquée passe le compte mais pas celle-ci.
    total = sum(len(item) // 2 for item in encoded)
    size = obj_size(listing)
    if size is not None and total != size:
        raise SystemExit(
            f"{total} octets relus pour une section de {size} : une "
            f"instruction a été tronquée à la relecture")
    return encoded


def obj_size(listing):
    """La fin de la dernière instruction, lue dans le désassemblage."""
    last = None
    for row in listing.splitlines():
        match = re.match(r"^\s*([0-9a-f]+):\t([0-9a-f]{2}(?: [0-9a-f]{2})*)", row)
        if match:
            last = int(match.group(1), 16) + len(match.group(2).split())
    return last


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

    # Les échanges, avec leurs deux issues et un accumulateur qui déborde de la
    # largeur — la seule façon de voir qu'un succès n'écrit pas l'accumulateur.
    exchangeTexts = [text for text, _ in EXCHANGES]
    exchangeEncoded = assemble(exchangeTexts)
    for offset, ((text, size), hexadecimal) in enumerate(
            zip(EXCHANGES, exchangeEncoded)):
        instruction = len(texts) + offset
        for matching in (True, False):
            state = exchange_state(size, matching)
            index = len(chosen)
            chosen.append(state)
            cases.append((instruction, hexadecimal, index, state))
    texts = texts + exchangeTexts
    encoded = encoded + exchangeEncoded

    # Les programmes : mêmes états que le reste, mais plusieurs instructions.
    program_masks = {}
    for name, lines in PROGRAMS:
        hexadecimal = assemble_program(lines)
        instruction = len(texts)
        program_masks[name] = program_defined_flags(lines)
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
        out.write("# cas\t<instr>\t<état>\t<rax>\t<rcx>\t<rdx>\t<drapeaux>\t<mémoire>"
                  "\t<pile>\t<rsp>\t<rbp>\t<rsi>\n")
        out.write("#   la mémoire est la fenêtre de 64 octets à 0x30001000, où pointe RSI ;\n")
        out.write("#   la pile de l'invité descend depuis 0x30003000\n")
        out.write("# fixe\t<registre>\t<valeur>\t<nom>  — ce que le silicium avait dans les\n")
        out.write("#   treize registres que « état » ne porte pas. Le fichier n'en gardait que\n")
        out.write("#   trois parce qu'aucune instruction relevée n'en écrivait d'autres ; ça ne\n")
        out.write("#   dit rien de ce qu'elles **lisent**, et `movzbl %bh, %eax` lit RBX. Un\n")
        out.write("#   harnais qui part de zéro compare alors son résultat à celui d'un\n")
        out.write("#   processeur qui, lui, partait d'ici.\n")
        out.write("#   Il y a deux fenêtres : les données, où pointe RSI, et la\n")
        out.write("#   pile, des deux côtés de RSP. Le cas porte les deux, dans\n")
        out.write("#   cet ordre, et « - » veut dire « inchangée ».\n")
        out.write("# fenêtre\t<adresse>\t<motif>  — la fenêtre de données, et le motif\n")
        out.write("#   dont elle part à chaque cas. RSI pointe dessus. Même leçon que\n")
        out.write("#   « fixe » : un harnais qui devine ce motif au lieu de le lire compare\n")
        out.write("#   son résultat à celui d'un processeur parti d'ailleurs.\n")
        # **Les registres que « état » ne porte pas.** La vérification plus bas
        # prouve qu'ils ne *bougent* pas ; elle ne dit rien de leur valeur de
        # départ, et une instruction qui les lit a besoin de celle-là.
        # RSP ne vient pas de `states()` : c'est `oracle.c` qui le pose sur la
        # pile de l'invité, juste avant de lancer le code.
        start = list(next(states()))
        start[4] = STACK
        for register in range(3, 16):
            out.write("fixe\t%d\t%x\t%s\n"
                      % (register, start[register], REGISTERS[register]))
        out.write("fenêtre\t%x\t%s\n" % (DATA, PRISTINE))
        out.write("fenêtre\t%x\t%s\n" % (STACK_WINDOW, STACK_PRISTINE))
        # **La base du segment GS**, que le pilote pose par `arch_prctl` avant
        # le premier cas. Elle n'est dans aucun registre visible : un harnais
        # qui la devinerait comparerait son résultat à celui d'un processeur
        # parti d'ailleurs — la même leçon que « fixe » et « fenêtre », pour la
        # troisième fois.
        out.write("segment\tgs\t%x\n" % DATA)
        for index, state in enumerate(chosen):
            out.write("état\t%d\t%x\t%x\t%x\t%x\n"
                      % (index, state[0], state[1], state[2], state[16] & ARITHMETIC_FLAGS))
        for index, (hexadecimal, text) in enumerate(zip(encoded, texts)):
            mask = program_masks.get(text)
            if mask is None:
                mask = defined_flags(text)
            out.write("instr\t%d\t%s\t%x\t%s\n" % (index, hexadecimal, mask, text))
        for (instruction, _, index, state), verdict in zip(cases, answer):
            fields = verdict.split("\t")
            # **Dix-sept colonnes, pas « tout le reste ».** Après l'état de
            # sortie viennent les deux fenêtres de mémoire et l'image x87, qui
            # ne sont pas des nombres hexadécimaux simples. Les avaler avec le
            # reste faisait échouer le script contre son propre binaire —
            # « invalid literal for int() » sur une liste séparée par des
            # virgules — et le corpus n'était plus régénérable du tout.
            after = [int(value, 16) for value in fields[18:35]]
            # Ce qui n'était pas censé bouger n'a pas bougé : la vérification
            # qui autorise à ne garder que trois registres dans le fichier.
            # RBP et RSP sont exclus — les programmes qui posent un cadre de
            # pile s'en servent — mais ils sont **écrits dans le cas**, deux
            # colonnes plus loin. Les laisser dehors était un trou : un
            # `leave` qui reprend RBP dans le désordre laisse RAX, RCX, RDX et
            # les deux fenêtres exactement justes, et rien ne le voyait.
            for register in [3, 7] + list(range(8, 16)):
                if after[register] != state[register]:
                    raise SystemExit(
                        f"{texts[instruction]} a écrit dans {REGISTERS[register]} : "
                        f"{state[register]:x} devenu {after[register]:x}")
            out.write("cas\t%d\t%d\t%x\t%x\t%x\t%x\t%s\t%s\t%x\t%x\t%x\n"
                      % (instruction, index,
                         after[0], after[1], after[2], after[16] & ARITHMETIC_FLAGS,
                         # « - » quand la fenêtre est restée telle qu'on l'avait
                         # posée : la plupart des instructions ne touchent pas à
                         # la mémoire, et écrire cent vingt-huit caractères pour
                         # dire « rien » quadruplerait le fichier.
                         "-" if fields[35] == PRISTINE else fields[35],
                         # **Et la pile.** Un `push` qui écrit à la mauvaise
                         # adresse laisse tous les registres justes ; sans cette
                         # colonne, rien ne le verrait.
                         "-" if fields[36] == STACK_PRISTINE else fields[36],
                         # **Le pointeur de pile et le pointeur de cadre.** Ce
                         # sont les deux seuls registres qu'on autorise à
                         # bouger sans les relever, et c'est précisément là que
                         # la pile se prouve : un `pop` qui remonte RSP de huit
                         # de trop ne se voit nulle part ailleurs.
                         # …et RSI, que les programmes qui parcourent la
                         # mémoire avancent. La vérification l'a refusé dès
                         # qu'on a voulu l'y soumettre : « une boucle qui
                         # parcourt la mémoire a écrit dans rsi ». C'est vrai,
                         # et c'est ce qu'elle prouve — donc on la relève au
                         # lieu de l'exclure.
                         after[4], after[5], after[6]))

    print(f"{len(texts)} instructions, {len(cases)} cas", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
