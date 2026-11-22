//! **Le JIT natif de la machine PC** : les blocs chauds du chemin rapide
//! (`pc::blocs`, `x86::rapide`) traduits en code machine de l'hôte, écrit à
//! la main, sans dépendance.
//!
//! **Ce qu'il traduit.** Un bloc est déjà décodé : ses instructions sont des
//! `Uop`, chacune avec la forme spécialisée qui l'exécute. Le JIT en fait une
//! fonction de l'hôte, d'un seul tenant, qui exécute le bloc entier sans
//! repasser par la boucle de `Machine::parcourir` :
//!
//! - les formes les plus fréquentes — `mov`, `movzx`, `movsx`, `lea`, `add`,
//!   `or`, `and`, `sub`, `xor`, `cmp`, `test`, `inc`, `dec`, `not`, `neg`,
//!   `push`, `pop`, `call`, `ret`, `jmp`, `jcc`, `nop` (`rapide::decrire`) —
//!   sont écrites en instructions de l'hôte, accès mémoire compris : le
//!   tampon de traduction (`x86_paging::Tlb`) est lu par le code engendré
//!   comme `Cpu::fast_place` le lit ;
//! - tout le reste, et chaque cas rare d'une forme écrite (un accès qui
//!   manque le tampon, une cible qui n'est pas canonique, une adresse à
//!   segment), **appelle la forme spécialisée elle-même**, depuis l'état
//!   d'avant l'instruction : rien n'a encore changé quand le code natif
//!   renonce, donc la forme fait exactement ce qu'elle aurait fait.
//!
//! **Ce qui le garde exact** : le code natif fait ce que la forme fait — mêmes
//! registres, même mémoire, mêmes six drapeaux, mêmes fautes —, et la boucle
//! qui l'appelle (`Machine::un_bloc`) garde toutes les gardes du chemin
//! rapide : le tampon de génération du bloc, le budget (un bloc n'est confié
//! au JIT que s'il tient entier dans ce qui reste jusqu'au prochain service du
//! matériel), et la relecture après une écriture. Une écriture par le chemin
//! rapide du tampon ne tombe jamais dans une page de code (`TLB_LIBRE`) ;
//! seule une écriture rendue à une forme peut réécrire le bloc, et c'est
//! après celle-là, comme dans `parcourir`, que la suite du bloc se relit.
//! Jugé par `tests/pc_jit.rs` : des programmes tirés au hasard, avec et sans
//! JIT, contre le pas à pas, instruction retirée pour instruction retirée.
//!
//! **Où il tourne.** Un JIT écrit du code dans une page puis l'exécute : il
//! faut que l'hôte l'accorde. Linux l'accorde ; macOS aussi, par `MAP_JIT`
//! (que le runtime durci n'accorde qu'avec `com.apple.security.cs.allow-jit`).
//! **iOS ne l'accorde à aucune application de l'App Store ni de
//! TestFlight** — seule une application de développement sous débogueur
//! reçoit une page exécutable —, et l'iPhone est arm64, pour lequel ce cœur
//! n'a pas de traducteur : sur iOS, le JIT ne demande rien au système et
//! n'existe pas. Partout où il est refusé (`Jit::nouveau` rend `None`), la
//! machine garde le chemin rapide interprété, au même résultat près — à
//! l'instruction près. Là où il sert aujourd'hui : `wisq-pc`, la fabrique
//! des bureaux prêts (`.github/workflows/bureaux.yml`, sur Linux x86-64), et
//! tout hôte x86-64 qui fait tourner la machine.
//!
//! Le code engendré est celui de l'hôte : x86-64 (`x86_jit_x64.rs`). Sur un
//! autre hôte, `Jit::nouveau` rend `None`.

use super::rapide::{decrire, Gabarit, Suite, Uop, AUCUNE};
use super::{Cpu, Decoded};
use crate::pc::blocs::{Bloc, Traduit, GENERALES};

