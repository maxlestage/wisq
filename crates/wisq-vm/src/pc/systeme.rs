//! **L'état de système du processeur, et ce qui s'en sert** : les tables de
//! descripteurs, le registre de tâche, les registres spécifiques au modèle,
//! `CPUID`, la livraison des interruptions et des fautes en mode long,
//! `iretq`, `syscall` et `sysretq` — le port de `X86Interrupts.swift`,
//! `X86SystemCalls.swift`, `X86SystemState.swift` et des instructions de
//! système de `X86Paging.swift`.
//!
//! **Pourquoi la livraison est là.** Le décompresseur 64 bits de Linux ne
//! cartographie pas toute la mémoire d'avance : il pose une IDT dont un seul
//! vecteur est rempli — le quatorze, la faute de page — et s'en sert pour
//! étendre l'identité à la demande. Un cœur sans livraison s'arrête sur la
//! première adresse que le noyau n'a pas encore cartographiée, et l'arrêt
//! ressemble à une divergence alors que c'est le fonctionnement normal.

use std::collections::BTreeMap;

use crate::x86::{Cpu, Width, IF, WRITABLE_FLAGS};
use crate::x86_paging::{is_canonical, Unmapped};

/// `IA32_EFER` et ses bits.
pub const MSR_EFER: u32 = 0xC000_0080;
pub const EFER_SCE: u64 = 1 << 0;
pub const EFER_LME: u64 = 1 << 8;
pub const EFER_LMA: u64 = 1 << 10;
/// Les quatre registres de l'appel système.
pub const MSR_STAR: u32 = 0xC000_0081;
pub const MSR_LSTAR: u32 = 0xC000_0082;
pub const MSR_CSTAR: u32 = 0xC000_0083;
pub const MSR_SFMASK: u32 = 0xC000_0084;
/// Les bases des deux segments qui en gardent une en mode long, et celle que
/// `swapgs` échange.
pub const MSR_FS_BASE: u32 = 0xC000_0100;
pub const MSR_GS_BASE: u32 = 0xC000_0101;
pub const MSR_KERNEL_GS_BASE: u32 = 0xC000_0102;
pub const MSR_TSC_AUX: u32 = 0xC000_0103;

/// Les drapeaux que la livraison éteint, en plus de celui d'interruption.
const TRAPPE: u64 = 1 << 8;
const IMBRIQUEE: u64 = 1 << 14;
const REPRISE: u64 = 1 << 16;
/// Le niveau de privilège des entrées-sorties, bits 12 et 13 de RFLAGS.
pub const IOPL: u64 = 3 << 12;

/// Une table de descripteurs : sa base, et sa limite — le dernier octet
/// valide.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Table {
    pub base: u64,
    pub limite: u64,
}

/// Une faute que le processeur lève et que le noyau invité traite.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Exception {
    /// `#DE`, vecteur 0 : un diviseur nul, ou un quotient qui ne tient pas.
    Division,
    /// `#UD`, vecteur 6 : `ud2`, ou une instruction que ce processeur n'a pas.
    Indefinie,
    /// `#SS`, vecteur 12, avec son code d'erreur : en mode long, une
    /// référence par la pile à une adresse qui n'est pas canonique (code 0).
    SegmentDePile(u64),
    /// `#GP`, vecteur 13, avec son code d'erreur.
    ProtectionGenerale(u64),
    /// `#PF`, vecteur 14 : l'adresse va dans CR2, le code dit pourquoi.
    FauteDePage { adresse: u64, code: u64 },
    /// `#MF`, vecteur 16 : une exception du x87 que le mot de contrôle ne
    /// masque pas, en attente, livrée à l'instruction du x87 (ou du MMX, ou
    /// `fwait`) qui suit. Sans code d'erreur.
    Flottant,
    /// `#XM`, vecteur 19 : une exception flottante de SSE que MXCSR ne
    /// masque pas, sous CR4.OSXMMEXCPT. Sans code d'erreur.
    FlottantSimd,
}

