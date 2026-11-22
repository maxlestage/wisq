//! **La carte de la machine PC** : ce qui répond aux ports d'E/S que ni les
//! deux 8259, ni le 8254, ni le 16550 de la boucle hôte ne prennent, et les
//! lignes d'interruption que ces périphériques tiennent.
//!
//! **Écrite une fois, pour deux machines.** La page WebKit la charge en
//! wasm32, derrière les exports `carte_*` de `crates/wisq-page`
//! (`src/carte_porte.rs`) et `web/carte.js` ; la machine PC native la prend
//! par [`pc::CartePc`], qui tient en plus les disques sur fichier
//! ([`fichier`]). C'est pour elle que ce dossier est un crate à lui,
//! `wisq-carte`, sans dépendance : `wisq-page` dépend de `wisq-vm`, et
//! `wisq-vm` ne pouvait donc pas nommer un module de `wisq-page`.
//!
//! **Pourquoi en Rust, et pourquoi ici.** Un port est un appel synchrone :
//! `env.in` est appelé depuis le module d'une région et doit rendre sa valeur
//! tout de suite. Swift n'est joignable que par message, donc aucun registre
//! ne peut vivre de son côté ; tout ce qui lit ou écrit un registre vit dans
//! la page. La carte du 14 novembre (§ 4.3) a tranché pour du Rust compilé en
//! wasm32 à côté de l'émetteur, dans le même module : les modèles se testent
//! en natif sans moteur JavaScript, se portent un pour un depuis le cœur
//! Swift, et se répartissent entre agents un fichier par périphérique, sans
//! que personne n'écrive dans `host.js`.
//!
//! **La carte est celle du cœur Swift, exactement** : mêmes ports, mêmes
//! lignes, mêmes réponses (`X86CoreDispatch.swift`, `portWrite` et
//! `portRead`). Un instantané pris par un cœur pourra un jour être repris par
//! l'autre seulement à ce prix.
//!
//! | ports | périphérique | ligne |
//! | --- | --- | --- |
//! | `0x60`, `0x64` | i8042, clavier et souris ([`i8042`]) | 1 et 12 |
//! | `0x70`, `0x71` | CMOS, horloge ([`cmos`]) | aucune |
//! | `0xCF8`, `0xCFC` à `0xCFF` | pont PCI ([`pci`]) : 440FX en 00:00.0 | — |
//! | la BAR0 du disque, `0x40` ports | virtio-blk de forme ancienne en 00:03.0 ([`virtio_blk`]) | 5, ou celle que le noyau écrit |
//! | la BAR0 du second disque, `0x40` ports | le même, en 00:04.0 | 6, ou celle que le noyau écrit |
//! | la BAR0 de la carte réseau, `0x40` ports | virtio-net de forme ancienne en 00:05.0 ([`virtio_net`]), quand elle est branchée | 3, ou celle que le noyau écrit |
//! | `0x1CE`, `0x1CF`, et en mémoire : 16 Mio à `0xE000_0000`, 4 Kio à `0xE100_0000` | l'écran Bochs en 00:02.0 ([`ecran`]), quand il est branché | aucune |
//! | en mémoire : 16 Kio à `0xE101_0000` | la tablette virtio en 00:07.0 ([`tablette`]), avec l'écran | 10, ou celle que le noyau écrit |
//!
//! **Deux périphériques vivent en mémoire, pas dans les ports** : la mémoire
//! vidéo et les registres de l'écran, et la tablette, dont le transport est
//! le virtio « moderne ». Leurs adresses ne sont pas de la RAM : la machine
//! passe à [`Carte::mem_lire`] et [`Carte::mem_ecrire`] tout accès de
//! l'invité qui tombe hors de sa RAM, et la carte dit si l'adresse est à
//! elle. Les adresses sont celles que le noyau écrit dans les BAR ; les
//! valeurs du tableau sont celles du départ.
//!
//! **Les lignes sont à niveau.** [`Carte::lignes`] dit, à l'instant, quelles
//! lignes ses périphériques tiennent levées, et [`Carte::tenues`] lesquelles
//! elle tient tout court : la boucle hôte recopie les premières dans les
//! registres de requête de ses 8259 et efface le reste des secondes, à chaque
//! tour — ce que `serviceInterrupts` fait du côté Swift. Une source qui n'est
//! pas un registre (une fin de lecture disque venue de Swift, un jour) lève et
//! baisse la sienne par [`Carte::lever`] et [`Carte::baisser`].
//!
//! **La RAM de l'invité** n'est pas dans la mémoire de ce module : elle est
//! dans la `WebAssembly.Memory` de la boucle hôte. Un périphérique qui la lit
//! — la file du disque virtio — passe donc par le trait [`Ram`], que chaque
//! appel de port reçoit.
//!
//! **Le disque répond plus tard.** Ses octets ne sont pas dans la page : une
//! lecture ou une écriture **part** ([`Carte::requete_disque`]), la boucle
//! hôte la confie à un arrière qui répond quand il peut, et la réponse
//! ([`Carte::disque_lu`], [`Carte::disque_fini`]) remplit la RAM et lève la
//! ligne. Voir [`virtio_blk`].

pub mod cmos;
pub mod ecran;
mod etat;
#[cfg(not(target_arch = "wasm32"))]
pub mod fichier;
pub mod i8042;
pub mod pc;
pub mod pci;
pub mod tablette;
pub mod virtio_blk;
pub mod virtio_net;

use cmos::Cmos;
use ecran::Ecran;
use i8042::{CodeTouche, I8042, LIGNE_CLAVIER, LIGNE_SOURIS, PORT_COMMANDE, PORT_DONNEES};
use pci::{masque, Disque, Pci, PORT_ADRESSE, PORT_DONNEE};
use tablette::Tablette;
use virtio_blk::{RequeteDisque, VirtioBlk};
use virtio_net::VirtioNet;

/// **La RAM de l'invité, vue d'un périphérique**, par adresse physique.
///
/// Rend `false`, sans rien toucher, quand la plage ne tient pas entière dans
/// la RAM : un périphérique qui suit un descripteur mal formé doit pouvoir le
/// refuser plutôt que lire à côté.
pub trait Ram {
    fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool;
    fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool;
}

/// **Une RAM en un seul bloc**, à partir de l'adresse zéro : celle des tests
/// natifs, et de tout appelant qui tient la RAM dans un `Vec`.
pub struct RamPlate(pub Vec<u8>);

impl RamPlate {
    fn plage(&self, adresse: u64, longueur: usize) -> Option<std::ops::Range<usize>> {
        let debut = usize::try_from(adresse).ok()?;
        let fin = debut.checked_add(longueur)?;
        (fin <= self.0.len()).then_some(debut..fin)
    }
}

impl Ram for RamPlate {
    fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool {
        let Some(plage) = self.plage(adresse, vers.len()) else {
            return false;
        };
        vers.copy_from_slice(&self.0[plage]);
        true
    }

    fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool {
        let Some(plage) = self.plage(adresse, depuis.len()) else {
            return false;
        };
        self.0[plage].copy_from_slice(depuis);
        true
    }
}

/// **Aucune RAM** : tout accès est refusé. Ce que reçoit un accès qui ne
/// doit pas la toucher, et ce que voit un disque qu'on conduit sans elle :
/// une file illisible, donc rien de servi.
pub struct SansRam;

impl Ram for SansRam {
    fn lire(&self, _: u64, _: &mut [u8]) -> bool {
        false
    }
    fn ecrire(&mut self, _: u64, _: &[u8]) -> bool {
        false
    }
}

/// Les lignes que les périphériques de la carte tiennent par eux-mêmes.
pub const LIGNES_DES_PERIPHERIQUES: u16 = (1 << LIGNE_CLAVIER) | (1 << LIGNE_SOURIS);

/// **Les lignes que la boucle hôte tient elle-même**, et que la carte refuse
/// donc de lever : la 0 (le 8254), la 2 (la cascade de l'esclave) et la 4 (le
/// port série). Si la carte les déclarait tenues, l'aiguillage de `host.js`
/// effacerait à chaque tour ce que ses propres puces y ont posé.
pub const LIGNES_DE_L_HOTE: u16 = (1 << 0) | (1 << 2) | (1 << 4);

