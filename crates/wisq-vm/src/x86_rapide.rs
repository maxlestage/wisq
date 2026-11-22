//! **Le chemin rapide de la machine PC** : des instructions déjà décodées, et
//! pour chacune une fonction choisie au décodage, qui l'exécute sans
//! redécider de rien.
//!
//! `Cpu::execute` est un juge : il reçoit une instruction décodée et pose, à
//! chaque fois, les questions que le décodage a déjà tranchées — quelle
//! opération, quelle largeur, registre ou mémoire, immédiat ou non. Ici ces
//! questions se posent **une fois**, quand l'instruction entre dans un bloc
//! (`pc::blocs`), et la réponse est une fonction : `preparer` la choisit, la
//! boucle l'appelle. Chaque forme est une instance d'une fonction générique
//! sur l'opération, la largeur et la forme des opérandes : le compilateur en
//! fait du code droit, sans aiguillage.
//!
//! **Les drapeaux sont calculés tout de suite**, sans aiguillage non plus :
//! chaque forme connaît son opération, et les six bits sortent de quelques
//! opérations sur le résultat. Une condition se lit sur ces bits par un
//! prédicat choisi lui aussi au décodage (`jcc`). Les drapeaux à la demande
//! de `Flags` restent ce que le chemin général pose ; les deux se lisent par
//! `Flags::read`, qui rend la même chose.
//!
//! **Ce qui garde ce chemin exact.** Chaque forme rend ce que `execute` rend
//! sur la même instruction — registres, mémoire, drapeaux, fautes et leur
//! code, dans le même ordre d'accès — et c'est jugé (`tests/pc_rapide.rs`) :
//! chaque forme contre `execute` sur des tirages au hasard, puis des
//! programmes entiers, sous pagination et budgets hachés, contre la machine
//! sans blocs. Ce que rien ne spécialise passe par `general`, qui est
//! `execute`.

use super::{
    Condition, Cpu, Decoded, FlagOp, Op, VectorFault, Width, AF, ARITHMETIC, CF, OF, PF, SF, ZF,
};
use crate::x86_paging::is_canonical;

/// Ce qu'une instruction exécutée laisse à faire à la boucle.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Suite {
    /// Rien n'a bougé RIP : la boucle l'avance de la longueur, et continue.
    Suivante,
    /// L'instruction a posé RIP elle-même (un saut pris, un appel, un
    /// retour, une chaîne qui reprendra) : la boucle sort du bloc.
    Saut,
    /// L'instruction a fauté, sans rien changer : `faulted` est levé, et
    /// `unmapped` dit pourquoi quand c'est un accès.
    Faute,
}

/// Une forme exécutable : la fonction choisie au décodage. Le troisième
/// argument tient les instructions que rien ne spécialise, celles de son
/// bloc : `general` y lit la sienne (`Uop::generale`).
pub type Executer = fn(&mut Cpu, &Uop, &[Decoded]) -> Suite;

/// **Une instruction prête**, sur trente-deux octets : sa fonction et ce
/// qu'elle lit — l'immédiat, le déplacement, la longueur, les registres, et
/// la forme de son adresse. `Decoded` en fait quarante-huit, et un bloc de
/// seize instructions sur une table de trente-deux mille ne tenait pas dans
/// le cache de l'hôte. Ce que rien ne spécialise garde son `Decoded` dans le
/// bloc, et `generale` dit lequel.
#[derive(Clone, Copy)]
#[repr(C)]
pub struct Uop {
    pub executer: Executer,
    /// L'immédiat, déjà étendu en signe, ou le déplacement d'un saut.
    pub imm: u64,
    /// Le déplacement de l'adresse, qui tient sur trente-deux bits.
    pub deplacement: i32,
    pub longueur: u8,
    pub dst: u8,
    pub src: u8,
    /// La base et l'index de l'adresse, quand elle en a.
    pub base: u8,
    pub index: u8,
    /// L'échelle de l'index, en décalage : 0 à 3.
    pub echelle: u8,
    /// Les bits de l'adresse : `FS`, `GS`, `RELATIF`, `A_BASE`, `A_INDEX`.
    pub adresse: u8,
    /// Le rang de l'instruction dans les générales de son bloc, ou
    /// `AUCUNE`.
    pub generale: u8,
}

/// Une instruction spécialisée : rien dans les générales.
pub const AUCUNE: u8 = u8::MAX;
const FS: u8 = 1;
const GS: u8 = 2;
const RELATIF: u8 = 4;
const A_BASE: u8 = 8;
const A_INDEX: u8 = 16;

impl Uop {
    /// Une case vide, qui ne désigne rien.
    pub fn vide() -> Self {
        Self {
            executer: general,
            imm: 0,
            deplacement: 0,
            longueur: 0,
            dst: 0,
            src: 0,
            base: 0,
            index: 0,
            echelle: 0,
            adresse: 0,
            generale: AUCUNE,
        }
    }
}

/// **Préparer une instruction**, une fois pour toutes : sa forme
/// spécialisée quand elle en a une, sinon le chemin général, qui lira
/// l'instruction au rang `generale` des générales de son bloc — c'est à
/// l'appelant de l'y ranger quand le résultat le demande
/// (`Uop::generale != AUCUNE`).
pub fn preparer(instruction: &Decoded, generale: u8) -> Uop {
    let mut uop = Uop {
        imm: instruction.imm,
        longueur: instruction.length as u8,
        dst: instruction.dst,
        src: instruction.src,
        ..Uop::vide()
    };
    let adresse = instruction.memory.map(|adresse| {
        uop.base = adresse.base.unwrap_or(0);
        uop.index = adresse.index.unwrap_or(0);
        uop.echelle = adresse.scale.trailing_zeros() as u8;
        (if adresse.fs { FS } else { 0 })
            | (if adresse.gs { GS } else { 0 })
            | (if adresse.relative { RELATIF } else { 0 })
            | (if adresse.base.is_some() { A_BASE } else { 0 })
            | (if adresse.index.is_some() { A_INDEX } else { 0 })
    });
    uop.adresse = adresse.unwrap_or(0);
    let deplacement = instruction.memory.map_or(0, |adresse| adresse.displacement);
    let tient = i32::try_from(deplacement).is_ok();
    match choisir(instruction).filter(|_| tient) {
        Some(executer) => {
            uop.executer = executer;
            uop.deplacement = deplacement as i32;
        }
        None => {
            uop.executer = if matches!(instruction.op, Op::Vector(_)) {
                vectorielle
            } else {
                general
            };
            uop.generale = generale;
        }
    }
    uop
}

/// **Exécuter une instruction seule par le chemin rapide**, comme une boucle
/// de bloc l'exécuterait : pour qui la juge contre `execute`.
pub fn executer_une(cpu: &mut Cpu, instruction: &Decoded) -> Suite {
    let uop = preparer(instruction, 0);
    (uop.executer)(cpu, &uop, std::slice::from_ref(instruction))
}

/// L'instruction a-t-elle une forme spécialisée ? Pour qui veut savoir ce
/// que ses tirages ont exercé.
pub fn specialisee(instruction: &Decoded) -> bool {
    preparer(instruction, 0).generale == AUCUNE
}