impl Exception {
    pub fn vecteur(&self) -> u8 {
        match self {
            Self::Division => 0,
            Self::Indefinie => 6,
            Self::SegmentDePile(_) => 12,
            Self::ProtectionGenerale(_) => 13,
            Self::FauteDePage { .. } => 14,
            Self::Flottant => 16,
            Self::FlottantSimd => 19,
        }
    }

    /// **Le code d'erreur que cette faute empile, ou `None` quand elle n'en
    /// empile pas.** Le gestionnaire compte dessus pour retrouver son cadre :
    /// en oublier un, ou en ajouter un, décale toute la pile.
    ///
    /// C'est la **faute** qui porte un code, pas le numéro du vecteur : une
    /// interruption de matériel ou un `int n` qui arrivent sur le vecteur
    /// treize n'en empilent pas. Un 8259 laissé à sa base d'origine livre
    /// l'horloge au vecteur huit, celui de la double faute ; lui prêter un
    /// code d'erreur ferait repartir son `iretq` sur une adresse qui n'en est
    /// pas une.
    pub fn code(&self) -> Option<u64> {
        match self {
            Self::SegmentDePile(code)
            | Self::ProtectionGenerale(code)
            | Self::FauteDePage { code, .. } => Some(*code),
            Self::Division | Self::Indefinie | Self::Flottant | Self::FlottantSimd => None,
        }
    }
}

/// Pourquoi une livraison n'a pas eu lieu.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Livraison {
    /// Pas d'IDT, une limite trop courte, ou une porte absente. Une
    /// interruption de matériel reste alors en attente : le noyau la trouvera
    /// quand il aura posé sa porte.
    SansPorte,
    /// `int n` depuis un anneau que la porte n'admet pas : `#GP`.
    Privilege,
    /// Un changement de pile sans TSS chargé, ou trop court pour le porter.
    SansTss,
    /// La porte, le TSS ou la pile du gestionnaire ne sont pas accessibles.
    Memoire(Unmapped),
}

/// Ce qu'une porte d'interruption dit : où aller, sous quel sélecteur, et de
/// quel genre — porte d'interruption (0xE, qui masque les interruptions en
/// entrant) ou porte de trappe (0xF, qui ne les masque pas).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Porte {
    pub cible: u64,
    pub selecteur: u16,
    pub genre: u8,
    /// Le numéro de pile d'interruption, de un à sept, ou zéro pour « aucune ».
    /// Linux s'en sert pour les fautes qui peuvent arriver alors que la pile
    /// du noyau est justement le problème — la double faute, la NMI.
    pub pile_d_interruption: u8,
    /// L'anneau le moins privilégié qui a le droit d'y entrer par `int n`.
    pub privilege: u8,
}

/// Là où le mode long range les piles, dans le segment d'état de tâche : RSP0
/// à quatre, IST1 à 0x24, de huit en huit. Le dernier octet qu'une de ces
/// lectures peut toucher est la fin d'IST7.
const DERNIER_OCTET_DU_TSS: u64 = 0x24 + 6 * 8 + 7;

/// L'état de système d'un processeur x86-64, hors de ce que `Cpu` porte déjà
/// (les registres de contrôle, EFER, les sélecteurs, les bases de FS et GS).
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Systeme {
    pub gdt: Table,
    pub idt: Table,
    /// Le registre de tâche : le sélecteur, et ce que `ltr` a recopié du
    /// descripteur.
    pub tache: u16,
    pub base_de_tache: u64,
    pub limite_de_tache: u64,
    pub ldt: u16,
    /// `IA32_KERNEL_GS_BASE` : ce que `swapgs` échange avec la base de GS.
    pub gs_du_noyau: u64,
    pub star: u64,
    pub lstar: u64,
    pub cstar: u64,
    pub masque_d_appel: u64,
    pub tsc_aux: u64,
    /// Les autres registres spécifiques au modèle : ce qu'on y écrit s'y
    /// relit, et un registre jamais écrit rend zéro — la règle du cœur Swift.
    pub autres: BTreeMap<u32, u64>,
    pub debug: [u64; 8],
}