#[cfg(all(target_arch = "x86_64", unix))]
#[path = "x86_jit_x64.rs"]
mod hote;

/// Une fonction engendrée : elle exécute un bloc entier depuis RIP.
pub type Code = unsafe extern "C" fn(*mut Cpu, *mut Contexte) -> u64;

/// Le bloc s'est exécuté jusqu'à sa fin.
pub const FIN: u64 = 0;
/// L'instruction `rang - 1` a posé RIP (un saut pris) : le bloc s'arrête là.
pub const SAUT: u64 = 1;
/// L'instruction `rang` a fauté sans rien changer.
pub const FAUTE: u64 = 2;
/// Une écriture a touché le bloc : il s'arrête avant l'instruction `rang`.
pub const ARRET: u64 = 3;

/// **Ce que le code engendré lit à côté du processeur**, posé par la boucle
/// avant chaque entrée : le bloc (ses `Uop`, que les appels aux formes
/// désignent), la RAM, et ce qu'il faut pour relire le bloc après une
/// écriture.
#[repr(C)]
pub struct Contexte {
    pub cpu: *mut Cpu,
    pub bloc: *const Bloc,
    /// `cpu.memory.bytes`, son début, sa longueur **arrondie à la page en
    /// dessous** (une trame qui commence avant y tient entière), et l'adresse
    /// physique de son premier octet (`GuestMemory::base`).
    pub ram: *mut u8,
    pub longueur: u64,
    pub base: u64,
    /// L'adresse physique du premier octet du bloc.
    pub debut: u64,
    /// **Le chaînage** (`x86_jit_x64.rs`, la routine `enchainer`) : d'un bloc
    /// traduit au suivant dans la même page sans repasser par la boucle. Ce
    /// qui reste du budget, ce que les blocs déjà finis ont retiré, la case
    /// du bloc courant ; la table des blocs, les générations des pages et
    /// l'époque, pour juger le suivant comme `Blocs::trouver` le jugerait ;
    /// la génération de la zone, pour savoir si son code est d'aujourd'hui.
    pub reste: u64,
    pub deja: u64,
    pub place: u64,
    pub cases: *const Bloc,
    pub generations: *const u32,
    pub pages: u64,
    pub epoque: *const u64,
    pub zone: u64,
    /// Les blocs entrés par chaînage.
    pub enchaines: u64,
    /// **Les droits qu'une case du tampon doit porter**, pour une lecture et
    /// pour une écriture, selon l'anneau de l'entrée (`Cpu::fast_place`) :
    /// aucun bloc ne change d'anneau.
    pub droits_lecture: u32,
    pub droits_ecriture: u32,
}

impl Contexte {
    /// Les droits de `fast_place` pour l'anneau de `cpu` : ceux de
    /// `read_memory_fast`, puis ceux de `write_memory_fast`.
    pub fn droits(cpu: &Cpu) -> (u32, u32) {
        use crate::x86_paging::{TLB_DIRTY, TLB_LIBRE, TLB_USER, TLB_WRITABLE};
        let ecriture = TLB_WRITABLE | TLB_DIRTY | TLB_LIBRE;
        if cpu.segments[1] & 3 == 3 {
            (u32::from(TLB_USER), u32::from(TLB_USER | ecriture))
        } else {
            (0, u32::from(ecriture))
        }
    }
}