/// **Le chemin général** : `execute`, et ce qu'il dit par `faulted` et
/// `jumped` traduit pour la boucle.
pub fn general(cpu: &mut Cpu, uop: &Uop, generales: &[Decoded]) -> Suite {
    let Some(instruction) = generales.get(uop.generale as usize) else {
        cpu.faulted = true;
        return Suite::Faute;
    };
    cpu.jumped = false;
    cpu.execute(instruction);
    if cpu.faulted {
        Suite::Faute
    } else if cpu.jumped {
        Suite::Saut
    } else {
        Suite::Suivante
    }
}

/// **Une instruction vectorielle entière** (`Op::Vector`) : `execute_vector`,
/// que la machine appelle au pas à pas. Une faute d'accès y lève `faulted` et
/// pose `unmapped`, comme partout ; la boucle la nomme par l'instruction
/// (`Machine::faute_d_execution`), comme `Machine::pas` le fait. `ldmxcsr`,
/// seul à pouvoir rendre `ReservedControl` (un `#GP(0)`, pas une faute
/// d'accès), n'entre dans aucun bloc (`pc::blocs::blocable`) : s'il arrivait
/// ici, la faute serait un arrêt nommé plutôt qu'une `#GP` fausse.
pub fn vectorielle(cpu: &mut Cpu, uop: &Uop, generales: &[Decoded]) -> Suite {
    let Some(instruction) = generales.get(uop.generale as usize) else {
        cpu.faulted = true;
        return Suite::Faute;
    };
    match cpu.execute_vector(instruction) {
        Ok(()) => Suite::Suivante,
        Err(VectorFault::Memory) => {
            cpu.faulted = true;
            Suite::Faute
        }
        Err(VectorFault::ReservedControl) => {
            cpu.faulted = true;
            cpu.unmapped = None;
            Suite::Faute
        }
    }
}

// ---- Les formes des opérandes ----

/// Registre et registre.
const RR: u8 = 0;
/// Registre et immédiat.
const RI: u8 = 1;
/// Registre, et la mémoire pour source.
const RM: u8 = 2;
/// La mémoire pour destination, un registre pour source.
const MR: u8 = 3;
/// La mémoire pour destination, un immédiat pour source.
const MI: u8 = 4;

/// La forme d'une instruction à deux opérandes, ou rien si elle n'en a
/// aucune des cinq — un immédiat avec la mémoire pour source, par exemple.
fn forme(instruction: &Decoded) -> Option<u8> {
    Some(
        match (instruction.memory.is_some(), instruction.immediate) {
            (false, false) => RR,
            (false, true) => RI,
            (true, false) if instruction.memory_is_source => RM,
            (true, false) => MR,
            (true, true) if !instruction.memory_is_source => MI,
            (true, true) => return None,
        },
    )
}

// ---- Les largeurs, en constantes ----

const fn largeur(octets: u8) -> Width {
    match octets {
        1 => Width::Byte,
        2 => Width::Word,
        4 => Width::Dword,
        _ => Width::Qword,
    }
}

const fn masque(octets: u8) -> u64 {
    largeur(octets).mask()
}

const fn signe(octets: u8) -> u64 {
    largeur(octets).sign()
}

/// Un registre lu à sa largeur. Jamais un octet haut : les formes qui en ont
/// un vont au chemin général.
#[inline(always)]
fn lire<const W: u8>(cpu: &Cpu, registre: u8) -> u64 {
    cpu.regs[(registre & 15) as usize] & masque(W)
}

/// Un registre écrit à sa largeur : trente-deux bits effacent la moitié
/// haute, huit et seize la préservent (`Cpu::set`).
#[inline(always)]
fn ecrire<const W: u8>(cpu: &mut Cpu, registre: u8, valeur: u64) {
    let case = &mut cpu.regs[(registre & 15) as usize];
    match W {
        8 => *case = valeur,
        4 => *case = valeur & 0xFFFF_FFFF,
        _ => *case = (*case & !masque(W)) | (valeur & masque(W)),
    }
}

// ---- Les formes d'adresse ----

/// Une base et un déplacement, sans index ni segment : `8(%rbx)`.
const BASE: u8 = 0;
/// Une base, un index mis à l'échelle et un déplacement, sans segment.
const INDEXEE: u8 = 1;
/// Relative à RIP, sans segment : les variables globales du noyau.
const RELATIVE: u8 = 2;
/// Tout le reste — FS, GS, un index sans base — par `effective_address`.
const GENERALE: u8 = 3;

/// La forme d'une adresse, ou celle de `lea`, qui ignore le segment.
fn forme_d_adresse(adresse: &super::Address, sans_segment: bool) -> u8 {
    if !sans_segment && (adresse.gs || adresse.fs) {
        return GENERALE;
    }
    match (adresse.relative, adresse.base, adresse.index) {
        (true, None, None) => RELATIVE,
        (false, Some(_), None) => BASE,
        (false, Some(_), Some(_)) => INDEXEE,
        _ => GENERALE,
    }
}

/// **L'adresse de l'opérande mémoire, par la forme `A` choisie au
/// décodage** : ce que `effective_address` calcule, sans les questions qu'il
/// pose à chaque fois — segment, relatif, base, index. Les formes mémoire ne
/// sont choisies que pour une instruction qui porte une adresse de cette
/// forme ; `GENERALE` refait le calcul entier, bit par bit.
#[inline(always)]
fn adresse<const A: u8>(cpu: &Cpu, uop: &Uop) -> u64 {
    let deplacement = uop.deplacement as i64 as u64;
    let base = || cpu.regs[(uop.base & 15) as usize];
    let index = || cpu.regs[(uop.index & 15) as usize] << uop.echelle;
    match A {
        BASE => deplacement.wrapping_add(base()),
        INDEXEE => deplacement.wrapping_add(base()).wrapping_add(index()),
        RELATIVE => deplacement
            .wrapping_add(cpu.rip)
            .wrapping_add(u64::from(uop.longueur)),
        _ => {
            let mut valeur = deplacement;
            if uop.adresse & GS != 0 {
                valeur = valeur.wrapping_add(cpu.gs_base);
            }
            if uop.adresse & FS != 0 {
                valeur = valeur.wrapping_add(cpu.fs_base);
            }
            if uop.adresse & RELATIF != 0 {
                return valeur
                    .wrapping_add(cpu.rip)
                    .wrapping_add(u64::from(uop.longueur));
            }
            if uop.adresse & A_BASE != 0 {
                valeur = valeur.wrapping_add(base());
            }
            if uop.adresse & A_INDEX != 0 {
                valeur = valeur.wrapping_add(index());
            }
            valeur
        }
    }
}

// ---- Les drapeaux ----

/// PF pour chacun des deux cent cinquante-six octets : posé quand ses uns
/// sont en nombre pair. Une table lue dans le cache de premier niveau coûte
/// une lecture ; le pli des quartets en coûtait six, et callgrind lui
/// donnait quatre pour cent des instructions de l'hôte.
const PARITES: [u8; 256] = {
    let mut table = [0u8; 256];
    let mut octet = 0;
    while octet < 256 {
        if (octet as u8).count_ones() % 2 == 0 {
            table[octet] = PF as u8;
        }
        octet += 1;
    }
    table
};

/// La parité de l'octet bas, en PF.
#[inline(always)]
fn parite(resultat: u64) -> u64 {
    u64::from(PARITES[resultat as u8 as usize])
}