impl Systeme {
    /// Lire un registre spécifique au modèle.
    pub fn lire_msr(&self, cpu: &Cpu, numero: u32) -> u64 {
        match numero {
            MSR_EFER => cpu.efer,
            MSR_STAR => self.star,
            MSR_LSTAR => self.lstar,
            MSR_CSTAR => self.cstar,
            MSR_SFMASK => self.masque_d_appel,
            MSR_FS_BASE => cpu.fs_base,
            MSR_GS_BASE => cpu.gs_base,
            MSR_KERNEL_GS_BASE => self.gs_du_noyau,
            MSR_TSC_AUX => self.tsc_aux,
            autre => self.autres.get(&autre).copied().unwrap_or(0),
        }
    }

    /// Écrire un registre spécifique au modèle.
    pub fn ecrire_msr(&mut self, cpu: &mut Cpu, numero: u32, valeur: u64) {
        match numero {
            MSR_EFER => {
                cpu.efer = valeur;
                rafraichir_le_mode_long(cpu);
                // NXE change ce que les traductions gardées veulent dire.
                cpu.flush_translations();
            }
            MSR_STAR => self.star = valeur,
            MSR_LSTAR => self.lstar = valeur,
            MSR_CSTAR => self.cstar = valeur,
            MSR_SFMASK => self.masque_d_appel = valeur,
            MSR_FS_BASE => cpu.fs_base = valeur,
            MSR_GS_BASE => cpu.gs_base = valeur,
            MSR_KERNEL_GS_BASE => self.gs_du_noyau = valeur,
            MSR_TSC_AUX => self.tsc_aux = valeur,
            autre => {
                self.autres.insert(autre, valeur);
            }
        }
    }

    /// **La porte du vecteur, lue dans l'IDT que le noyau a chargée.**
    pub fn porte(&self, cpu: &mut Cpu, vecteur: u8) -> Result<Porte, Livraison> {
        let position = u64::from(vecteur) * 16;
        // La limite est le dernier octet valide : une porte doit tenir
        // **entièrement** dedans.
        if self.idt.limite < 15 || position + 15 > self.idt.limite {
            return Err(Livraison::SansPorte);
        }
        let entree = self.idt.base.wrapping_add(position);
        let bas = lire(cpu, entree)?;
        let haut = lire(cpu, entree.wrapping_add(8))?;
        if bas & (1 << 47) == 0 {
            return Err(Livraison::SansPorte);
        }
        // Le décalage est en trois morceaux, dispersés par l'héritage du 386 :
        // les seize bits du bas, les seize du milieu tout en haut du mot bas,
        // et les trente-deux du haut dans le mot suivant.
        let cible = (bas & 0xFFFF) | ((bas >> 32) & 0xFFFF_0000) | ((haut & 0xFFFF_FFFF) << 32);
        Ok(Porte {
            cible,
            selecteur: (bas >> 16) as u16,
            genre: ((bas >> 40) & 0x0F) as u8,
            pile_d_interruption: ((bas >> 32) & 0x07) as u8,
            privilege: ((bas >> 45) & 0x03) as u8,
        })
    }

    /// **`ltr`** : recopier la base et la limite du segment d'état de tâche
    /// depuis son descripteur. Il fait **seize** octets en mode long, ce qui
    /// permet à sa base d'être une adresse de soixante-quatre bits.
    pub fn charger_la_tache(&mut self, cpu: &mut Cpu, selecteur: u16) -> Result<(), Exception> {
        // Un sélecteur nul ne désigne rien, et un sélecteur hors de la GDT non
        // plus : le silicium lève `#GP` avec le sélecteur pour code.
        let position = u64::from(selecteur & !7);
        if position == 0 || position + 15 > self.gdt.limite {
            return Err(Exception::ProtectionGenerale(u64::from(selecteur & !3)));
        }
        let entree = self.gdt.base.wrapping_add(position);
        // Un descripteur dans une page absente : la faute de page nomme
        // l'adresse du mot qui manque, pas zéro.
        let mut mots = [0u64; 2];
        for (rang, mot) in mots.iter_mut().enumerate() {
            let adresse = entree.wrapping_add(8 * rang as u64);
            *mot = cpu
                .read_memory_as_machine(adresse, Width::Qword)
                .map_err(|_| faute_du_dernier_acces(cpu, false))?;
        }
        let [bas, haut] = mots;
        self.base_de_tache =
            ((bas >> 16) & 0xFF_FFFF) | (((bas >> 56) & 0xFF) << 24) | ((haut & 0xFFFF_FFFF) << 32);
        let mut limite = (bas & 0xFFFF) | (((bas >> 48) & 0x0F) << 16);
        // Le bit de granularité : la limite compte des pages de quatre
        // kibioctets, et le dernier octet valide est celui du haut de la
        // dernière page.
        if bas & (1 << 55) != 0 {
            limite = (limite << 12) | 0xFFF;
        }
        self.limite_de_tache = limite;
        self.tache = selecteur;
        Ok(())
    }