/// Les décalages de `Contexte`, pour le code engendré.
pub(crate) mod contexte {
    use super::Contexte;
    pub const BLOC: i32 = std::mem::offset_of!(Contexte, bloc) as i32;
    pub const RAM: i32 = std::mem::offset_of!(Contexte, ram) as i32;
    pub const LONGUEUR: i32 = std::mem::offset_of!(Contexte, longueur) as i32;
    pub const BASE: i32 = std::mem::offset_of!(Contexte, base) as i32;
    pub const DEBUT: i32 = std::mem::offset_of!(Contexte, debut) as i32;
    pub const RESTE: i32 = std::mem::offset_of!(Contexte, reste) as i32;
    pub const DEJA: i32 = std::mem::offset_of!(Contexte, deja) as i32;
    pub const PLACE: i32 = std::mem::offset_of!(Contexte, place) as i32;
    pub const CASES: i32 = std::mem::offset_of!(Contexte, cases) as i32;
    pub const GENERATIONS: i32 = std::mem::offset_of!(Contexte, generations) as i32;
    pub const PAGES: i32 = std::mem::offset_of!(Contexte, pages) as i32;
    pub const EPOQUE: i32 = std::mem::offset_of!(Contexte, epoque) as i32;
    pub const ZONE: i32 = std::mem::offset_of!(Contexte, zone) as i32;
    pub const ENCHAINES: i32 = std::mem::offset_of!(Contexte, enchaines) as i32;
    pub const DROITS_LECTURE: i32 = std::mem::offset_of!(Contexte, droits_lecture) as i32;
    pub const DROITS_ECRITURE: i32 = std::mem::offset_of!(Contexte, droits_ecriture) as i32;
}

/// Les décalages de `Cpu` et de `Bloc` que le code engendré lit.
pub(crate) mod disposition {
    use super::super::{Cpu, Flags};
    use crate::pc::blocs::Bloc;
    pub const REGS: i32 = std::mem::offset_of!(Cpu, regs) as i32;
    pub const RIP: i32 = std::mem::offset_of!(Cpu, rip) as i32;
    pub const CONTROLE: i32 = std::mem::offset_of!(Cpu, control) as i32;
    pub const TLB: i32 = std::mem::offset_of!(Cpu, tlb) as i32;
    pub const DRAPEAUX_OP: i32 =
        (std::mem::offset_of!(Cpu, flags) + std::mem::offset_of!(Flags, op)) as i32;
    pub const DRAPEAUX_ARITH: i32 =
        (std::mem::offset_of!(Cpu, flags) + std::mem::offset_of!(Flags, arithmetic)) as i32;
    pub const UOPS: i32 = std::mem::offset_of!(Bloc, uops) as i32;
    pub const GENERALES: i32 = std::mem::offset_of!(Bloc, generales) as i32;
    pub const TAILLE_UOP: i32 = std::mem::size_of::<super::Uop>() as i32;
    pub const TAILLE_BLOC: i32 = std::mem::size_of::<Bloc>() as i32;
    pub const ETIQUETTE: i32 = std::mem::offset_of!(Bloc, etiquette) as i32;
    pub const EPOQUE: i32 = std::mem::offset_of!(Bloc, epoque) as i32;
    pub const GENERATION: i32 = std::mem::offset_of!(Bloc, generation) as i32;
    pub const NOMBRE: i32 = std::mem::offset_of!(Bloc, nombre) as i32;
    pub const JIT_CODE: i32 = (std::mem::offset_of!(Bloc, jit)
        + std::mem::offset_of!(crate::pc::blocs::Traduit, code))
        as i32;
    pub const JIT_ZONE: i32 = (std::mem::offset_of!(Bloc, jit)
        + std::mem::offset_of!(crate::pc::blocs::Traduit, zone))
        as i32;
}

// `Option<Box<Tlb>>` est un pointeur, nul pour `None` : garanti par le
// langage, et le code engendré le lit comme tel.
const _: () = assert!(
    std::mem::size_of::<Option<Box<crate::x86_paging::Tlb>>>() == std::mem::size_of::<usize>()
);