/// ZF, SF et PF d'un résultat, et AF des trois termes : ce que
/// `Flags::compute` pose pour toutes les opérations.
#[inline(always)]
fn communs<const W: u8>(gauche: u64, droite: u64, resultat: u64) -> u64 {
    let resultat = resultat & masque(W);
    (u64::from(resultat == 0) * ZF)
        | (((resultat >> (W as u32 * 8 - 1)) & 1) * SF)
        | parite(resultat)
        | ((gauche ^ droite ^ resultat) & AF)
}

/// Les drapeaux d'une addition, opérandes masqués.
#[inline(always)]
fn drapeaux_addition<const W: u8>(gauche: u64, droite: u64, resultat: u64) -> u64 {
    let resultat = resultat & masque(W);
    communs::<W>(gauche, droite, resultat)
        | (u64::from(resultat < gauche) * CF)
        | (u64::from((gauche ^ resultat) & (droite ^ resultat) & signe(W) != 0) * OF)
}

/// Les drapeaux d'une soustraction, opérandes masqués.
#[inline(always)]
fn drapeaux_soustraction<const W: u8>(gauche: u64, droite: u64, resultat: u64) -> u64 {
    let resultat = resultat & masque(W);
    communs::<W>(gauche, droite, resultat)
        | (u64::from(gauche < droite) * CF)
        | (u64::from((gauche ^ droite) & (gauche ^ resultat) & signe(W) != 0) * OF)
}

/// Poser les six bits arithmétiques, connus : le reste de RFLAGS ne bouge
/// pas.
#[inline(always)]
fn poser(cpu: &mut Cpu, bits: u64) {
    cpu.flags.op = FlagOp::Known;
    cpu.flags.arithmetic = bits & ARITHMETIC;
}

/// Les six bits arithmétiques, quel que soit l'état des drapeaux.
#[inline(always)]
fn arithmetiques(cpu: &Cpu) -> u64 {
    if cpu.flags.op == FlagOp::Known {
        cpu.flags.arithmetic
    } else {
        cpu.flags.read()
    }
}

/// **Une condition, sans aiguillage** : les huit prédicats de base rangés
/// dans un octet, et le sien pris par un décalage. Instanciée par condition,
/// le compilateur ne calcule que celui qu'il faut.
#[inline(always)]
fn tient<const C: u8>(bits: u64) -> bool {
    let of = (bits >> 11) & 1;
    let cf = bits & 1;
    let zf = (bits >> 6) & 1;
    let sf = (bits >> 7) & 1;
    let pf = (bits >> 2) & 1;
    let moins = sf ^ of;
    let predicats = of
        | (cf << 1)
        | (zf << 2)
        | ((cf | zf) << 3)
        | (sf << 4)
        | (pf << 5)
        | (moins << 6)
        | ((zf | moins) << 7);
    ((predicats >> ((C >> 1) & 7)) & 1) ^ u64::from(C & 1) != 0
}

// ---- Les opérations à deux opérandes ----

const ADD: u8 = 0;
const OR: u8 = 1;
const ADC: u8 = 2;
const SBB: u8 = 3;
const AND: u8 = 4;
const SUB: u8 = 5;
const XOR: u8 = 6;
const CMP: u8 = 7;
const TEST: u8 = 8;

/// **`add`, `or`, `adc`, `sbb`, `and`, `sub`, `xor`, `cmp`, `test`**, dans
/// l'ordre de `Cpu::compute` : lire la destination puis la source, calculer,
/// écrire (sauf `cmp` et `test`), et alors seulement poser les drapeaux — une
/// écriture qui faute ne laisse rien. `adc` et `sbb` lisent la retenue
/// d'avant, et la comptent dans la leur comme `Flags::compute` : une retenue
/// entrante rend une égalité débordante (`0xff + 0 + 1`).
fn alu<const OP: u8, const W: u8, const F: u8, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let memoire_en_destination = F == MR || F == MI;
    let ici = if F == RR || F == RI {
        0
    } else {
        adresse::<A>(cpu, instruction)
    };
    let gauche = if memoire_en_destination {
        match cpu.read_memory_fast(ici, largeur(W)) {
            Ok(valeur) => valeur,
            Err(_) => {
                cpu.faulted = true;
                return Suite::Faute;
            }
        }
    } else {
        lire::<W>(cpu, instruction.dst)
    };
    let droite = match F {
        RI | MI => instruction.imm & masque(W),
        RM => match cpu.read_memory_fast(ici, largeur(W)) {
            Ok(valeur) => valeur,
            Err(_) => {
                cpu.faulted = true;
                return Suite::Faute;
            }
        },
        _ => lire::<W>(cpu, instruction.src),
    };
    let (resultat, bits) = match OP {
        ADD => {
            let resultat = gauche.wrapping_add(droite);
            (resultat, drapeaux_addition::<W>(gauche, droite, resultat))
        }
        SUB | CMP => {
            let resultat = gauche.wrapping_sub(droite);
            (
                resultat,
                drapeaux_soustraction::<W>(gauche, droite, resultat),
            )
        }
        ADC => {
            let entrante = arithmetiques(cpu) & CF;
            let resultat = gauche.wrapping_add(droite).wrapping_add(entrante);
            let masque_du_resultat = resultat & masque(W);
            let retenue =
                masque_du_resultat < gauche || (entrante == 1 && masque_du_resultat == gauche);
            (
                resultat,
                communs::<W>(gauche, droite, resultat)
                    | (u64::from(retenue) * CF)
                    | (u64::from(
                        (gauche ^ masque_du_resultat) & (droite ^ masque_du_resultat) & signe(W)
                            != 0,
                    ) * OF),
            )
        }
        SBB => {
            let entrante = arithmetiques(cpu) & CF;
            let resultat = gauche.wrapping_sub(droite).wrapping_sub(entrante);
            let masque_du_resultat = resultat & masque(W);
            let retenue = gauche < droite || (entrante == 1 && gauche == droite);
            (
                resultat,
                communs::<W>(gauche, droite, resultat)
                    | (u64::from(retenue) * CF)
                    | (u64::from(
                        (gauche ^ droite) & (gauche ^ masque_du_resultat) & signe(W) != 0,
                    ) * OF),
            )
        }
        _ => {
            let resultat = match OP {
                OR => gauche | droite,
                XOR => gauche ^ droite,
                _ => gauche & droite,
            };
            (resultat, communs::<W>(gauche, droite, resultat))
        }
    };
    if OP != CMP && OP != TEST {
        if memoire_en_destination {
            if cpu.write_memory_fast(ici, largeur(W), resultat).is_err() {
                cpu.faulted = true;
                return Suite::Faute;
            }
        } else {
            ecrire::<W>(cpu, instruction.dst, resultat);
        }
    }
    poser(cpu, bits);
    Suite::Suivante
}

const INC: u8 = 0;
const DEC: u8 = 1;
const NOT: u8 = 2;
const NEG: u8 = 3;