    /// La base d'un segment de données, lue dans son descripteur de la GDT :
    /// ce que charger FS ou GS avec un sélecteur non nul pose comme base.
    pub fn base_du_descripteur(&self, cpu: &mut Cpu, selecteur: u16) -> Option<u64> {
        let position = u64::from(selecteur & !7);
        if selecteur & 4 != 0 || position == 0 || position + 7 > self.gdt.limite {
            return None;
        }
        let bas = lire(cpu, self.gdt.base.wrapping_add(position)).ok()?;
        Some(((bas >> 16) & 0xFF_FFFF) | (((bas >> 56) & 0xFF) << 24))
    }

    /// La pile sur laquelle le processeur doit poser le cadre, ou `None` quand
    /// c'est celle qu'on a déjà.
    ///
    /// **Deux raisons d'en changer, et elles ne se recouvrent pas.** Une porte
    /// qui nomme une pile d'interruption l'impose toujours ; sinon, on change
    /// seulement si le niveau de privilège baisse — une interruption prise en
    /// anneau trois ne s'empile pas sur la pile du programme.
    fn pile_pour(&self, cpu: &mut Cpu, porte: &Porte) -> Result<Option<u64>, Livraison> {
        let cible = (porte.selecteur & 3) as u8;
        if porte.pile_d_interruption == 0 && cible >= cpu.privilege() {
            return Ok(None);
        }
        // Le segment doit être assez long pour porter ce qu'on va y lire. Un
        // registre de tâche jamais chargé a une limite nulle (`ltr` refuse le
        // sélecteur nul) : la même comparaison le refuse.
        if self.limite_de_tache < DERNIER_OCTET_DU_TSS {
            return Err(Livraison::SansTss);
        }
        let ou = if porte.pile_d_interruption != 0 {
            0x24 + u64::from(porte.pile_d_interruption - 1) * 8
        } else {
            4 + u64::from(cible) * 8
        };
        lire(cpu, self.base_de_tache.wrapping_add(ou)).map(Some)
    }

