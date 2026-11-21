//! **Le poste** : la machine PC telle qu'une application la mène — ce que
//! l'ABI C (`wisq_pc_*`, `ffi.rs`) expose, et ce que `RustPCMachine` enveloppe
//! côté Swift.
//!
//! [`Machine`] sait exécuter ; il lui manque ce qu'un hôte demande autour :
//! une course qu'un autre fil peut arrêter, des octets tapés au port série
//! depuis n'importe quel fil, un clavier dont la frappe s'annule, un toucher,
//! un temps passé dehors à rattraper, et ce qui se voit pendant qu'elle tourne.
//! C'est le port de ce que `X86Machine.swift` met autour de `X86Core`.
//!
//! **Deux moitiés, et la frontière est celle des fils.** Le [`Poste`] lui-même
//! n'est touché que par le fil qui le fait tourner (charger, brancher, courir,
//! sauver, reprendre). Les [`Commandes`] sont partagées (`Arc`) : arrêter,
//! taper, toucher, lire l'écran et l'avancement se font de n'importe quel fil,
//! chacune sous son verrou ou par une valeur atomique. L'ABI tend les deux
//! moitiés par deux champs distincts, pour qu'un fil qui tape ne forme jamais
//! de référence sur la machine qu'un autre fil fait tourner.
//!
//! **La carte est toujours branchée** (`pc::carte::brancher`), comme sous
//! `wisq-pc` : l'i8042, l'horloge CMOS, le pont PCI, puis les disques et
//! l'écran qu'on lui donne avant le chargement.
//!
//! Rien ici ne demande de fichier ni d'horloge de l'hôte : la cible `wasm32`
//! le compile. Le disque sur fichier et l'heure du système sont donnés par
//! l'appelant (`ffi.rs`).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use wisq_carte::ecran::BASE_DE_LA_MEMOIRE_VIDEO;
use wisq_carte::i8042::{CodeTouche, LIMITE_DE_FRAPPE, TOUCHES};
use wisq_carte::pc::{Arriere, CartePc, Disque};

use super::carte::{brancher, CartePartagee};
use super::chargeur::{Ecran, Placement, Refus};
use super::herites::HERTZ_DU_8253;
use super::machine::{Alea, Machine};

/// Ce qu'une course fait au plus d'un coup, entre deux regards sur les
/// commandes : un arrêt demandé, des octets tapés et une frappe passent dans
/// ce délai (deux cent mille instructions, deux millisecondes à peine).
pub const TRANCHE: u64 = 200_000;

/// **Le plus grand pas d'un rattrapage**, en secondes de l'invité : dix,
/// comme `GuestClock.stepSeconds` — sous les vingt secondes du chien de garde
/// de Linux et sous la borne de sa conversion du compteur.
pub const PAS_DE_RATTRAPAGE_EN_SECONDES: u64 = 10;

/// Au-delà, le temps passé dehors est borné : dix ans, comme
/// `GuestClock.longestElapse`.
pub const PLUS_LONG_RATTRAPAGE_EN_SECONDES: f64 = 10.0 * 365.0 * 86_400.0;

/// **Combien de frappes le poste remet à la fois à l'i8042.** Le reste attend
/// ici, où il peut être jeté (`Commandes::abandonner_la_frappe`) : la file de
/// la carte, elle, ne se vide pas de l'extérieur. Trente-deux frappes, c'est
/// moins d'une seconde de jeu.
pub const FRAPPES_REMISES: usize = 32;

/// Comment une course s'est terminée.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Fin {
    /// Le budget est épuisé : la machine tourne ou dort encore.
    Budget,
    /// Quelqu'un a demandé l'arrêt ([`Commandes::arreter`]).
    Arretee,
    /// L'invité attend sur `hlt` et plus rien ne peut le réveiller : son
    /// attente est épuisée. C'est l'extinction d'un noyau.
    Eteinte,
    /// L'invité a demandé la remise à zéro (l'impulsion de l'i8042) : un
    /// redémarrage.
    Remise,
    /// Le cœur a refusé quelque chose, nommé.
    Faute(String),
}

/// Pourquoi un octet du jeu 1 ne se lit pas comme une frappe.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RefusDeTouches {
    /// Un `E0` sans code derrière lui.
    PrefixeSeul,
    /// `E1` (la touche Pause, qui n'a pas de relâchement) ou un second `E0`.
    PrefixeInconnu,
    /// Le code zéro, qui n'est pas une touche.
    CodeNul,
}