/// **`inc`, `dec`, `not`, `neg`** sur un registre. `inc` et `dec`
/// préservent la retenue ; `not` ne touche à aucun drapeau ; `neg` est
/// `0 - x`, drapeaux compris.
fn unaire<const OP: u8, const W: u8>(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let valeur = lire::<W>(cpu, instruction.dst);
    match OP {
        INC | DEC => {
            let retenue = arithmetiques(cpu) & CF;
            let (resultat, bits) = if OP == INC {
                let resultat = valeur.wrapping_add(1);
                let resultat_masque = resultat & masque(W);
                (
                    resultat,
                    communs::<W>(valeur, 1, resultat)
                        | (u64::from(
                            (valeur ^ resultat_masque) & (1 ^ resultat_masque) & signe(W) != 0,
                        ) * OF),
                )
            } else {
                let resultat = valeur.wrapping_sub(1);
                let resultat_masque = resultat & masque(W);
                (
                    resultat,
                    communs::<W>(valeur, 1, resultat)
                        | (u64::from((valeur ^ 1) & (valeur ^ resultat_masque) & signe(W) != 0)
                            * OF),
                )
            };
            ecrire::<W>(cpu, instruction.dst, resultat);
            poser(cpu, bits | retenue);
        }
        NOT => ecrire::<W>(cpu, instruction.dst, !valeur),
        _ => {
            let resultat = 0u64.wrapping_sub(valeur);
            let bits = drapeaux_soustraction::<W>(0, valeur, resultat);
            ecrire::<W>(cpu, instruction.dst, resultat);
            poser(cpu, bits);
        }
    }
    Suite::Suivante
}

const SHL: u8 = 0;
const SHR: u8 = 1;
const SAR: u8 = 2;

/// **`shl`, `shr`, `sar` sur un registre**, par un immédiat ou par CL — les
/// règles de `Cpu::shift`, recopiées pour une largeur connue : le compte
/// masqué, un compte nul qui écrit la destination sans toucher un drapeau,
/// la retenue du dernier bit sorti, et AF à zéro.
fn decalage<const OP: u8, const W: u8, const CL: bool>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let bits_de_largeur = W as u64 * 8;
    let brut = if CL { cpu.regs[1] } else { instruction.imm };
    let compte = brut & if W == 8 { 63 } else { 31 };
    let valeur = lire::<W>(cpu, instruction.dst);
    if compte == 0 {
        ecrire::<W>(cpu, instruction.dst, valeur);
        return Suite::Suivante;
    }
    let (resultat, retenue, debordement) = match OP {
        SHL => {
            let resultat = (valeur << compte.min(63)) & masque(W);
            let retenue = if compte <= bits_de_largeur {
                (valeur >> (bits_de_largeur - compte)) & 1
            } else {
                0
            };
            let signe_du_resultat = u64::from(resultat & signe(W) != 0);
            (resultat, retenue, signe_du_resultat ^ retenue)
        }
        SHR => {
            let resultat = valeur >> compte.min(63);
            let retenue = if compte <= bits_de_largeur {
                (valeur >> (compte - 1)) & 1
            } else {
                0
            };
            (resultat, retenue, u64::from(valeur & signe(W) != 0))
        }
        _ => {
            let monte = 64 - bits_de_largeur;
            let etendu = ((valeur << monte) as i64) >> monte;
            let resultat = ((etendu >> compte.min(63)) as u64) & masque(W);
            let retenue = if compte < bits_de_largeur {
                (valeur >> (compte - 1)) & 1
            } else {
                u64::from(etendu < 0)
            };
            (resultat, retenue, 0)
        }
    };
    let bits = (u64::from(resultat & masque(W) == 0) * ZF)
        | (u64::from(resultat & signe(W) != 0) * SF)
        | parite(resultat)
        | (retenue * CF)
        | (debordement * OF);
    ecrire::<W>(cpu, instruction.dst, resultat);
    poser(cpu, bits);
    Suite::Suivante
}

/// **`rol` et `ror` sur un registre**, par un immédiat ou par CL — les
/// règles de `Cpu::rotate`, pour une largeur connue : le compte masqué, un
/// compte nul qui écrit la destination sans toucher un drapeau, un tour
/// complet qui rend la valeur mais pose quand même CF et OF, et seuls ces
/// deux drapeaux qui bougent.
fn rotation<const GAUCHE: bool, const W: u8, const CL: bool>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let bits = W as u64 * 8;
    let brut = if CL { cpu.regs[1] } else { instruction.imm };
    let compte = brut & if W == 8 { 63 } else { 31 };
    let valeur = lire::<W>(cpu, instruction.dst);
    if compte == 0 {
        ecrire::<W>(cpu, instruction.dst, valeur);
        return Suite::Suivante;
    }
    let tour = compte % bits;
    let resultat = if tour == 0 {
        valeur
    } else if GAUCHE {
        ((valeur << tour) | (valeur >> (bits - tour))) & masque(W)
    } else {
        ((valeur >> tour) | (valeur << (bits - tour))) & masque(W)
    };
    let haut = u64::from(resultat & signe(W) != 0);
    let (retenue, debordement) = if GAUCHE {
        let retenue = resultat & 1;
        (retenue, haut ^ retenue)
    } else {
        (haut, haut ^ ((resultat >> (bits - 2)) & 1))
    };
    ecrire::<W>(cpu, instruction.dst, resultat);
    poser(
        cpu,
        (arithmetiques(cpu) & !(CF | OF)) | (retenue * CF) | (debordement * OF),
    );
    Suite::Suivante
}

/// **`inc`, `dec`, `not`, `neg` sur la mémoire** (un `lock` devant n'y
/// change rien ici) : lire, calculer, écrire, puis poser les drapeaux —
/// ceux de la forme registre, une écriture qui faute ne laissant rien.
fn unaire_memoire<const OP: u8, const W: u8, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let ici = adresse::<A>(cpu, instruction);
    let valeur = match cpu.read_memory_fast(ici, largeur(W)) {
        Ok(valeur) => valeur,
        Err(_) => {
            cpu.faulted = true;
            return Suite::Faute;
        }
    };
    let (resultat, bits) = match OP {
        INC | DEC => {
            let retenue = arithmetiques(cpu) & CF;
            let resultat = if OP == INC {
                valeur.wrapping_add(1)
            } else {
                valeur.wrapping_sub(1)
            };
            let masque_du_resultat = resultat & masque(W);
            let debordement = if OP == INC {
                (valeur ^ masque_du_resultat) & (1 ^ masque_du_resultat) & signe(W) != 0
            } else {
                (valeur ^ 1) & (valeur ^ masque_du_resultat) & signe(W) != 0
            };
            (
                resultat,
                Some(communs::<W>(valeur, 1, resultat) | (u64::from(debordement) * OF) | retenue),
            )
        }
        NOT => (!valeur, None),
        _ => {
            let resultat = 0u64.wrapping_sub(valeur);
            (
                resultat,
                Some(drapeaux_soustraction::<W>(0, valeur, resultat)),
            )
        }
    };
    if cpu.write_memory_fast(ici, largeur(W), resultat).is_err() {
        cpu.faulted = true;
        return Suite::Faute;
    }
    if let Some(bits) = bits {
        poser(cpu, bits);
    }
    Suite::Suivante
}

/// **`bswap`** : les octets du registre à rebours, à sa largeur, comme
/// `execute_general`.
fn renverser<const W: u8>(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let valeur = lire::<W>(cpu, instruction.dst);
    ecrire::<W>(
        cpu,
        instruction.dst,
        valeur.swap_bytes() >> (64 - W as u32 * 8),
    );
    Suite::Suivante
}

/// **`xchg` entre deux registres** : la destination reçoit la source, puis
/// la source l'ancienne destination. Aucun drapeau.
fn echange_registres<const W: u8>(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let destination = lire::<W>(cpu, instruction.dst);
    let source = lire::<W>(cpu, instruction.src);
    ecrire::<W>(cpu, instruction.dst, source);
    ecrire::<W>(cpu, instruction.src, destination);
    Suite::Suivante
}