/// **Appeler une forme depuis le code engendré** : l'ABI de Rust ne se
/// promet pas, celle de C oui. Rend `Suite` en entier : 0, 1 ou 2.
///
/// # Safety
/// Les trois pointeurs viennent de la boucle (`Machine::un_bloc`) : le
/// processeur, une `Uop` du bloc, et ses générales.
unsafe extern "C" fn appeler(cpu: *mut Cpu, uop: *const Uop, generales: *const Decoded) -> u32 {
    // SAFETY: voir plus haut ; rien d'autre ne tient le processeur pendant
    // l'appel, le code engendré ne lit ni n'écrit rien en même temps.
    let (cpu, uop, generales) = unsafe {
        (
            &mut *cpu,
            &*uop,
            std::slice::from_raw_parts(generales, GENERALES),
        )
    };
    match (uop.executer)(cpu, uop, generales) {
        Suite::Suivante => 0,
        Suite::Saut => 1,
        Suite::Faute => 2,
    }
}

/// **Les six bits arithmétiques**, quand ils ne sont pas déjà connus
/// (`rapide::arithmetiques`).
///
/// # Safety
/// `cpu` est le processeur de la boucle.
unsafe extern "C" fn arithmetiques(cpu: *const Cpu) -> u64 {
    // SAFETY: lecture seule du processeur de la boucle.
    unsafe { (*cpu).flags.read() }
}

/// **Après une écriture rendue à une forme, le reste du bloc est-il
/// intact ?** Ce que `parcourir` fait après chaque instruction qui peut
/// écrire : le tampon de la page d'abord, les octets sinon, depuis `octet`.
///
/// # Safety
/// `contexte` est celui que la boucle a posé pour ce bloc.
unsafe extern "C" fn verifier(contexte: *const Contexte, octet: u64) -> u32 {
    // SAFETY: le contexte, le processeur et le bloc vivent le temps de
    // l'appel au code engendré, qui ne les touche pas pendant celui-ci.
    let (cpu, bloc, debut) = unsafe {
        let contexte = &*contexte;
        (&*contexte.cpu, &*contexte.bloc, contexte.debut)
    };
    let tamponne = matches!(
        cpu.code.as_deref(),
        Some(pages) if pages.epoque == bloc.epoque
            && pages.generation(debut) == Some(bloc.generation)
    );
    u32::from(tamponne || bloc.intact_depuis(&cpu.memory.bytes, debut as usize, octet as usize))
}

/// Les adresses des trois fonctions que le code engendré appelle.
pub(crate) struct Appels {
    pub appeler: u64,
    pub arithmetiques: u64,
    pub verifier: u64,
}

fn appels() -> Appels {
    Appels {
        appeler: appeler as *const () as u64,
        arithmetiques: arithmetiques as *const () as u64,
        verifier: verifier as *const () as u64,
    }
}

/// **Une instruction du bloc, telle que le traducteur la voit** : sa `Uop`,
/// son gabarit quand le code natif la refait, l'octet où elle commence, et
/// si elle peut écrire.
pub(crate) struct Instruction {
    pub uop: Uop,
    pub gabarit: Option<Gabarit>,
    pub octet: u32,
    pub ecrit: bool,
}

/// **Préparer un bloc pour le traducteur** : chaque instruction relue sur
/// les octets du bloc, par le décodeur de la machine, pour son gabarit.
fn instructions(bloc: &Bloc, lire: &dyn Fn(&[u8]) -> Option<Decoded>) -> Vec<Instruction> {
    let mut octets = [0u8; 64];
    for (rang, mot) in bloc.octets.iter().enumerate() {
        octets[rang * 8..rang * 8 + 8].copy_from_slice(&mot.to_le_bytes());
    }
    let mut position = 0usize;
    let mut liste = Vec::with_capacity(bloc.nombre as usize);
    for (rang, uop) in bloc.uops[..bloc.nombre as usize].iter().enumerate() {
        let longueur = uop.longueur as usize;
        let gabarit = if uop.generale == AUCUNE {
            octets
                .get(position..position + longueur)
                .and_then(lire)
                .filter(|instruction| instruction.length == longueur)
                .and_then(|instruction| decrire(&instruction))
        } else {
            None
        };
        liste.push(Instruction {
            uop: *uop,
            gabarit,
            octet: position as u32,
            ecrit: bloc.ecrit & (1 << rang) != 0,
        });
        position += longueur;
    }
    liste
}