/// **À qui est une adresse hors de la RAM**, et où elle tombe dedans. Dans
/// l'ordre où le cœur Swift les essaie (`X86Memory.readSlowly`) : la mémoire
/// vidéo, les registres de la carte graphique, la tablette.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Region {
    /// La mémoire vidéo, et le décalage dedans.
    MemoireVideo(usize),
    /// Les registres de la carte graphique (sa BAR2), et le décalage dedans.
    RegistresDeLEcran(u64),
    /// La BAR0 de la tablette, et le décalage dedans.
    Tablette(u64),
}

/// **La carte** : les périphériques, et les lignes levées du dehors.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Carte {
    pub cmos: Cmos,
    pub ps2: I8042,
    /// Le bus PCI, et le disque qui est dessus.
    pub pci: Pci,
    /// Les lignes levées par [`Carte::lever`] et pas encore baissées.
    levees_du_dehors: u16,
    /// Toutes celles que [`Carte::lever`] ou [`Carte::baisser`] ont nommées :
    /// une fois nommée, la carte la tient, et une ligne baissée doit retomber
    /// chez les 8259.
    nommees_du_dehors: u16,
}

impl Default for Carte {
    fn default() -> Self {
        Self::nouvelle()
    }
}

impl Carte {
    /// Une carte comme la laisse un BIOS. `const` pour tenir dans une
    /// `static` (la porte de la page).
    pub const fn nouvelle() -> Self {
        Self {
            cmos: Cmos::nouvelle(),
            ps2: I8042::nouveau(),
            pci: Pci::nouveau(),
            levees_du_dehors: 0,
            nommees_du_dehors: 0,
        }
    }

    /// **Lire un port**, de `largeur` octets (1, 2 ou 4). `None` : personne
    /// ici — la boucle hôte rend alors ce qu'elle rend pour un port vide
    /// (`0xff`, le bus qui flotte).
    ///
    /// L'i8042 et l'horloge sont des puces à registres d'un octet : une
    /// lecture plus large rend l'octet, et zéro au-dessus, comme `portRead`
    /// du cœur Swift (qui ne regarde pas la largeur pour eux). Le bus et le
    /// disque rendent leur registre ramené à la largeur, comme l'`in` du cœur
    /// Swift l'écrit dans le registre de l'invité.
    ///
    /// **Les ports fixes passent avant la fenêtre du disque** : une BAR posée
    /// par-dessus l'i8042 ne lui vole rien.
    pub fn port_lire(&mut self, port: u16, largeur: u8, _ram: &mut dyn Ram) -> Option<u32> {
        if !largeur_valide(largeur) {
            return None;
        }
        let octet = match port {
            PORT_DONNEES => self.ps2.lire_donnee(),
            PORT_COMMANDE => self.ps2.etat(),
            // L'index ne se relit pas : le cœur Swift rend zéro (il tombe
            // dans son cas par défaut), et Linux ne le lit jamais.
            0x70 => 0,
            0x71 => self.cmos.lire(),
            PORT_ADRESSE => return Some((u64::from(self.pci.adresse()) & masque(largeur)) as u32),
            PORT_DONNEE..=0xCFF => {
                return Some(self.pci.lire_donnee(u32::from(port - PORT_DONNEE), largeur))
            }
            // Les registres DISPI de l'écran : seize bits, ramenés à la
            // largeur de l'accès. Sans écran, ces deux ports ne sont à
            // personne.
            ecran::PORT_INDEX | ecran::PORT_DONNEE if self.pci.ecran.is_some() => {
                let registre = self.pci.ecran.as_ref()?.lire_port(port);
                return Some((u64::from(registre) & masque(largeur)) as u32);
            }
            _ => {
                let valeur = if let Some((quel, decalage)) = self.fenetre_au_port(port) {
                    let disque = self.pci.emplacement_mut(quel).peripherique.as_mut()?;
                    disque.lire_port(decalage, largeur)
                } else {
                    let decalage = self.reseau_au_port(port)?;
                    let reseau = self.pci.reseau.peripherique.as_mut()?;
                    reseau.lire_port(decalage, largeur)
                };
                return Some((u64::from(valeur) & masque(largeur)) as u32);
            }
        };
        Some(u32::from(octet))
    }