/// **`cbtw`, `cwtl`, `cltq`** : la moitié basse de l'accumulateur, de
/// largeur `S`, étendue en signe dans lui-même à la largeur `W`.
fn elargir<const W: u8, const S: u8>(cpu: &mut Cpu, _: &Uop, _: &[Decoded]) -> Suite {
    let source = lire::<S>(cpu, 0);
    let valeur = if source & signe(S) != 0 {
        source | !masque(S)
    } else {
        source
    };
    ecrire::<W>(cpu, 0, valeur);
    Suite::Suivante
}

// ---- Les transferts ----

/// **`mov` et `movzx` entre registres**, ou d'un immédiat : la source lue à
/// sa largeur `S`, écrite à la largeur `W`.
fn transfert_registre<const W: u8, const S: u8, const IMMEDIAT: bool>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let valeur = if IMMEDIAT {
        instruction.imm & masque(S)
    } else {
        lire::<S>(cpu, instruction.src)
    };
    ecrire::<W>(cpu, instruction.dst, valeur);
    Suite::Suivante
}

/// **`movsx` entre registres** : la source étendue en signe depuis sa
/// largeur.
fn extension_registre<const W: u8, const S: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let source = lire::<S>(cpu, instruction.src);
    let valeur = if source & signe(S) != 0 {
        source | !masque(S)
    } else {
        source
    };
    ecrire::<W>(cpu, instruction.dst, valeur);
    Suite::Suivante
}

/// **`mov`, `movzx` et `movsx` depuis la mémoire** : `S` octets lus.
fn chargement<const W: u8, const S: u8, const SIGNE: bool, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let ici = adresse::<A>(cpu, instruction);
    let Ok(source) = cpu.read_memory_fast(ici, largeur(S)) else {
        cpu.faulted = true;
        return Suite::Faute;
    };
    let valeur = if SIGNE && source & signe(S) != 0 {
        source | !masque(S)
    } else {
        source
    };
    ecrire::<W>(cpu, instruction.dst, valeur);
    Suite::Suivante
}

/// **`mov` vers la mémoire**, d'un registre ou d'un immédiat. Il ne lit pas
/// sa destination : une page absente faute en écriture.
fn rangement<const W: u8, const S: u8, const IMMEDIAT: bool, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let valeur = if IMMEDIAT {
        instruction.imm & masque(S)
    } else {
        lire::<S>(cpu, instruction.src)
    };
    let ici = adresse::<A>(cpu, instruction);
    if cpu.write_memory_fast(ici, largeur(W), valeur).is_err() {
        cpu.faulted = true;
        return Suite::Faute;
    }
    Suite::Suivante
}

/// **`lea`** : l'adresse sans la base de segment (`Cpu::lea`), la forme `A`
/// choisie sans elle.
fn lea<const W: u8, const A: u8>(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let sans_segment = Uop {
        adresse: instruction.adresse & !(FS | GS),
        ..*instruction
    };
    let valeur = adresse::<A>(cpu, &sans_segment);
    ecrire::<W>(cpu, instruction.dst, valeur);
    Suite::Suivante
}

/// **`cmovcc`**, la condition `C` choisie au décodage, comme
/// `execute_general` : la source lue d'abord (la mémoire faute même quand la
/// condition ne tient pas), puis la destination **écrite dans les deux cas**
/// — trente-deux bits effacent la moitié haute même sans copie. Aucun
/// drapeau.
fn cmov<const C: u8, const W: u8, const F: u8, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let source = if F == RM {
        let ici = adresse::<A>(cpu, instruction);
        match cpu.read_memory_fast(ici, largeur(W)) {
            Ok(valeur) => valeur,
            Err(_) => {
                cpu.faulted = true;
                return Suite::Faute;
            }
        }
    } else {
        lire::<W>(cpu, instruction.src)
    };
    let valeur = if tient::<C>(arithmetiques(cpu)) {
        source
    } else {
        lire::<W>(cpu, instruction.dst)
    };
    ecrire::<W>(cpu, instruction.dst, valeur);
    Suite::Suivante
}

/// **`setcc`** : un octet, zéro ou un, vers un registre (jamais un octet
/// haut : ceux-là vont au chemin général) ou vers la mémoire. Aucun drapeau.
fn setcc<const C: u8, const MEMOIRE: bool, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let valeur = u64::from(tient::<C>(arithmetiques(cpu)));
    if MEMOIRE {
        let ici = adresse::<A>(cpu, instruction);
        if cpu.write_memory_fast(ici, Width::Byte, valeur).is_err() {
            cpu.faulted = true;
            return Suite::Faute;
        }
    } else {
        ecrire::<1>(cpu, instruction.dst, valeur);
    }
    Suite::Suivante
}

/// **`imul` à deux et trois opérandes** (`Op::Multiply`) : le produit signé
/// tronqué à la largeur, rangé dans `reg` ; CF et OF levés quand il ne tient
/// pas, les quatre autres bits laissés tels quels, comme
/// `arithmetic_in_two_registers`. À trois opérandes, les facteurs sont `rm`
/// et l'immédiat ; à deux, la destination et `rm`.
fn imul<const W: u8, const F: u8, const IMMEDIAT: bool, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let source = if F == RM {
        let ici = adresse::<A>(cpu, instruction);
        match cpu.read_memory_fast(ici, largeur(W)) {
            Ok(valeur) => valeur,
            Err(_) => {
                cpu.faulted = true;
                return Suite::Faute;
            }
        }
    } else {
        lire::<W>(cpu, instruction.src)
    };
    let (gauche, droite) = if IMMEDIAT {
        (source, instruction.imm)
    } else {
        (lire::<W>(cpu, instruction.dst), source)
    };
    let etendre = |valeur: u64| -> i128 {
        let decalage = 64 - W as u32 * 8;
        i128::from(((valeur << decalage) as i64) >> decalage)
    };
    let produit = etendre(gauche) * etendre(droite);
    let bas = produit as u64 & masque(W);
    let tient = etendre(bas) == produit;
    ecrire::<W>(cpu, instruction.dst, bas);
    let leves = if tient { 0 } else { CF | OF };
    poser(cpu, (arithmetiques(cpu) & !(CF | OF)) | leves);
    Suite::Suivante
}

fn nop(_: &mut Cpu, _: &Uop, _: &[Decoded]) -> Suite {
    Suite::Suivante
}

// ---- Les sauts et la pile ----

/// **Un saut conditionnel**, la condition `C` choisie au décodage. La cible
/// se juge comme dans `Cpu::jump` : prise et pas canonique, le saut faute
/// sur lui-même.
fn jcc<const C: u8>(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    if !tient::<C>(arithmetiques(cpu)) {
        return Suite::Suivante;
    }
    let cible = cpu
        .rip
        .wrapping_add(u64::from(instruction.longueur))
        .wrapping_add(instruction.imm);
    if !is_canonical(cible) {
        cpu.refuse_target(cible);
        return Suite::Faute;
    }
    cpu.rip = cible;
    Suite::Saut
}

/// `jmp` relatif.
fn jmp(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let cible = cpu
        .rip
        .wrapping_add(u64::from(instruction.longueur))
        .wrapping_add(instruction.imm);
    if !is_canonical(cible) {
        cpu.refuse_target(cible);
        return Suite::Faute;
    }
    cpu.rip = cible;
    Suite::Saut
}