/// **Lire une suite d'octets du jeu 1** : un code par touche, `| 0x80` pour
/// le relâchement, `E0` devant une touche étendue. `E0 48` enfonce la flèche
/// du haut, `E0 C8` la relâche.
pub fn frappes_du_jeu_1(octets: &[u8]) -> Result<Vec<(CodeTouche, bool)>, RefusDeTouches> {
    let mut frappes = Vec::with_capacity(octets.len());
    let mut suite = octets.iter().copied();
    while let Some(octet) = suite.next() {
        let (octet, etendue) = match octet {
            0xE0 => match suite.next() {
                None => return Err(RefusDeTouches::PrefixeSeul),
                Some(0xE0 | 0xE1) => return Err(RefusDeTouches::PrefixeInconnu),
                Some(code) => (code, true),
            },
            0xE1 => return Err(RefusDeTouches::PrefixeInconnu),
            octet => (octet, false),
        };
        let jeu1 = octet & 0x7F;
        if jeu1 == 0 {
            return Err(RefusDeTouches::CodeNul);
        }
        let code = if etendue {
            CodeTouche::etendue(jeu1)
        } else {
            CodeTouche::simple(jeu1)
        };
        frappes.push((code, octet & 0x80 == 0));
    }
    Ok(frappes)
}

/// Le rang d'une touche dans un ensemble de touches tenues : son code du
/// jeu 1, plus 256 pour une touche étendue — celui de l'i8042.
fn rang(code: CodeTouche) -> (usize, u64) {
    let index = usize::from(code.jeu1) | if code.etendue { 256 } else { 0 };
    (index / 64, 1 << (index % 64))
}

/// Les touches qu'une suite de frappes laisse enfoncées, un bit par touche.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
struct Tenues([u64; TOUCHES / 64]);

impl Tenues {
    fn noter(&mut self, code: CodeTouche, enfoncee: bool) {
        let (mot, bit) = rang(code);
        if enfoncee {
            self.0[mot] |= bit;
        } else {
            self.0[mot] &= !bit;
        }
    }

    fn contient(&self, code: CodeTouche) -> bool {
        let (mot, bit) = rang(code);
        self.0[mot] & bit != 0
    }

    fn codes(&self) -> Vec<CodeTouche> {
        (0..TOUCHES)
            .filter(|index| self.0[index / 64] & (1 << (index % 64)) != 0)
            .map(|index| {
                let jeu1 = (index & 0xFF) as u8;
                if index >= 256 {
                    CodeTouche::etendue(jeu1)
                } else {
                    CodeTouche::simple(jeu1)
                }
            })
            .collect()
    }
}

/// **Les frappes qui attendent leur tour**, avant la file de l'i8042 — le
/// port de `X86TypingHandoff`.
#[derive(Default)]
struct Touches {
    attente: VecDeque<(CodeTouche, bool)>,
    /// L'état du clavier une fois tout joué, l'attente comprise : la règle
    /// du relâchement qui passe toujours.
    tenues_au_bout: Tenues,
    /// L'état du clavier une fois jouées les seules frappes remises à
    /// l'i8042 : ce qu'une annulation doit relâcher.
    tenues_remises: Tenues,
}

/// **Ce que les autres fils peuvent faire**, pendant qu'un fil fait tourner
/// le poste.
pub struct Commandes {
    arret: AtomicBool,
    serie: Mutex<Vec<u8>>,
    touches: Mutex<Touches>,
    carte: CartePartagee,
    /// L'avancement publié à chaque tranche : en retard, jamais faux.
    retirees: AtomicU64,
    rip: AtomicU64,
    publie: AtomicBool,
}

fn tenir<T>(verrou: &Mutex<T>) -> MutexGuard<'_, T> {
    verrou.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// **L'écran, tel qu'une vue le lit** : la mémoire vidéo entière (son adresse
/// dans l'hôte et sa taille), le rectangle montré, et le compte des
/// changements.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct VueDeLEcran {
    pub memoire: *const u8,
    pub taille: usize,
    pub largeur: u32,
    pub hauteur: u32,
    pub octets_par_ligne: u32,
    pub debut: u64,
    pub revision: u64,
}

impl Commandes {
    /// Demander à une course de rendre la main, à la fin de sa tranche. Une
    /// demande faite avant la course la fait rendre tout de suite : elle est
    /// consommée par la course qui la voit.
    pub fn arreter(&self) {
        self.arret.store(true, Ordering::SeqCst);
    }