    /// **Écrire un port**, de `largeur` octets. `false` : personne ici, et
    /// l'écriture tombe dans le vide. Une écriture plus large qu'un octet
    /// n'en garde que l'octet bas pour l'i8042 et l'horloge, comme
    /// `portWrite` du cœur Swift ; le bus et le disque reçoivent la valeur
    /// ramenée à la largeur — un `outw` écrit deux octets, pas quatre.
    ///
    /// `ram` est celle de l'invité : la notification du disque y lit sa file.
    pub fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32, ram: &mut dyn Ram) -> bool {
        if !largeur_valide(largeur) {
            return false;
        }
        let octet = valeur as u8;
        let valeur = (u64::from(valeur) & masque(largeur)) as u32;
        match port {
            PORT_DONNEES => self.ps2.ecrire_donnee(octet),
            PORT_COMMANDE => self.ps2.ecrire_commande(octet),
            0x70 => self.cmos.choisir(octet),
            0x71 => self.cmos.ecrire(octet),
            PORT_ADRESSE => self.pci.ecrire_adresse(valeur),
            PORT_DONNEE..=0xCFF => {
                self.pci
                    .ecrire_donnee(u32::from(port - PORT_DONNEE), largeur, valeur)
            }
            // Les registres DISPI : la valeur ramenée à la largeur, puis à
            // seize bits, comme `portWrite` du cœur Swift.
            ecran::PORT_INDEX | ecran::PORT_DONNEE if self.pci.ecran.is_some() => {
                if let Some(ecran) = self.pci.ecran.as_mut() {
                    ecran.ecrire_port(port, valeur as u16);
                }
            }
            _ => {
                if let Some((quel, decalage)) = self.fenetre_au_port(port) {
                    let Some(disque) = self.pci.emplacement_mut(quel).peripherique.as_mut() else {
                        return false;
                    };
                    disque.ecrire_port(decalage, valeur, ram);
                } else {
                    let Some(decalage) = self.reseau_au_port(port) else {
                        return false;
                    };
                    let Some(reseau) = self.pci.reseau.peripherique.as_mut() else {
                        return false;
                    };
                    reseau.ecrire_port(decalage, valeur, ram);
                }
            }
        }
        true
    }

    /// **Le disque qui répond à ce port, et le décalage dans sa fenêtre** —
    /// jamais pour un port fixe de la carte : une BAR posée par-dessus
    /// l'i8042 ne lui vole rien.
    pub fn fenetre_au_port(&self, port: u16) -> Option<(Disque, u16)> {
        if self.est_fixe(port) {
            return None;
        }
        self.pci.au_port(port)
    }

    /// **Le décalage d'un port dans la fenêtre de la carte réseau** — jamais
    /// pour un port fixe, ni pour un port qu'un disque a déjà : la fenêtre
    /// d'un disque passe devant ([`Pci::reseau_au_port`]).
    pub fn reseau_au_port(&self, port: u16) -> Option<u16> {
        if self.est_fixe(port) {
            return None;
        }
        self.pci.reseau_au_port(port)
    }

    /// **Un port fixe de cette carte** : ceux de toute carte ([`port_fixe`]),
    /// et les deux ports DISPI quand un écran est branché. Ils passent avant
    /// toute fenêtre de disque, dans l'ordre du cœur Swift (`portWrite`).
    pub fn est_fixe(&self, port: u16) -> bool {
        port_fixe(port)
            || (self.pci.ecran.is_some() && matches!(port, ecran::PORT_INDEX | ecran::PORT_DONNEE))
    }

    // ------------------------------------------------- l'écran et la tablette

    /// **Brancher l'écran** (`X86Machine.attachDisplay`) : la carte graphique
    /// en 00:02.0, un cadre de `largeur` × `hauteur` au démarrage dans seize
    /// mébioctets de mémoire vidéo, et **la tablette qui va avec** en 00:07.0
    /// — un écran se touche. À faire avant le démarrage : c'est le chargeur
    /// qui annonce le cadre au noyau ([`ecran::Cadre::mode_de_depart`],
    /// [`ecran::Cadre::base`]). Un écran déjà branché est remplacé, sa
    /// tablette aussi.
    ///
    /// `false`, sans rien changer, si le cadre du démarrage ne tient pas dans
    /// la mémoire vidéo.
    ///
    /// **La RAM de l'invité ne doit pas couvrir ses adresses** (le trou sous
    /// quatre gibioctets, à partir de `0xE000_0000`) : c'est à la machine de
    /// le tenir, la carte ne connaît pas la RAM.
    pub fn brancher_ecran(&mut self, largeur: u32, hauteur: u32) -> bool {
        let Some(ecran) = Ecran::de_machine(largeur, hauteur) else {
            return false;
        };
        self.pci.ecran = Some(ecran);
        self.pci.tablette = Some(Tablette::de_machine());
        true
    }

    /// L'écran, s'il est branché : son cadre ([`Ecran::cadre`]) porte la
    /// mémoire vidéo, le mode montré et le compte des changements.
    pub fn ecran(&self) -> Option<&Ecran> {
        self.pci.ecran.as_ref()
    }

    /// Le même, pour y écrire d'un bloc ([`ecran::Cadre::octets_mut`]).
    pub fn ecran_mut(&mut self) -> Option<&mut Ecran> {
        self.pci.ecran.as_mut()
    }

    /// La tablette, si un écran est branché.
    pub fn tablette(&self) -> Option<&Tablette> {
        self.pci.tablette.as_ref()
    }

    /// La même, pour la conduire.
    pub fn tablette_mut(&mut self) -> Option<&mut Tablette> {
        self.pci.tablette.as_mut()
    }

    /// **À qui est cette adresse physique**, pour un accès de `largeur`
    /// octets : la mémoire vidéo d'abord, puis les registres de la carte
    /// graphique, puis la tablette — l'ordre du cœur Swift. `None` : pas à
    /// la carte. L'accès doit tenir entier dans la région.
    pub fn region(&self, adresse: u64, largeur: usize) -> Option<Region> {
        if let Some(ecran) = &self.pci.ecran {
            if let Some(a) = ecran.cadre.decalage(adresse, largeur) {
                return Some(Region::MemoireVideo(a));
            }
            if let Some(decalage) = ecran.decalage_des_registres(adresse, largeur) {
                return Some(Region::RegistresDeLEcran(decalage));
            }
        }
        let decalage = self.pci.tablette.as_ref()?.decalage(adresse, largeur)?;
        Some(Region::Tablette(decalage))
    }

    /// **Lire la mémoire d'un périphérique**, de `largeur` octets (un à
    /// huit : les largeurs impaires sont les moitiés d'un accès à cheval sur
    /// une page), à une adresse physique hors de la RAM. `None` : l'adresse
    /// n'est pas à la carte, et la machine lève sa faute « hors mémoire ».
    ///
    /// `&mut`, parce que lire l'ISR de la tablette l'efface.
    pub fn mem_lire(&mut self, adresse: u64, largeur: u8) -> Option<u64> {
        if !(1..=8).contains(&largeur) {
            return None;
        }
        let n = usize::from(largeur);
        let valeur = match self.region(adresse, n)? {
            Region::MemoireVideo(a) => self.pci.ecran.as_ref()?.cadre.lire(a, n),
            Region::RegistresDeLEcran(decalage) => {
                self.pci.ecran.as_ref()?.lire_registres(decalage, n)
            }
            Region::Tablette(decalage) => self.pci.tablette.as_mut()?.lire(decalage, n),
        };
        Some(if n >= 8 {
            valeur
        } else {
            valeur & ((1u64 << (8 * n)) - 1)
        })
    }

    /// **Écrire la mémoire d'un périphérique.** `false` : l'adresse n'est pas
    /// à la carte. `ram` est celle de l'invité : la sonnette de la tablette y
    /// lit sa file.
    pub fn mem_ecrire(
        &mut self,
        adresse: u64,
        largeur: u8,
        valeur: u64,
        ram: &mut dyn Ram,
    ) -> bool {
        if !(1..=8).contains(&largeur) {
            return false;
        }
        let n = usize::from(largeur);
        match self.region(adresse, n) {
            Some(Region::MemoireVideo(a)) => {
                if let Some(ecran) = self.pci.ecran.as_mut() {
                    ecran.cadre.ecrire(a, n, valeur);
                }
            }
            Some(Region::RegistresDeLEcran(decalage)) => {
                if let Some(ecran) = self.pci.ecran.as_mut() {
                    ecran.ecrire_registres(decalage, n, valeur);
                }
            }
            Some(Region::Tablette(decalage)) => {
                if let Some(tablette) = self.pci.tablette.as_mut() {
                    tablette.ecrire(decalage, n, valeur, ram);
                }
            }
            None => return false,
        }
        true
    }

    /// **Lire un bloc de la mémoire vidéo**, de n'importe quelle longueur :
    /// la copie d'une ligne entière (`rep movs`). `false`, sans rien toucher,
    /// si la plage ne tient pas entière dans la mémoire vidéo — les
    /// registres ne se lisent pas par blocs.
    pub fn mem_lire_bloc(&self, adresse: u64, vers: &mut [u8]) -> bool {
        let Some(ecran) = &self.pci.ecran else {
            return false;
        };
        let Some(a) = ecran.cadre.decalage(adresse, vers.len()) else {
            return false;
        };
        vers.copy_from_slice(&ecran.cadre.octets()[a..a + vers.len()]);
        true
    }

    /// **Écrire un bloc dans la mémoire vidéo.** La révision avance une
    /// fois, pas une fois par octet. `false`, sans rien toucher, si la plage
    /// ne tient pas entière.
    pub fn mem_ecrire_bloc(&mut self, adresse: u64, depuis: &[u8]) -> bool {
        let Some(ecran) = self.pci.ecran.as_mut() else {
            return false;
        };
        let Some(a) = ecran.cadre.decalage(adresse, depuis.len()) else {
            return false;
        };
        if !depuis.is_empty() {
            ecran.cadre.octets_mut()[a..a + depuis.len()].copy_from_slice(depuis);
            ecran.cadre.marquer();
        }
        true
    }

    /// **Un toucher**, par la tablette (`X86Machine.touch`) : la position
    /// rapportée à l'écran, de 0 à 1 sur chaque axe, et les boutons (bit 0
    /// gauche, 1 droit, 2 milieu). `false` quand l'invité n'a pas pris la
    /// tablette — pas d'écran, ou pas encore de pilote : l'application garde
    /// alors la souris PS/2 ([`Carte::souris`]). Le toucher part au prochain
    /// [`Carte::livrer`].
    pub fn toucher(&mut self, x: f64, y: f64, boutons: u8) -> bool {
        match self.pci.tablette.as_mut() {
            Some(tablette) if tablette.prete() => {
                tablette.pointer(x, y, boutons);
                true
            }
            _ => false,
        }
    }

    /// **La molette**, par la tablette (`X86Machine.scroll`) : des crans,
    /// positifs vers le haut, un paquet par cran, trente-deux au plus d'un
    /// coup. `false` quand la tablette n'est pas prise — la souris PS/2 de
    /// l'invité n'a que trois octets, pas de molette — ou pour zéro cran.
    pub fn defiler(&mut self, crans: i32) -> bool {
        match self.pci.tablette.as_mut() {
            Some(tablette) if tablette.prete() && crans != 0 => {
                tablette.defiler(crans);
                true
            }
            _ => false,
        }
    }

    /// **Rendre à l'invité ce que le doigt a fait**, dans les tampons de son
    /// pilote, au rythme d'un doigt : `tics` est l'heure de la machine, en
    /// tics du 8254, comme pour [`Carte::battre`]. La boucle hôte l'appelle
    /// à chaque tour, avant de relire les lignes (`serviceInterrupts` du
    /// côté Swift). Sans rien en attente, elle ne touche pas à la RAM.
    pub fn livrer(&mut self, tics: u64, ram: &mut dyn Ram) {
        if let Some(tablette) = self.pci.tablette.as_mut() {
            if tablette.en_attente() {
                tablette.livrer(ram, Some(tics));
            }
        }
    }

    /// **Brancher le disque** en 00:03.0 : `secteurs` secteurs de 512
    /// octets, dont les octets sont à l'arrière. Un disque déjà branché est
    /// remplacé, ses requêtes parties oubliées — à faire avant le démarrage,
    /// comme on branche un câble machine éteinte.
    ///
    /// **Les noms continuent** d'un disque à l'autre. Les requêtes de
    /// l'ancien sont oubliées, mais leurs réponses peuvent encore venir de
    /// l'arrière ; un disque neuf qui recommencerait à nommer depuis 1
    /// donnerait à sa première requête le nom d'une requête de l'ancien, et
    /// la réponse en retard remplirait ses tampons avec les octets d'un autre
    /// secteur, en la disant réussie.
    ///
    /// **Ce que l'ancien a confié reste compté** dans la borne du neuf
    /// ([`virtio_blk::PLUS_TENU`]) jusqu'à sa réponse : l'arrière le sert
    /// encore, quel que soit le disque branché.
    pub fn brancher_disque(&mut self, secteurs: u64) {
        self.brancher(Disque::Premier, secteurs);
    }

    /// **Brancher l'un des deux disques** : le premier en 00:03.0 (ligne 5,
    /// `vda`), le second en 00:04.0 (ligne 6, `vdb`). Les mêmes règles que
    /// [`Carte::brancher_disque`], emplacement par emplacement : chacun a ses
    /// noms et ses requêtes, et l'ordre de branchement est libre.
    pub fn brancher(&mut self, quel: Disque, secteurs: u64) {
        let place = self.pci.emplacement_mut(quel);
        let mut neuf = VirtioBlk::nouveau(secteurs);
        if let Some(ancien) = &place.peripherique {
            neuf.succeder_a(ancien);
        }
        place.peripherique = Some(neuf);
    }

    // ---------------------------------------------------------- la carte réseau

    /// **Brancher la carte réseau** en 00:05.0 (`X86Machine.attach(network:)`),
    /// d'adresse `mac`, ligne 3, **câble débranché** : ce que l'invité envoie
    /// est perdu jusqu'à [`VirtioNet::brancher_cable`]. Une carte déjà
    /// branchée est remplacée, ce qui l'attendait perdu, **et son
    /// emplacement repart neuf** ([`Pci::brancher_reseau`]) : fenêtre fermée,
    /// commande nulle, ligne 3, comme l'hôte neuf du cœur Swift — à faire
    /// avant le démarrage.
    pub fn brancher_reseau(&mut self, mac: [u8; 6]) {
        self.pci.brancher_reseau(VirtioNet::nouvelle(mac));
    }

    /// La carte réseau, si elle est branchée.
    pub fn reseau(&self) -> Option<&VirtioNet> {
        self.pci.reseau.peripherique.as_ref()
    }

    /// La même, pour la conduire : lui donner ce qui arrive
    /// ([`VirtioNet::entrer`], [`VirtioNet::livrer`], [`VirtioNet::sonder`]),
    /// prendre ce qui part ([`VirtioNet::sortir`]).
    pub fn reseau_mut(&mut self) -> Option<&mut VirtioNet> {
        self.pci.reseau.peripherique.as_mut()
    }

    /// La ligne de la carte réseau, en bit : celle que le noyau a écrite,
    /// trois au départ. Zéro sans carte, ou pour une ligne de l'hôte.
    fn bit_du_reseau(&self) -> u16 {
        if self.pci.reseau.peripherique.is_none() {
            return 0;
        }
        bit_du_dehors(self.pci.reseau.ligne).unwrap_or(0)
    }

    /// L'un des deux disques, s'il est branché.
    pub fn disque(&self, quel: Disque) -> Option<&VirtioBlk> {
        self.pci.emplacement(quel).peripherique.as_ref()
    }

    /// Le même, pour le conduire : prendre ses requêtes, lui rendre ses
    /// réponses ([`VirtioBlk::prendre_requete`], [`VirtioBlk::lu`],
    /// [`VirtioBlk::fini`]).
    pub fn disque_mut(&mut self, quel: Disque) -> Option<&mut VirtioBlk> {
        self.pci.emplacement_mut(quel).peripherique.as_mut()
    }

    /// **Notifier un disque sans passer par son port** : relire sa file dans
    /// `ram`, comme l'écriture de son registre `0x10`. Ce que fait une
    /// machine qui a noté la notification pendant l'`out` et ne prête sa RAM
    /// qu'après ([`pc::CartePc::servir`]).
    pub fn notifier(&mut self, quel: Disque, ram: &mut dyn Ram) {
        if let Some(disque) = self.disque_mut(quel) {
            disque.ecrire_port(virtio_blk::REGISTRE_DE_NOTIFICATION, 0, ram);
        }
    }

    /// **La prochaine requête du premier disque pour l'arrière**, ou rien.
    /// La boucle hôte la prend après chaque `out` qui a pu notifier, la
    /// confie à l'arrière, et rend la réponse quand elle arrive. Celles du
    /// second se prennent par [`Carte::disque_mut`].
    pub fn requete_disque(&mut self) -> Option<RequeteDisque> {
        self.pci.premier.peripherique.as_mut()?.prendre_requete()
    }

    /// **Les octets d'une lecture sont arrivés** : voir [`VirtioBlk::lu`].
    /// `false` quand `id` ne nomme aucune requête partie.
    pub fn disque_lu(&mut self, id: u32, octets: &[u8], ram: &mut dyn Ram) -> bool {
        self.pci
            .premier
            .peripherique
            .as_mut()
            .is_some_and(|disque| disque.lu(id, octets, ram))
    }

    /// **Une requête est finie sans octets** : voir [`VirtioBlk::fini`].
    pub fn disque_fini(&mut self, id: u32, reussi: bool, ram: &mut dyn Ram) -> bool {
        self.pci
            .premier
            .peripherique
            .as_mut()
            .is_some_and(|disque| disque.fini(id, reussi, ram))
    }

    /// **La ligne d'un disque, en bit**, si elle est une ligne que la carte
    /// peut tenir : celle que le noyau a écrite dans la configuration, cinq
    /// au départ pour le premier, six pour le second. Une ligne de l'hôte ou
    /// au-delà de 15 n'est jamais tenue — le disque s'y tairait plutôt que
    /// d'effacer ce que les puces de la boucle hôte y posent.
    fn bit_du_disque(&self, quel: Disque) -> u16 {
        let place = self.pci.emplacement(quel);
        if place.peripherique.is_none() {
            return 0;
        }
        bit_du_dehors(place.ligne).unwrap_or(0)
    }

    /// Les lignes des disques branchés, levées ou non.
    fn bits_des_disques(&self) -> u16 {
        Disque::TOUS
            .into_iter()
            .fold(0, |bits, quel| bits | self.bit_du_disque(quel))
    }

    /// **Les seize lignes, à niveau** : le bit `n` est la ligne `n` (0 à 7 au
    /// maître, 8 à 15 à l'esclave). Seules les lignes de [`Carte::tenues`]
    /// peuvent y paraître.
    pub fn lignes(&self) -> u16 {
        let mut lignes = self.levees_du_dehors;
        // Chaque disque, tant que son état d'interruption n'est pas
        // acquitté. Deux disques que le noyau aurait mis sur la même ligne la
        // partagent : elle reste levée tant que l'un des deux la tient.
        for quel in Disque::TOUS {
            if self.disque(quel).is_some_and(VirtioBlk::interrompt) {
                lignes |= self.bit_du_disque(quel);
            }
        }
        // La tablette, tant que son ISR n'est pas lu.
        if self.pci.tablette.as_ref().is_some_and(Tablette::interrompt) {
            lignes |= self.bit_de_la_tablette();
        }
        // La carte réseau, de même, sur la ligne 3 du maître.
        if self.reseau().is_some_and(VirtioNet::interrompt) {
            lignes |= self.bit_du_reseau();
        }
        // Le clavier sur la ligne 1, la souris sur la ligne 12 — la
        // quatrième de l'esclave. À niveau, comme le port série.
        if self.ps2.clavier_interrompt() {
            lignes |= 1 << LIGNE_CLAVIER;
        }
        if self.ps2.souris_interrompt() {
            lignes |= 1 << LIGNE_SOURIS;
        }
        lignes
    }

    /// **Les lignes que la carte tient**, levées ou non : celles que la
    /// boucle hôte doit effacer quand [`Carte::lignes`] ne les lève pas.
    pub fn tenues(&self) -> u16 {
        LIGNES_DES_PERIPHERIQUES
            | self.bits_des_disques()
            | self.bit_de_la_tablette()
            | self.bit_du_reseau()
            | self.nommees_du_dehors
    }

    /// **La ligne de la tablette, en bit** : celle que le noyau a écrite dans
    /// sa configuration, dix au départ — la deuxième de l'esclave. Zéro sans
    /// tablette, ou pour une ligne que la carte ne peut pas tenir.
    fn bit_de_la_tablette(&self) -> u16 {
        self.pci
            .tablette
            .as_ref()
            .and_then(|tablette| bit_du_dehors(tablette.ligne))
            .unwrap_or(0)
    }

    /// **Lever une ligne du dehors**, jusqu'à [`Carte::baisser`]. Refusé
    /// (`false`) pour une ligne au-delà de 15 et pour celles de l'hôte
    /// ([`LIGNES_DE_L_HOTE`]).
    pub fn lever(&mut self, ligne: u8) -> bool {
        let Some(bit) = bit_du_dehors(ligne) else {
            return false;
        };
        self.nommees_du_dehors |= bit;
        self.levees_du_dehors |= bit;
        true
    }

    /// **Baisser une ligne levée du dehors.** Une ligne qu'un périphérique de
    /// la carte tient reste levée tant que lui la tient.
    pub fn baisser(&mut self, ligne: u8) -> bool {
        let Some(bit) = bit_du_dehors(ligne) else {
            return false;
        };
        self.nommees_du_dehors |= bit;
        self.levees_du_dehors &= !bit;
        true
    }

    /// **Le temps qui passe**, en tics du 8254 (1,193182 MHz) depuis le
    /// départ de la machine : ce qui pose les frappes de l'hôte à leur heure.
    /// La boucle hôte l'appelle à chaque tour, avant de relire les lignes.
    pub fn battre(&mut self, tics: u64) {
        if !self.ps2.frappes.is_empty() {
            self.ps2.rythmer(tics);
        }
    }

    /// **L'heure UTC de l'hôte**, en millisecondes depuis 1970 : voir
    /// [`Cmos::regler_heure_hote`].
    pub fn regler_heure(&mut self, ms: i64) {
        self.cmos.regler_heure_hote(ms);
    }

    /// Une touche posée tout de suite (un geste, une touche tenue par la
    /// barre de l'application).
    pub fn touche(&mut self, code: CodeTouche, enfoncee: bool) {
        self.ps2.touche(code, enfoncee);
    }

    /// Une frappe posée à son tour, au rythme d'une main ([`Carte::battre`]).
    /// `false` si la file pleine la refuse ; le relâchement d'une touche que
    /// la file laisse enfoncée n'est jamais refusé ([`I8042::taper`]).
    pub fn taper(&mut self, code: CodeTouche, enfoncee: bool) -> bool {
        self.ps2.taper(code, enfoncee)
    }

    /// **Un texte**, tapé sur un clavier américain, au rythme d'une main.
    /// Rend le nombre de frappes mises en file.
    ///
    /// La file est bornée ([`i8042::LIMITE_DE_FRAPPE`]), et un caractère y
    /// entre **entier ou pas du tout** : couper Maj, A, A, Maj après le
    /// premier A laissait A et Maj enfoncées dans l'invité. Le texte s'arrête
    /// au premier caractère qui ne tient plus, plutôt que de sauter celui-là
    /// et de taper les suivants, plus courts : l'invité reçoit le début du
    /// texte, pas un texte troué.
    pub fn taper_texte(&mut self, texte: &str) -> usize {
        let avant = self.ps2.frappes.len();
        for caractere in texte.chars() {
            let groupe = i8042::frappes_du_caractere(caractere);
            if !self.ps2.taper_groupe(&groupe) {
                break;
            }
        }
        self.ps2.frappes.len() - avant
    }

    /// Un mouvement de souris, Y vers le bas comme à l'écran.
    pub fn souris(&mut self, dx: i32, dy: i32, boutons: u8) {
        self.ps2.souris(dx, dy, boutons);
    }

    /// **L'invité a tiré la ligne de remise à zéro** (`0xFE` sur `0x64`) : la
    /// boucle hôte doit rendre « redémarrage ».
    pub fn remise_demandee(&self) -> bool {
        self.ps2.remise_demandee
    }

    /// **Quelque chose peut encore lever une ligne sans que l'invité
    /// agisse** : des frappes attendent leur tour, une requête du disque
    /// attend sa réponse, ou le disque tient sa ligne. Ce que `wakeable` de
    /// la boucle hôte doit compter, comme `devicesArmed` du côté Swift (qui
    /// compte `storage.interrupting`).
    ///
    /// La tablette compte quand sa ligne est levée ou qu'un geste attend son
    /// heure ([`Tablette::reveil`]). Le cœur Swift, lui, tient la machine
    /// éveillée dès qu'une tablette existe.
    ///
    /// **La carte réseau compte dès que son câble est branché** : une trame
    /// peut arriver à tout moment, et c'est ce que `devicesArmed` dit du côté
    /// Swift dès qu'une carte existe (là-bas, une carte n'est jamais branchée
    /// sans réseau : `GuestMachine` ne l'attache qu'avec lui). Câble
    /// débranché, elle compte encore tant que sa ligne est levée ou qu'une
    /// trame attend un tampon.
    pub fn reveil(&self) -> bool {
        !self.ps2.frappes.is_empty()
            || Disque::TOUS.into_iter().any(|quel| {
                self.disque(quel)
                    .is_some_and(|d| d.en_attente() || d.interrompt())
            })
            || self.pci.tablette.as_ref().is_some_and(Tablette::reveil)
            || self.reseau().is_some_and(|reseau| {
                reseau.cable_branche() || reseau.interrompt() || reseau.en_attente() > 0
            })
    }
}