    /// **Entrer dans le gestionnaire d'un vecteur.** C'est le même chemin pour
    /// une faute, une interruption de matériel et un `int n` (`logicielle`) ;
    /// seuls le vecteur, le code d'erreur — `Some` pour une faute qui en
    /// empile un, `None` pour tout le reste — et le contrôle du privilège de
    /// la porte changent.
    ///
    /// **RIP doit déjà valoir l'adresse à empiler** : celle de l'instruction
    /// fautive pour une faute, celle de la suivante pour un `int n` et pour
    /// une interruption.
    ///
    /// Si la livraison échoue, rien n'a changé : ni la pile, ni les
    /// sélecteurs, ni RIP.
    pub fn entrer(
        &self,
        cpu: &mut Cpu,
        vecteur: u8,
        code: Option<u64>,
        logicielle: bool,
    ) -> Result<(), Livraison> {
        let porte = self.porte(cpu, vecteur)?;
        if logicielle && porte.privilege < cpu.privilege() {
            return Err(Livraison::Privilege);
        }
        // Le cadre du mode long : toujours SS et RSP, même sans changement de
        // privilège. Ce qu'on empile, c'est la pile **d'avant**, lue ici avant
        // tout changement : c'est elle que l'`iretq` rendra.
        let pile = cpu.regs[4];
        let ss = cpu.segments[2];
        let cs = cpu.segments[1];
        let drapeaux = cpu.flags.read();
        let nouvelle = self.pile_pour(cpu, &porte)?;
        // Le sélecteur de pile devient nul en même temps que la pile change,
        // comme le fait le processeur.
        if let Some(nouvelle) = nouvelle {
            cpu.regs[4] = nouvelle;
            cpu.segments[2] = 0;
        }
        // **Et l'anneau change avant les empilements, pas après.** Le cadre
        // s'écrit sur la pile du noyau, qui est interdite aux programmes ; le
        // processeur y écrit parce qu'il est déjà passé en anneau zéro.
        cpu.segments[1] = porte.selecteur;
        let mut pointeur = cpu.regs[4] & !0xF;
        let mut cadre = [
            u64::from(ss),
            pile,
            drapeaux,
            u64::from(cs),
            cpu.rip,
            code.unwrap_or(0),
        ];
        let mots = if code.is_some() { 6 } else { 5 };
        for mot in &mut cadre[..mots] {
            pointeur = pointeur.wrapping_sub(8);
            if let Err(pourquoi) = cpu.write_memory(pointeur, Width::Qword, *mot) {
                // La pile du gestionnaire n'est pas là : on défait tout, et
                // l'appelant nomme l'arrêt.
                cpu.faulted = false;
                cpu.unmapped = None;
                cpu.regs[4] = pile;
                cpu.segments[2] = ss;
                cpu.segments[1] = cs;
                return Err(Livraison::Memoire(pourquoi));
            }
        }
        cpu.regs[4] = pointeur;
        cpu.rip = porte.cible;
        // Une porte d'interruption masque les interruptions en entrant ; une
        // porte de trappe les laisse. Le pas-à-pas et la reprise s'éteignent
        // dans les deux cas.
        let mut apres = drapeaux & !(TRAPPE | IMBRIQUEE | REPRISE);
        if porte.genre == 0x0E {
            apres &= !IF;
        }
        cpu.flags.write(apres);
        Ok(())
    }

    /// **`iretq`** : défaire le cadre et repartir où on en était. Les cinq
    /// mots sont lus avant que rien ne change : une faute au milieu du cadre
    /// laisse la machine telle qu'elle était.
    ///
    /// Le code d'erreur, lui, n'est **pas** dépilé par le processeur : c'est
    /// au gestionnaire de le faire.
    pub fn retour_d_interruption(&self, cpu: &mut Cpu) -> Result<(), Exception> {
        let sommet = cpu.regs[4];
        let mut cadre = [0u64; 5];
        for (rang, mot) in cadre.iter_mut().enumerate() {
            *mot = depiler(cpu, sommet, rang as u64)?;
        }
        let [rip, cs, drapeaux, pile, ss] = cadre;
        // **Un retour ne monte jamais en privilège.** Un programme qui
        // fabriquerait un cadre pour revenir « en anneau zéro » reçoit `#GP`.
        let anneau = cpu.privilege();
        if ((cs & 3) as u8) < anneau {
            return Err(Exception::ProtectionGenerale(cs & 0xFFFC));
        }
        // Une cible qui n'est pas canonique faute sur l'`iretq`, pas après.
        if !is_canonical(rip) {
            return Err(Exception::ProtectionGenerale(0));
        }
        cpu.rip = rip;
        cpu.segments[1] = cs as u16;
        cpu.flags
            .write(drapeaux_permis(cpu.flags.read(), drapeaux, anneau));
        cpu.regs[4] = pile;
        cpu.segments[2] = ss as u16;
        cpu.jumped = true;
        Ok(())
    }