/// **Les entrées dans un bloc avant de le traduire**, mesuré sur le
/// démarrage d'Alpine (le journal du 22 novembre) : à deux, la traduction
/// coûte plus qu'elle ne rend (395 689 blocs traduits, 14,1 s) ; à 256, des
/// blocs chauds restent interprétés trop longtemps (12,9 s) ; à 32, 12,3 s.
pub const SEUIL: u32 = 32;

/// La place que le code engendré occupe, au plus, avant d'être vidé.
const ZONE: usize = 32 << 20;

/// **Le JIT** : la zone de code, et ce qu'il en a fait (chaque bloc retient
/// son propre code, `Bloc::jit`).
pub struct Jit {
    zone: memoire::Zone,
    /// Les routines au début de la zone, que les blocs appellent.
    #[cfg(all(target_arch = "x86_64", unix))]
    routines: hote::Routines,
    /// Combien de fois la zone a été vidée : une entrée d'une autre
    /// génération n'a plus de code.
    generation: u32,
    /// **Les entrées dans un bloc avant de le traduire.** Un bloc qui ne sert
    /// qu'une fois (le démarrage en est plein) coûterait plus à traduire qu'à
    /// interpréter.
    pub seuil: u32,
    /// Les blocs traduits, et les passages par du code traduit.
    pub traduits: u64,
    pub passages: u64,
    /// Les entrées dans un bloc par chaînage, sans repasser par la boucle.
    pub enchaines: u64,
    pub octets: u64,
}

// SAFETY: la zone appartient au seul `Jit`, qui ne la partage avec personne ;
// la machine qui le porte passe d'un fil à l'autre entière.
unsafe impl Send for Jit {}

impl Jit {
    /// **Un JIT, si l'hôte accorde une page exécutable** et si ce cœur sait
    /// écrire son code machine. `None` sinon : la machine interprète.
    pub fn nouveau() -> Option<Self> {
        if !hote_pris_en_charge() {
            return None;
        }
        let zone = memoire::Zone::nouvelle(ZONE)?;
        let mut jit = Self {
            zone,
            #[cfg(all(target_arch = "x86_64", unix))]
            routines: hote::Routines::vides(),
            generation: 1,
            seuil: SEUIL,
            traduits: 0,
            passages: 0,
            enchaines: 0,
            octets: 0,
        };
        // **Essayer avant de promettre** : une page que l'hôte dit
        // exécutable et qui ne l'est pas tuerait le processus à la première
        // entrée. Un essai minuscule, maintenant, et le JIT n'existe que s'il
        // rend ce qu'on attend.
        if !jit.essayer() || !jit.poser_les_routines() {
            return None;
        }
        Some(jit)
    }

    #[cfg(all(target_arch = "x86_64", unix))]
    fn essayer(&mut self) -> bool {
        // `mov eax, 0x2a ; ret`
        let Some(code) = self.zone.ecrire(&[0xB8, 0x2A, 0, 0, 0, 0xC3]) else {
            return false;
        };
        // SAFETY: six octets de x86-64 qui ne lisent ni n'écrivent rien.
        let essai: unsafe extern "C" fn() -> u32 = unsafe { std::mem::transmute(code) };
        let rendu = unsafe { essai() };
        self.zone.vider();
        rendu == 0x2A
    }

    #[cfg(not(all(target_arch = "x86_64", unix)))]
    fn essayer(&mut self) -> bool {
        false
    }