pub(crate) fn largeur_valide(largeur: u8) -> bool {
    matches!(largeur, 1 | 2 | 4)
}

/// **Les ports fixes de toute carte** : l'i8042, l'horloge et le bus. Ils
/// passent avant toute fenêtre de disque. Un écran branché en ajoute deux
/// ([`Carte::est_fixe`]).
const fn port_fixe(port: u16) -> bool {
    matches!(
        port,
        PORT_DONNEES | PORT_COMMANDE | 0x70 | 0x71 | PORT_ADRESSE | PORT_DONNEE..=0xCFF
    )
}

fn bit_du_dehors(ligne: u8) -> Option<u16> {
    let bit = 1u16.checked_shl(u32::from(ligne))?;
    (ligne < 16 && bit & LIGNES_DE_L_HOTE == 0).then_some(bit)
}

// ------------------------------------------------- l'état, pour l'instantané

/// **La carte relue**, pas encore posée ([`Carte::poser`]).
pub(crate) struct CarteLu<'a> {
    cmos: Cmos,
    ps2: I8042,
    pub(crate) pci: pci::PciLu<'a>,
    levees_du_dehors: u16,
    nommees_du_dehors: u16,
}

impl Carte {
    /// **La carte**, pour l'instantané de la machine native ([`etat`]) :
    /// l'horloge, l'i8042, le bus et ses périphériques, les lignes levées du
    /// dehors.
    pub(crate) fn sauver(&self, e: &mut etat::Ecrivain) {
        self.cmos.sauver(e);
        self.ps2.sauver(e);
        self.pci.sauver(e);
        e.u16(self.levees_du_dehors);
        e.u16(self.nommees_du_dehors);
    }