/// `call` relatif : la cible jugée avant d'empiler, l'empilement avant de
/// sauter.
fn call(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let apres = cpu.rip.wrapping_add(u64::from(instruction.longueur));
    let cible = apres.wrapping_add(instruction.imm);
    if !is_canonical(cible) {
        cpu.refuse_target(cible);
        return Suite::Faute;
    }
    let sommet = cpu.regs[4].wrapping_sub(8);
    if cpu.write_memory_fast(sommet, Width::Qword, apres).is_err() {
        cpu.faulted = true;
        return Suite::Faute;
    }
    cpu.regs[4] = sommet;
    cpu.rip = cible;
    Suite::Saut
}

/// La cible d'un saut ou d'un appel indirect : un registre, ou huit octets
/// de mémoire.
#[inline(always)]
fn cible_indirecte<const MEMOIRE: bool, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
) -> Option<u64> {
    if MEMOIRE {
        let ici = adresse::<A>(cpu, instruction);
        match cpu.read_memory_fast(ici, Width::Qword) {
            Ok(cible) => Some(cible),
            Err(_) => {
                cpu.faulted = true;
                None
            }
        }
    } else {
        Some(cpu.regs[(instruction.dst & 15) as usize])
    }
}

/// `jmp *` vers un registre ou la mémoire : la cible lue, jugée, prise.
fn saut_indirect<const MEMOIRE: bool, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let Some(cible) = cible_indirecte::<MEMOIRE, A>(cpu, instruction) else {
        return Suite::Faute;
    };
    if !is_canonical(cible) {
        cpu.refuse_target(cible);
        return Suite::Faute;
    }
    cpu.rip = cible;
    Suite::Saut
}

/// `call *` vers un registre ou la mémoire : la cible lue **avant** que la
/// pile ne bouge, jugée avant d'empiler, l'empilement avant de sauter.
fn appel_indirect<const MEMOIRE: bool, const A: u8>(
    cpu: &mut Cpu,
    instruction: &Uop,
    _: &[Decoded],
) -> Suite {
    let Some(cible) = cible_indirecte::<MEMOIRE, A>(cpu, instruction) else {
        return Suite::Faute;
    };
    if !is_canonical(cible) {
        cpu.refuse_target(cible);
        return Suite::Faute;
    }
    let apres = cpu.rip.wrapping_add(u64::from(instruction.longueur));
    let sommet = cpu.regs[4].wrapping_sub(8);
    if cpu.write_memory_fast(sommet, Width::Qword, apres).is_err() {
        cpu.faulted = true;
        return Suite::Faute;
    }
    cpu.regs[4] = sommet;
    cpu.rip = cible;
    Suite::Saut
}

/// `ret`, et `ret $n` : dépiler, juger la cible (une faute rend RSP), puis
/// jeter les arguments.
fn ret(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let Ok(cible) = cpu.read_memory_fast(cpu.regs[4], Width::Qword) else {
        cpu.faulted = true;
        return Suite::Faute;
    };
    if !is_canonical(cible) {
        cpu.refuse_target(cible);
        return Suite::Faute;
    }
    cpu.regs[4] = cpu.regs[4]
        .wrapping_add(8)
        .wrapping_add(instruction.imm & 0xFFFF);
    cpu.rip = cible;
    Suite::Saut
}

/// `push` d'un registre de huit octets, lu avant que RSP ne descende.
fn push_registre(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let valeur = cpu.regs[(instruction.dst & 15) as usize];
    let sommet = cpu.regs[4].wrapping_sub(8);
    if cpu.write_memory_fast(sommet, Width::Qword, valeur).is_err() {
        cpu.faulted = true;
        return Suite::Faute;
    }
    cpu.regs[4] = sommet;
    Suite::Suivante
}

/// `push` d'un immédiat, à la largeur de l'instruction.
fn push_immediat<const W: u8>(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let sommet = cpu.regs[4].wrapping_sub(W as u64);
    if cpu
        .write_memory_fast(sommet, largeur(W), instruction.imm)
        .is_err()
    {
        cpu.faulted = true;
        return Suite::Faute;
    }
    cpu.regs[4] = sommet;
    Suite::Suivante
}

/// `pop` vers un registre : lire, remonter, puis écrire — `pop %rsp` rend la
/// valeur dépilée.
fn pop_registre(cpu: &mut Cpu, instruction: &Uop, _: &[Decoded]) -> Suite {
    let Ok(valeur) = cpu.read_memory_fast(cpu.regs[4], Width::Qword) else {
        cpu.faulted = true;
        return Suite::Faute;
    };
    cpu.regs[4] = cpu.regs[4].wrapping_add(8);
    cpu.regs[(instruction.dst & 15) as usize] = valeur;
    Suite::Suivante
}

// ---- Le choix ----

/// Une forme générique, instanciée pour chaque largeur.
macro_rules! par_largeur {
    ($largeur:expr, $fonction:ident, [$($avant:tt),*], [$($apres:tt),*]) => {
        match $largeur {
            Width::Byte => $fonction::<$($avant,)* 1 $(, $apres)*> as Executer,
            Width::Word => $fonction::<$($avant,)* 2 $(, $apres)*> as Executer,
            Width::Dword => $fonction::<$($avant,)* 4 $(, $apres)*> as Executer,
            Width::Qword => $fonction::<$($avant,)* 8 $(, $apres)*> as Executer,
        }
    };
}

/// Une forme générique sur deux largeurs, la destination et la source.
macro_rules! par_deux_largeurs {
    ($destination:expr, $source:expr, $fonction:ident, [$($apres:tt),*]) => {
        match ($destination, $source) {
            (Width::Byte, Width::Byte) => Some($fonction::<1, 1 $(, $apres)*> as Executer),
            (Width::Word, Width::Byte) => Some($fonction::<2, 1 $(, $apres)*> as Executer),
            (Width::Word, Width::Word) => Some($fonction::<2, 2 $(, $apres)*> as Executer),
            (Width::Dword, Width::Byte) => Some($fonction::<4, 1 $(, $apres)*> as Executer),
            (Width::Dword, Width::Word) => Some($fonction::<4, 2 $(, $apres)*> as Executer),
            (Width::Dword, Width::Dword) => Some($fonction::<4, 4 $(, $apres)*> as Executer),
            (Width::Qword, Width::Byte) => Some($fonction::<8, 1 $(, $apres)*> as Executer),
            (Width::Qword, Width::Word) => Some($fonction::<8, 2 $(, $apres)*> as Executer),
            (Width::Qword, Width::Dword) => Some($fonction::<8, 4 $(, $apres)*> as Executer),
            (Width::Qword, Width::Qword) => Some($fonction::<8, 8 $(, $apres)*> as Executer),
            _ => None,
        }
    };
}

/// `cmovcc` pour une largeur, une forme et une forme d'adresse.
fn choisir_cmov<const C: u8>(largeur: Width, forme: u8, adresse: u8) -> Option<Executer> {
    Some(match (forme, adresse) {
        (RR, _) => match largeur {
            Width::Word => cmov::<C, 2, RR, GENERALE>,
            Width::Dword => cmov::<C, 4, RR, GENERALE>,
            Width::Qword => cmov::<C, 8, RR, GENERALE>,
            Width::Byte => return None,
        },
        (RM, BASE) => choisir_cmov_memoire::<C, BASE>(largeur)?,
        (RM, INDEXEE) => choisir_cmov_memoire::<C, INDEXEE>(largeur)?,
        (RM, RELATIVE) => choisir_cmov_memoire::<C, RELATIVE>(largeur)?,
        (RM, _) => choisir_cmov_memoire::<C, GENERALE>(largeur)?,
        _ => return None,
    })
}

