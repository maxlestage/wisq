//! **Des blocs d'instructions décodées côte à côte**, vérifiés par les
//! générations de leurs pages, et à défaut par comparaison d'octets — le
//! port de `X86BlockCache.swift`, sur le chemin rapide de `x86::rapide`.
//!
//! Le cache de décodage (`Machine::chercher`) range une instruction par case,
//! à l'adresse où elle commence : deux instructions qui se suivent sont à
//! deux endroits d'une table de six mébioctets, et chaque instruction attend
//! sa ligne de cache. Un bloc range à la suite les instructions qui se
//! suivent dans une page — seize au plus, sur soixante-quatre octets au
//! plus —, chacune avec la fonction qui l'exécute (`x86::rapide::preparer`).
//! La boucle le trouve une fois, s'assure une fois que ses octets sont ceux
//! de la mémoire, et exécute ses instructions l'une après l'autre.
//!
//! **Ce qui garde la machine exacte**, et où c'est tenu :
//!
//! - *Un bloc porte un tampon* (`Bloc::epoque`, `Bloc::generation`) : la
//!   génération de sa page quand ses octets ont été lus ou comparés, et
//!   l'époque d'alors (`x86_paging::PagesDeCode`, qui dit ce qui fait
//!   avancer l'une et l'autre). Le même tampon aujourd'hui : rien n'a écrit
//!   sa page, ses octets sont ceux de la mémoire (`Trouve::Juste`). Un autre
//!   : ses octets se comparent (`Bloc::intact`) — un code réécrit par
//!   l'invité, par un périphérique, par le chargeur ne retrouve pas son
//!   bloc, qui est refait ; un code intact est tamponné de nouveau. Rien
//!   n'est à vider.
//! - *Après une instruction qui peut écrire en mémoire* (`pourrait_ecrire`),
//!   la génération de la page se relit, et, si elle a bougé, les octets qui
//!   restent se recomparent avant la suivante : un bloc qui se réécrit
//!   s'arrête là, et la suite se relit (`Machine::bloc`).
//! - *Le budget et le service du matériel à cadence fixe* : la boucle ne
//!   donne à un bloc que ce qui reste jusqu'au prochain multiple de 256
//!   instructions et jusqu'à la fin du budget — le matériel est donc servi
//!   aux mêmes instructions qu'au pas à pas, et l'horloge de l'invité ne voit
//!   aucune différence.
//! - *Aucune instruction de système n'entre dans un bloc* (`blocable`) :
//!   `hlt`, `sti`, `mov cr`, `wrmsr`, `iretq`, `invlpg`… changent l'arrêt,
//!   l'anneau, la pagination, le tampon de traduction. Elles passent par
//!   `Machine::pas`, et un bloc s'arrête devant elles : la page d'instructions
//!   et l'anneau ne changent donc jamais au milieu d'un bloc.
//! - *Rien au-delà de la page* : une instruction à cheval sur deux pages
//!   n'entre dans aucun bloc.
//! - *Un saut pris sort du bloc* : `jmp`, `call`, `ret` le terminent ; un
//!   saut conditionnel non pris continue.
//! - *Une coupure ne reprend que si rien n'a changé* (`Machine::reprendre`) :
//!   l'adresse physique de RIP doit être celle de l'instruction d'après, et
//!   le bloc tamponné, ou ses octets intacts.
//!
//! Le code machine x86-64 a un seul mode ici (la machine ne connaît que le
//! mode long), donc les octets suffisent à dire ce qu'un bloc exécute.
//!
//! **Ce qui le rend rapide**, chaque pas mesuré en courses alternées sur le
//! démarrage d'Alpine (le journal du 20 novembre a les chiffres) : deux cases
//! par adresse (un bloc chassé garde la seconde : quatre fois moins de
//! constructions), la construction sur place, des instructions prêtes de
//! trente-deux octets (`x86::rapide::Uop`) dont les générales vivent au bout
//! du bloc, la reprise après une coupure, et le préchargement des deux blocs
//! qui ont suivi celui-ci (`enchainer`) — une table de vingt-cinq mébioctets
//! ne tient pas dans le cache de l'hôte, et l'entrée dans un bloc attendait
//! sa ligne. Puis (le journal du 22 novembre) : le tampon au lieu de la
//! comparaison à chaque entrée — ni les octets du bloc ni ceux de l'invité
//! ne se lisent plus —, les octets rangés après les instructions, et le bloc
//! sur une ligne de cache.