    /// **Relue contre cette carte** (l'écran doit être le sien), ou rien.
    /// Une ligne levée du dehors est nommée, et aucune n'est de celles que
    /// l'hôte tient ([`LIGNES_DE_L_HOTE`]) : [`Carte::lever`] les refuse.
    pub(crate) fn relire<'a>(&self, l: &mut etat::Lecteur<'a>) -> Option<CarteLu<'a>> {
        let cmos = Cmos::relire(l)?;
        let ps2 = I8042::relire(l)?;
        let pci = self.pci.relire(l)?;
        let levees_du_dehors = l.u16()?;
        let nommees_du_dehors = l.u16()?;
        let valide =
            levees_du_dehors & !nommees_du_dehors == 0 && nommees_du_dehors & LIGNES_DE_L_HOTE == 0;
        valide.then_some(CarteLu {
            cmos,
            ps2,
            pci,
            levees_du_dehors,
            nommees_du_dehors,
        })
    }

    /// **Poser la carte relue**, d'un coup : rien ne peut plus échouer.
    pub(crate) fn poser(&mut self, lu: CarteLu<'_>) {
        self.cmos = lu.cmos;
        self.ps2 = lu.ps2;
        self.pci.poser(lu.pci);
        self.levees_du_dehors = lu.levees_du_dehors;
        self.nommees_du_dehors = lu.nommees_du_dehors;
    }
}