fn choisir_cmov_memoire<const C: u8, const A: u8>(largeur: Width) -> Option<Executer> {
    Some(match largeur {
        Width::Word => cmov::<C, 2, RM, A>,
        Width::Dword => cmov::<C, 4, RM, A>,
        Width::Qword => cmov::<C, 8, RM, A>,
        Width::Byte => return None,
    })
}

/// `setcc` vers un registre ou vers la mémoire, par sa forme d'adresse.
fn choisir_setcc<const C: u8>(forme: u8, adresse: u8) -> Option<Executer> {
    Some(match (forme, adresse) {
        (RR, _) => setcc::<C, false, GENERALE>,
        (MR, BASE) => setcc::<C, true, BASE>,
        (MR, INDEXEE) => setcc::<C, true, INDEXEE>,
        (MR, RELATIVE) => setcc::<C, true, RELATIVE>,
        (MR, _) => setcc::<C, true, GENERALE>,
        _ => return None,
    })
}

/// `imul` à deux ou trois opérandes, par largeur, forme et forme d'adresse.
fn choisir_imul(instruction: &Decoded, adresse: u8) -> Option<Executer> {
    macro_rules! largeurs {
        ($f:expr, $i:expr, $a:expr) => {
            match instruction.width {
                Width::Word => imul::<2, $f, $i, $a> as Executer,
                Width::Dword => imul::<4, $f, $i, $a> as Executer,
                Width::Qword => imul::<8, $f, $i, $a> as Executer,
                Width::Byte => return None,
            }
        };
    }
    let memoire = instruction.memory.is_some();
    Some(match (memoire, instruction.immediate, adresse) {
        (false, false, _) => largeurs!(RR, false, GENERALE),
        (false, true, _) => largeurs!(RR, true, GENERALE),
        (true, false, BASE) => largeurs!(RM, false, BASE),
        (true, false, INDEXEE) => largeurs!(RM, false, INDEXEE),
        (true, false, RELATIVE) => largeurs!(RM, false, RELATIVE),
        (true, false, _) => largeurs!(RM, false, GENERALE),
        (true, true, BASE) => largeurs!(RM, true, BASE),
        (true, true, INDEXEE) => largeurs!(RM, true, INDEXEE),
        (true, true, RELATIVE) => largeurs!(RM, true, RELATIVE),
        (true, true, _) => largeurs!(RM, true, GENERALE),
    })
}

/// `inc`, `dec`, `not`, `neg` sur la mémoire, par sa forme d'adresse.
fn choisir_unaire_memoire(op: Op, largeur: Width, adresse: u8) -> Executer {
    match adresse {
        BASE => choisir_unaire_memoire_a::<BASE>(op, largeur),
        INDEXEE => choisir_unaire_memoire_a::<INDEXEE>(op, largeur),
        RELATIVE => choisir_unaire_memoire_a::<RELATIVE>(op, largeur),
        _ => choisir_unaire_memoire_a::<GENERALE>(op, largeur),
    }
}

fn choisir_unaire_memoire_a<const A: u8>(op: Op, largeur: Width) -> Executer {
    match op {
        Op::Inc => par_largeur!(largeur, unaire_memoire, [INC], [A]),
        Op::Dec => par_largeur!(largeur, unaire_memoire, [DEC], [A]),
        Op::Not => par_largeur!(largeur, unaire_memoire, [NOT], [A]),
        _ => par_largeur!(largeur, unaire_memoire, [NEG], [A]),
    }
}

/// `alu` pour une opération, une largeur, une forme et une forme
/// d'adresse.
fn choisir_alu<const OP: u8>(largeur: Width, forme: u8, adresse: u8) -> Executer {
    match adresse {
        BASE => choisir_alu_a::<OP, BASE>(largeur, forme),
        INDEXEE => choisir_alu_a::<OP, INDEXEE>(largeur, forme),
        RELATIVE => choisir_alu_a::<OP, RELATIVE>(largeur, forme),
        _ => choisir_alu_a::<OP, GENERALE>(largeur, forme),
    }
}

fn choisir_alu_a<const OP: u8, const A: u8>(largeur: Width, forme: u8) -> Executer {
    match forme {
        // Sans mémoire, la forme d'adresse ne sert pas : une seule instance.
        RR => par_largeur!(largeur, alu, [OP], [RR, GENERALE]),
        RI => par_largeur!(largeur, alu, [OP], [RI, GENERALE]),
        RM => par_largeur!(largeur, alu, [OP], [RM, A]),
        MR => par_largeur!(largeur, alu, [OP], [MR, A]),
        _ => par_largeur!(largeur, alu, [OP], [MI, A]),
    }
}

/// Les transferts avec la mémoire, pour une forme d'adresse.
fn choisir_transfert<const A: u8>(instruction: &Decoded, forme: u8) -> Option<Executer> {
    let (largeur, source) = (instruction.width, instruction.src_width);
    match (instruction.op, forme) {
        (Op::Mov, RM) => par_deux_largeurs!(largeur, source, chargement, [false, A]),
        (Op::Movsx, RM) => par_deux_largeurs!(largeur, source, chargement, [true, A]),
        (Op::Mov, MR) if largeur == source => {
            par_deux_largeurs!(largeur, source, rangement, [false, A])
        }
        (Op::Mov, MI) if largeur == source => {
            par_deux_largeurs!(largeur, source, rangement, [true, A])
        }
        (Op::Lea, _) => match largeur {
            Width::Qword => Some(lea::<8, A> as Executer),
            Width::Dword => Some(lea::<4, A> as Executer),
            Width::Word => Some(lea::<2, A> as Executer),
            Width::Byte => None,
        },
        _ => None,
    }
}

/// Un transfert avec la mémoire, par sa forme d'adresse.
fn transfert(instruction: &Decoded, forme: u8, adresse: u8) -> Option<Executer> {
    match adresse {
        BASE => choisir_transfert::<BASE>(instruction, forme),
        INDEXEE => choisir_transfert::<INDEXEE>(instruction, forme),
        RELATIVE => choisir_transfert::<RELATIVE>(instruction, forme),
        _ => choisir_transfert::<GENERALE>(instruction, forme),
    }
}

/// Les seize conditions.
fn choisir_jcc(condition: Condition) -> Executer {
    match condition.0 & 15 {
        0 => jcc::<0>,
        1 => jcc::<1>,
        2 => jcc::<2>,
        3 => jcc::<3>,
        4 => jcc::<4>,
        5 => jcc::<5>,
        6 => jcc::<6>,
        7 => jcc::<7>,
        8 => jcc::<8>,
        9 => jcc::<9>,
        10 => jcc::<10>,
        11 => jcc::<11>,
        12 => jcc::<12>,
        13 => jcc::<13>,
        14 => jcc::<14>,
        _ => jcc::<15>,
    }
}

