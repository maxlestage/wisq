//! **La machine PC** : le processeur, sa mémoire, les périphériques hérités,
//! et la boucle qui exécute, sert le matériel et sait dormir sur `hlt` — le
//! port de `X86Machine.swift` et de `X86Core.run`.
//!
//! **Ce que la boucle garde du cœur Swift, à l'instruction près**, pour que
//! les deux cœurs se comparent : le temps de l'invité est le compteur
//! d'instructions (`retirees + attente`), un battement du 8253 vaut
//! `instructions_par_battement` instructions, le matériel est regardé toutes
//! les deux cent cinquante-six instructions, et une machine arrêtée sur `hlt`
//! saute jusqu'à la prochaine échéance de l'horloge.
//!
//! **Deux chemins, qui retirent les mêmes instructions.** Le pas à pas
//! (`pas`) : une instruction, son cache de décodage, `Cpu::execute`. Le
//! chemin rapide (`bloc`, quand `blocs_actifs`) : des blocs d'instructions
//! décodées côte à côte (`pc::blocs`), chacune par la forme choisie à son
//! décodage (`x86::rapide`). Le second ne prend jamais une instruction de
//! système, ne dépasse jamais le prochain service du matériel ni le budget,
//! et laisse au premier tout ce qu'il ne sait pas faire — les deux arrivent
//! au shell d'Alpine en 1 907 638 318 instructions, à l'instruction près.

use std::collections::BTreeMap;

use crate::x86::rapide::Suite;
use crate::x86::{
    decode, decode_extended, Address, Cpu, Decoded, Extended, ExtendedFault, Op, Segment,
    VectorFault, Width, ARITHMETIC, CF, IF,
};
use crate::x86_paging::{Access, Unmapped};

use super::blocs::{Blocs, PORTEE};
use super::chargeur::{self, Ecran, Placement, Refus};
use super::herites::{Herites, INSTRUCTIONS_PAR_BATTEMENT};
use super::memoire;
use super::systeme::{
    self, cpuid, drapeaux_permis, faute_du_dernier_acces, Exception, Livraison, Systeme, EFER_LME,
    IOPL,
};

/// **Les instructions qui touchent la pile sans opérande pour le dire** :
/// leurs références implicites passent par SS.
fn pile_implicite(op: Op) -> bool {
    matches!(
        op,
        Op::Push
            | Op::Pop
            | Op::Call
            | Op::CallIndirect
            | Op::Return
            | Op::Leave
            | Op::PushFlags
            | Op::PopFlags
    )
}

/// **D'autres périphériques, derrière les ports que la carte héritée ne sert
/// pas** : c'est par là que la `Carte` de `wisq-page` (clavier, PCI, disque,
/// écran) se branchera. Les noms sont les siens.
pub trait Peripheriques {
    /// Lire un port. `None` quand personne n'y répond.
    fn port_lire(&mut self, port: u16, largeur: u8, ram: &mut [u8]) -> Option<u32>;
    /// Écrire un port. `false` quand personne n'y répond.
    fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32, ram: &mut [u8]) -> bool;
    /// Les lignes d'interruption levées, un bit par ligne de 0 à 15, à niveau.
    fn lignes(&self) -> u16;
    /// Quelque chose peut-il arriver sans que l'invité fasse rien ? Tant que
    /// oui, une machine arrêtée sur `hlt` n'est pas éteinte.
    fn reveil(&self) -> bool {
        false
    }
    /// Le temps passe : `tics` battements du 8253 depuis le démarrage.
    fn battre(&mut self, _tics: u64) {}
    /// L'invité a demandé la remise à zéro de la machine (l'impulsion de
    /// l'i8042) : la course s'arrête sur l'`out` qui l'a tirée.
    fn remise_demandee(&self) -> bool {
        false
    }
}

/// **D'où `rdrand` et `rdseed` tirent leurs nombres** — le port de
/// `X86Entropy.swift`.
///
/// Sans aléa matériel, le générateur du noyau ne mélange que des instants
/// comptés en instructions, et il met du temps à se dire prêt : mesuré sur
/// Alpine 6.18, 43 millions d'instructions de plus avant `SLUB`, passées à
/// réextraire son réservoir à chaque nombre demandé, et aucun « crng init
/// done » avant le shell.
///
/// Deux sources, et le choix est celui de qui construit la machine : une
/// suite fixée par sa graine (le défaut — deux exécutions du même noyau
/// rendent la même chose, sinon un écart ne se rejoue pas), ou ce que l'hôte
/// fournit.
pub enum Alea {
    /// SplitMix64, de cette graine : la même graine rend les mêmes nombres.
    Fixe(u64),
    /// Le générateur de l'hôte.
    Hote(Box<dyn FnMut() -> u64>),
}

/// La graine d'une machine à qui l'on n'a rien donné : « wisq_rng », celle du
/// cœur Swift, pour que les deux cœurs tirent la même suite.
pub const GRAINE_REPRODUCTIBLE: u64 = 0x7769_7371_5F72_6E67;