#[cfg(test)]
mod tests {
    //! La carte par ses ports et ses lignes, comme la boucle hôte la voit :
    //! le cinquième cas de `X86CMOSClockTests` (par les ports), le neuvième
    //! de `X86PS2Tests` (la cascade, réduite à ce que la carte en tient : la
    //! ligne 12, quatrième de l'esclave), le rythme de frappe vu des lignes,
    //! et ce que la carte ne prend pas.
    use super::cmos::tests::MOMENT_MS;
    use super::*;

    fn lire(carte: &mut Carte, port: u16) -> Option<u32> {
        carte.port_lire(port, 1, &mut SansRam)
    }

    fn ecrire(carte: &mut Carte, port: u16, valeur: u32) -> bool {
        carte.port_ecrire(port, 1, valeur, &mut SansRam)
    }

    /// **Par les ports de la machine**, comme le noyau y accède.
    #[test]
    fn the_clock_answers_through_the_ports() {
        let mut carte = Carte::nouvelle();
        carte.regler_heure(MOMENT_MS);
        assert!(ecrire(&mut carte, 0x70, 0x09));
        assert_eq!(lire(&mut carte, 0x71), Some(0x26));
        ecrire(&mut carte, 0x70, 0x08);
        assert_eq!(lire(&mut carte, 0x71), Some(0x10));
        ecrire(&mut carte, 0x70, 0x0F);
        ecrire(&mut carte, 0x71, 0x5A);
        assert_eq!(lire(&mut carte, 0x71), Some(0x5A));
        // L'index ne se relit pas, mais le port est pris.
        assert_eq!(lire(&mut carte, 0x70), Some(0));
    }

    /// Le 8042 par ses deux ports : la sonde de Linux, et la largeur d'un
    /// accès qui ne change rien à une puce d'un octet.
    #[test]
    fn the_keyboard_controller_answers_through_the_ports() {
        let mut carte = Carte::nouvelle();
        assert_eq!(
            lire(&mut carte, 0x64),
            Some(0x14),
            "rien à lire, non verrouillé"
        );
        assert!(ecrire(&mut carte, 0x64, 0xAA));
        assert_eq!(lire(&mut carte, 0x64).map(|e| e & 0x09), Some(0x09));
        assert_eq!(carte.port_lire(0x60, 4, &mut SansRam), Some(0x55));
        // Une écriture large ne garde que l'octet bas : `0x1_2347` écrit
        // `0x47` dans le CTR.
        carte.port_ecrire(0x64, 1, 0x60, &mut SansRam);
        carte.port_ecrire(0x60, 2, 0x1_2347, &mut SansRam);
        ecrire(&mut carte, 0x64, 0x20);
        assert_eq!(lire(&mut carte, 0x60), Some(0x47));
        // Une largeur que l'émetteur ne rend pas n'est à personne.
        assert_eq!(carte.port_lire(0x60, 3, &mut SansRam), None);
        assert!(!carte.port_ecrire(0x64, 8, 0xFE, &mut SansRam));
        assert!(!carte.remise_demandee());
        // **L'impulsion de Linux** par le port : la ligne de remise à zéro.
        ecrire(&mut carte, 0x64, 0xFE);
        assert!(carte.remise_demandee());
    }

    /// **Ce que la carte ne prend pas** reste à la boucle hôte : ses puces,
    /// et les ports où il n'y a personne.
    #[test]
    fn ports_that_are_not_the_cards_are_left_to_the_host() {
        let mut carte = Carte::nouvelle();
        for port in [
            0x20, 0x21, 0x40, 0x43, 0x61, 0x3F8, 0x72, 0x80, 0xCF9, 0xCFB, 0xC000, 0x5F,
        ] {
            assert_eq!(lire(&mut carte, port), None, "{port:#x}");
            assert!(!ecrire(&mut carte, port, 0), "{port:#x}");
        }
        assert_eq!(carte, Carte::nouvelle(), "et rien n'a bougé");
    }

    /// **La ligne 12 est la quatrième de l'esclave** : une demande de la
    /// souris se lit au bit 12, et la carte tient les deux lignes de son
    /// 8042 — levées ou non — pour que la boucle hôte les efface quand elles
    /// retombent.
    #[test]
    fn the_mouse_line_is_the_fourth_of_the_slave() {
        let mut carte = Carte::nouvelle();
        assert_eq!(carte.lignes(), 0);
        assert_eq!(carte.tenues(), (1 << 1) | (1 << 12));
        ecrire(&mut carte, 0x64, 0xD3);
        ecrire(&mut carte, 0x60, 1);
        assert_eq!(carte.lignes(), 1 << 12);
        assert_eq!(
            (carte.lignes() >> 8) as u8,
            1 << 4,
            "quatrième ligne de l'esclave"
        );
        // Plus d'interruption de la souris : la ligne retombe, l'octet reste.
        ecrire(&mut carte, 0x64, 0x60);
        ecrire(&mut carte, 0x60, 0x44);
        assert_eq!(carte.lignes(), 0);
        assert_eq!(lire(&mut carte, 0x64).map(|e| e & 0x21), Some(0x21));
        // Une touche : la ligne 1, au maître.
        ecrire(&mut carte, 0x64, 0x60);
        ecrire(&mut carte, 0x60, 0x47);
        assert_eq!(lire(&mut carte, 0x60), Some(1), "l'octet bouclé, lu");
        carte.touche(CodeTouche::ESPACE, true);
        assert_eq!(carte.lignes(), 1 << 1);
        assert_eq!(lire(&mut carte, 0x60), Some(0x39));
        assert_eq!(carte.lignes(), 0, "lu, la ligne retombe");
    }

    /// **Le rythme de frappe, vu des lignes** : un texte tapé ne lève la
    /// ligne 1 qu'à l'heure de chaque frappe, une à la fois, et la carte se
    /// dit réveillable tant qu'il en reste.
    #[test]
    fn typed_text_raises_the_keyboard_line_at_the_pace_of_a_hand() {
        let mut carte = Carte::nouvelle();
        assert!(!carte.reveil());
        assert_eq!(carte.taper_texte("A"), 4, "Maj, A, A, Maj");
        assert!(carte.reveil());
        assert_eq!(carte.lignes(), 0, "rien avant le premier battement");
        let mut lus = Vec::new();
        let mut tics = 10_000u64;
        let mut battements_leves = 0;
        // Une milliseconde de l'invité par battement (1 193 tics).
        while carte.reveil() || carte.lignes() != 0 {
            carte.battre(tics);
            if carte.lignes() & (1 << 1) != 0 {
                battements_leves += 1;
                lus.push((tics, lire(&mut carte, 0x60).expect("le 8042 répond")));
            }
            tics += 1_193;
            assert!(tics < 10_000 + 1_193 * 1_000, "la frappe ne finit pas");
        }
        assert_eq!(battements_leves, 4);
        assert_eq!(
            lus.iter().map(|l| l.1).collect::<Vec<_>>(),
            [0x2A, 0x1E, 0x9E, 0xAA]
        );
        // Une touche enfoncée (Maj, puis A) est tenue trente millisecondes ;
        // une relâchée (A) en laisse vingt avant la suivante. Au battement
        // près.
        let ecarts: Vec<u64> = lus.windows(2).map(|w| w[1].0 - w[0].0).collect();
        let attendus = [i8042::TENUE_TICS, i8042::TENUE_TICS, i8042::ECART_TICS];
        assert_eq!(ecarts.len(), attendus.len());
        for (ecart, attendu) in ecarts.iter().zip(attendus) {
            assert!(
                (attendu..attendu + 1_193).contains(ecart),
                "{ecarts:?} : attendu {attendus:?}, au battement près"
            );
        }
        assert!(!carte.reveil());
    }