    /// Des octets tapés au port série de l'invité ; la course les donne au
    /// 16550 à sa prochaine tranche.
    pub fn envoyer(&self, octets: &[u8]) {
        tenir(&self.serie).extend_from_slice(octets);
    }

    /// La carte, pour qui veut la lire (un test, l'écran).
    pub fn carte(&self) -> &CartePartagee {
        &self.carte
    }

    /// **Des frappes qui vont ensemble** (un caractère, une touche et ses
    /// modificateurs), admises toutes ou aucune, comme `X86Machine.press`.
    ///
    /// La borne est celle de l'i8042 ([`LIMITE_DE_FRAPPE`]), comptée sur ce
    /// qui attend ici et ce que la carte tient encore. Au-delà, un groupe qui
    /// ne fait que relâcher entre quand même, pour les touches que la file
    /// laisse enfoncées : le refuser les laisserait enfoncées pour de bon.
    pub fn frapper(&self, groupe: &[(CodeTouche, bool)]) -> bool {
        let mut touches = tenir(&self.touches);
        let dans_la_carte = self.carte.tenir().carte().ps2.frappes.len();
        let total = touches.attente.len() + dans_la_carte;
        if total.saturating_add(groupe.len()) <= LIMITE_DE_FRAPPE {
            for &(code, enfoncee) in groupe {
                touches.attente.push_back((code, enfoncee));
                touches.tenues_au_bout.noter(code, enfoncee);
            }
            return true;
        }
        if groupe.iter().all(|&(_, enfoncee)| !enfoncee) {
            for &(code, _) in groupe {
                if touches.tenues_au_bout.contient(code) {
                    touches.attente.push_back((code, false));
                    touches.tenues_au_bout.noter(code, false);
                }
            }
            return true;
        }
        false
    }

    /// **Les frappes que l'invité n'a pas encore reçues** : celles qui
    /// attendent ici et celles que l'i8042 tient.
    pub fn frappes_en_attente(&self) -> usize {
        let touches = tenir(&self.touches);
        touches.attente.len() + self.carte.tenir().carte().ps2.frappes.len()
    }

    /// **Annuler la frappe en cours**, comme `X86Machine.abandonTyping` : ce
    /// qui attend ici est jeté, et chaque touche que les frappes déjà remises
    /// laissent enfoncée est relâchée derrière elles. Ce qu'on tape ensuite
    /// part aussitôt, derrière au plus [`FRAPPES_REMISES`] frappes.
    pub fn abandonner_la_frappe(&self) {
        let mut touches = tenir(&self.touches);
        touches.attente.clear();
        let tenues = touches.tenues_remises;
        for code in tenues.codes() {
            touches.attente.push_back((code, false));
        }
        touches.tenues_au_bout = Tenues::default();
    }

    /// Un mouvement de la souris PS/2, en pixels, Y vers le bas.
    pub fn souris(&self, dx: i32, dy: i32, boutons: u8) {
        self.carte.tenir().souris(dx, dy, boutons);
    }

    /// Un toucher de la tablette, de 0 à 1 ; `false` quand l'invité ne l'a
    /// pas prise (ou qu'une coordonnée n'est pas un nombre).
    pub fn toucher(&self, x: f64, y: f64, boutons: u8) -> bool {
        if !x.is_finite() || !y.is_finite() {
            return false;
        }
        self.carte.tenir().toucher(x, y, boutons)
    }

    /// La molette, en crans positifs vers le haut.
    pub fn defiler(&self, crans: i32) -> bool {
        self.carte.tenir().defiler(crans)
    }

    /// **L'écran**, ou rien sans écran branché.
    pub fn ecran(&self) -> Option<VueDeLEcran> {
        let carte = self.carte.tenir();
        let cadre = &carte.ecran()?.cadre;
        let mode = cadre.mode();
        let octets = cadre.octets();
        Some(VueDeLEcran {
            memoire: octets.as_ptr(),
            taille: octets.len(),
            largeur: mode.largeur,
            hauteur: mode.hauteur,
            octets_par_ligne: mode.octets_par_ligne,
            debut: mode.debut,
            revision: cadre.revision(),
        })
    }