impl Alea {
    /// Le nombre suivant, sur soixante-quatre bits.
    pub fn suivant(&mut self) -> u64 {
        match self {
            Self::Fixe(etat) => {
                *etat = etat.wrapping_add(0x9E37_79B9_7F4A_7C15);
                let mut melange = *etat;
                melange = (melange ^ (melange >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
                melange = (melange ^ (melange >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
                melange ^ (melange >> 31)
            }
            Self::Hote(source) => source(),
        }
    }
}

/// Comment un `executer` s'est terminé.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Issue {
    /// Le budget s'est épuisé : la machine tourne ou dort encore.
    Arretee,
    /// L'invité s'est arrêté lui-même, et plus rien ne peut le réveiller.
    Eteinte,
    /// Le cœur a refusé quelque chose. Nommé, parce qu'un arrêt sans nom
    /// envoie chercher partout.
    Faute(String),
}

/// Ce qui interrompt le cours d'une instruction.
enum Evenement {
    /// Une faute à livrer au noyau invité.
    Exception(Exception),
    /// Un arrêt de la machine, avec son nom.
    Arret(String),
}

impl From<Exception> for Evenement {
    fn from(exception: Exception) -> Self {
        Self::Exception(exception)
    }
}

/// Où reprendre un bloc coupé : sa case, son début, l'instruction suivante,
/// et l'adresse physique de celle-ci.
#[derive(Clone, Copy)]
struct Reprise {
    place: usize,
    debut: u64,
    rang: usize,
    physique: u64,
}

/// Le décalage, dans son bloc, de l'instruction de rang `rang`.
#[inline(always)]
fn physique_du_rang(bloc: &super::blocs::Bloc, rang: usize) -> usize {
    bloc.uops[..rang]
        .iter()
        .map(|uop| uop.longueur as usize)
        .sum()
}

/// L'instruction qui commence à l'octet `debut` de la RAM, si elle tient
/// dans `disponibles` octets.
fn lire_en_ram(ram: &[u8], debut: usize, disponibles: usize) -> Option<Decoded> {
    let octets = ram.get(debut..debut + disponibles)?;
    // `fwait` peut livrer `#MF` : il passe par le pas à pas (`Lue::Attente`).
    if attente(octets).is_some() {
        return None;
    }
    decode(octets)
}

/// **`fwait`, préfixes compris** : `Some(Some(longueur))` quand `octets` en
/// commence un, `Some(None)` pour `lock fwait`, illisible. Un préfixe devant
/// `9b` ne change rien à l'attente — sur l'hôte, `48 9b`, `66 9b`, `f3 9b`,
/// `2e 9b` et `67 9b` livrent `#MF` comme `9b` seul ; `f0 9b` est `#UD`
/// (SIGILL), que `decode`, que l'émetteur partage, lit pourtant comme un
/// `nop`. La longueur est celle que `decode` lit.
fn attente(octets: &[u8]) -> Option<Option<usize>> {
    let prefixes = octets
        .iter()
        .take_while(|octet| {
            matches!(
                octet,
                0x26 | 0x2E | 0x36 | 0x3E | 0x40..=0x4F | 0x64..=0x67 | 0xF0 | 0xF2 | 0xF3
            )
        })
        .count();
    if octets.get(prefixes) != Some(&0x9B) {
        return None;
    }
    if octets[..prefixes].contains(&0xF0) {
        return Some(None);
    }
    let lue = decode(octets)?;
    (lue.op == Op::Nop && lue.length == prefixes + 1).then_some(Some(lue.length))
}

/// Ce qu'un passage par un bloc a donné.
enum Passage {
    /// Pas de bloc ici : l'instruction passe par le pas à pas.
    Aucun,
    /// Tant d'instructions retirées, sans faute.
    Fait(u64),
    /// Tant d'instructions retirées, puis celle d'après a fauté.
    Faute(u64, Evenement),
}

/// Une instruction lue : par le décodeur que l'émetteur partage, ou par le
/// second, que seule cette machine consulte (`x86_extended.rs`).
#[derive(Clone, Copy)]
enum Lue {
    Commune(Decoded),
    Etendue(Extended),
    /// **`fwait`** (`9b`, et ses préfixes) : `decode` le lit comme un `nop`,
    /// et c'est ce qu'il est — sauf quand une exception du x87 démasquée
    /// attend, qu'il livre (`#MF`). La longueur, préfixes compris.
    Attente(usize),
}

impl Lue {
    fn longueur(&self) -> usize {
        match self {
            Self::Commune(instruction) => instruction.length,
            Self::Etendue(instruction) => instruction.length,
            Self::Attente(longueur) => *longueur,
        }
    }
}

/// Lire une instruction, par l'un ou l'autre décodeur.
fn lire(octets: &[u8]) -> Option<Lue> {
    if let Some(longueur) = attente(octets) {
        return longueur.map(Lue::Attente);
    }
    decode(octets)
        .map(Lue::Commune)
        .or_else(|| decode_extended(octets).map(Lue::Etendue))
        .or_else(|| sans_taille_d_adresse(octets))
}

/// **Le préfixe `67` devant une instruction qui n'adresse rien.** En mode
/// 64 bits, il ne change que la taille des adresses : devant `mul %r14`, il
/// ne change rien, et le silicium l'ignore. OpenSSL en sème pour aligner son
/// code (`67 49 f7 e6`, dans `libcrypto.so.3` d'Alpine 3.24, que `apk` charge
/// en installant les paquets de l'ISO). `decode`, que l'émetteur partage, ne
/// le lit que devant `call` et `jmp` ; ici, l'instruction sans lui est lue, et
/// acceptée seulement si elle n'a ni opérande mémoire ni adresse implicite
/// (les chaînes, que `67` ferait compter sur RSI, RDI et ECX ; `loop` et
/// `jrcxz`, sur ECX).
fn sans_taille_d_adresse(octets: &[u8]) -> Option<Lue> {
    let mut ici = 0;
    while let Some(&octet) = octets.get(ici) {
        match octet {
            0x67 => break,
            0x66 | 0xF2 | 0xF3 | 0x2E | 0x36 | 0x3E | 0x26 | 0x64 | 0x65 | 0xF0 => ici += 1,
            _ => return None,
        }
    }
    if octets.get(ici) != Some(&0x67) {
        return None;
    }
    let mut reste = [0u8; 15];
    let longueur = octets.len().min(15);
    reste[..ici].copy_from_slice(&octets[..ici]);
    reste[ici..longueur - 1].copy_from_slice(&octets[ici + 1..longueur]);
    let mut instruction = decode(&reste[..longueur - 1])?;
    let adresse_implicite = matches!(
        instruction.op,
        Op::StringMove { .. }
            | Op::StringStore { .. }
            | Op::StringLoad { .. }
            | Op::StringCompare { .. }
            | Op::StringScan { .. }
            | Op::LoopWhile { .. }
            | Op::JumpIfCountZero
    );
    // `reste` n'a que quatorze octets : l'instruction lue sans le `67` en a
    // quatorze au plus, et quinze avec lui.
    if instruction.memory.is_some() || adresse_implicite {
        return None;
    }
    instruction.length += 1;
    Some(Lue::Commune(instruction))
}

/// **Le décodage a-t-il échoué faute d'octets ?** La question de
/// `x86::cut_short`, posée aux deux décodeurs : on essaie chaque valeur du
/// premier octet manquant, des zéros derrière, et l'instruction est coupée si
/// l'une de ces suites se lit plus longue que ce qu'on avait.
fn coupee(octets: &[u8]) -> bool {
    let ici = octets.len();
    if ici >= 15 {
        return false;
    }
    let mut fenetre = [0u8; 15];
    fenetre[..ici].copy_from_slice(octets);
    (0..=u8::MAX).any(|premier| {
        fenetre[ici] = premier;
        lire(&fenetre).is_some_and(|lue| lue.longueur() > ici)
    })
}

/// Une case du cache de décodage : l'adresse physique de l'instruction, ses
/// octets, et ce que le décodeur en a lu.
///
/// **Vérifiée par comparaison d'octets**, comme celui du cœur Swift : une
/// instruction réécrite (les alternatives du noyau, un module chargé, une page
/// rendue puis redonnée) ne se retrouve simplement pas, et rien n'est à vider.
#[derive(Clone, Copy)]
struct Case {
    /// L'adresse physique, plus un : zéro veut dire « vide ».
    etiquette: u64,
    /// Les octets de l'instruction, petit-boutistes, le reste à zéro.
    octets: u128,
    /// Les bits de `octets` qui comptent : huit par octet de l'instruction.
    masque: u128,
    lue: Lue,
}

const CASES: usize = 1 << 16;

/// Où la pagination d'identité du démarrage est posée : hors du chemin du
/// noyau, qui commence à seize mébioctets, et hors de la page zéro.
pub const RACINE_DES_TABLES: u64 = 0x5_0000;
/// La pile du démarrage, sous le premier mébioctet.
pub const PILE_DU_DEMARRAGE: u64 = 0x9_0000;

/// Une machine PC complète.
pub struct Machine {
    pub cpu: Cpu,
    pub systeme: Systeme,
    pub herites: Herites,
    /// La RAM de l'invité, en octets, trou non compris.
    pub ram: u64,
    /// Ce que l'invité a vraiment exécuté. Une instruction qui faute n'y
    /// compte pas, et le temps passé dans un `hlt` non plus.
    pub retirees: u64,
    /// Le temps passé à attendre sur `hlt`, en instructions : l'autre moitié
    /// de l'horloge de l'invité.
    pub attente: u64,
    /// Le processeur est arrêté sur `hlt`, en attente d'une interruption.
    pub arretee: bool,
    /// Combien d'instructions valent un battement du 8253.
    pub instructions_par_battement: u64,
    /// Les autres périphériques, quand il y en a.
    pub peripheriques: Option<Box<dyn Peripheriques>>,
    /// La source de `rdrand` et `rdseed`.
    pub alea: Alea,
    /// **Ce qu'un programme a demandé et que ce processeur n'a pas** : il a
    /// reçu son « Illegal instruction », la machine continue, et l'hôte peut
    /// dire pourquoi.
    pub refus: Vec<String>,
    /// Les ports où personne ne répond, et combien de fois on y a frappé :
    /// pour qui cherche pourquoi un pilote ne trouve pas son périphérique.
    pub ports_muets: BTreeMap<u16, u64>,
    /// **L'ombre de `sti`** (et de `mov ss`) : les interruptions attendent une
    /// instruction de plus. Sans ce retard, une interruption passerait entre
    /// `sti` et `hlt`, et le noyau s'endormirait sur un réveil déjà consommé.
    ///
    /// C'est le compte d'instructions retirées **juste après** celle qui pose
    /// l'ombre : tant que `retirees` vaut encore cela, l'instruction couverte
    /// n'a pas été exécutée. Une adresse ne le dirait pas — une boucle
    /// d'attente revient sur la sienne (`sti ; jmp .`), et l'ombre ne se
    /// lèverait jamais.
    ombre: Option<u64>,
    cache: Vec<Case>,
    /// La page d'instructions courante : son étiquette (la page virtuelle,
    /// l'anneau, « valide »), sa page physique, et le compte de vidages du
    /// tampon de traduction auquel elle a été prise.
    page_cle: u64,
    page_physique: u64,
    page_generation: u64,
    /// La page zéro telle que le chargeur l'a posée, pour qui veut la relire.
    placement: Option<Placement>,
    /// **Le chemin rapide** : les blocs d'instructions décodées et leurs
    /// formes spécialisées (`pc::blocs`, `x86::rapide`). Éteint, chaque
    /// instruction passe par le pas à pas et `Cpu::execute` : c'est le terme
    /// de comparaison, et les deux chemins retirent les mêmes instructions.
    pub blocs_actifs: bool,
    pub blocs: Blocs,
    /// Le bloc coupé par le dernier passage, à reprendre.
    reprise: Option<Reprise>,
    /// La case du dernier bloc exécuté (`Blocs::enchainer`).
    dernier_bloc: usize,
}

impl Machine {
    /// Une machine de `ram` octets (au moins le plancher), éteinte.
    pub fn nouvelle(ram: u64) -> Self {
        Self::essayer(ram)
            .unwrap_or_else(|| panic!("l'hôte ne peut pas donner {ram} octets de RAM"))
    }

    /// **`nouvelle`, ou rien quand l'hôte ne peut pas donner la RAM** :
    /// c'est le système qui dit combien il en a, pas un plafond écrit ici.
    pub fn essayer(ram: u64) -> Option<Self> {
        let ram = ram.max(memoire::RAM_MINIMALE);
        let mut cpu = Cpu::default().with_translation_cache();
        if !memoire::essayer_de_brancher(&mut cpu, ram) {
            return None;
        }
        cpu.mxcsr = 0x1F80;
        cpu.fpu_control = 0x037F;
        Some(Self {
            cpu,
            systeme: Systeme::default(),
            herites: Herites::default(),
            ram,
            retirees: 0,
            attente: 0,
            arretee: false,
            instructions_par_battement: INSTRUCTIONS_PAR_BATTEMENT,
            peripheriques: None,
            alea: Alea::Fixe(GRAINE_REPRODUCTIBLE),
            refus: Vec::new(),
            ports_muets: BTreeMap::new(),
            ombre: None,
            cache: vec![
                Case {
                    etiquette: 0,
                    octets: 0,
                    masque: 0,
                    lue: Lue::Commune(Decoded::empty()),
                };
                // Une case de plus, hors de portée des adresses : celle de
                // l'instruction à cheval sur deux pages, qui ne se garde pas.
                CASES + 1
            ],
            page_cle: 0,
            page_physique: 0,
            page_generation: 0,
            placement: None,
            blocs_actifs: true,
            blocs: Blocs::default(),
            reprise: None,
            dernier_bloc: usize::MAX,
        })
    }

    /// **Charger un noyau**, et éventuellement un initramfs, puis mettre le
    /// processeur dans l'état que le protocole de démarrage 64 bits exige : le
    /// mode long actif, la pagination en place, RSI sur la page zéro.
    pub fn charger(
        &mut self,
        noyau: &[u8],
        ligne: Option<&str>,
        initramfs: Option<&[u8]>,
        ecran: Option<Ecran>,
    ) -> Result<Placement, Refus> {
        let placement = chargeur::charger(
            noyau,
            &mut self.cpu.memory,
            self.ram,
            ligne.unwrap_or(chargeur::LIGNE_PAR_DEFAUT),
            initramfs,
            ecran,
        )?;
        // Quatre entrées de un gibioctet suffisent à couvrir les quatre
        // premiers, là où des pages de quatre kibioctets en demanderaient un
        // million. Le noyau posera les siennes dès qu'il en aura besoin.
        let repertoire = RACINE_DES_TABLES + 0x1000;
        let presente_et_inscriptible = 0x3;
        let grande = 1 << 7;
        let memoire = &mut self.cpu.memory;
        memoire.write(
            RACINE_DES_TABLES,
            Width::Qword,
            repertoire | presente_et_inscriptible,
        );
        for gibioctet in 0..4u64 {
            memoire.write(
                repertoire + gibioctet * 8,
                Width::Qword,
                (gibioctet << 30) | presente_et_inscriptible | grande,
            );
        }
        self.cpu.regs = [0; 16];
        self.cpu.rip = placement.entree;
        self.cpu.flags.write(0);
        self.cpu.segments = [0; 6];
        self.systeme = Systeme::default();
        self.cpu.control = [0; 9];
        self.cpu.control[3] = RACINE_DES_TABLES;
        self.cpu.control[4] = 1 << 5; // PAE
        self.cpu.efer = EFER_LME;
        self.cpu.control[0] = (1 << 31) | 1; // PG et PE
        systeme::rafraichir_le_mode_long(&mut self.cpu);
        self.cpu.flush_translations();
        self.cpu.regs[6] = placement.page_zero;
        self.cpu.regs[4] = PILE_DU_DEMARRAGE;
        self.arretee = false;
        self.placement = Some(placement);
        Ok(placement)
    }

    /// Où le chargeur a tout posé, une fois un noyau chargé.
    pub fn placement(&self) -> Option<Placement> {
        self.placement
    }

    /// Le temps de l'invité, en battements du 8253.
    pub fn tics(&self) -> u64 {
        (self.retirees.wrapping_add(self.attente)) / self.instructions_par_battement
    }

    /// Donner des octets tapés au port série de l'invité.
    pub fn taper(&mut self, octets: &[u8]) {
        self.herites.serie.entree.extend(octets.iter().copied());
    }

    /// Prendre ce que l'invité a écrit sur son port série.
    pub fn sortie(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.herites.serie.sortie)
    }

    /// Vrai quand quelque chose peut arriver sans que l'invité fasse rien.
    fn armes(&self) -> bool {
        self.herites.armes()
            || self
                .peripheriques
                .as_ref()
                .is_some_and(|autres| autres.reveil())
    }

    /// **Lever ce qui est dû, puis livrer la ligne la plus prioritaire.**
    ///
    /// Appelée périodiquement plutôt qu'à chaque instruction : un vrai
    /// processeur regarde sa broche entre deux instructions, et le faire ici
    /// coûterait un test sur le chemin le plus chaud pour un événement qui
    /// arrive toutes les dizaines de milliers d'instructions. Le prix est une
    /// latence bornée, qu'aucun noyau ne distingue d'une horloge un peu moins
    /// précise.
    pub fn servir(&mut self) -> Result<(), String> {
        let tics = self.tics();
        let lignes = match self.peripheriques.as_mut() {
            Some(autres) => {
                autres.battre(tics);
                autres.lignes()
            }
            None => 0,
        };
        self.herites.lever(tics, lignes);
        if !self.cpu.flags.interrupts_enabled() {
            return Ok(());
        }
        // L'ombre de `sti` ne couvre qu'une instruction : dès qu'une de plus
        // est retirée, elle est passée.
        if self.ombre == Some(self.retirees) {
            return Ok(());
        }
        self.ombre = None;
        let Some(candidat) = self.herites.candidat() else {
            return Ok(());
        };
        match self
            .systeme
            .entrer(&mut self.cpu, candidat.vecteur, None, false)
        {
            Ok(()) => {
                // La demande n'est retirée **que** si elle a été livrée.
                self.herites.livree(candidat);
                self.arretee = false; // une interruption réveille un `hlt`
                Ok(())
            }
            // Pas de porte : la demande reste, et le noyau la trouvera quand
            // il aura posé la sienne.
            Err(Livraison::SansPorte) => Ok(()),
            Err(pourquoi) => Err(format!(
                "l'interruption {:#x} n'a pas pu être livrée ({pourquoi:?}), rip {:#x}",
                candidat.vecteur, self.cpu.rip
            )),
        }
    }

    /// Combien d'instructions d'attente avant que le 8253 lève sa prochaine
    /// interruption. Au moins une. Sans canal zéro armé, rien de ce qui peut
    /// réveiller la machine ne dépend du temps, et l'on avance d'un tour.
    fn pas_d_attente(&self) -> u64 {
        let Some(echeance) = self.herites.minuterie.prochaine() else {
            return 1;
        };
        let reveil = echeance.wrapping_mul(self.instructions_par_battement);
        let maintenant = self.retirees.wrapping_add(self.attente);
        if reveil > maintenant {
            reveil - maintenant
        } else {
            1
        }
    }

    /// **Exécuter jusqu'à `budget` instructions**, le temps d'attente compris,
    /// et rendre combien l'ont été. S'arrête plus tôt quand le processeur est
    /// arrêté sur un `hlt` que rien ne peut réveiller.
    pub fn tourner(&mut self, budget: u64) -> Result<u64, String> {
        let mut faites = 0u64;
        while faites < budget {
            if faites & 0xFF == 0 && self.armes() {
                self.servir()?;
            }
            if self.arretee {
                if !(self.armes() && self.cpu.flags.interrupts_enabled()) {
                    break;
                }
                self.servir()?;
                if !self.arretee {
                    continue;
                }
                let pas = self.pas_d_attente().min(budget - faites);
                self.attente = self.attente.wrapping_add(pas);
                faites += pas;
                continue;
            }
            if self.blocs_actifs {
                // Ce qu'un bloc peut retirer : jusqu'au prochain service du
                // matériel, et jusqu'à la fin du budget.
                let permis = (0x100 - (faites & 0xFF)).min(budget - faites);
                match self.bloc(permis) {
                    Passage::Aucun => {}
                    Passage::Fait(retirees) => {
                        faites += retirees;
                        continue;
                    }
                    Passage::Faute(retirees, evenement) => {
                        faites += retirees;
                        match evenement {
                            Evenement::Exception(exception) => self.livrer(exception)?,
                            Evenement::Arret(pourquoi) => return Err(pourquoi),
                        }
                        faites += 1;
                        continue;
                    }
                }
            }
            match self.pas() {
                Ok(()) => {}
                Err(Evenement::Exception(exception)) => self.livrer(exception)?,
                Err(Evenement::Arret(pourquoi)) => return Err(pourquoi),
            }
            faites += 1;
        }
        Ok(faites)
    }

    /// **Faire tourner l'invité** jusqu'à ce qu'il s'arrête ou que le budget
    /// s'épuise. Le budget compte le temps, pas seulement le travail : un
    /// processeur arrêté sur un `hlt` ne retire aucune instruction, et ne
    /// compter que celles-là ferait tourner cette boucle sans fin autour d'un
    /// invité qui dort.
    pub fn executer(&mut self, budget: u64) -> Issue {
        const TRANCHE: u64 = 200_000;
        let mut reste = budget;
        while reste > 0 {
            match self.tourner(TRANCHE.min(reste)) {
                // **Une tranche qui n'exécute rien veut dire que plus rien ne
                // peut arriver** : un `hlt` sans horloge armée, ou avec les
                // interruptions masquées.
                Ok(0) => return Issue::Eteinte,
                Ok(faites) => reste -= faites.min(reste),
                Err(pourquoi) => return Issue::Faute(pourquoi),
            }
        }
        Issue::Arretee
    }

    /// Livrer une faute au noyau invité. RIP pointe encore sur l'instruction
    /// fautive : c'est l'adresse à reprendre après `iretq`.
    fn livrer(&mut self, exception: Exception) -> Result<(), String> {
        if let Exception::FauteDePage { adresse, .. } = exception {
            self.cpu.control[2] = adresse;
        }
        // L'instruction que l'ombre de `sti` couvrait a fauté : l'ombre ne
        // passe pas au gestionnaire, dont la première instruction n'est pas
        // celle qui suivait `sti`.
        self.ombre = None;
        match self
            .systeme
            .entrer(&mut self.cpu, exception.vecteur(), exception.code(), false)
        {
            Ok(()) => {
                self.arretee = false;
                Ok(())
            }
            Err(pourquoi) => Err(format!(
                "{exception:x?} à rip {:#x}, sans livraison possible ({pourquoi:x?})",
                self.cpu.rip
            )),
        }
    }

    /// Les octets de l'instruction à RIP, autant qu'il s'en lit, en
    /// hexadécimal : pour nommer ce qu'on refuse.
    fn octets_a_rip(&mut self) -> String {
        let mut texte = String::new();
        for rang in 0..15u64 {
            let Ok(octet) = self
                .cpu
                .fetch_memory(self.cpu.rip.wrapping_add(rang), Width::Byte)
            else {
                break;
            };
            texte.push_str(&format!("{octet:02x} "));
        }
        self.cpu.faulted = false;
        self.cpu.unmapped = None;
        texte.trim_end().to_string()
    }

    /// Une instruction que ce cœur ne sait pas exécuter. **Dans un programme :
    /// `#UD`, et le programme seul en meurt** — un « Illegal instruction »,
    /// comme sur un processeur qui ne l'a pas —, et le nom est gardé. **Dans le
    /// noyau, elle arrête la machine avec son nom** : c'est un trou de ce cœur,
    /// et le livrer ferait croire au noyau que son propre code est faux.
    fn refuser(&mut self, quoi: &str) -> Evenement {
        let octets = self.octets_a_rip();
        let nom = format!("{quoi} ({octets})");
        if self.cpu.privilege() == 3 {
            self.refus.push(nom);
            Evenement::Exception(Exception::Indefinie)
        } else {
            Evenement::Arret(format!(
                "{nom} à rip {:#x}, en anneau {}",
                self.cpu.rip,
                self.cpu.privilege()
            ))
        }
    }

    /// Ce que le dernier accès refusé de `cpu` veut dire : une faute à livrer
    /// (de page, ou `#GP(0)` pour une adresse qui n'est pas canonique), ou —
    /// hors de la RAM — un arrêt nommé.
    ///
    /// **Hors de la boucle chaude** : appelée de `pas`, elle y était recopiée.
    /// Avec les corrections qui l'ont fait grossir (la `#GP` des adresses
    /// non canoniques), le démarrage d'Alpine prenait 9 % de plus (médianes
    /// de cinq courses alternées : 47,4 s contre 43,4 s) ; sortie de la
    /// boucle, 44,3 s.
    #[cold]
    #[inline(never)]
    fn faute_d_acces(&mut self) -> Evenement {
        match self.cpu.unmapped {
            Some(Unmapped::Outside { address }) | Some(Unmapped::TableOutside { address, .. }) => {
                self.cpu.faulted = false;
                self.cpu.unmapped = None;
                Evenement::Arret(format!(
                    "un accès hors de la mémoire (adresse {address:#x}) à rip {:#x}",
                    self.cpu.rip
                ))
            }
            _ => Evenement::Exception(faute_du_dernier_acces(&mut self.cpu, false)),
        }
    }

    /// **La faute d'un accès refusé à une instruction**, quand l'instruction
    /// est connue : comme `faute_d_acces`, sauf pour une adresse qui n'est
    /// pas canonique, où le silicium distingue le segment. Par la pile — une
    /// référence implicite (`push`, `pop`, `call`, `ret`, `leave`, `pushf`,
    /// `popf`), ou un opérande bâti sur RSP ou RBP sans préfixe FS ni GS —,
    /// c'est `#SS(0)`, vecteur douze ; sinon `#GP(0)`. Linux en fait SIGBUS
    /// dans un cas, SIGSEGV dans l'autre.
    ///
    /// **Laquelle des deux références a fauté.** Une instruction sans
    /// référence implicite n'a que son opérande : c'est lui, quelle que soit
    /// l'adresse refusée — un accès à cheval sur le bord de la moitié basse,
    /// `fxsave` qui en sort par sa fin. Une instruction qui a les deux
    /// (`push (%rax)`, `pop (%rax)`, `call *(%rax)`, toutes de `largeur`
    /// octets au plus) : l'opérande si l'adresse refusée tombe dans ses
    /// octets, l'implicite sinon — même juste derrière l'opérande, où une
    /// fenêtre plus large les confondait. Une faute ne laisse aucune trace,
    /// donc les registres sont encore ceux de l'adresse calculée. Un opérande
    /// relatif à RIP n'a pas de base (le décodeur n'en pose pas), donc jamais
    /// la pile.
    #[cold]
    #[inline(never)]
    fn faute_d_operande(
        &mut self,
        operande: Option<Address>,
        largeur: u64,
        longueur: usize,
        pile_implicite: bool,
    ) -> Evenement {
        if let Some(Unmapped::NonCanonical { address }) = self.cpu.unmapped {
            let apres = self.cpu.rip.wrapping_add(longueur as u64);
            let par_la_pile = match operande {
                Some(operande)
                    if !pile_implicite
                        || address.wrapping_sub(self.cpu.effective_address(&operande, apres))
                            < largeur =>
                {
                    !operande.fs && !operande.gs && matches!(operande.base, Some(4 | 5))
                }
                _ => pile_implicite,
            };
            return Evenement::Exception(faute_du_dernier_acces(&mut self.cpu, par_la_pile));
        }
        self.faute_d_acces()
    }

    /// `faute_d_operande` pour une instruction commune.
    fn faute_de(&mut self, instruction: &Decoded) -> Evenement {
        self.faute_d_operande(
            instruction.memory,
            instruction.width as u64,
            instruction.length,
            pile_implicite(instruction.op),
        )
    }

    /// **L'adresse physique de RIP**, par la page d'instructions courante
    /// quand rien n'a bougé : presque toutes les instructions suivent la
    /// précédente dans la même page, et la page se garde hors du tampon.
    #[inline(always)]
    fn physique_de_rip(&mut self) -> Result<u64, Evenement> {
        let rip = self.cpu.rip;
        let cle = (rip & !0xFFF) | (u64::from(self.cpu.segments[1] & 3) << 1) | 1;
        let generation = self.cpu.tlb.as_ref().map_or(0, |tlb| tlb.generation);
        if self.page_cle != cle || self.page_generation != generation {
            match self.cpu.translate_cached(rip, Access::Fetch) {
                Ok(physique) => {
                    self.page_physique = physique & !0xFFF;
                    self.page_generation = self.cpu.tlb.as_ref().map_or(0, |tlb| tlb.generation);
                    self.page_cle = if self.cpu.paging() { cle } else { 0 };
                }
                Err(pourquoi) => {
                    self.cpu.unmapped = Some(pourquoi);
                    return Err(self.faute_d_acces());
                }
            }
        }
        Ok(self.page_physique | (rip & 0xFFF))
    }

    /// **Trouver l'instruction à RIP** : sa case du cache, vérifiée contre les
    /// octets en mémoire, ou un décodage neuf. Rend la **place** de la case :
    /// l'instruction s'y lit sur place, sans être recopiée à chaque pas.
    #[inline(always)]
    fn chercher(&mut self) -> Result<usize, Evenement> {
        let physique = self.physique_de_rip()?;
        let dans_la_page = physique & 0xFFF;
        let memoire = &self.cpu.memory.bytes;
        let debut = physique as usize;
        let emplacement = debut & (CASES - 1);
        // Le chemin chaud : seize octets lus d'un coup, comparés sous le
        // masque de la case.
        if let Some(seize) = memoire.get(debut..debut.wrapping_add(16)) {
            let lus = u128::from_le_bytes(seize.try_into().expect("seize octets"));
            let case = &self.cache[emplacement];
            if case.etiquette == physique.wrapping_add(1) && (lus ^ case.octets) & case.masque == 0
            {
                return Ok(emplacement);
            }
        }
        self.decoder(physique, dans_la_page as usize)
    }

    /// **Un passage par un bloc** (`pc::blocs`) : trouver celui qui commence
    /// à RIP, ou le construire, puis exécuter au plus `permis` de ses
    /// instructions par leurs formes (`x86::rapide`). `Aucun` quand
    /// l'instruction à RIP ne va dans aucun bloc : le pas à pas s'en charge,
    /// fautes de lecture comprises.
    #[inline(always)]
    fn bloc(&mut self, permis: u64) -> Passage {
        // **De bloc en bloc sans repasser par la boucle** : entre deux blocs,
        // `tourner` n'aurait rien fait — le matériel ne se sert qu'aux
        // multiples de 256, que `permis` ne dépasse pas, et aucun bloc ne
        // s'arrête sur `hlt`.
        let mut faites = 0u64;
        loop {
            match self.un_bloc(permis - faites) {
                Passage::Aucun if faites == 0 => return Passage::Aucun,
                Passage::Aucun => return Passage::Fait(faites),
                Passage::Fait(retirees) => {
                    faites += retirees;
                    if faites == permis {
                        return Passage::Fait(faites);
                    }
                }
                Passage::Faute(retirees, evenement) => {
                    return Passage::Faute(faites + retirees, evenement)
                }
            }
        }
    }

    /// Un bloc : celui qui commence à RIP, ou celui qu'une coupure a laissé.
    #[inline(always)]
    fn un_bloc(&mut self, permis: u64) -> Passage {
        let physique = match self.physique_de_rip() {
            Ok(physique) => physique,
            Err(evenement) => return Passage::Faute(0, evenement),
        };
        let debut = physique as usize;
        // Le bloc se compare sur soixante-quatre octets lus d'un coup : il
        // faut qu'ils soient dans la RAM, hors du trou des périphériques.
        if debut.wrapping_add(PORTEE) > self.cpu.memory.bytes.len()
            || (self.cpu.memory_hole.1 != 0
                && physique.wrapping_sub(self.cpu.memory_hole.0) < self.cpu.memory_hole.1)
        {
            return Passage::Aucun;
        }
        if let Some(passage) = self.reprendre(physique, permis) {
            return passage;
        }
        let place = match self.blocs.trouver(&self.cpu.memory.bytes, physique) {
            Some(place) => place,
            None => {
                let reste = 0x1000 - (debut & 0xFFF);
                let memoire = &self.cpu.memory.bytes;
                self.blocs
                    .construire(memoire, physique, reste, &mut |ici, disponibles| {
                        lire_en_ram(memoire, ici, disponibles)
                    })
            }
        };
        let bloc = self.blocs.bloc(place);
        let nombre = u64::from(bloc.nombre).min(permis);
        if nombre == 0 {
            return Passage::Aucun;
        }
        self.parcourir(place, 0, nombre)
    }

    /// **Reprendre un bloc là où le service du matériel l'a coupé.** Sans
    /// elle, l'instruction d'après la coupure commençait un bloc neuf, à une
    /// adresse où aucun saut n'arrive : un bloc construit toutes les 256
    /// instructions, et une table qui se chasse elle-même. La reprise ne
    /// suppose rien de ce qui s'est passé entre-temps : l'adresse physique de
    /// RIP doit être celle de l'instruction qui suit la coupure, et les
    /// octets du bloc les siens — décoder à cette adresse rendrait alors la
    /// même instruction.
    #[inline(always)]
    fn reprendre(&mut self, physique: u64, permis: u64) -> Option<Passage> {
        let reprise = self.reprise.take()?;
        if reprise.physique != physique {
            return None;
        }
        let bloc = self.blocs.bloc(reprise.place);
        let debut = bloc.etiquette.wrapping_sub(1);
        if debut != reprise.debut || !bloc.intact(&self.cpu.memory.bytes, debut as usize) {
            return None;
        }
        let nombre = (u64::from(bloc.nombre) - reprise.rang as u64).min(permis);
        if nombre == 0 {
            return None;
        }
        Some(self.parcourir(reprise.place, reprise.rang, nombre))
    }

    /// Exécuter `nombre` instructions du bloc de `place`, depuis `premier`.
    #[inline(always)]
    fn parcourir(&mut self, place: usize, premier: usize, nombre: u64) -> Passage {
        self.blocs.enchainer(self.dernier_bloc, place);
        self.dernier_bloc = place;
        let bloc = self.blocs.bloc(place);
        let debut = bloc.etiquette.wrapping_sub(1) as usize;
        let cpu = &mut self.cpu;
        let fin = premier + nombre as usize;
        let mut rang = premier;
        let mut octet = physique_du_rang(bloc, premier);
        let faites = loop {
            let uop = &bloc.uops[rang];
            match (uop.executer)(cpu, uop, &bloc.generales) {
                Suite::Suivante => {
                    cpu.rip = cpu.rip.wrapping_add(u64::from(uop.longueur));
                    octet += uop.longueur as usize;
                    rang += 1;
                    if rang == fin {
                        // Coupé avant sa fin par le budget ou le service du
                        // matériel : la suite reprendra ici.
                        if rang < bloc.nombre as usize {
                            self.reprise = Some(Reprise {
                                place,
                                debut: debut as u64,
                                rang,
                                physique: (debut + octet) as u64,
                            });
                        }
                        break nombre;
                    }
                    // Une écriture a pu tomber dans le bloc même : ce qui reste
                    // à exécuter se recompare avant l'instruction suivante.
                    if bloc.ecrit & (1 << (rang - 1)) != 0
                        && !bloc.intact_depuis(&cpu.memory.bytes, debut, octet)
                    {
                        break (rang - premier) as u64;
                    }
                }
                Suite::Saut => break (rang - premier) as u64 + 1,
                Suite::Faute => {
                    // L'instruction entière, pour nommer la faute : la sienne
                    // si elle est générale, sinon relue à son adresse — les
                    // octets du bloc sont intacts (comparés à l'entrée et après
                    // chaque écriture), et une instruction qui faute n'a rien
                    // écrit.
                    let instruction = match bloc.generales.get(uop.generale as usize) {
                        Some(instruction) => *instruction,
                        None => {
                            let ici = debut + octet;
                            let disponibles = 15.min(0x1000 - (ici & 0xFFF));
                            match lire_en_ram(&cpu.memory.bytes, ici, disponibles) {
                                Some(instruction) => instruction,
                                None => {
                                    return Passage::Faute(
                                        (rang - premier) as u64,
                                        Evenement::Arret(format!(
                                        "une instruction d'un bloc ne se relit plus à rip {:#x}",
                                        cpu.rip
                                    )),
                                    )
                                }
                            }
                        }
                    };
                    let faites = (rang - premier) as u64;
                    self.retirees = self.retirees.wrapping_add(faites);
                    let evenement = self.faute_d_execution(&instruction);
                    return Passage::Faute(faites, evenement);
                }
            }
        };
        self.retirees = self.retirees.wrapping_add(faites);
        Passage::Fait(faites)
    }

    /// Le chemin lent de `chercher` : lire les octets, décoder, garder.
    #[inline(never)]
    fn decoder(&mut self, physique: u64, dans_la_page: usize) -> Result<usize, Evenement> {
        let rip = self.cpu.rip;
        let disponibles = if self.cpu.paging() {
            (0x1000 - dans_la_page).min(15)
        } else {
            15
        };
        let debut = physique as usize;
        let memoire = &self.cpu.memory.bytes;
        let Some(octets) = memoire.get(debut..(debut + disponibles).min(memoire.len())) else {
            return Err(Evenement::Arret(format!(
                "une instruction hors de la mémoire (adresse physique {physique:#x}) à rip {rip:#x}"
            )));
        };
        if self.cpu.memory_hole.1 != 0
            && physique.wrapping_sub(self.cpu.memory_hole.0) < self.cpu.memory_hole.1
        {
            return Err(Evenement::Arret(format!(
                "une instruction dans le trou des périphériques (adresse physique {physique:#x}) à rip {rip:#x}"
            )));
        }
        if let Some(lue) = lire(octets) {
            let longueur = lue.longueur();
            let mut garde = [0u8; 16];
            garde[..longueur].copy_from_slice(&octets[..longueur]);
            let emplacement = debut & (CASES - 1);
            self.cache[emplacement] = Case {
                etiquette: physique.wrapping_add(1),
                octets: u128::from_le_bytes(garde),
                masque: (1u128 << (8 * longueur)) - 1,
                lue,
            };
            return Ok(emplacement);
        }
        // **L'instruction déborde-t-elle sur la page suivante ?** Seulement
        // alors celle-ci se charge — et peut fauter, à sa propre adresse.
        if octets.len() < 15 && coupee(octets) {
            let mut fenetre = [0u8; 15];
            let ici = octets.len();
            fenetre[..ici].copy_from_slice(octets);
            let suivante = (rip & !0xFFF).wrapping_add(0x1000);
            for (rang, case) in fenetre.iter_mut().enumerate().skip(ici) {
                match self
                    .cpu
                    .fetch_memory(suivante.wrapping_add((rang - ici) as u64), Width::Byte)
                {
                    Ok(octet) => *case = octet as u8,
                    Err(_) if rang == ici => return Err(self.faute_d_acces()),
                    Err(_) => {
                        self.cpu.faulted = false;
                        self.cpu.unmapped = None;
                        break;
                    }
                }
            }
            if let Some(lue) = lire(&fenetre) {
                // Hors du cache : ses octets ne sont pas d'un seul tenant, et
                // la comparaison du chemin chaud ne saurait pas les vérifier.
                self.cache[CASES].lue = lue;
                return Ok(CASES);
            }
        }
        Err(self.refuser("une instruction que ce cœur ne lit pas"))
    }

    /// **Un pas** : trouver l'instruction, l'exécuter, avancer.
    #[inline(always)]
    fn pas(&mut self) -> Result<(), Evenement> {
        let emplacement = self.chercher()?;
        // L'instruction se lit dans sa case : le processeur et le cache sont
        // deux champs, et l'emprunt de l'un laisse l'autre libre.
        let instruction = match &self.cache[emplacement].lue {
            Lue::Commune(instruction) => instruction,
            Lue::Etendue(instruction) => {
                let instruction = *instruction;
                return match self.cpu.execute_extended(&instruction) {
                    Ok(()) => {
                        self.cpu.rip = self.cpu.rip.wrapping_add(instruction.length as u64);
                        self.retirees = self.retirees.wrapping_add(1);
                        Ok(())
                    }
                    Err(ExtendedFault::Memory) => {
                        Err(self.faute_d_operande(instruction.memory, 0, instruction.length, false))
                    }
                    Err(ExtendedFault::ReservedControl) => {
                        Err(Exception::ProtectionGenerale(0).into())
                    }
                    // **Une exception de SSE démasquée** : `#XM` quand le
                    // noyau a dit savoir la traiter (CR4.OSXMMEXCPT), `#UD`
                    // sinon — ce que fait le silicium.
                    Err(ExtendedFault::SimdException) => {
                        Err(if self.cpu.control[4] & (1 << 10) != 0 {
                            Exception::FlottantSimd
                        } else {
                            Exception::Indefinie
                        }
                        .into())
                    }
                    // **Une exception du x87 démasquée attendait** : `#MF`,
                    // le cadre sur l'instruction qui ne s'est pas faite.
                    // CR0.NE n'est pas consulté : le mode « MS-DOS » de FERR#
                    // et de l'IRQ 13, qu'un noyau de 64 bits n'utilise pas,
                    // n'est pas modélisé.
                    Err(ExtendedFault::FloatingPoint) => Err(Exception::Flottant.into()),
                };
            }
            Lue::Attente(longueur) => {
                if self.cpu.x87_pending() {
                    return Err(Exception::Flottant.into());
                }
                self.cpu.rip = self.cpu.rip.wrapping_add(*longueur as u64);
                self.retirees = self.retirees.wrapping_add(1);
                return Ok(());
            }
        };
        self.cpu.jumped = false;
        let longueur = instruction.length as u64;
        match instruction.op {
            // Tout ce que l'interpréteur nu refuse, et qu'une machine fait.
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
            | Op::WriteControlRegister { .. } => {
                let instruction = *instruction;
                self.systeme(&instruction)?;
            }
            // **`rdrand` et `rdseed`, avec une source.** L'interpréteur nu
            // répond « rien de disponible » ; la machine en a une, et le dit :
            // la retenue posée, les cinq autres drapeaux effacés.
            Op::ReadRandom { .. } => {
                let (registre, largeur) = (instruction.dst, instruction.width);
                let nombre = self.alea.suivant();
                self.cpu.set(registre, largeur, false, nombre);
                let drapeaux = self.cpu.flags.read();
                self.cpu.flags.write((drapeaux & !ARITHMETIC) | CF);
            }
            Op::Vector(_) => match self.cpu.execute_vector(instruction) {
                Ok(()) => {}
                Err(VectorFault::Memory) => {
                    let instruction = *instruction;
                    return Err(self.faute_de(&instruction));
                }
                Err(VectorFault::ReservedControl) => {
                    return Err(Exception::ProtectionGenerale(0).into())
                }
            },
            _ => {
                self.cpu.execute(instruction);
                if self.cpu.faulted {
                    let instruction = *instruction;
                    return Err(self.faute_d_execution(&instruction));
                }
            }
        }
        if !self.cpu.jumped {
            self.cpu.rip = self.cpu.rip.wrapping_add(longueur);
        }
        self.retirees = self.retirees.wrapping_add(1);
        Ok(())
    }

    /// Ce que `faulted` veut dire après un `execute` : une faute de page, une
    /// division qui lève, ou une instruction que l'interpréteur refuse.
    #[inline(never)]
    fn faute_d_execution(&mut self, instruction: &Decoded) -> Evenement {
        if self.cpu.unmapped.is_some() {
            return self.faute_de(instruction);
        }
        self.cpu.faulted = false;
        match instruction.op {
            Op::Divide { .. } => Exception::Division.into(),
            autre => self.refuser(&format!("{autre:?}, que l'interpréteur n'exécute pas")),
        }
    }

    /// L'adresse de l'opérande mémoire d'une instruction.
    fn adresse(&self, instruction: &Decoded) -> u64 {
        let adresse = instruction
            .memory
            .expect("une instruction à opérande mémoire");
        self.cpu
            .effective_address(&adresse, self.cpu.after(instruction))
    }

    /// Lire en mémoire pour une instruction de système, la faute prête à
    /// livrer.
    fn lire(
        &mut self,
        instruction: &Decoded,
        adresse: u64,
        largeur: Width,
    ) -> Result<u64, Evenement> {
        match self.cpu.read_memory(adresse, largeur) {
            Ok(valeur) => Ok(valeur),
            Err(_) => Err(self.faute_de(instruction)),
        }
    }

    fn ecrire(
        &mut self,
        instruction: &Decoded,
        adresse: u64,
        largeur: Width,
        valeur: u64,
    ) -> Result<(), Evenement> {
        match self.cpu.write_memory(adresse, largeur, valeur) {
            Ok(()) => Ok(()),
            Err(_) => Err(self.faute_de(instruction)),
        }
    }

    /// Réservé à l'anneau zéro : `#GP(0)` ailleurs.
    fn exiger_le_noyau(&self) -> Result<(), Evenement> {
        if self.cpu.privilege() != 0 {
            return Err(Exception::ProtectionGenerale(0).into());
        }
        Ok(())
    }

    /// Réservé à qui a le privilège des entrées-sorties : `#GP(0)` quand
    /// l'anneau dépasse IOPL.
    fn exiger_les_entrees_sorties(&self) -> Result<(), Evenement> {
        if u64::from(self.cpu.privilege()) > (self.cpu.flags.read() & IOPL) >> 12 {
            return Err(Exception::ProtectionGenerale(0).into());
        }
        Ok(())
    }

    fn port_lire(&mut self, port: u16, largeur: Width) -> u64 {
        let tics = self.tics();
        if let Some(valeur) = self.herites.port_lire(port, tics) {
            return u64::from(valeur);
        }
        if let Some(autres) = self.peripheriques.as_mut() {
            if let Some(valeur) = autres.port_lire(port, largeur as u8, &mut self.cpu.memory.bytes)
            {
                // Pas de masque ici : `in` range la valeur par `Cpu::set`, à
                // la largeur de l'instruction, et les bits en trop d'un
                // périphérique n'atteignent jamais le registre.
                return u64::from(valeur);
            }
        }
        // Personne : le bus rend des uns, comme sur un vrai PC.
        *self.ports_muets.entry(port).or_insert(0) += 1;
        largeur.mask()
    }

    fn port_ecrire(&mut self, port: u16, largeur: Width, valeur: u64) {
        let tics = self.tics();
        if self.herites.port_ecrire(port, valeur as u32, tics) {
            return;
        }
        if let Some(autres) = self.peripheriques.as_mut() {
            if autres.port_ecrire(
                port,
                largeur as u8,
                valeur as u32,
                &mut self.cpu.memory.bytes,
            ) {
                return;
            }
        }
        *self.ports_muets.entry(port).or_insert(0) += 1;
    }

    /// **Les instructions de système** : ce que `Cpu::execute` refuse en le
    /// nommant, parce qu'il y faut une machine.
    #[inline(never)]
    fn systeme(&mut self, instruction: &Decoded) -> Result<(), Evenement> {
        let largeur = instruction.width;
        match instruction.op {
            Op::PortIn | Op::PortOut => {
                self.exiger_les_entrees_sorties()?;
                let port = if instruction.immediate {
                    instruction.imm as u16
                } else {
                    self.cpu.regs[2] as u16
                };
                if instruction.op == Op::PortIn {
                    let valeur = self.port_lire(port, largeur);
                    self.cpu.set(0, largeur, false, valeur);
                } else {
                    let valeur = self.cpu.get(0, largeur, false);
                    self.port_ecrire(port, largeur, valeur);
                    // **L'impulsion de remise à zéro** : la course s'arrête
                    // sur l'`out` qui l'a tirée, en le disant — le nom du banc
                    // Swift.
                    if self
                        .peripheriques
                        .as_ref()
                        .is_some_and(|autres| autres.remise_demandee())
                    {
                        return Err(Evenement::Arret(
                            "redémarrage demandé (impulsion du 8042)".into(),
                        ));
                    }
                }
            }
            Op::ReadTimestamp | Op::ReadTimestampAndProcessor => {
                // Le compteur d'horodatage est l'horloge de l'invité : les
                // instructions retirées, tours d'attente compris.
                let cycles = self.retirees.wrapping_add(self.attente);
                self.cpu.regs[0] = cycles & 0xFFFF_FFFF;
                self.cpu.regs[2] = cycles >> 32;
                if instruction.op == Op::ReadTimestampAndProcessor {
                    self.cpu.regs[1] = self.systeme.tsc_aux & 0xFFFF_FFFF;
                }
            }
            Op::CpuId => {
                let [a, b, c, d] = cpuid(self.cpu.regs[0] as u32, self.cpu.regs[1] as u32);
                self.cpu.regs[0] = u64::from(a);
                self.cpu.regs[3] = u64::from(b);
                self.cpu.regs[1] = u64::from(c);
                self.cpu.regs[2] = u64::from(d);
            }
            Op::ReadModelRegister => {
                self.exiger_le_noyau()?;
                let valeur = self.systeme.lire_msr(&self.cpu, self.cpu.regs[1] as u32);
                self.cpu.regs[0] = valeur & 0xFFFF_FFFF;
                self.cpu.regs[2] = valeur >> 32;
            }
            Op::WriteModelRegister => {
                self.exiger_le_noyau()?;
                let valeur = (self.cpu.regs[2] << 32) | (self.cpu.regs[0] & 0xFFFF_FFFF);
                let numero = self.cpu.regs[1] as u32;
                self.systeme.ecrire_msr(&mut self.cpu, numero, valeur);
            }
            Op::FarReturn => {
                if largeur != Width::Qword {
                    return Err(self.refuser("un retour lointain hors du mode 64 bits"));
                }
                self.systeme.retour_lointain(&mut self.cpu)?;
            }
            Op::InterruptReturn => {
                if largeur != Width::Qword {
                    return Err(self.refuser("un retour d'interruption hors du mode 64 bits"));
                }
                self.systeme.retour_d_interruption(&mut self.cpu)?;
            }
            Op::SoftwareInterrupt => {
                // **Un appel, pas une faute** : l'adresse empilée est celle de
                // l'instruction suivante.
                let vecteur = instruction.imm as u8;
                let ici = self.cpu.rip;
                self.cpu.rip = ici.wrapping_add(instruction.length as u64);
                match self.systeme.entrer(&mut self.cpu, vecteur, None, true) {
                    Ok(()) => self.cpu.jumped = true,
                    Err(pourquoi) => {
                        self.cpu.rip = ici;
                        return Err(match pourquoi {
                            // La porte manque ou ne l'admet pas : `#GP`, avec
                            // le vecteur et le bit « IDT » pour code.
                            Livraison::SansPorte | Livraison::Privilege => {
                                Exception::ProtectionGenerale(u64::from(vecteur) * 8 + 2).into()
                            }
                            autre => Evenement::Arret(format!(
                                "int {vecteur:#x} à rip {ici:#x} sans livraison possible ({autre:x?})"
                            )),
                        });
                    }
                }
            }
            Op::LoadDescriptorTable { interrupts } => {
                self.exiger_le_noyau()?;
                let adresse = self.adresse(instruction);
                let limite = self.lire(instruction, adresse, Width::Word)?;
                let base = self.lire(instruction, adresse.wrapping_add(2), Width::Qword)?;
                let table = systeme::Table { base, limite };
                if interrupts {
                    self.systeme.idt = table;
                } else {
                    self.systeme.gdt = table;
                }
            }
            Op::StoreDescriptorTable { interrupts } => {
                let adresse = self.adresse(instruction);
                let table = if interrupts {
                    self.systeme.idt
                } else {
                    self.systeme.gdt
                };
                // Les dix octets tiennent, ou rien n'est écrit.
                if self
                    .cpu
                    .probe_memory(adresse.wrapping_add(9), Access::Write)
                    .is_err()
                {
                    return Err(self.faute_de(instruction));
                }
                self.ecrire(instruction, adresse, Width::Word, table.limite)?;
                self.ecrire(
                    instruction,
                    adresse.wrapping_add(2),
                    Width::Qword,
                    table.base,
                )?;
            }
            Op::SwapGs => {
                self.exiger_le_noyau()?;
                std::mem::swap(&mut self.cpu.gs_base, &mut self.systeme.gs_du_noyau);
            }
            // Trois instructions que `CPUID` n'annonce pas : le silicium qui
            // ne les a pas lève `#UD`, et c'est ce que le noyau attend.
            Op::LoadKernelGs | Op::HypervisorCall { .. } | Op::InvalidatePcid => {
                return Err(Exception::Indefinie.into());
            }
            Op::LoadTaskRegister => {
                self.exiger_le_noyau()?;
                let selecteur = self.cpu.regs[instruction.dst as usize] as u16;
                self.systeme.charger_la_tache(&mut self.cpu, selecteur)?;
            }
            Op::LoadLocalDescriptorTable => {
                self.exiger_le_noyau()?;
                self.systeme.ldt = self.cpu.regs[instruction.dst as usize] as u16;
            }
            Op::SystemCall => self
                .systeme
                .appel_systeme(&mut self.cpu, instruction.length)?,
            Op::SystemReturn => self.systeme.retour_systeme(&mut self.cpu)?,
            Op::ReadDebugRegister { which } => {
                self.exiger_le_noyau()?;
                self.cpu.regs[instruction.dst as usize] = self.systeme.debug[which as usize];
            }
            Op::WriteDebugRegister { which } => {
                self.exiger_le_noyau()?;
                self.systeme.debug[which as usize] = self.cpu.regs[instruction.dst as usize];
            }
            Op::LoadSegment { segment } => {
                let selecteur = match instruction.memory {
                    Some(_) => self.lire(instruction, self.adresse(instruction), Width::Word)?,
                    None => self.cpu.regs[instruction.dst as usize],
                } as u16;
                self.cpu.segments[segment as usize] = selecteur;
                // **FS et GS gardent une base en mode long.** Un sélecteur nul
                // la remet à zéro ; un autre la prend dans son descripteur.
                if matches!(segment, Segment::Fs | Segment::Gs) {
                    let base = if selecteur == 0 {
                        Some(0)
                    } else {
                        self.systeme.base_du_descripteur(&mut self.cpu, selecteur)
                    };
                    if let Some(base) = base {
                        if segment == Segment::Fs {
                            self.cpu.fs_base = base;
                        } else {
                            self.cpu.gs_base = base;
                        }
                    }
                }
                // Charger SS retarde les interruptions d'une instruction.
                if segment == Segment::Ss {
                    self.ombre = Some(self.retirees.wrapping_add(1));
                }
            }
            Op::StoreSegment { segment } => {
                let selecteur = u64::from(self.cpu.segments[segment as usize]);
                match instruction.memory {
                    // En mémoire, toujours seize bits.
                    Some(_) => self.ecrire(
                        instruction,
                        self.adresse(instruction),
                        Width::Word,
                        selecteur,
                    )?,
                    None => self.cpu.set(instruction.dst, largeur, false, selecteur),
                }
            }
            Op::InterruptFlag(allume) => {
                self.exiger_les_entrees_sorties()?;
                let avant = self.cpu.flags.read();
                if allume {
                    // Seulement quand `sti` **lève** le drapeau : s'il l'était
                    // déjà, rien n'attendait derrière lui.
                    if avant & IF == 0 {
                        self.ombre = Some(self.retirees.wrapping_add(1));
                    }
                    self.cpu.flags.write(avant | IF);
                } else {
                    self.cpu.flags.write(avant & !IF);
                }
            }
            Op::Halt => {
                self.exiger_le_noyau()?;
                self.arretee = true;
            }
            Op::FpuInit => {
                // Toutes les exceptions masquées, précision étendue, arrondi
                // au plus proche ; mot d'état à zéro, pile vide.
                self.cpu.fpu_control = 0x037F;
                self.cpu.fpu_status = 0;
                self.cpu.fpu_tags = 0;
            }
            Op::FxSave | Op::FxRestore => {
                let adresse = self.adresse(instruction);
                let rendu = if instruction.op == Op::FxSave {
                    self.cpu.save_floating_point_state(adresse)
                } else {
                    self.cpu.restore_floating_point_state(adresse)
                };
                match rendu {
                    Ok(()) => {}
                    Err(ExtendedFault::Memory) => return Err(self.faute_de(instruction)),
                    Err(ExtendedFault::ReservedControl) => {
                        return Err(Exception::ProtectionGenerale(0).into())
                    }
                    Err(ExtendedFault::SimdException | ExtendedFault::FloatingPoint) => {
                        unreachable!("fxsave et fxrstor ne calculent pas")
                    }
                }
            }
            Op::PushFlags => {
                // VM et RF ne s'empilent pas.
                let valeur = self.cpu.flags.read() & !((1 << 16) | (1 << 17));
                let sommet = self.cpu.regs[4].wrapping_sub(largeur as u64);
                self.ecrire(instruction, sommet, largeur, valeur)?;
                self.cpu.regs[4] = sommet;
            }
            Op::PopFlags => {
                let sommet = self.cpu.regs[4];
                let depiles = self.lire(instruction, sommet, largeur)?;
                let avant = self.cpu.flags.read();
                // En seize bits, la moitié haute de RFLAGS ne bouge pas.
                let demandes = if largeur == Width::Word {
                    (avant & !0xFFFF) | depiles
                } else {
                    depiles
                };
                self.cpu.regs[4] = sommet.wrapping_add(largeur as u64);
                self.cpu
                    .flags
                    .write(drapeaux_permis(avant, demandes, self.cpu.privilege()));
            }
            Op::Undefined => return Err(Exception::Indefinie.into()),
            Op::InvalidatePage => {
                self.exiger_le_noyau()?;
                self.cpu.flush_translations();
            }
            Op::ReadControlRegister { .. } => {
                self.exiger_le_noyau()?;
                self.cpu.execute(instruction);
            }
            Op::WriteControlRegister { which } => {
                self.exiger_le_noyau()?;
                self.cpu.execute(instruction);
                if which == 0 {
                    systeme::rafraichir_le_mode_long(&mut self.cpu);
                }
            }
            autre => unreachable!("{autre:?} n'est pas une instruction de système"),
        }
        Ok(())
    }
}