    /// **`lretq`** : dépiler RIP puis CS, et — quand le retour descend vers un
    /// anneau moins privilégié — RSP et SS, qui suivent sur la pile. Tout est
    /// lu avant que rien ne change.
    ///
    /// **Un retour ne monte jamais en privilège**, pas plus que par `iretq` :
    /// sans cette garde, un programme empilait un sélecteur de l'anneau zéro
    /// et s'y retrouvait. Linux ne s'en sert qu'à anneau égal, pour changer
    /// de CS au démarrage.
    pub fn retour_lointain(&self, cpu: &mut Cpu) -> Result<(), Exception> {
        let sommet = cpu.regs[4];
        let rip = depiler(cpu, sommet, 0)?;
        let cs = depiler(cpu, sommet, 1)?;
        let anneau = cpu.privilege();
        let demande = (cs & 3) as u8;
        if demande < anneau {
            return Err(Exception::ProtectionGenerale(cs & 0xFFFC));
        }
        if !is_canonical(rip) {
            return Err(Exception::ProtectionGenerale(0));
        }
        if demande > anneau {
            let pile = depiler(cpu, sommet, 2)?;
            let ss = depiler(cpu, sommet, 3)?;
            cpu.regs[4] = pile;
            cpu.segments[2] = ss as u16;
        } else {
            cpu.regs[4] = sommet.wrapping_add(16);
        }
        cpu.segments[1] = cs as u16;
        cpu.rip = rip;
        cpu.jumped = true;
        Ok(())
    }

    /// **`syscall`** : entrer dans le noyau sans passer par l'IDT. L'adresse
    /// de retour va dans RCX, les drapeaux dans R11, le segment et la cible
    /// viennent des MSR. **Elle ne change pas de pile.**
    pub fn appel_systeme(&self, cpu: &mut Cpu, longueur: usize) -> Result<(), Exception> {
        if cpu.efer & EFER_SCE == 0 {
            return Err(Exception::Indefinie);
        }
        let drapeaux = cpu.flags.read();
        cpu.regs[1] = cpu.rip.wrapping_add(longueur as u64);
        cpu.regs[11] = drapeaux;
        cpu.flags.write(drapeaux & !self.masque_d_appel & !REPRISE);
        let entree = (self.star >> 32) as u16;
        cpu.segments[1] = entree & !3;
        cpu.segments[2] = entree.wrapping_add(8) & !3;
        cpu.rip = self.lstar;
        cpu.jumped = true;
        Ok(())
    }

    /// **`sysretq`** : rendre la main au programme, sous le second sélecteur
    /// de STAR.
    pub fn retour_systeme(&self, cpu: &mut Cpu) -> Result<(), Exception> {
        if cpu.efer & EFER_SCE == 0 {
            return Err(Exception::Indefinie);
        }
        if cpu.privilege() != 0 {
            return Err(Exception::ProtectionGenerale(0));
        }
        let sortie = (self.star >> 48) as u16;
        cpu.rip = cpu.regs[1];
        cpu.flags
            .write(cpu.regs[11] & WRITABLE_FLAGS & !(REPRISE | IMBRIQUEE));
        cpu.segments[1] = sortie.wrapping_add(16) | 3;
        cpu.segments[2] = sortie.wrapping_add(8) | 3;
        cpu.jumped = true;
        Ok(())
    }
}

/// **Ce qu'un `popf` ou un `iretq` a le droit de changer dans RFLAGS**, selon
/// l'anneau qui l'exécute : IOPL ne se change qu'en anneau zéro, et le drapeau
/// d'interruption seulement si l'anneau ne dépasse pas IOPL. Le reste suit le
/// masque des bits inscriptibles.
pub fn drapeaux_permis(anciens: u64, demandes: u64, anneau: u8) -> u64 {
    let mut nouveaux = demandes & WRITABLE_FLAGS;
    if anneau > 0 {
        nouveaux = (nouveaux & !IOPL) | (anciens & IOPL);
        if u64::from(anneau) > (anciens & IOPL) >> 12 {
            nouveaux = (nouveaux & !IF) | (anciens & IF);
        }
    }
    nouveaux
}