    /// **Un texte qui remplit la file s'arrête sur un caractère entier.**
    /// Avant, la borne coupait `Maj A A Maj` après l'enfoncement : A et Maj
    /// restaient enfoncées dans l'invité, et Xorg répétait A sans fin. Ici
    /// le texte s'arrête au premier caractère qui ne tient plus, même si le
    /// suivant, plus court, tiendrait : pas de texte troué.
    #[test]
    fn a_text_that_fills_the_queue_ends_on_a_whole_character() {
        let mut carte = Carte::nouvelle();
        let texte = format!("a{}Ab", "A".repeat(2047));
        // « a » : deux frappes ; chaque « A » : quatre. 2 + 4 × 2 047 = 8 190,
        // et le « A » suivant n'a plus que deux places.
        assert_eq!(carte.taper_texte(&texte), 8_190);
        let file: Vec<_> = carte.ps2.frappes.iter().copied().collect();
        let fin: Vec<_> = file[file.len() - 4..]
            .iter()
            .map(|f| (f.code.jeu1, f.enfoncee))
            .collect();
        assert_eq!(
            fin,
            [(0x2A, true), (0x1E, true), (0x1E, false), (0x2A, false)],
            "le dernier caractère est entier"
        );
        let compte = |jeu1, enfoncee| {
            file.iter()
                .filter(|f| f.code.jeu1 == jeu1 && f.enfoncee == enfoncee)
                .count()
        };
        assert_eq!((compte(0x2A, true), compte(0x2A, false)), (2_047, 2_047));
        assert_eq!((compte(0x1E, true), compte(0x1E, false)), (2_048, 2_048));
        assert_eq!(compte(0x30, true), 0, "« b » ne passe pas devant « A »");
        // Un autre texte, plus tard, prend les places qui restent.
        assert_eq!(carte.taper_texte("b"), 2);
        assert_eq!(carte.taper_texte("c"), 0);
    }

    /// **Les lignes du dehors, à niveau**, et le refus des lignes de l'hôte.
    #[test]
    fn lines_raised_from_outside_stay_up_until_lowered() {
        let mut carte = Carte::nouvelle();
        assert!(carte.lever(5));
        assert!(carte.lever(10));
        assert_eq!(carte.lignes(), (1 << 5) | (1 << 10));
        assert!(carte.baisser(5));
        assert_eq!(carte.lignes(), 1 << 10);
        assert_ne!(carte.tenues() & (1 << 5), 0, "baissée, mais tenue");
        // Une ligne qu'un périphérique tient ne retombe pas parce qu'on la
        // baisse du dehors.
        carte.touche(CodeTouche::ESPACE, true);
        carte.baisser(1);
        assert_ne!(carte.lignes() & (1 << 1), 0);
        for ligne in [0, 2, 4, 16, 200] {
            assert!(!carte.lever(ligne), "ligne {ligne}");
            assert!(!carte.baisser(ligne), "ligne {ligne}");
        }
        assert_eq!(carte.tenues() & LIGNES_DE_L_HOTE, 0);
    }

    /// **Les ports fixes sont exactement ceux qu'une carte sans disque
    /// prend** : la liste qui les fait passer avant les fenêtres
    /// ([`port_fixe`]) et l'aiguillage des ports ne peuvent pas se
    /// désaccorder sans que ce test le voie, sur les 65 536 ports.
    #[test]
    fn the_fixed_ports_are_the_ones_a_card_without_a_disk_takes() {
        let mut pris = Vec::new();
        for port in 0..=u16::MAX {
            let mut carte = Carte::nouvelle();
            let lu = lire(&mut carte, port).is_some();
            let ecrit = ecrire(&mut Carte::nouvelle(), port, 0);
            assert_eq!(lu, ecrit, "{port:#x}");
            assert_eq!(lu, port_fixe(port), "{port:#x}");
            if lu {
                pris.push(port);
            }
        }
        assert_eq!(
            pris,
            [0x60, 0x64, 0x70, 0x71, 0xCF8, 0xCFC, 0xCFD, 0xCFE, 0xCFF]
        );
    }