    /// **L'image montrée, copiée** dans `vers` sous le verrou de la carte :
    /// ligne à ligne, sans remplissage, quatre octets par pixel. Rend la vue
    /// de l'écran (le mode, la révision de l'image copiée), et `Err` avec
    /// elle quand `vers` est trop court — rien n'est alors copié.
    pub fn copier_l_image(&self, vers: &mut [u8]) -> Option<Result<VueDeLEcran, VueDeLEcran>> {
        let carte = self.carte.tenir();
        let cadre = &carte.ecran()?.cadre;
        let mode = cadre.mode();
        let octets = cadre.octets();
        let vue = VueDeLEcran {
            memoire: octets.as_ptr(),
            taille: octets.len(),
            largeur: mode.largeur,
            hauteur: mode.hauteur,
            octets_par_ligne: mode.octets_par_ligne,
            debut: mode.debut,
            revision: cadre.revision(),
        };
        let ligne = mode.largeur as usize * 4;
        let besoin = ligne * mode.hauteur as usize;
        if vers.len() < besoin {
            return Some(Err(vue));
        }
        for rang in 0..mode.hauteur as usize {
            let depuis = mode.debut as usize + rang * mode.octets_par_ligne as usize;
            let Some(source) = octets.get(depuis..depuis + ligne) else {
                // Un mode qui sortirait de la mémoire vidéo : la carte le
                // refuse (`Cadre::regler_mode`) ; rien n'est lu au-delà.
                return Some(Err(vue));
            };
            vers[rang * ligne..(rang + 1) * ligne].copy_from_slice(source);
        }
        Some(Ok(vue))
    }

    /// **Ce que le premier disque a vu** : les requêtes servies et refusées,
    /// ou rien sans disque. Zéro et zéro dit un noyau sans pilote bloc.
    pub fn activite_du_disque(&self) -> Option<(u64, u64)> {
        let carte = self.carte.tenir();
        carte
            .carte()
            .disque(Disque::Premier)
            .map(|disque| (disque.servies, disque.refusees))
    }

    /// Les octets que l'invité a changés, sur les deux disques.
    pub fn octets_ecrits(&self) -> u64 {
        let carte = self.carte.tenir();
        Disque::TOUS
            .iter()
            .map(|&quel| carte.octets_ecrits(quel))
            .fold(0u64, u64::saturating_add)
    }

    /// Pousser les écritures des disques jusqu'au stockage durable ; `false`
    /// si un arrière l'a refusé.
    pub fn vider_les_disques(&self) -> bool {
        self.carte.tenir().vider()
    }

    /// **Où en est la course**, publié à la fin de chaque tranche : les
    /// instructions retirées et RIP. Rien avant la première tranche.
    pub fn avancement(&self) -> Option<(u64, u64)> {
        self.publie.load(Ordering::Acquire).then(|| {
            (
                self.retirees.load(Ordering::Relaxed),
                self.rip.load(Ordering::Relaxed),
            )
        })
    }
}

/// Pourquoi un branchement est refusé.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RefusDeBranchement {
    /// Le noyau est déjà chargé (ou une machine reprise) : on branche machine
    /// éteinte.
    DejaDemarree,
    /// Un écran est déjà branché.
    EcranDejaLa,
    /// Le cadre ne tient pas dans les seize mébioctets de la mémoire vidéo,
    /// ou une dimension est nulle.
    EcranTropGrand,
}

/// **La machine, menée par un hôte.**
pub struct Poste {
    pub machine: Machine,
    commandes: Arc<Commandes>,
    ecran: Option<Ecran>,
    /// Un noyau a été chargé, ou un instantané repris : il y a quelque chose
    /// à faire tourner.
    pret: bool,
    /// Le temps passé dehors, encore à rattraper, en instructions.
    du: u64,
    /// Le temps rattrapé jusqu'ici, en instructions : du temps du dehors, pas
    /// du travail, et que [`Poste::temps`] ne compte pas.
    rattrape: u64,
}

impl Poste {
    /// **Un poste de `ram` octets** (au moins le plancher de la machine), sa
    /// carte branchée ; rien quand l'hôte ne peut pas donner la RAM.
    pub fn essayer(ram: u64) -> Option<Self> {
        let mut machine = Machine::essayer(ram)?;
        let carte = brancher(&mut machine, CartePc::nouvelle());
        Some(Self {
            machine,
            commandes: Arc::new(Commandes {
                arret: AtomicBool::new(false),
                serie: Mutex::new(Vec::new()),
                touches: Mutex::new(Touches::default()),
                carte,
                retirees: AtomicU64::new(0),
                rip: AtomicU64::new(0),
                publie: AtomicBool::new(false),
            }),
            ecran: None,
            pret: false,
            du: 0,
            rattrape: 0,
        })
    }