use crate::x86::rapide::{preparer, Uop, AUCUNE};
use crate::x86::{Decoded, Op, Vector};

/// Les instructions d'un bloc, au plus.
pub const CAPACITE: usize = 16;
/// Les octets qu'un bloc couvre, au plus : huit mots comparés.
pub const PORTEE: usize = 64;
/// Le nombre de cases de la table.
pub const LOGEMENTS: usize = 1 << 15;

/// Un bloc : où il commence, ce qu'il exécute, ce qu'il compare. **Dans
/// cet ordre** (`repr(C)`, sur une ligne de cache) : l'étiquette, le tampon
/// et les deux premières instructions tiennent dans la première ligne, celle
/// qu'une entrée fait venir de toute façon ; les octets comparés, qu'on ne lit
/// plus que quand le tampon ne suffit pas, viennent après les instructions.
#[derive(Clone, Copy)]
#[repr(C, align(64))]
pub struct Bloc {
    /// L'adresse physique du premier octet, plus un : zéro veut dire
    /// « vide ».
    pub etiquette: u64,
    /// **L'époque et la génération de sa page** (`x86_paging::PagesDeCode`)
    /// quand ses octets ont été lus ou comparés pour la dernière fois : les
    /// mêmes aujourd'hui, ses octets n'ont pas changé.
    pub epoque: u64,
    pub generation: u32,
    /// Les instructions du bloc. Zéro : la première ne va dans aucun bloc,
    /// et la boucle passe par le pas à pas — la case s'en souvient, pour ne
    /// pas redécoder à chaque passage.
    pub nombre: u8,
    /// Les mots de huit octets comparés à l'entrée.
    pub mots: u8,
    /// Bit `i` : l'instruction `i` peut écrire en mémoire, et la génération
    /// de la page du bloc se relit après elle.
    pub ecrit: u16,
    /// Le bloc qui a suivi celui-ci la dernière fois : sa case, que l'entrée
    /// dans celui-ci fait venir au cache pendant qu'il s'exécute.
    pub suivant: u32,
    /// Celui qui le suivait avant : un saut conditionnel a deux suites.
    pub autre_suivant: u32,
    pub uops: [Uop; CAPACITE],
    /// Les bits du dernier mot qui comptent.
    pub dernier: u64,
    /// Les octets d'origine, petit-boutistes, ceux d'au-delà du bloc à zéro.
    /// Après les instructions : ils ne se lisent que quand le tampon ne
    /// suffit pas.
    pub octets: [u64; PORTEE / 8],
    /// **Les instructions que rien ne spécialise**, entières : le chemin
    /// général les lit ici (`Uop::generale`). Au bout du bloc, loin des
    /// lignes qu'une entrée fait venir : elles sont rares. Un bloc s'arrête
    /// devant la cinquième.
    pub generales: [Decoded; GENERALES],
}

/// Les instructions générales d'un bloc, au plus.
pub const GENERALES: usize = 4;

impl Bloc {
    fn vide() -> Self {
        Self {
            etiquette: 0,
            epoque: 0,
            generation: 0,
            nombre: 0,
            mots: 0,
            ecrit: 0,
            suivant: 0,
            autre_suivant: 0,
            dernier: 0,
            octets: [0; PORTEE / 8],
            uops: [Uop::vide(); CAPACITE],
            generales: [Decoded::empty(); GENERALES],
        }
    }

    /// **Les octets à `debut` sont-ils ceux du bloc ?** Les mots entiers,
    /// puis le dernier sous son masque.
    #[inline(always)]
    pub fn intact(&self, ram: &[u8], debut: usize) -> bool {
        self.intact_depuis(ram, debut, 0)
    }