    /// Placer et ouvrir la fenêtre d'un disque par les ports du bus.
    fn ouvrir(carte: &mut Carte, emplacement: u32, fenetre: u32) {
        let adresse = |registre: u32| 0x8000_0000 | (emplacement << 11) | registre;
        carte.port_ecrire(0xCF8, 4, adresse(0x10), &mut SansRam);
        carte.port_ecrire(0xCFC, 4, fenetre, &mut SansRam);
        carte.port_ecrire(0xCF8, 4, adresse(0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 2, 1, &mut SansRam);
    }

    /// **Une fenêtre posée par-dessus un port fixe ne lui vole rien**, quel
    /// que soit le disque : à `0x40`, la fenêtre du second couvre `0x60`,
    /// `0x64`, `0x70` et `0x71` ; à `0xCC0`, les ports du bus.
    #[test]
    fn a_window_over_a_fixed_port_steals_nothing() {
        for emplacement in [3, 4] {
            let quel = Disque::TOUS[emplacement as usize - 3];
            let mut carte = Carte::nouvelle();
            carte.brancher(quel, 0x0102_0304);
            ouvrir(&mut carte, emplacement, 0x40);
            assert_eq!(carte.fenetre_au_port(0x54), Some((quel, 0x14)));
            assert_eq!(lire(&mut carte, 0x54), Some(0x04), "la capacité");
            assert_eq!(carte.fenetre_au_port(0x64), None);
            assert_eq!(lire(&mut carte, 0x64), Some(0x14), "l'état du 8042");
            carte.regler_heure(MOMENT_MS);
            assert!(ecrire(&mut carte, 0x70, 0x09), "l'index de l'horloge");
            assert_eq!(lire(&mut carte, 0x71), Some(0x26));
            // Le statut du disque (0x12 de sa fenêtre, le port 0x52) n'a pas
            // bougé : l'écriture à 0x70 n'est pas allée au disque.
            assert_eq!(lire(&mut carte, 0x52), Some(0));
            ouvrir(&mut carte, emplacement, 0xCC0);
            assert_eq!(carte.fenetre_au_port(0xCD4), Some((quel, 0x14)));
            assert_eq!(carte.fenetre_au_port(0xCF8), None);
            assert_eq!(carte.fenetre_au_port(0xCFC), None);
            assert_eq!(
                carte.fenetre_au_port(0xCF9),
                Some((quel, 0x39)),
                "0xCF9 n'est pas à la carte : la fenêtre le prend"
            );
        }
    }

    /// **Le second disque frappe sur la ligne six**, le premier sur la cinq,
    /// et chacun ne tient que la sienne ; deux disques que le noyau met sur
    /// la même ligne la partagent, levée tant que l'un des deux la tient.
    #[test]
    fn each_disk_holds_its_own_line() {
        let mut carte = Carte::nouvelle();
        assert_eq!(carte.tenues() & 0x60, 0, "sans disque, ni l'une ni l'autre");
        carte.brancher(Disque::Second, 16);
        assert_eq!(carte.tenues() & 0x60, 0x40);
        carte.brancher_disque(8);
        assert_eq!(carte.tenues() & 0x60, 0x60);
        ouvrir(&mut carte, 3, 0xC000);
        ouvrir(&mut carte, 4, 0xC040);
        // Une requête sur chacun : une lecture d'un secteur, la file du
        // premier à la page 1, celle du second à la page 0x10.
        let mut ram = RamPlate(vec![0; 0x40000]);
        let demander = |carte: &mut Carte, ram: &mut RamPlate, base: u16, page: u32| {
            let table = u64::from(page) * 4096;
            carte.port_ecrire(base + 0x08, 4, page, ram);
            let decrire =
                |ram: &mut RamPlate, i: u64, a: u64, n: u32, drapeaux: u16, suivant: u16| {
                    let at = table + i * 16;
                    ram.ecrire(at, &a.to_le_bytes());
                    ram.ecrire(at + 8, &n.to_le_bytes());
                    ram.ecrire(at + 12, &drapeaux.to_le_bytes());
                    ram.ecrire(at + 14, &suivant.to_le_bytes());
                };
            decrire(ram, 0, table + 0x3000, 16, 1, 1);
            decrire(ram, 1, table + 0x4000, 512, 3, 2);
            decrire(ram, 2, table + 0x3800, 1, 2, 0);
            ram.ecrire(table + 0x802, &1u16.to_le_bytes());
            assert!(carte.port_ecrire(base + 0x10, 2, 0, ram));
        };
        demander(&mut carte, &mut ram, 0xC040, 0x10);
        assert!(carte.reveil(), "une requête du second attend sa réponse");
        assert_eq!(carte.lignes(), 0);
        assert_eq!(carte.requete_disque(), None, "pas sur le premier");
        let second = carte.disque_mut(Disque::Second).unwrap();
        let requete = second.prendre_requete().expect("sur le second");
        assert!(second.lu(requete.id, &[0x5A; 512], &mut ram));
        assert_eq!(carte.lignes(), 1 << 6, "la ligne six, et elle seule");
        assert_eq!(ram.0[0x14000..0x14200], [0x5A; 512]);

        demander(&mut carte, &mut ram, 0xC000, 1);
        let requete = carte.requete_disque().expect("sur le premier");
        assert!(carte.disque_lu(requete.id, &[0xA5; 512], &mut ram));
        assert_eq!(carte.lignes(), (1 << 5) | (1 << 6));
        assert_eq!(carte.port_lire(0xC013, 1, &mut SansRam), Some(1));
        assert_eq!(carte.lignes(), 1 << 6, "le premier acquitté, pas le second");
        assert!(carte.reveil(), "le second tient encore sa ligne");

        // Le noyau met le premier sur la ligne six aussi, puis une requête de
        // plus sur lui : la ligne est partagée.
        carte.port_ecrire(0xCF8, 4, 0x8000_183C, &mut SansRam);
        carte.port_ecrire(0xCFC, 1, 6, &mut SansRam);
        assert_eq!(carte.tenues() & 0x60, 0x40, "plus personne sur la cinq");
        ram.ecrire(0x1804 + 2, &0u16.to_le_bytes());
        ram.ecrire(0x1802, &2u16.to_le_bytes());
        carte.port_ecrire(0xC010, 2, 0, &mut ram);
        let requete = carte.requete_disque().expect("la seconde du premier");
        assert!(carte.disque_fini(requete.id, false, &mut ram));
        assert_eq!(carte.lignes(), 1 << 6);
        assert_eq!(carte.port_lire(0xC053, 1, &mut SansRam), Some(1));
        assert_eq!(carte.lignes(), 1 << 6, "le premier la tient encore");
        assert_eq!(carte.port_lire(0xC013, 1, &mut SansRam), Some(1));
        assert_eq!(carte.lignes(), 0);
        assert!(!carte.reveil());
    }

    /// **La RAM vue d'un périphérique** : une plage entière ou rien.
    #[test]
    fn the_ram_refuses_what_does_not_fit_whole() {
        let mut ram = RamPlate(vec![0; 16]);
        assert!(ram.ecrire(12, &[1, 2, 3, 4]));
        let mut lu = [0; 4];
        assert!(ram.lire(12, &mut lu));
        assert_eq!(lu, [1, 2, 3, 4]);
        assert!(!ram.ecrire(13, &[9; 4]), "déborde d'un octet");
        assert!(
            !ram.lire(u64::MAX, &mut lu),
            "l'addition ne fait pas le tour"
        );
        assert_eq!(ram.0[12..], [1, 2, 3, 4], "un refus ne touche à rien");
        assert!(!SansRam.lire(0, &mut lu));
        assert!(!SansRam.ecrire(0, &lu));
    }
}

#[cfg(test)]
mod tests_de_l_etat {
    //! **La carte sauvée et relue contre une carte** ([`Carte::sauver`]) :
    //! les lignes levées du dehors, les fenêtres du bus, l'écran et sa
    //! tablette qui vont ensemble.
    use super::etat::{essais::octets_de, Lecteur};
    use super::*;

    fn relue_contre(ici: &Carte, octets: &[u8]) -> Option<Carte> {
        let mut l = Lecteur::nouveau(octets);
        let lu = ici.relire(&mut l)?;
        if !l.au_bout() {
            return None;
        }
        let mut posee = ici.clone();
        posee.poser(lu);
        Some(posee)
    }

    fn levee() -> Carte {
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(8);
        carte.pci.premier.fenetre = 0xC040;
        carte.pci.premier.commande = 1;
        assert!(carte.lever(9));
        assert!(carte.baisser(11));
        carte
    }

    #[test]
    fn a_card_reads_back_against_one_like_it() {
        let carte = levee();
        let octets = octets_de(&carte, Carte::sauver);
        assert_eq!(
            relue_contre(&Carte::nouvelle(), &octets),
            Some(carte.clone())
        );
        for longueur in 0..octets.len() {
            assert!(
                relue_contre(&carte, &octets[..longueur]).is_none(),
                "coupée à {longueur}"
            );
        }
        let mut longue = octets.clone();
        longue.push(0);
        assert!(relue_contre(&carte, &longue).is_none(), "un octet de trop");
    }

    #[test]
    fn lines_windows_and_screens_that_do_not_fit_are_refused() {
        let carte = levee();
        let relit = |abimer: fn(&mut Carte)| {
            let mut abimee = carte.clone();
            abimer(&mut abimee);
            relue_contre(&Carte::nouvelle(), &octets_de(&abimee, Carte::sauver)).is_some()
        };
        assert!(relit(|_| {}), "telle quelle");
        assert!(
            !relit(|c| c.levees_du_dehors |= 1 << 7),
            "une ligne levée sans avoir été nommée"
        );
        assert!(
            !relit(|c| {
                c.levees_du_dehors |= 1 << 4;
                c.nommees_du_dehors |= 1 << 4;
            }),
            "une ligne que l'hôte tient"
        );
        assert!(
            !relit(|c| c.pci.premier.fenetre = 0xC044),
            "une fenêtre de travers"
        );
        assert!(
            !relit(|c| c.pci.reseau.fenetre = 0xC081),
            "celle de la carte réseau aussi"
        );

        // L'écran et sa tablette vont ensemble, et l'écran est celui d'ici.
        let mut avec_ecran = Carte::nouvelle();
        assert!(avec_ecran.brancher_ecran(640, 480));
        let octets = octets_de(&avec_ecran, Carte::sauver);
        assert!(
            relue_contre(&avec_ecran, &octets).is_some(),
            "le même écran"
        );
        assert!(
            relue_contre(&Carte::nouvelle(), &octets).is_none(),
            "un écran que la carte n'a pas"
        );
        let sans = octets_de(&Carte::nouvelle(), Carte::sauver);
        assert!(
            relue_contre(&avec_ecran, &sans).is_none(),
            "pas d'écran là où la carte en a un"
        );
        let mut seule = avec_ecran.clone();
        seule.pci.tablette = None;
        assert!(
            relue_contre(&avec_ecran, &octets_de(&seule, Carte::sauver)).is_none(),
            "un écran sans tablette"
        );
        let mut tablette_seule = Carte::nouvelle();
        tablette_seule.pci.tablette = avec_ecran.pci.tablette.clone();
        assert!(
            relue_contre(
                &Carte::nouvelle(),
                &octets_de(&tablette_seule, Carte::sauver)
            )
            .is_none(),
            "une tablette sans écran"
        );
    }
}