/// LMA suit LME et la pagination : le mode long est actif quand il est demandé
/// et que la pagination est allumée.
pub fn rafraichir_le_mode_long(cpu: &mut Cpu) {
    if cpu.efer & EFER_LME != 0 && cpu.paging() {
        cpu.efer |= EFER_LMA;
    } else {
        cpu.efer &= !EFER_LMA;
    }
}

/// Une lecture que le processeur fait pour son compte, en anneau zéro.
fn lire(cpu: &mut Cpu, adresse: u64) -> Result<u64, Livraison> {
    let lu = cpu.read_memory_as_machine(adresse, Width::Qword);
    // La lecture a levé `faulted` ; ce n'est pas l'instruction en cours qui
    // faute, c'est la livraison, et l'appelant en décide.
    lu.map_err(|pourquoi| {
        cpu.faulted = false;
        cpu.unmapped = None;
        Livraison::Memoire(pourquoi)
    })
}

/// Le mot de rang `rang` d'un cadre posé à `sommet`, lu avec les droits de
/// l'anneau courant — ce que `iretq` et `lretq` dépilent.
fn depiler(cpu: &mut Cpu, sommet: u64, rang: u64) -> Result<u64, Exception> {
    match cpu.read_memory(sommet.wrapping_add(8 * rang), Width::Qword) {
        Ok(valeur) => Ok(valeur),
        Err(_) => Err(faute_du_dernier_acces(cpu, true)),
    }
}

/// **La faute que le dernier accès refusé de `cpu` demande**, témoins
/// effacés : une faute de page, ou — pour une adresse qui n'est pas
/// canonique, que les tables ne savent pas nommer — `#SS(0)` quand l'accès
/// passait `par_la_pile`, `#GP(0)` sinon. Une cible de saut refusée rend
/// toujours `#GP(0)`.
///
/// **Les témoins effacés ne sont pas un détail** : `faute_d_execution`
/// regarde `unmapped` avant tout le reste, et un témoin resté là ferait
/// d'une division par zéro, plus tard, une faute de page.
pub fn faute_du_dernier_acces(cpu: &mut Cpu, par_la_pile: bool) -> Exception {
    let pourquoi = cpu.unmapped.take();
    cpu.faulted = false;
    match pourquoi {
        Some(Unmapped::NonCanonical { .. }) if par_la_pile => {
            return Exception::SegmentDePile(0);
        }
        Some(Unmapped::NonCanonical { .. } | Unmapped::NonCanonicalTarget { .. }) => {
            return Exception::ProtectionGenerale(0);
        }
        _ => {}
    }
    Exception::FauteDePage {
        adresse: pourquoi.map_or(0, |pourquoi| pourquoi.address()),
        code: cpu.fault_code,
    }
}