    /// **Le reste du bloc est-il intact, depuis l'octet `octet` ?** Ce qui
    /// précède a déjà été exécuté : une écriture qui y tombe ne change rien
    /// à ce passage, et l'entrée suivante dans le bloc le verra. Après une
    /// écriture, c'est donc la suite seule qui se recompare — en moyenne la
    /// moitié des mots.
    #[inline(always)]
    pub fn intact_depuis(&self, ram: &[u8], debut: usize, octet: usize) -> bool {
        let mots = self.mots as usize;
        let Some(la) = ram.get(debut..debut + mots * 8) else {
            return false;
        };
        let mot = |rang: usize| {
            u64::from_le_bytes(la[rang * 8..rang * 8 + 8].try_into().expect("huit octets"))
        };
        // Un bloc compare toujours au moins un mot.
        let dernier = mots.saturating_sub(1);
        let mut ecart = (mot(dernier) & self.dernier) ^ self.octets[dernier];
        let premier = (octet / 8).min(dernier);
        for (rang, &attendu) in self.octets[..dernier].iter().enumerate().skip(premier) {
            ecart |= mot(rang) ^ attendu;
        }
        ecart == 0
    }
}

/// **La table des blocs**, à accès direct par l'adresse physique.
pub struct Blocs {
    cases: Box<[Bloc]>,
    /// Les blocs construits : ce qui dit si la table sert ou si elle tourne.
    pub construits: u64,
}

impl Default for Blocs {
    fn default() -> Self {
        Self {
            cases: vec![Bloc::vide(); LOGEMENTS].into_boxed_slice(),
            construits: 0,
        }
    }
}

/// Demander une ligne de cache à l'hôte, sans l'attendre.
#[inline(always)]
fn precharger(adresse: *const u8) {
    #[cfg(target_arch = "x86_64")]
    // SAFETY: une indication de préchargement ne lit ni n'écrit rien que le
    // programme voie, et ne faute jamais, même sur une adresse invalide.
    unsafe {
        std::arch::x86_64::_mm_prefetch::<{ std::arch::x86_64::_MM_HINT_T0 }>(adresse.cast());
    }
    #[cfg(target_arch = "aarch64")]
    // SAFETY: `prfm` est une indication : elle ne faute pas et ne change
    // aucun état visible.
    unsafe {
        std::arch::asm!("prfm pldl1keep, [{0}]", in(reg) adresse, options(nostack, readonly, preserves_flags));
    }
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    let _ = adresse;
}

/// La case d'une adresse physique : un hachage multiplicatif, pour que des
/// blocs à la même distance d'un multiple de la table ne se chassent pas.
#[inline(always)]
pub fn case(physique: u64) -> usize {
    (physique.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> (64 - LOGEMENTS.trailing_zeros())) as usize
}

/// **Ce qui peut entrer dans un bloc** : ce que `Machine::pas` confie à
/// `Cpu::execute`, et les vectorielles entières, que `Machine::pas` confie à
/// `Cpu::execute_vector` (`x86::rapide::vectorielle`) — sauf `ldmxcsr`, dont
/// le refus est une `#GP(0)` et non une faute d'accès. Les instructions de
/// système, `rdrand` et l'instruction indéfinie ont chacune leur chemin dans
/// la machine.
pub fn blocable(op: Op) -> bool {
    !matches!(
        op,
        Op::PortIn
            | Op::PortOut
            | Op::ReadTimestamp
            | Op::ReadTimestampAndProcessor
            | Op::CpuId
            | Op::ReadModelRegister
            | Op::WriteModelRegister
            | Op::FarReturn
            | Op::InterruptReturn
            | Op::SoftwareInterrupt
            | Op::LoadDescriptorTable { .. }
            | Op::StoreDescriptorTable { .. }
            | Op::SwapGs
            | Op::LoadKernelGs
            | Op::HypervisorCall { .. }
            | Op::InvalidatePcid
            | Op::LoadTaskRegister
            | Op::SystemCall
            | Op::SystemReturn
            | Op::LoadLocalDescriptorTable
            | Op::ReadDebugRegister { .. }
            | Op::WriteDebugRegister { .. }
            | Op::LoadSegment { .. }
            | Op::StoreSegment { .. }
            | Op::InterruptFlag(_)
            | Op::Halt
            | Op::FpuInit
            | Op::FxSave
            | Op::FxRestore
            | Op::PushFlags
            | Op::PopFlags
            | Op::Undefined
            | Op::InvalidatePage
            | Op::ReadControlRegister { .. }
            | Op::WriteControlRegister { .. }
            | Op::ReadRandom { .. }
            | Op::Vector(Vector::LoadControl)
    )
}

/// Après celles-ci, rien ne s'exécute à la suite : décoder plus loin serait
/// décoder pour rien.
fn terminale(op: Op) -> bool {
    matches!(
        op,
        Op::Jump(None) | Op::JumpIndirect | Op::Call | Op::CallIndirect | Op::Return
    )
}