    /// Les commandes, à tendre aux autres fils.
    pub fn commandes(&self) -> &Arc<Commandes> {
        &self.commandes
    }

    /// Quelque chose à faire tourner : un noyau chargé, ou une machine reprise.
    pub fn pret(&self) -> bool {
        self.pret
    }

    /// L'écran annoncé au noyau, s'il y en a un.
    pub fn ecran(&self) -> Option<Ecran> {
        self.ecran
    }

    /// **L'heure de l'horloge CMOS**, en secondes depuis 1970, figée : deux
    /// courses du même noyau retirent alors les mêmes instructions. Sans
    /// elle, la carte lit l'horloge qu'on lui donne ([`Poste::horloge`]), ou
    /// 1970.
    pub fn regler_l_heure(&mut self, secondes: i64) {
        let millisecondes = secondes.saturating_mul(1000);
        let mut carte = self.commandes.carte.tenir();
        // Une horloge déjà donnée serait relue au premier accès aux ports
        // 0x70 et 0x71, par-dessus l'heure posée : elle est remplacée par
        // une horloge arrêtée.
        carte.horloge(move || millisecondes);
        carte.regler_heure(millisecondes);
        self.machine.herites.cmos.regler(secondes.max(0) as u64);
    }

    /// Donner une horloge à la carte : l'heure UTC, en millisecondes.
    pub fn horloge(&mut self, horloge: impl FnMut() -> i64 + Send + 'static) {
        self.commandes.carte.tenir().horloge(horloge);
    }

    /// La graine de `rdrand` et `rdseed` : la même graine rend les mêmes
    /// nombres. Le défaut est celle du cœur Swift (`GRAINE_REPRODUCTIBLE`).
    pub fn semer(&mut self, graine: u64) {
        self.machine.alea = Alea::Fixe(graine);
    }

    /// **Brancher un disque**, machine éteinte : le premier (`vda`) ou le
    /// second (`vdb`).
    pub fn brancher_disque(
        &mut self,
        quel: Disque,
        arriere: impl Arriere + 'static,
    ) -> Result<(), RefusDeBranchement> {
        if self.pret {
            return Err(RefusDeBranchement::DejaDemarree);
        }
        self.commandes.carte.tenir().brancher(quel, arriere);
        Ok(())
    }

    /// **Brancher l'écran** (la carte de Bochs et sa tablette), machine
    /// éteinte et une seule fois : la mémoire vidéo ne bouge plus ensuite, et
    /// son adresse peut être tendue à une vue.
    pub fn brancher_ecran(&mut self, largeur: u32, hauteur: u32) -> Result<(), RefusDeBranchement> {
        if self.pret {
            return Err(RefusDeBranchement::DejaDemarree);
        }
        if self.ecran.is_some() {
            return Err(RefusDeBranchement::EcranDejaLa);
        }
        if largeur == 0
            || hauteur == 0
            || !self
                .commandes
                .carte
                .tenir()
                .brancher_ecran(largeur, hauteur)
        {
            return Err(RefusDeBranchement::EcranTropGrand);
        }
        self.ecran = Some(Ecran {
            base: BASE_DE_LA_MEMOIRE_VIDEO,
            largeur: largeur as usize,
            hauteur: hauteur as usize,
        });
        Ok(())
    }

    /// **Charger un noyau**, avec sa ligne (celle par défaut sinon) et son
    /// initramfs : `Machine::charger`, l'écran branché annoncé.
    pub fn charger(
        &mut self,
        noyau: &[u8],
        ligne: Option<&str>,
        initramfs: Option<&[u8]>,
    ) -> Result<Placement, Refus> {
        let placement = self.machine.charger(noyau, ligne, initramfs, self.ecran)?;
        self.pret = true;
        Ok(placement)
    }

    /// Combien d'instructions vaut une seconde de l'invité.
    pub fn hertz(&self) -> u64 {
        self.machine
            .instructions_par_battement
            .saturating_mul(HERTZ_DU_8253)
    }

    /// **Le temps de l'invité**, en instructions : ce qu'il a retiré et ce
    /// qu'il a dormi, sans le temps rattrapé — qui n'est ni du travail ni de
    /// l'attente que l'hôte doive dormir.
    pub fn temps(&self) -> u64 {
        self.machine
            .retirees
            .wrapping_add(self.machine.attente)
            .wrapping_sub(self.rattrape)
    }