/// **La forme spécialisée d'une instruction**, quand elle en a une. Les
/// conditions de chaque bras sont celles sous lesquelles la forme fait
/// exactement ce que `execute` fait : un octet haut, une largeur de source
/// inattendue, une opération que rien ne spécialise — le chemin général.
fn choisir(instruction: &Decoded) -> Option<Executer> {
    if instruction.dst_high || instruction.src_high {
        return None;
    }
    let largeur = instruction.width;
    let source = instruction.src_width;
    let adresse = instruction.memory.map_or(GENERALE, |adresse| {
        forme_d_adresse(&adresse, instruction.op == Op::Lea)
    });
    // `imul` à trois opérandes porte un immédiat et lit la mémoire : aucune
    // des cinq formes, il se choisit avant.
    if instruction.op == Op::Multiply {
        return choisir_imul(instruction, adresse);
    }
    let forme = forme(instruction)?;
    let ecrit = !instruction.discards;
    Some(match instruction.op {
        Op::Adc if ecrit => choisir_alu::<ADC>(largeur, forme, adresse),
        Op::Sbb if ecrit => choisir_alu::<SBB>(largeur, forme, adresse),
        Op::CondMove(condition) if largeur == source => {
            macro_rules! cmov_par {
                ($c:literal) => {
                    choisir_cmov::<$c>(largeur, forme, adresse)
                };
            }
            match condition.0 & 15 {
                0 => cmov_par!(0),
                1 => cmov_par!(1),
                2 => cmov_par!(2),
                3 => cmov_par!(3),
                4 => cmov_par!(4),
                5 => cmov_par!(5),
                6 => cmov_par!(6),
                7 => cmov_par!(7),
                8 => cmov_par!(8),
                9 => cmov_par!(9),
                10 => cmov_par!(10),
                11 => cmov_par!(11),
                12 => cmov_par!(12),
                13 => cmov_par!(13),
                14 => cmov_par!(14),
                _ => cmov_par!(15),
            }?
        }
        Op::Set(condition) if largeur == Width::Byte => {
            macro_rules! set_par {
                ($c:literal) => {
                    choisir_setcc::<$c>(forme, adresse)
                };
            }
            match condition.0 & 15 {
                0 => set_par!(0),
                1 => set_par!(1),
                2 => set_par!(2),
                3 => set_par!(3),
                4 => set_par!(4),
                5 => set_par!(5),
                6 => set_par!(6),
                7 => set_par!(7),
                8 => set_par!(8),
                9 => set_par!(9),
                10 => set_par!(10),
                11 => set_par!(11),
                12 => set_par!(12),
                13 => set_par!(13),
                14 => set_par!(14),
                _ => set_par!(15),
            }?
        }
        Op::Add if ecrit => choisir_alu::<ADD>(largeur, forme, adresse),
        Op::Or if ecrit => choisir_alu::<OR>(largeur, forme, adresse),
        Op::And if ecrit => choisir_alu::<AND>(largeur, forme, adresse),
        Op::Sub if ecrit => choisir_alu::<SUB>(largeur, forme, adresse),
        Op::Xor if ecrit => choisir_alu::<XOR>(largeur, forme, adresse),
        Op::Cmp if !ecrit => choisir_alu::<CMP>(largeur, forme, adresse),
        Op::Test if !ecrit => choisir_alu::<TEST>(largeur, forme, adresse),
        Op::Inc | Op::Dec | Op::Not | Op::Neg
            if instruction.memory.is_none() && !instruction.immediate && ecrit =>
        {
            match instruction.op {
                Op::Inc => par_largeur!(largeur, unaire, [INC], []),
                Op::Dec => par_largeur!(largeur, unaire, [DEC], []),
                Op::Not => par_largeur!(largeur, unaire, [NOT], []),
                _ => par_largeur!(largeur, unaire, [NEG], []),
            }
        }
        Op::Inc | Op::Dec | Op::Not | Op::Neg if forme == MR && !instruction.immediate && ecrit => {
            choisir_unaire_memoire(instruction.op, largeur, adresse)
        }
        Op::Rol | Op::Ror if instruction.memory.is_none() && ecrit => {
            match (instruction.op, instruction.count_is_cl) {
                (Op::Rol, false) => par_largeur!(largeur, rotation, [true], [false]),
                (Op::Rol, true) => par_largeur!(largeur, rotation, [true], [true]),
                (_, false) => par_largeur!(largeur, rotation, [false], [false]),
                (_, true) => par_largeur!(largeur, rotation, [false], [true]),
            }
        }
        Op::ByteSwap if forme == RR => match largeur {
            Width::Word => renverser::<2>,
            Width::Dword => renverser::<4>,
            Width::Qword => renverser::<8>,
            Width::Byte => return None,
        },
        Op::Exchange if forme == RR => par_largeur!(largeur, echange_registres, [], []),
        Op::WidenAccumulator => match (largeur, source) {
            (Width::Word, Width::Byte) => elargir::<2, 1>,
            (Width::Dword, Width::Word) => elargir::<4, 2>,
            (Width::Qword, Width::Dword) => elargir::<8, 4>,
            _ => return None,
        },
        Op::JumpIndirect if largeur == Width::Qword => match (forme, adresse) {
            (RR, _) => saut_indirect::<false, GENERALE>,
            (MR, BASE) => saut_indirect::<true, BASE>,
            (MR, INDEXEE) => saut_indirect::<true, INDEXEE>,
            (MR, RELATIVE) => saut_indirect::<true, RELATIVE>,
            (MR, _) => saut_indirect::<true, GENERALE>,
            _ => return None,
        },
        Op::CallIndirect if largeur == Width::Qword => match (forme, adresse) {
            (RR, _) => appel_indirect::<false, GENERALE>,
            (MR, BASE) => appel_indirect::<true, BASE>,
            (MR, INDEXEE) => appel_indirect::<true, INDEXEE>,
            (MR, RELATIVE) => appel_indirect::<true, RELATIVE>,
            (MR, _) => appel_indirect::<true, GENERALE>,
            _ => return None,
        },
        Op::Shl | Op::Shr | Op::Sar if instruction.memory.is_none() && ecrit => {
            match (instruction.op, instruction.count_is_cl) {
                (Op::Shl, false) => par_largeur!(largeur, decalage, [SHL], [false]),
                (Op::Shl, true) => par_largeur!(largeur, decalage, [SHL], [true]),
                (Op::Shr, false) => par_largeur!(largeur, decalage, [SHR], [false]),
                (Op::Shr, true) => par_largeur!(largeur, decalage, [SHR], [true]),
                (_, false) => par_largeur!(largeur, decalage, [SAR], [false]),
                (_, true) => par_largeur!(largeur, decalage, [SAR], [true]),
            }
        }
        Op::Mov => match forme {
            RR => par_deux_largeurs!(largeur, source, transfert_registre, [false])?,
            RI => par_deux_largeurs!(largeur, source, transfert_registre, [true])?,
            RM | MR | MI => transfert(instruction, forme, adresse)?,
            _ => return None,
        },
        Op::Movsx => match forme {
            RR => par_deux_largeurs!(largeur, source, extension_registre, [])?,
            RM => transfert(instruction, forme, adresse)?,
            _ => return None,
        },
        Op::Lea => transfert(instruction, forme, adresse)?,
        Op::Nop => nop,
        Op::Jump(Some(condition)) => choisir_jcc(condition),
        Op::Jump(None) => jmp,
        Op::Call => call,
        Op::Return => ret,
        Op::Push if instruction.memory.is_none() => {
            if instruction.immediate {
                match largeur {
                    Width::Qword => push_immediat::<8>,
                    Width::Word => push_immediat::<2>,
                    _ => return None,
                }
            } else if largeur == Width::Qword {
                push_registre
            } else {
                return None;
            }
        }
        Op::Pop if instruction.memory.is_none() => pop_registre,
        _ => return None,
    })
}