    /// **Le code de `bloc`**, s'il est traduit dans la zone d'aujourd'hui ;
    /// traduit maintenant s'il vient de passer le seuil. `lire` est le
    /// décodeur de la machine.
    #[inline(always)]
    pub fn code(
        &mut self,
        bloc: &mut Bloc,
        lire: &dyn Fn(&[u8]) -> Option<Decoded>,
    ) -> Option<Code> {
        let traduit = &mut bloc.jit;
        if traduit.zone == self.generation && traduit.code != 0 {
            self.passages += 1;
            // SAFETY: `code` vient de `traduire`, dans la zone de cette
            // génération, pour ce bloc-ci : un bloc reconstruit repart de zéro.
            return Some(unsafe { std::mem::transmute::<usize, Code>(traduit.code) });
        }
        if traduit.zone != self.generation {
            *traduit = Traduit {
                code: 0,
                zone: self.generation,
                compte: 0,
            };
        }
        traduit.compte += 1;
        if traduit.compte < self.seuil {
            return None;
        }
        self.traduire_et_retenir(bloc, lire)
    }

    #[cold]
    #[inline(never)]
    fn traduire_et_retenir(
        &mut self,
        bloc: &mut Bloc,
        lire: &dyn Fn(&[u8]) -> Option<Decoded>,
    ) -> Option<Code> {
        let Some(code) = self.traduire(bloc, lire) else {
            // Ne pas réessayer à chaque entrée.
            bloc.jit.compte = 0;
            return None;
        };
        bloc.jit = Traduit {
            code: code as usize,
            zone: self.generation,
            compte: 0,
        };
        self.traduits += 1;
        self.passages += 1;
        // SAFETY: comme plus haut.
        Some(unsafe { std::mem::transmute::<usize, Code>(code as usize) })
    }

    /// **Traduire un bloc et poser son code dans la zone**, vidée si elle
    /// est pleine : le code est assemblé pour l'adresse où il sera posé (il
    /// appelle les routines par des déplacements relatifs).
    fn traduire(
        &mut self,
        bloc: &Bloc,
        lire: &dyn Fn(&[u8]) -> Option<Decoded>,
    ) -> Option<*const u8> {
        let instructions = instructions(bloc, lire);
        for _ in 0..2 {
            let origine = self.zone.prochaine() as u64;
            let debut = bloc.etiquette.wrapping_sub(1);
            let octets = self.traduire_pour_l_hote(&instructions, origine, debut)?;
            if let Some(code) = self.zone.ecrire(&octets) {
                debug_assert_eq!(code as u64, origine);
                self.octets += octets.len() as u64;
                return Some(code);
            }
            // La zone est pleine : tout ce qu'elle tient est oublié d'un coup.
            self.oublier();
        }
        None
    }

    #[cfg(all(target_arch = "x86_64", unix))]
    fn traduire_pour_l_hote(
        &self,
        instructions: &[Instruction],
        origine: u64,
        debut: u64,
    ) -> Option<Vec<u8>> {
        Some(hote::traduire(
            instructions,
            origine,
            debut,
            &self.routines,
            &appels(),
        ))
    }

    #[cfg(not(all(target_arch = "x86_64", unix)))]
    fn traduire_pour_l_hote(&self, _: &[Instruction], _: u64, _: u64) -> Option<Vec<u8>> {
        None
    }

    /// Les routines, au début d'une zone vide.
    #[cfg(all(target_arch = "x86_64", unix))]
    fn poser_les_routines(&mut self) -> bool {
        let origine = self.zone.prochaine() as u64;
        let (octets, routines) = hote::routines(origine, &appels());
        match self.zone.ecrire(&octets) {
            Some(code) if code as u64 == origine => {
                self.routines = routines;
                true
            }
            _ => false,
        }
    }

    #[cfg(not(all(target_arch = "x86_64", unix)))]
    fn poser_les_routines(&mut self) -> bool {
        false
    }

    /// La génération de la zone, que le chaînage compare à celle d'un bloc.
    pub fn generation(&self) -> u32 {
        self.generation
    }

    /// Oublier tout le code traduit (une machine reprise d'un instantané a
    /// une autre table de blocs).
    pub fn oublier(&mut self) {
        self.zone.vider();
        self.generation = self.generation.wrapping_add(1).max(1);
        let posees = self.poser_les_routines();
        debug_assert!(posees, "les routines tiennent dans une zone vide");
    }
}