/// **L'instruction peut-elle écrire en mémoire ?** Vrai sauf pour ce qui ne
/// lit qu'un registre, ou ne lit la mémoire que comme source : dans le doute,
/// oui — se tromper dans ce sens coûte une comparaison, dans l'autre un code
/// réécrit qu'on n'aurait pas relu.
pub fn pourrait_ecrire(instruction: &Decoded) -> bool {
    let op = instruction.op;
    if matches!(
        op,
        Op::Push
            | Op::Call
            | Op::CallIndirect
            | Op::StringMove { .. }
            | Op::StringStore { .. }
            | Op::StringLoad { .. }
            | Op::StringCompare { .. }
            | Op::StringScan { .. }
            | Op::CompareAndExchangeSixteen
    ) {
        return true;
    }
    let Some(_) = instruction.memory else {
        return false;
    };
    if op == Op::Lea {
        return false;
    }
    let lecteur = matches!(
        op,
        Op::Mov
            | Op::Movsx
            | Op::Add
            | Op::Or
            | Op::Adc
            | Op::Sbb
            | Op::And
            | Op::Sub
            | Op::Xor
            | Op::Cmp
            | Op::Test
            | Op::CondMove(_)
            | Op::Multiply
    );
    if lecteur && instruction.memory_is_source {
        return false;
    }
    // `cmp` et `test` vers la mémoire ne rangent rien.
    !(matches!(op, Op::Cmp | Op::Test) && instruction.discards)
}

/// Ce que la table a pour une adresse.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Trouve {
    /// Un bloc, et sa page n'a pas été écrite depuis qu'il l'a lue : ses
    /// octets sont ceux de la mémoire.
    Juste(usize),
    /// Un bloc, et sa page a pu être écrite depuis (une autre génération,
    /// une autre époque) : il faut comparer ses octets, et le tamponner
    /// s'ils n'ont pas changé.
    AComparer(usize),
    /// Rien à cette adresse.
    Rien,
}

impl Blocs {
    /// **Le bloc rangé à cette adresse**, et s'il faut comparer ses octets :
    /// une génération (`generation`, celle de sa page aujourd'hui, rien hors
    /// de la RAM suivie) et une époque (`epoque`) qui sont celles de son
    /// tampon disent que rien n'a écrit sa page depuis.
    #[inline(always)]
    pub fn trouver(&self, physique: u64, epoque: u64, generation: Option<u32>) -> Trouve {
        let paire = case(physique) & !1;
        let etiquette = physique.wrapping_add(1);
        for place in [paire, paire + 1] {
            let bloc = &self.cases[place];
            if bloc.etiquette == etiquette {
                return if bloc.epoque == epoque && Some(bloc.generation) == generation {
                    Trouve::Juste(place)
                } else {
                    Trouve::AComparer(place)
                };
            }
        }
        Trouve::Rien
    }

    /// Le bloc rangé à cette adresse, si ses octets sont ceux de la mémoire,
    /// sans regarder son tampon : ce que l'entrée fait quand il faut
    /// comparer.
    pub fn trouver_par_les_octets(&self, ram: &[u8], physique: u64) -> Option<usize> {
        match self.trouver(physique, 0, None) {
            Trouve::Juste(place) | Trouve::AComparer(place) => self.cases[place]
                .intact(ram, physique as usize)
                .then_some(place),
            Trouve::Rien => None,
        }
    }

    /// **Le bloc de `place` a été comparé à la mémoire, ou vient d'être
    /// lu** : retenir l'époque et la génération de sa page. C'est à
    /// l'appelant de marquer la page (`Cpu::marquer_code`), pour qu'aucune
    /// écriture rapide n'y tombe sans être notée.
    #[inline(always)]
    pub fn tamponner(&mut self, place: usize, epoque: u64, generation: u32) {
        let bloc = &mut self.cases[place];
        bloc.epoque = epoque;
        bloc.generation = generation;
    }

    pub fn bloc(&self, place: usize) -> &Bloc {
        &self.cases[place]
    }