/// **Ce que `CPUID` annonce.** Une promesse, pas une lecture : chaque bit mis
/// dit au noyau « tu peux utiliser ça », et il le croit sur parole.
///
/// **Le nom et la signature sont ceux du cœur Swift** — `AuthenticAMD`,
/// famille 15, modèle 107 — pour que le noyau prenne les mêmes chemins sur
/// les deux cœurs, et que leurs comptes d'instructions se comparent. (D'après
/// les sources de Linux, et sans l'avoir mesuré ici : un fournisseur inconnu
/// est tenu pour vulnérable à Meltdown, et le noyau isole alors ses tables de
/// pages à chaque entrée.)
///
/// **Les capacités sont celles de x86-64-v2** : le coprocesseur, PSE, TSC,
/// MSR, PAE, CX8, PGE, CMOV, MMX, FXSR, SSE, SSE2, SSE3, SSSE3, SSE4.1,
/// SSE4.2, POPCNT, `cmpxchg16b`, LAHF/SAHF en mode long, et le mode long. La
/// glibc de RHEL 9 (AlmaLinux, Rocky) refuse de démarrer sans eux ; chacune
/// de leurs instructions est jugée contre le silicium (`x86_v2_host`). Ni
/// AVX, ni BMI, ni AES, ni XSAVE : ce cœur ne les exécute pas, et une glibc
/// ou un noyau choisissent leurs routines d'après ces bits.
///
/// **`rdrand` et `rdseed` sont annoncés**, parce que la machine a une source
/// (`machine::Alea`) : sans eux le générateur du noyau n'est pas prêt avant
/// le shell, et tout programme qui lui demande un nombre attend.
///
/// **Les chaînes rapides sont annoncées** (ERMS, FSRM, FSRS), comme le fait le
/// cœur Swift : ce n'est pas une instruction de plus, c'est dire que `rep
/// movsb` et `rep stosb` sont le bon `memcpy` — ce qui est vrai ici plus
/// qu'ailleurs, puisqu'un `rep` copie une page d'un coup.
pub fn cpuid(feuille: u32, sous_feuille: u32) -> [u32; 4] {
    const NOM: &[u8; 12] = b"AuthenticAMD";
    const MARQUE: &[u8] = b"wisq x86-64 (coeur Rust)";
    let mot = |octets: &[u8], ou: usize| {
        (0..4).fold(0u32, |mot, rang| {
            mot | u32::from(octets.get(ou + rang).copied().unwrap_or(0)) << (8 * rang)
        })
    };
    match feuille {
        // EAX : la plus haute feuille de base ; le nom dans EBX, EDX, ECX.
        0 => [7, mot(NOM, 0), mot(NOM, 8), mot(NOM, 4)],
        1 => [0x0006_0FB1, 0, CAPACITES_ECX, CAPACITES_EDX],
        7 => match sous_feuille {
            0 => [1, CHAINES_RAPIDES_EBX | RDSEED, 0, CHAINES_RAPIDES_EDX],
            1 => [CHAINES_RAPIDES_SOUS_FEUILLE_UN, 0, 0, 0],
            _ => [0; 4],
        },
        0x8000_0000 => [0x8000_0004, 0, 0, 0],
        0x8000_0001 => [0, 0, LAHF_EN_MODE_LONG, MODE_LONG],
        0x8000_0002..=0x8000_0004 => {
            let base = (feuille - 0x8000_0002) as usize * 16;
            [
                mot(MARQUE, base),
                mot(MARQUE, base + 4),
                mot(MARQUE, base + 8),
                mot(MARQUE, base + 12),
            ]
        }
        _ => [0; 4],
    }
}

/// EDX de la feuille 1 : FPU (0), PSE (3), TSC (4), MSR (5), PAE (6), CX8 (8),
/// PGE (13), CMOV (15), MMX (23), FXSR (24), SSE (25), SSE2 (26).
pub const CAPACITES_EDX: u32 = 1
    | (1 << 3)
    | (1 << 4)
    | (1 << 5)
    | (1 << 6)
    | (1 << 8)
    | (1 << 13)
    | (1 << 15)
    | (1 << 23)
    | (1 << 24)
    | (1 << 25)
    | (1 << 26);
/// ECX de la feuille 1 : SSE3 (0), SSSE3 (9), `cmpxchg16b` (13), SSE4.1
/// (19), SSE4.2 (20), POPCNT (23) et `rdrand` (30) — x86-64-v2.
pub const CAPACITES_ECX: u32 =
    1 | (1 << 9) | (1 << 13) | (1 << 19) | (1 << 20) | (1 << 23) | (1 << 30);
/// ECX de la feuille 0x8000_0001 : LAHF et SAHF en mode long (0).
pub const LAHF_EN_MODE_LONG: u32 = 1;
/// EBX de la feuille 7 : `rdseed` (18).
pub const RDSEED: u32 = 1 << 18;
/// ERMS (feuille 7, EBX bit 9), FSRM (EDX bit 4), FSRS (sous-feuille 1, EAX
/// bit 11).
pub const CHAINES_RAPIDES_EBX: u32 = 1 << 9;
pub const CHAINES_RAPIDES_EDX: u32 = 1 << 4;
pub const CHAINES_RAPIDES_SOUS_FEUILLE_UN: u32 = 1 << 11;
/// EDX de la feuille 0x8000_0001 : le mode long (29).
pub const MODE_LONG: u32 = 1 << 29;