fn hote_pris_en_charge() -> bool {
    cfg!(all(target_arch = "x86_64", unix))
}

/// **La mémoire exécutable**, demandée au système sans bibliothèque : `mmap`,
/// `munmap`, et rien d'autre.
mod memoire {
    #[cfg(unix)]
    mod systeme {
        use std::ffi::c_void;
        pub const PROT_READ: i32 = 1;
        pub const PROT_WRITE: i32 = 2;
        pub const PROT_EXEC: i32 = 4;
        pub const MAP_PRIVATE: i32 = 2;
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        pub const MAP_ANON: i32 = 0x1000;
        #[cfg(not(any(target_os = "macos", target_os = "ios")))]
        pub const MAP_ANON: i32 = 0x20;
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        pub const MAP_JIT: i32 = 0x800;
        #[cfg(not(any(target_os = "macos", target_os = "ios")))]
        pub const MAP_JIT: i32 = 0;
        extern "C" {
            pub fn mmap(
                adresse: *mut c_void,
                taille: usize,
                protection: i32,
                drapeaux: i32,
                fichier: i32,
                decalage: i64,
            ) -> *mut c_void;
            pub fn munmap(adresse: *mut c_void, taille: usize) -> i32;
        }
    }

    /// Une zone de code : écrite à la suite, vidée d'un coup.
    pub struct Zone {
        debut: *mut u8,
        taille: usize,
        prise: usize,
    }

    impl Zone {
        /// `taille` octets lisibles, inscriptibles et exécutables, ou rien
        /// si le système les refuse.
        #[cfg(unix)]
        pub fn nouvelle(taille: usize) -> Option<Self> {
            use systeme::*;
            // **iOS n'accorde une page exécutable qu'à un processus sous
            // débogueur**, et ce cœur n'y a de toute façon pas de traducteur
            // (l'iPhone est arm64) : rien n'est demandé au système.
            if cfg!(target_os = "ios") {
                return None;
            }
            // SAFETY: une projection anonyme, sans adresse imposée.
            let debut = unsafe {
                mmap(
                    std::ptr::null_mut(),
                    taille,
                    PROT_READ | PROT_WRITE | PROT_EXEC,
                    MAP_PRIVATE | MAP_ANON | MAP_JIT,
                    -1,
                    0,
                )
            };
            if debut.is_null() || debut as isize == -1 {
                return None;
            }
            Some(Self {
                debut: debut.cast(),
                taille,
                prise: 0,
            })
        }

        #[cfg(not(unix))]
        pub fn nouvelle(_: usize) -> Option<Self> {
            None
        }

        /// Copier du code dans la zone, aligné sur seize octets ; rien si
        /// elle est pleine.
        pub fn ecrire(&mut self, code: &[u8]) -> Option<*const u8> {
            let debut = self.prise.next_multiple_of(16);
            let fin = debut.checked_add(code.len())?;
            if fin > self.taille {
                return None;
            }
            // SAFETY: `debut..fin` est dans la projection, que personne
            // n'exécute pendant qu'on l'écrit (un seul fil, et aucun code de
            // cette plage n'est encore rendu).
            unsafe {
                std::ptr::copy_nonoverlapping(code.as_ptr(), self.debut.add(debut), code.len());
            }
            self.prise = fin;
            Some(self.debut.wrapping_add(debut))
        }

        /// L'adresse où `ecrire` posera son code.
        pub fn prochaine(&self) -> usize {
            self.debut as usize + self.prise.next_multiple_of(16)
        }

        pub fn vider(&mut self) {
            self.prise = 0;
        }
    }

    impl Drop for Zone {
        fn drop(&mut self) {
            #[cfg(unix)]
            // SAFETY: la projection faite par `nouvelle`, de cette taille.
            unsafe {
                systeme::munmap(self.debut.cast(), self.taille);
            }
        }
    }
}