    /// **Noter que `apres` a suivi `avant`, et faire venir au cache le bloc
    /// qui a suivi `apres` la dernière fois.** Une table de trente-deux
    /// mille blocs ne tient pas dans le cache de l'hôte, et chaque entrée
    /// dans un bloc attendait sa ligne : `perf` mettait un dixième des
    /// échantillons sur la lecture de l'étiquette. Le bloc suivant est
    /// presque toujours le même ; le demander pendant que celui-ci
    /// s'exécute cache l'attente. Ce n'est qu'une indication à l'hôte : un
    /// suivant faux coûte une ligne lue pour rien, jamais une instruction.
    #[inline(always)]
    pub fn enchainer(&mut self, avant: usize, apres: usize) {
        if let Some(precedent) = self.cases.get_mut(avant) {
            if precedent.suivant as usize != apres {
                precedent.autre_suivant = precedent.suivant;
                precedent.suivant = apres as u32;
            }
        }
        let courant = &self.cases[apres];
        for suivant in [courant.suivant, courant.autre_suivant] {
            if let Some(bloc) = self.cases.get(suivant as usize) {
                let debut = (bloc as *const Bloc).cast::<u8>();
                for ligne in 0..4 {
                    precharger(debut.wrapping_add(64 * ligne));
                }
            }
        }
    }

    /// **Décoder les instructions qui se suivent depuis `physique`** et les
    /// ranger. `place_dans_la_page` est ce qui reste de la page : aucune
    /// instruction n'en sort. `lire(debut, disponibles)` rend l'instruction
    /// qui commence à l'octet `debut` de la RAM si elle tient dans
    /// `disponibles` octets — `decode`, ou le cache de décodage de la
    /// machine, qui rend la même chose. Rend la case ; le bloc peut être
    /// vide.
    #[inline(never)]
    pub fn construire(
        &mut self,
        ram: &[u8],
        physique: u64,
        place_dans_la_page: usize,
        lire: &mut dyn FnMut(usize, usize) -> Option<Decoded>,
    ) -> usize {
        let debut = physique as usize;
        // **Deux cases par adresse** : la première tient le bloc le plus
        // récent, la seconde celui qu'il a chassé. Un bloc dont l'adresse est
        // déjà dans l'une se refait là.
        let paire = case(physique) & !1;
        let etiquette = physique.wrapping_add(1);
        let place = if self.cases[paire].etiquette == etiquette {
            paire
        } else if self.cases[paire + 1].etiquette == etiquette {
            paire + 1
        } else {
            self.cases[paire + 1] = self.cases[paire];
            paire
        };
        // **Sur place** : un bloc d'un kibioctet construit à côté puis
        // recopié se payait deux fois, à chaque construction. Les cases
        // au-delà de `nombre` et de `mots` gardent ce qu'elles avaient : rien
        // ne les lit.
        let bloc = &mut self.cases[place];
        bloc.ecrit = 0;
        let mut position = 0usize;
        let mut nombre = 0usize;
        let mut generales = 0usize;
        while nombre < CAPACITE {
            let disponibles = 15.min(place_dans_la_page - position).min(PORTEE - position);
            if disponibles == 0 {
                break;
            }
            let Some(instruction) = lire(debut + position, disponibles) else {
                break;
            };
            if !blocable(instruction.op) {
                break;
            }
            let uop = preparer(&instruction, generales as u8);
            if uop.generale != AUCUNE {
                if generales == GENERALES {
                    break;
                }
                bloc.generales[generales] = instruction;
                generales += 1;
            }
            if pourrait_ecrire(&instruction) {
                bloc.ecrit |= 1 << nombre;
            }
            bloc.uops[nombre] = uop;
            nombre += 1;
            position += instruction.length;
            if terminale(instruction.op) {
                break;
            }
        }
        // Un bloc vide compare quand même les seize premiers octets : si le
        // code change, la case se refait.
        let couverts = if nombre == 0 { 16 } else { position };
        let mots = couverts.div_ceil(8);
        bloc.mots = mots as u8;
        bloc.dernier = match couverts % 8 {
            0 => !0,
            reste => (1u64 << (8 * reste)) - 1,
        };
        for rang in 0..mots {
            let mot = u64::from_le_bytes(
                ram[debut + rang * 8..debut + rang * 8 + 8]
                    .try_into()
                    .expect("huit octets"),
            );
            bloc.octets[rang] = if rang + 1 == mots {
                mot & bloc.dernier
            } else {
                mot
            };
        }
        bloc.nombre = nombre as u8;
        bloc.etiquette = physique.wrapping_add(1);
        self.construits += 1;
        place
    }
}