    /// Le temps encore à rattraper, en instructions.
    pub fn temps_du(&self) -> u64 {
        self.du
    }

    /// **Le temps passé hors de la machine**, en secondes : payé ensuite par
    /// pas de dix secondes au plus, pendant que l'invité dort — voir
    /// `GuestMachine.elapse(seconds:)`. Un écart négatif, nul ou qui n'est
    /// pas un nombre ne fait rien ; au-delà de dix ans, il est borné.
    pub fn rattraper(&mut self, secondes: f64) {
        if !secondes.is_finite() || secondes <= 0.0 {
            return;
        }
        let secondes = secondes.min(PLUS_LONG_RATTRAPAGE_EN_SECONDES);
        let instructions = (secondes * self.hertz() as f64) as u64;
        self.du = self.du.saturating_add(instructions);
    }

    /// Les octets tapés et les frappes qui attendent, donnés à la machine.
    fn donner_les_entrees(&mut self) {
        let serie = std::mem::take(&mut *tenir(&self.commandes.serie));
        if !serie.is_empty() {
            self.machine.taper(&serie);
        }
        let mut touches = tenir(&self.commandes.touches);
        if touches.attente.is_empty() {
            return;
        }
        let mut carte = self.commandes.carte.tenir();
        while carte.carte().ps2.frappes.len() < FRAPPES_REMISES {
            let Some((code, enfoncee)) = touches.attente.pop_front() else {
                break;
            };
            carte.taper(code, enfoncee);
            touches.tenues_remises.noter(code, enfoncee);
        }
    }

    /// L'avancement, publié pour les autres fils.
    fn publier(&self) {
        self.commandes
            .retirees
            .store(self.machine.retirees, Ordering::Relaxed);
        self.commandes
            .rip
            .store(self.machine.cpu.rip, Ordering::Relaxed);
        self.commandes.publie.store(true, Ordering::Release);
    }

    /// **Faire tourner l'invité** jusqu'à `budget` instructions de son temps
    /// (le sommeil compté, le rattrapage non), ou jusqu'à ce qu'il s'arrête,
    /// qu'on le lui demande, ou qu'il faute. Ce qu'il écrit sur son port série
    /// part dans `sortie`, tranche par tranche.
    pub fn courir(&mut self, budget: u64, sortie: &mut dyn FnMut(&[u8])) -> Fin {
        if !self.pret {
            return Fin::Faute(
                "rien à faire tourner : ni noyau chargé, ni machine reprise".to_string(),
            );
        }
        let pas_de_rattrapage = self.hertz().saturating_mul(PAS_DE_RATTRAPAGE_EN_SECONDES);
        let mut faites = 0u64;
        loop {
            if self.commandes.arret.swap(false, Ordering::SeqCst) {
                return Fin::Arretee;
            }
            if faites >= budget {
                return Fin::Budget;
            }
            self.donner_les_entrees();
            let rendu = self.machine.tourner(TRANCHE.min(budget - faites));
            self.publier();
            let octets = self.machine.sortie();
            if !octets.is_empty() {
                sortie(&octets);
            }
            match rendu {
                Err(pourquoi) => {
                    return if self.commandes.carte.tenir().remise_demandee() {
                        Fin::Remise
                    } else {
                        Fin::Faute(pourquoi)
                    };
                }
                // Une tranche qui n'exécute rien : un `hlt` que rien ne
                // réveille.
                Ok(0) => return Fin::Eteinte,
                Ok(rendues) => faites = faites.saturating_add(rendues),
            }
            // **Le temps dû, un pas par sommeil** : il ne compte pas dans le
            // budget, c'est du temps du dehors.
            if self.machine.arretee && self.du > 0 {
                let pas = self.du.min(pas_de_rattrapage.max(1));
                self.machine.attente = self.machine.attente.wrapping_add(pas);
                self.rattrape = self.rattrape.wrapping_add(pas);
                self.du -= pas;
            }
        }
    }

    /// Les deux compteurs de rattrapage, pour l'instantané.
    pub(super) fn rattrapage(&self) -> (u64, u64) {
        (self.du, self.rattrape)
    }

    /// Reposés par une reprise.
    pub(super) fn reposer(&mut self, du: u64, rattrape: u64) {
        self.du = du;
        self.rattrape = rattrape;
        self.pret = true;
    }
}
