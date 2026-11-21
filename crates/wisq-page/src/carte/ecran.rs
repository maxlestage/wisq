//! **L'écran : la carte graphique de QEMU (« std VGA », la carte Bochs) et sa
//! mémoire vidéo.** Porté depuis `X86BochsDisplay` et `X86Framebuffer` du
//! cœur Swift (`Sources/WisqVM/X86BochsDisplay.swift`,
//! `Sources/WisqVM/X86Framebuffer.swift`), registre pour registre.
//!
//! **Pourquoi elle.** `bochs-drm` est dans presque tous les noyaux, puisque
//! c'est la carte qu'un QEMU montre par défaut. Il fait de l'écran un vrai
//! `/dev/dri/card0` : un siège pour `logind`, de quoi pour Xorg. Void Linux
//! Xfce n'a pas `simpledrm` ; sans cette carte, son bureau ne démarre pas
//! (mesuré du côté Swift).
//!
//! **Ce qu'elle est, vue du noyau** (`drivers/gpu/drm/tiny/bochs.c`) :
//!
//! - sur le bus, en 00:02.0, fabricant `1234`, modèle `1111`, classe
//!   « contrôleur VGA », révision 2, sous-système `1AF4:1100` ;
//! - BAR0 : la mémoire vidéo, 16 Mio, préchargeable, à `0xE000_0000` tant que
//!   le noyau ne la déplace pas ([`BASE_DE_LA_MEMOIRE_VIDEO`]) ;
//! - BAR2 : quatre kibioctets de registres, à `0xE100_0000`
//!   ([`BASE_DES_REGISTRES`]) : l'EDID (absent : des zéros, que le pilote lit
//!   comme « pas d'EDID », d'où ses modes par défaut, 1024 × 768 en tête),
//!   les registres « DISPI » de Bochs à `0x500`, seize bits chacun, et les
//!   deux registres étendus de QEMU à `0x600` ;
//! - les mêmes registres DISPI par les ports `0x1CE` (index) et `0x1CF`
//!   (donnée) ;
//! - aucune ligne d'interruption.
//!
//! **Ce qu'elle fait** : dire au cadre ce qu'il faut montrer. Le pilote écrit
//! la résolution, la profondeur (32 bits), la largeur virtuelle et les
//! décalages ; l'écran de l'application montre ce rectangle de la mémoire
//! vidéo ([`Mode`]). Changer de page n'est qu'un décalage.
//!
//! **La mémoire vidéo n'est pas de la RAM** : elle vit ici, dans un
//! [`Cadre`], que la machine lit d'un bloc pour l'afficher
//! ([`Cadre::octets`], [`Cadre::image_dans`]) et dont le compteur de
//! révision ([`Cadre::revision`]) dit si l'image a bougé — une vue qui
//! repeint trente fois par seconde une image identique se paie en batterie.
//! Les accès de l'invité à ses adresses passent par
//! [`Carte::mem_lire`](super::Carte::mem_lire) et
//! [`Carte::mem_ecrire`](super::Carte::mem_ecrire).
//!
//! **Ce qui n'est pas porté** : l'instantané (`State`, `save`, `apply`), qui
//! viendra avec celui de la machine.

use std::fmt;

/// L'emplacement sur le bus : celui où QEMU met sa carte
/// (`X86BochsDisplay.slot`).
pub const EMPLACEMENT_DE_L_ECRAN: u32 = 2;
/// **La taille de la mémoire vidéo** : celle de QEMU. `bochs-drm` refuse les
/// modes dont deux images ne tiennent pas dedans ; seize mébioctets laissent
/// passer le 1920 × 1080.
pub const MEMOIRE_VIDEO: usize = 16 << 20;
/// La fenêtre des registres (BAR2).
pub const TAILLE_DES_REGISTRES: u64 = 0x1000;
/// **Où la mémoire vidéo se pose** (`X86Machine.displayBase`) : le trou que
/// les PC réservent depuis toujours aux périphériques, sous les quatre
/// gibioctets. Un noyau qui voit un cadre là n'est pas surpris.
pub const BASE_DE_LA_MEMOIRE_VIDEO: u64 = 0xE000_0000;
/// Les registres de la carte (sa BAR2), juste après sa mémoire vidéo
/// (`X86Machine.displayRegistersBase`).
pub const BASE_DES_REGISTRES: u64 = BASE_DE_LA_MEMOIRE_VIDEO + MEMOIRE_VIDEO as u64;
/// Le port de l'index des registres DISPI.
pub const PORT_INDEX: u16 = 0x1CE;
/// Le port de leur donnée.
pub const PORT_DONNEE: u16 = 0x1CF;

/// **Ce que l'écran montre** : un rectangle de la mémoire vidéo. Au
/// démarrage, le cadre déclaré au noyau, à l'adresse zéro et sans
/// remplissage ; ensuite, ce que le pilote de la carte choisit.
///
/// XRGB8888 : quatre octets par pixel, le bleu dans l'octet bas. C'est le
/// format que `bochs-drm` prend sans conversion côté invité, et que Core
/// Graphics et Metal prennent sans conversion côté hôte.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mode {
    pub largeur: u32,
    pub hauteur: u32,
    /// La longueur d'une ligne en mémoire : la largeur virtuelle, qui peut
    /// dépasser la largeur montrée.
    pub octets_par_ligne: u32,
    /// Le premier pixel montré, en octets depuis le début de la mémoire
    /// vidéo : ce qui change quand un bureau passe d'un tampon à l'autre.
    /// Sur 64 bits, parce que le pilote peut demander un décalage que la
    /// mémoire n'a pas, et que le refuser demande de pouvoir le compter.
    pub debut: u64,
}

impl Mode {
    /// Ce que le mode lit de la mémoire, du premier pixel au dernier.
    fn etendue(&self) -> u64 {
        u64::from(self.octets_par_ligne) * (u64::from(self.hauteur).saturating_sub(1))
            + u64::from(self.largeur) * 4
    }

    /// Les octets de l'image montrée, quatre par pixel, sans remplissage.
    pub fn octets_de_l_image(&self) -> usize {
        (self.largeur as usize)
            .saturating_mul(self.hauteur as usize)
            .saturating_mul(4)
    }
}

/// **La mémoire derrière l'écran** (`X86Framebuffer`) : les pixels, le mode
/// montré, et le compte des changements.
#[derive(Clone, PartialEq, Eq)]
pub struct Cadre {
    /// L'adresse physique invitée du premier octet de la mémoire vidéo.
    base: u64,
    /// Le cadre déclaré au noyau par le chargeur.
    depart: Mode,
    mode: Mode,
    revision: u64,
    pixels: Vec<u8>,
}

/// Seize mébioctets de pixels ne s'impriment pas : un test qui tombe dirait
/// son message après cent mégaoctets de chiffres.
impl fmt::Debug for Cadre {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Cadre")
            .field("base", &format_args!("{:#x}", self.base))
            .field("depart", &self.depart)
            .field("mode", &self.mode)
            .field("revision", &self.revision)
            .field("octets", &self.pixels.len())
            .finish()
    }
}

impl Cadre {
    /// Un cadre de `largeur` × `hauteur` à l'adresse `base`. `memoire` : la
    /// taille de la mémoire vidéo, celle du cadre du démarrage si elle n'est
    /// pas donnée (un écran sans carte) — jamais moins que lui.
    pub fn nouveau(base: u64, largeur: u32, hauteur: u32, memoire: Option<usize>) -> Self {
        let (largeur, hauteur) = (largeur.max(1), hauteur.max(1));
        let depart = Mode {
            largeur,
            hauteur,
            octets_par_ligne: largeur.saturating_mul(4),
            debut: 0,
        };
        let taille = memoire.unwrap_or(0).max(depart.octets_de_l_image());
        Self {
            base,
            depart,
            mode: depart,
            revision: 0,
            pixels: vec![0; taille],
        }
    }

    /// L'adresse physique invitée du premier octet de la mémoire vidéo. Elle
    /// bouge si le noyau déplace la BAR0 de la carte.
    pub fn base(&self) -> u64 {
        self.base
    }

    /// La taille de la mémoire vidéo, en octets.
    pub fn taille(&self) -> usize {
        self.pixels.len()
    }

    /// Le cadre déclaré au noyau par le chargeur (`screen_info`).
    pub fn mode_de_depart(&self) -> Mode {
        self.depart
    }

    /// Le mode affiché en ce moment.
    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// **Combien de fois l'image a changé.** Une vue compare ce nombre au
    /// sien : égal, elle ne redessine rien.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// **Un autre mode**, s'il tient dans la mémoire vidéo ; sinon rien ne
    /// change, et la réponse le dit. Un pilote qui demande plus qu'il n'y a
    /// ne doit pas faire lire à la vue au-delà des pixels.
    pub fn regler_mode(&mut self, mode: Mode) -> bool {
        let tient = mode.largeur >= 1
            && mode.hauteur >= 1
            && u64::from(mode.octets_par_ligne) >= u64::from(mode.largeur) * 4
            && mode
                .debut
                .checked_add(mode.etendue())
                .is_some_and(|fin| fin <= self.pixels.len() as u64);
        if !tient {
            return false;
        }
        if self.mode != mode {
            self.mode = mode;
            self.revision = self.revision.wrapping_add(1);
        }
        true
    }

    /// La mémoire vidéo déplacée : le noyau a reprogrammé la BAR0.
    pub fn deplacer(&mut self, base: u64) {
        self.base = base;
    }

    /// Efface les `octets` premiers octets de la mémoire vidéo : ce que fait
    /// la carte en changeant de mode.
    pub fn effacer(&mut self, octets: u64) {
        let combien = usize::try_from(octets)
            .unwrap_or(usize::MAX)
            .min(self.pixels.len());
        self.pixels[..combien].fill(0);
        self.revision = self.revision.wrapping_add(1);
    }

    /// **Le décalage dans la mémoire vidéo**, ou rien si l'adresse est
    /// ailleurs.
    ///
    /// La fenêtre s'arrête exactement à la fin de la mémoire vidéo : un octet
    /// de trop et une écriture perdue deviendrait silencieuse, au lieu de
    /// lever la faute qui la ferait remarquer. Une largeur plus grande que la
    /// mémoire n'y tient pas, et le dit. Et la fenêtre est la mémoire vidéo
    /// entière, pas l'image montrée : un bureau peint dans le tampon qu'il
    /// montrera ensuite.
    pub fn decalage(&self, adresse: u64, largeur: usize) -> Option<usize> {
        if adresse < self.base || largeur > self.pixels.len() {
            return None;
        }
        let rang = adresse - self.base;
        (rang <= (self.pixels.len() - largeur) as u64).then_some(rang as usize)
    }

    /// Lire `largeur` octets (huit au plus) à `a`, petit-boutiens. `a` vient
    /// de [`Cadre::decalage`].
    pub fn lire(&self, a: usize, largeur: usize) -> u64 {
        let mut huit = [0u8; 8];
        let largeur = largeur.min(8);
        huit[..largeur].copy_from_slice(&self.pixels[a..a + largeur]);
        u64::from_le_bytes(huit)
    }

    /// Écrire les `largeur` octets bas de `valeur` (huit au plus) à `a`. La
    /// révision avance.
    pub fn ecrire(&mut self, a: usize, largeur: usize, valeur: u64) {
        let largeur = largeur.min(8);
        self.pixels[a..a + largeur].copy_from_slice(&valeur.to_le_bytes()[..largeur]);
        self.revision = self.revision.wrapping_add(1);
    }

    /// **La mémoire vidéo entière, en lecture, sans copie** : ce que la
    /// machine tend à la vue, ou à un instantané. Le rectangle montré s'y
    /// trouve d'après [`Cadre::mode`].
    pub fn octets(&self) -> &[u8] {
        &self.pixels
    }

    /// **Les pixels eux-mêmes, pour une copie d'un bloc** : le cœur y copie
    /// une ligne entière d'un coup, et dit ensuite qu'il l'a fait
    /// ([`Cadre::marquer`]), puisque [`Cadre::ecrire`] n'y est pas passé.
    pub fn octets_mut(&mut self) -> &mut [u8] {
        &mut self.pixels
    }

    /// Une écriture faite directement dans [`Cadre::octets_mut`] : la vue
    /// doit repeindre.
    pub fn marquer(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }

    /// **L'image telle qu'elle est, copiée dans `vers`** : le mode courant,
    /// ligne à ligne, sans remplissage — `largeur × hauteur × 4` octets. Rend
    /// le mode, pris avec l'image : une vue qui lirait la taille puis les
    /// pixels pourrait tomber entre les deux sur un changement de résolution.
    /// `vers` est réemployé d'une image à l'autre.
    pub fn image_dans(&self, vers: &mut Vec<u8>) -> Mode {
        let mode = self.mode;
        let ligne = mode.largeur as usize * 4;
        let debut = mode.debut as usize;
        vers.clear();
        if mode.octets_par_ligne as usize == ligne {
            vers.extend_from_slice(&self.pixels[debut..debut + ligne * mode.hauteur as usize]);
        } else {
            vers.reserve(mode.octets_de_l_image());
            for rang in 0..mode.hauteur as usize {
                let a = debut + rang * mode.octets_par_ligne as usize;
                vers.extend_from_slice(&self.pixels[a..a + ligne]);
            }
        }
        mode
    }

    /// La même, dans un tampon neuf.
    pub fn image(&self) -> (Mode, Vec<u8>) {
        let mut octets = Vec::new();
        let mode = self.image_dans(&mut octets);
        (mode, octets)
    }
}

/// Les registres DISPI, dans l'ordre de leurs index.
mod registre {
    pub const ID: usize = 0;
    pub const XRES: usize = 1;
    pub const YRES: usize = 2;
    pub const BPP: usize = 3;
    pub const ENABLE: usize = 4;
    pub const LARGEUR_VIRTUELLE: usize = 6;
    pub const HAUTEUR_VIRTUELLE: usize = 7;
    pub const X: usize = 8;
    pub const Y: usize = 9;
    pub const MEMOIRE_64K: usize = 10;
    /// Onze registres : de l'identifiant à la mémoire.
    pub const COMBIEN: usize = 11;
}

/// Les bits de `ENABLE`.
const ALLUMEE: u16 = 0x01;
const CAPACITES: u16 = 0x02;
const CADRE_LINEAIRE: u16 = 0x40;
const SANS_EFFACER: u16 = 0x80;

/// La version annoncée : la dernière, celle de QEMU.
pub const DERNIER_ID: u16 = 0xB0C5;
/// Les plus grandes valeurs, rendues sous `GETCAPS`.
pub const LARGEUR_MAXIMALE: u16 = 2560;
pub const HAUTEUR_MAXIMALE: u16 = 1600;
pub const PROFONDEUR_MAXIMALE: u16 = 32;
/// Les deux registres étendus de QEMU : leur taille, huit octets.
const TAILLE_ETENDUE: u32 = 8;

/// **La carte graphique** : ses registres, sa place sur le bus, et le cadre
/// qu'elle pilote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ecran {
    /// L'écran que la carte pilote : sa mémoire vidéo et le mode montré.
    pub cadre: Cadre,
    /// Les onze registres DISPI.
    registres: [u16; registre::COMBIEN],
    /// L'index choisi par le port `0x1CE`.
    index: u16,
    /// Où sont les registres (BAR2).
    base_des_registres: u64,
    /// Le registre de commande PCI. Les BAR sont décodées quoi qu'il dise :
    /// le noyau ne coupe le décodage que le temps de mesurer leur taille, et
    /// la mesure est déjà prise à part.
    commande: u16,
    /// Le noyau mesure la taille d'une BAR en y écrivant des uns : vrai
    /// jusqu'à ce qu'il y remette une adresse.
    mesure_de_la_memoire: bool,
    mesure_des_registres: bool,
    /// L'ordre des octets que le pilote demande (registre étendu `0x604`).
    ordre_des_octets: u32,
}

impl Ecran {
    /// La carte d'un cadre, ses registres à `base_des_registres`.
    pub fn nouveau(cadre: Cadre, base_des_registres: u64) -> Self {
        let mut registres = [0u16; registre::COMBIEN];
        registres[registre::ID] = DERNIER_ID;
        registres[registre::MEMOIRE_64K] = (cadre.taille() >> 16) as u16;
        Self {
            cadre,
            registres,
            index: 0,
            base_des_registres,
            commande: 0x0003,
            mesure_de_la_memoire: false,
            mesure_des_registres: false,
            ordre_des_octets: 0x1E1E_1E1E,
        }
    }

    /// **L'écran d'une machine** (`X86Machine.attachDisplay`) : un cadre de
    /// `largeur` × `hauteur` au démarrage, seize mébioctets de mémoire vidéo
    /// à [`BASE_DE_LA_MEMOIRE_VIDEO`], les registres à
    /// [`BASE_DES_REGISTRES`]. Rien si le cadre du démarrage ne tient pas
    /// dans la mémoire vidéo : la BAR0 annonce seize mébioctets, pas plus.
    pub fn de_machine(largeur: u32, hauteur: u32) -> Option<Self> {
        let pixels = u64::from(largeur.max(1))
            .saturating_mul(u64::from(hauteur.max(1)))
            .saturating_mul(4);
        (pixels <= MEMOIRE_VIDEO as u64).then(|| {
            let cadre = Cadre::nouveau(
                BASE_DE_LA_MEMOIRE_VIDEO,
                largeur,
                hauteur,
                Some(MEMOIRE_VIDEO),
            );
            Self::nouveau(cadre, BASE_DES_REGISTRES)
        })
    }

    /// Où sont les registres (BAR2).
    pub fn base_des_registres(&self) -> u64 {
        self.base_des_registres
    }

    // ------------------------------------------------------ les registres DISPI

    /// Lit un registre DISPI. Sous `GETCAPS`, la taille et la profondeur se
    /// lisent à leur maximum.
    pub fn lire_registre(&self, lequel: u16) -> u16 {
        let lequel = usize::from(lequel);
        if lequel >= registre::COMBIEN {
            return 0;
        }
        if self.registres[registre::ENABLE] & CAPACITES != 0 {
            match lequel {
                registre::XRES => return LARGEUR_MAXIMALE,
                registre::YRES => return HAUTEUR_MAXIMALE,
                registre::BPP => return PROFONDEUR_MAXIMALE,
                _ => {}
            }
        }
        self.registres[lequel]
    }

    /// Écrit un registre DISPI, comme QEMU (`vbe_ioport_write_data`) : la
    /// mise en marche remet la largeur virtuelle et les décalages à leur
    /// valeur de départ, et efface ce que l'écran va montrer.
    pub fn ecrire_registre(&mut self, lequel: u16, valeur: u16) {
        let lequel = usize::from(lequel);
        if lequel >= registre::COMBIEN {
            return;
        }
        match lequel {
            registre::ID => {
                if (0xB0C0..=DERNIER_ID).contains(&valeur) {
                    self.registres[lequel] = valeur;
                }
            }
            registre::MEMOIRE_64K => {} // en lecture seule
            registre::BPP => self.registres[lequel] = if valeur == 0 { 8 } else { valeur },
            registre::ENABLE => {
                let etait_allumee = self.registres[lequel] & ALLUMEE != 0;
                self.registres[lequel] = valeur;
                if valeur & ALLUMEE != 0 && !etait_allumee {
                    self.registres[registre::LARGEUR_VIRTUELLE] = self.registres[registre::XRES];
                    self.registres[registre::HAUTEUR_VIRTUELLE] = self.registres[registre::YRES];
                    self.registres[registre::X] = 0;
                    self.registres[registre::Y] = 0;
                    if valeur & SANS_EFFACER == 0 {
                        // Ce que le mode demandé montre, en octets depuis son
                        // premier pixel.
                        let visibles = u64::from(self.registres[registre::LARGEUR_VIRTUELLE])
                            * 4
                            * u64::from(self.registres[registre::YRES]);
                        self.cadre.effacer(visibles);
                    }
                }
            }
            _ => self.registres[lequel] = valeur,
        }
        self.montrer();
    }

    /// **Le mode que l'écran affiche**, d'après les registres. Allumée, en
    /// trente-deux bits et en cadre linéaire, la carte montre le rectangle
    /// qu'elle décrit ; éteinte, l'écran revient au cadre du démarrage. Une
    /// autre profondeur ne se montre pas : aucun des pilotes qui comptent ne
    /// la demande, et une image mal lue serait pire qu'une image figée.
    fn montrer(&mut self) {
        let allumage = self.registres[registre::ENABLE];
        if allumage & ALLUMEE == 0 {
            self.cadre.regler_mode(self.cadre.mode_de_depart());
            return;
        }
        if allumage & CADRE_LINEAIRE == 0 || self.registres[registre::BPP] != 32 {
            return;
        }
        let largeur = u32::from(self.registres[registre::XRES]);
        let hauteur = u32::from(self.registres[registre::YRES]);
        let virtuelle = u32::from(self.registres[registre::LARGEUR_VIRTUELLE]).max(largeur);
        let debut = (u64::from(self.registres[registre::Y]) * u64::from(virtuelle)
            + u64::from(self.registres[registre::X]))
            * 4;
        self.cadre.regler_mode(Mode {
            largeur,
            hauteur,
            octets_par_ligne: virtuelle * 4,
            debut,
        });
    }

    // ------------------------------------------------------------------ ports

    /// Écrire le port `0x1CE` (l'index) ou `0x1CF` (la donnée).
    pub fn ecrire_port(&mut self, port: u16, valeur: u16) {
        if port == PORT_INDEX {
            self.index = valeur;
        } else if port == PORT_DONNEE {
            self.ecrire_registre(self.index, valeur);
        }
    }

    /// Lire l'un des deux ports.
    pub fn lire_port(&self, port: u16) -> u16 {
        match port {
            PORT_INDEX => self.index,
            PORT_DONNEE => self.lire_registre(self.index),
            _ => 0xFFFF,
        }
    }

    // ---------------------------------------------------------------- la BAR2

    /// Le décalage dans la fenêtre des registres, ou rien si l'adresse est
    /// ailleurs.
    pub fn decalage_des_registres(&self, adresse: u64, largeur: usize) -> Option<u64> {
        let decalage = adresse.checked_sub(self.base_des_registres)?;
        (decalage.checked_add(largeur as u64)? <= TAILLE_DES_REGISTRES).then_some(decalage)
    }

    /// Lit dans la fenêtre des registres. L'EDID est absent — des zéros, que
    /// `bochs-drm` reconnaît comme « pas d'EDID » —, et les ports VGA ne
    /// disent rien.
    pub fn lire_registres(&self, decalage: u64, largeur: usize) -> u64 {
        match decalage {
            0x500..=0x515 => {
                let lequel = ((decalage - 0x500) / 2) as u16;
                let mut valeur = u64::from(self.lire_registre(lequel));
                if largeur > 2 && usize::from(lequel) + 1 < registre::COMBIEN {
                    valeur |= u64::from(self.lire_registre(lequel + 1)) << 16;
                }
                valeur
            }
            0x600 => u64::from(TAILLE_ETENDUE),
            0x604 => u64::from(self.ordre_des_octets),
            _ => 0,
        }
    }

    /// Écrit dans la fenêtre des registres.
    pub fn ecrire_registres(&mut self, decalage: u64, largeur: usize, valeur: u64) {
        match decalage {
            0x500..=0x515 => {
                let lequel = ((decalage - 0x500) / 2) as u16;
                self.ecrire_registre(lequel, valeur as u16);
                if largeur > 2 {
                    self.ecrire_registre(lequel + 1, (valeur >> 16) as u16);
                }
            }
            0x604 => self.ordre_des_octets = valeur as u32,
            // L'EDID est en lecture seule, les ports VGA sans effet.
            _ => {}
        }
    }

    // ----------------------------------------- l'espace de configuration PCI

    /// Le mot de configuration à `registre`.
    pub fn configuration(&self, registre: u32) -> u32 {
        match registre {
            0x00 => 0x1111_1234, // Bochs / QEMU std VGA
            0x04 => u32::from(self.commande),
            0x08 => 0x0300_0002, // contrôleur VGA, révision 2
            // BAR0 : la mémoire vidéo, préchargeable.
            0x10 => {
                if self.mesure_de_la_memoire {
                    !((self.cadre.taille() as u64 - 1) as u32) | 0x08
                } else {
                    self.cadre.base() as u32 | 0x08
                }
            }
            // BAR2 : les registres.
            0x18 => {
                if self.mesure_des_registres {
                    !((TAILLE_DES_REGISTRES - 1) as u32)
                } else {
                    self.base_des_registres as u32
                }
            }
            0x2C => 0x1100_1AF4, // sous-système : QEMU
            // En-tête de type zéro, ni ligne ni broche : la carte
            // n'interrompt pas.
            _ => 0,
        }
    }

    /// Une écriture de configuration, déjà recomposée en un mot entier.
    pub fn ecrire_configuration(&mut self, registre: u32, valeur: u32) {
        match registre {
            0x04 => self.commande = valeur as u16,
            0x10 => {
                if valeur == 0xFFFF_FFFF {
                    self.mesure_de_la_memoire = true;
                } else {
                    self.mesure_de_la_memoire = false;
                    // Les bits bas disent le type ; l'adresse est alignée
                    // sur la taille.
                    let masque = !(self.cadre.taille() as u64 - 1);
                    self.cadre.deplacer(u64::from(valeur) & masque);
                }
            }
            0x18 => {
                if valeur == 0xFFFF_FFFF {
                    self.mesure_des_registres = true;
                } else {
                    self.mesure_des_registres = false;
                    self.base_des_registres = u64::from(valeur) & !(TAILLE_DES_REGISTRES - 1);
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    //! **La mémoire vidéo seule**, comme `X86FramebufferTests` la juge : un
    //! cadre de 8 × 4 sans carte, à `0xE000_0000`. Puis **la carte
    //! graphique, telle que `bochs-drm` la voit** : les cas de
    //! `X86BochsDisplayTests`, portés un pour un, à travers le bus, les ports
    //! et les accès mémoire de la [`Carte`] — comme le Swift les joue à
    //! travers sa machine. Chacun rejoue ce que le pilote fait
    //! (`drivers/gpu/drm/tiny/bochs.c`) : trouver la carte sur le bus, lire
    //! ses BAR, son identifiant et sa mémoire, poser un mode, changer de
    //! page. Le cas d'instantané n'est pas porté : la carte Rust n'en a pas
    //! encore.
    use super::super::pci::tests::adresse;
    use super::super::{Carte, Region, SansRam};
    use super::*;

    const BASE: u64 = 0xE000_0000;

    /// Le cadre des tests Swift, et de quoi y écrire par adresse comme
    /// l'invité : `X86Memory.write` quand l'adresse est au cadre.
    fn cadre() -> Cadre {
        Cadre::nouveau(BASE, 8, 4, None)
    }

    fn ecrire(cadre: &mut Cadre, adresse: u64, largeur: usize, valeur: u64) -> bool {
        match cadre.decalage(adresse, largeur) {
            Some(a) => {
                cadre.ecrire(a, largeur, valeur);
                true
            }
            None => false,
        }
    }

    fn lire(cadre: &Cadre, adresse: u64, largeur: usize) -> Option<u64> {
        cadre
            .decalage(adresse, largeur)
            .map(|a| cadre.lire(a, largeur))
    }

    /// **Ce que l'invité écrit dans la fenêtre, l'hôte doit le relire**
    /// (`testWhatTheGuestWritesTheHostReads`). C'est tout le contrat : sans
    /// ça, il n'y a pas d'image à montrer.
    #[test]
    fn what_the_guest_writes_the_host_reads() {
        let mut cadre = cadre();
        let octets = cadre.mode().octets_de_l_image();
        // Un pixel bleu en haut à gauche, en XRGB8888.
        assert!(ecrire(&mut cadre, BASE, 4, 0x00_00_00_FF));
        // Et un rouge au dernier pixel, pour tenir aussi le bord.
        assert!(ecrire(
            &mut cadre,
            BASE + octets as u64 - 4,
            4,
            0x00_FF_00_00
        ));
        let (mode, image) = cadre.image();
        assert_eq!(image.len(), 8 * 4 * 4, "quatre octets par pixel");
        assert_eq!((mode.largeur, mode.hauteur), (8, 4));
        assert_eq!(image[..4], [0xFF, 0, 0, 0], "le bleu occupe l'octet bas");
        assert_eq!(image[image.len() - 4..], [0, 0, 0xFF, 0]);
        assert_eq!(cadre.octets(), &image[..], "sans carte : l'image entière");
    }

    /// **Relire par la mémoire doit rendre ce qu'on y a mis**
    /// (`testTheGuestCanReadBackItsOwnPixels`) : un noyau lit son propre
    /// cadre pour faire défiler une console.
    #[test]
    fn the_guest_can_read_back_its_own_pixels() {
        let mut cadre = cadre();
        assert!(ecrire(&mut cadre, BASE + 16, 4, 0x00_12_34_56));
        assert_eq!(lire(&cadre, BASE + 16, 4), Some(0x00_12_34_56));
    }

    /// **Chaque largeur relit ce qu'elle a écrit**, petit-boutienne
    /// (`testEveryWidthReadsBackWhatWasWritten`) : un, deux, quatre et huit
    /// octets, et trois — la moitié d'un accès à cheval sur une page.
    #[test]
    fn every_width_reads_back_what_was_written() {
        let mut cadre = cadre();
        assert!(ecrire(&mut cadre, BASE + 8, 8, 0x0102_0304_0506_0708));
        assert_eq!(cadre.octets()[8..16], [8, 7, 6, 5, 4, 3, 2, 1]);
        assert_eq!(lire(&cadre, BASE + 8, 8), Some(0x0102_0304_0506_0708));
        assert_eq!(lire(&cadre, BASE + 9, 2), Some(0x0607));
        assert_eq!(lire(&cadre, BASE + 15, 1), Some(0x01));
        assert_eq!(lire(&cadre, BASE + 10, 3), Some(0x04_0506));
        assert!(ecrire(&mut cadre, BASE + 20, 2, 0xBEEF));
        assert!(ecrire(&mut cadre, BASE + 23, 1, 0x7F));
        assert!(ecrire(&mut cadre, BASE + 24, 3, 0xAA_BBCC));
        assert_eq!(
            cadre.octets()[20..27],
            [0xEF, 0xBE, 0, 0x7F, 0xCC, 0xBB, 0xAA]
        );
        // Une écriture ne garde que ses octets : le voisin n'a pas bougé.
        assert!(ecrire(&mut cadre, BASE + 28, 2, 0xFFFF_FFFF_FFFF_1234));
        assert_eq!(cadre.octets()[28..32], [0x34, 0x12, 0, 0]);
        // Cinq, six et sept octets, que seul un accès à cheval demande.
        for largeur in [5usize, 6, 7] {
            assert!(ecrire(
                &mut cadre,
                BASE + 32,
                largeur,
                0x0807_0605_0403_0201
            ));
            let masque = (1u64 << (8 * largeur)) - 1;
            assert_eq!(
                lire(&cadre, BASE + 32, largeur),
                Some(0x0807_0605_0403_0201 & masque),
                "{largeur} octets"
            );
            assert_eq!(
                cadre.octets()[32 + largeur],
                0,
                "{largeur} : pas un de plus"
            );
        }
    }

    /// **La fenêtre s'arrête exactement à la fin du cadre**
    /// (`testJustPastTheEndIsStillAFault`). Un octet de plus et une écriture
    /// perdue deviendrait silencieuse.
    #[test]
    fn just_past_the_end_is_still_outside() {
        let mut cadre = cadre();
        let fin = BASE + cadre.taille() as u64;
        assert!(!ecrire(&mut cadre, fin, 4, 0xFF), "juste après la fin");
        assert_eq!(cadre.decalage(fin - 4, 4), Some(124), "le dernier pixel");
        assert_eq!(cadre.decalage(fin - 3, 4), None, "à cheval sur la fin");
        assert_eq!(cadre.decalage(fin - 1, 1), Some(127));
        assert_eq!(cadre.decalage(fin, 1), None);
        assert_eq!(cadre.decalage(BASE - 1, 1), None, "juste avant le début");
        assert_eq!(cadre.decalage(BASE - 1, 4), None, "à cheval sur le début");
        assert_eq!(cadre.decalage(BASE, 0), Some(0));
        assert_eq!(cadre.decalage(fin, 0), Some(128), "rien, à la fin : dedans");
        assert_eq!(cadre.decalage(fin + 1, 0), None);
        assert_eq!(cadre.decalage(u64::MAX, 1), None, "sans faire le tour");
        assert_eq!(cadre.decalage(0, 4), None, "la RAM n'est pas le cadre");
        // **Une largeur plus grande que le cadre n'y tient pas**, et le dit :
        // un cadre d'un pixel rendait `taille − largeur` négatif.
        let minuscule = Cadre::nouveau(BASE, 1, 1, None);
        assert_eq!(minuscule.taille(), 4);
        assert_eq!(minuscule.decalage(BASE, 4), Some(0));
        assert_eq!(minuscule.decalage(BASE, 8), None);
        assert_eq!(minuscule.decalage(BASE, 4096), None);
        assert_eq!(cadre.revision(), 0, "aucun refus n'a rien changé");
    }

    /// **Le compteur de révision dit si l'image a bougé**
    /// (`testTheRevisionAdvancesOnlyOnAWrite`).
    #[test]
    fn the_revision_advances_only_on_a_write() {
        let mut cadre = cadre();
        let depart = cadre.revision();
        assert_eq!(lire(&cadre, BASE, 4), Some(0));
        let _ = cadre.image();
        let _ = cadre.octets();
        assert_eq!(cadre.revision(), depart, "lire ne change rien");
        assert!(ecrire(&mut cadre, BASE, 4, 1));
        assert_eq!(cadre.revision(), depart + 1, "écrire doit se voir");
        // Une copie d'un bloc ne passe pas par `ecrire` : elle se dit.
        cadre.octets_mut()[4..8].fill(9);
        assert_eq!(cadre.revision(), depart + 1);
        cadre.marquer();
        assert_eq!(cadre.revision(), depart + 2);
        // Effacer se voit ; reposer le même mode, non ; un autre, oui.
        cadre.effacer(4);
        assert_eq!(cadre.revision(), depart + 3);
        assert_eq!(cadre.octets()[..8], [0, 0, 0, 0, 9, 9, 9, 9]);
        assert!(cadre.regler_mode(cadre.mode()));
        assert_eq!(
            cadre.revision(),
            depart + 3,
            "le même mode : rien à repeindre"
        );
        let moitie = Mode {
            largeur: 4,
            hauteur: 4,
            octets_par_ligne: 32,
            debut: 0,
        };
        assert!(cadre.regler_mode(moitie));
        assert_eq!(cadre.revision(), depart + 4);
        // Un mode refusé ne change ni le mode ni le compte : 112 octets lus
        // à partir du dix-septième, quatre de plus que la mémoire.
        assert!(
            cadre.regler_mode(Mode {
                debut: 16,
                ..moitie
            }),
            "juste"
        );
        assert!(cadre.regler_mode(moitie));
        assert_eq!(cadre.revision(), depart + 6);
        let depart = depart + 2;
        assert!(!cadre.regler_mode(Mode {
            debut: 17,
            ..moitie
        }));
        assert_eq!((cadre.mode(), cadre.revision()), (moitie, depart + 4));
    }

    /// **Un cadre sans taille en a une quand même** : un pixel, comme
    /// `X86Framebuffer.init` (`max(width, 1)`), et une mémoire donnée plus
    /// petite que le cadre ne le rogne pas.
    #[test]
    fn a_frame_is_never_smaller_than_its_boot_mode() {
        let rien = Cadre::nouveau(BASE, 0, 0, None);
        assert_eq!(
            rien.mode_de_depart(),
            Mode {
                largeur: 1,
                hauteur: 1,
                octets_par_ligne: 4,
                debut: 0
            }
        );
        assert_eq!(rien.taille(), 4);
        let petit = Cadre::nouveau(BASE, 8, 4, Some(16));
        assert_eq!(
            petit.taille(),
            128,
            "jamais moins que le cadre du démarrage"
        );
        let grand = Cadre::nouveau(BASE, 8, 4, Some(4096));
        assert_eq!(grand.taille(), 4096);
        assert_eq!(grand.mode(), grand.mode_de_depart());
        assert_eq!(grand.base(), BASE);
    }

    /// **Un mode qui ne tient pas dans la mémoire est refusé**, à l'octet
    /// près, et sans que l'addition fasse le tour.
    #[test]
    fn a_mode_must_fit_in_the_memory_to_the_byte() {
        let mut cadre = Cadre::nouveau(BASE, 8, 4, Some(256));
        let mode = |largeur, hauteur, octets_par_ligne, debut| Mode {
            largeur,
            hauteur,
            octets_par_ligne,
            debut,
        };
        // 8 × 4 avec des lignes de 64 octets : 3 × 64 + 32 = 224 octets lus.
        assert!(
            cadre.regler_mode(mode(8, 4, 64, 32)),
            "224 + 32 = 256 : juste"
        );
        assert!(!cadre.regler_mode(mode(8, 4, 64, 33)), "un octet de trop");
        assert!(!cadre.regler_mode(mode(8, 5, 64, 0)), "une ligne de trop");
        assert!(cadre.regler_mode(mode(8, 4, 32, 128)));
        assert!(
            !cadre.regler_mode(mode(8, 4, 31, 0)),
            "une ligne trop courte"
        );
        assert!(!cadre.regler_mode(mode(0, 4, 32, 0)), "sans largeur");
        assert!(!cadre.regler_mode(mode(8, 0, 32, 0)), "sans hauteur");
        assert!(
            !cadre.regler_mode(mode(1, 1, 4, u64::MAX)),
            "sans faire le tour"
        );
        assert!(!cadre.regler_mode(mode(1, 1, 4, 253)));
        assert!(cadre.regler_mode(mode(1, 1, 4, 252)), "le dernier pixel");
        assert_eq!(cadre.mode(), mode(1, 1, 4, 252));
        cadre.octets_mut()[252..].copy_from_slice(&[1, 2, 3, 4]);
        assert_eq!(cadre.image().1, [1, 2, 3, 4]);
    }

    /// **L'image copiée réemploie son tampon**, et ne garde rien de l'image
    /// d'avant quand le mode rétrécit.
    #[test]
    fn the_copied_image_reuses_its_buffer() {
        let mut cadre = Cadre::nouveau(BASE, 8, 4, None);
        for (rang, octet) in cadre.octets_mut().iter_mut().enumerate() {
            *octet = rang as u8;
        }
        let mut image = Vec::new();
        let mode = cadre.image_dans(&mut image);
        assert_eq!(mode, cadre.mode_de_depart());
        assert_eq!(image, (0..128).collect::<Vec<u8>>());
        let garde = (image.as_ptr(), image.capacity());
        // Deux pixels sur deux lignes, des lignes de 32 octets, à partir du
        // neuvième octet : le remplissage n'est pas dans l'image.
        assert!(cadre.regler_mode(Mode {
            largeur: 2,
            hauteur: 2,
            octets_par_ligne: 32,
            debut: 8,
        }));
        let mode = cadre.image_dans(&mut image);
        assert_eq!((mode.largeur, mode.hauteur), (2, 2));
        assert_eq!(
            image,
            [8, 9, 10, 11, 12, 13, 14, 15, 40, 41, 42, 43, 44, 45, 46, 47]
        );
        assert_eq!((image.as_ptr(), image.capacity()), garde, "le même tampon");
    }

    /// Imprimer un cadre ne déverse pas ses pixels.
    #[test]
    fn debug_printing_a_frame_does_not_dump_its_pixels() {
        let texte = format!("{:?}", Ecran::de_machine(1024, 768).unwrap());
        assert!(texte.len() < 1_000, "{} caractères", texte.len());
        assert!(texte.contains("0xe0000000") && texte.contains("16777216"));
    }

    // ------------------------------------------------- la carte, sur la machine

    /// Une machine avec un écran 1024 × 768, sans disque
    /// (`X86BochsDisplayTests.machine`).
    fn machine() -> Carte {
        let mut carte = Carte::nouvelle();
        assert!(carte.brancher_ecran(1024, 768));
        carte
    }

    /// Le mot de configuration de la carte graphique à `registre`, par les
    /// deux ports du bus.
    fn configuration(carte: &mut Carte, registre: u32) -> u32 {
        assert!(carte.port_ecrire(
            0xCF8,
            4,
            adresse(EMPLACEMENT_DE_L_ECRAN, registre),
            &mut SansRam
        ));
        carte.port_lire(0xCFC, 4, &mut SansRam).expect("le bus")
    }

    fn regler_configuration(carte: &mut Carte, registre: u32, valeur: u32) {
        carte.port_ecrire(
            0xCF8,
            4,
            adresse(EMPLACEMENT_DE_L_ECRAN, registre),
            &mut SansRam,
        );
        assert!(carte.port_ecrire(0xCFC, 4, valeur, &mut SansRam));
    }

    /// Un registre DISPI, par la BAR2, comme le pilote quand il l'a.
    fn dispi(carte: &mut Carte, registre: u64) -> u64 {
        carte
            .mem_lire(BASE_DES_REGISTRES + 0x500 + registre * 2, 2)
            .expect("les registres répondent")
    }

    fn regler_dispi(carte: &mut Carte, registre: u64, valeur: u64) {
        assert!(carte.mem_ecrire(
            BASE_DES_REGISTRES + 0x500 + registre * 2,
            2,
            valeur,
            &mut SansRam
        ));
    }

    /// **Ce que `bochs_hw_setmode` écrit**, dans son ordre : la carte
    /// éteinte, la profondeur, la taille, la banque, la taille virtuelle,
    /// les décalages, puis la carte rallumée en cadre linéaire.
    fn regler_mode(carte: &mut Carte, largeur: u64, hauteur: u64) {
        regler_dispi(carte, 4, 0);
        regler_dispi(carte, 3, 32);
        regler_dispi(carte, 1, largeur);
        regler_dispi(carte, 2, hauteur);
        regler_dispi(carte, 5, 0);
        regler_dispi(carte, 6, largeur);
        regler_dispi(carte, 7, MEMOIRE_VIDEO as u64 / (largeur * 4));
        regler_dispi(carte, 8, 0);
        regler_dispi(carte, 9, 0);
        regler_dispi(carte, 4, 0x41);
    }

    fn cadre_de(carte: &Carte) -> &Cadre {
        &carte.ecran().expect("un écran").cadre
    }

    fn peindre(carte: &mut Carte, adresse: u64, valeur: u64) {
        assert!(
            carte.mem_ecrire(adresse, 4, valeur, &mut SansRam),
            "{adresse:#x}"
        );
    }

    fn mode(largeur: u32, hauteur: u32, octets_par_ligne: u32, debut: u64) -> Mode {
        Mode {
            largeur,
            hauteur,
            octets_par_ligne,
            debut,
        }
    }

    /// **La carte est en 00:02.0**, avec l'identité que le pilote cherche
    /// (`testTheCardIsOnTheBusWhereThePilotLooks`) : 1234:1111, contrôleur
    /// VGA, révision 2, sous-système de QEMU. Et même sans disque : une
    /// machine qui n'a qu'un écran a un bus.
    #[test]
    fn the_card_is_on_the_bus_where_the_pilot_looks() {
        let mut carte = machine();
        assert_eq!(EMPLACEMENT_DE_L_ECRAN, 2);
        assert_eq!(configuration(&mut carte, 0x00), 0x1111_1234);
        assert_eq!(configuration(&mut carte, 0x08), 0x0300_0002);
        assert_eq!(configuration(&mut carte, 0x2C), 0x1100_1AF4);
        assert_eq!(
            configuration(&mut carte, 0x04) & 0x03,
            0x03,
            "mémoire et ports décodés"
        );
        assert_eq!(configuration(&mut carte, 0x0C), 0, "en-tête de type zéro");
        assert_eq!(configuration(&mut carte, 0x14), 0, "pas de BAR1");
        assert_eq!(configuration(&mut carte, 0x3C), 0, "ni ligne ni broche");
        // À la largeur de l'accès, comme tout registre du bus.
        configuration(&mut carte, 0x00);
        assert_eq!(carte.port_lire(0xCFE, 2, &mut SansRam), Some(0x1111));
        assert_eq!(carte.port_lire(0xCFC, 1, &mut SansRam), Some(0x34));
        carte.port_ecrire(0xCF8, 4, adresse(1, 0), &mut SansRam);
        assert_eq!(
            carte.port_lire(0xCFC, 4, &mut SansRam),
            Some(0xFFFF_FFFF),
            "rien en 00:01.0"
        );
        // Ni à la fonction un, ni sur le bus un, ni sans le bit d'activation.
        for ailleurs in [
            adresse(2, 0) | (1 << 8),
            adresse(2, 0) | (1 << 16),
            adresse(2, 0) & !0x8000_0000,
        ] {
            carte.port_ecrire(0xCF8, 4, ailleurs, &mut SansRam);
            assert_eq!(
                carte.port_lire(0xCFC, 4, &mut SansRam),
                Some(0xFFFF_FFFF),
                "{ailleurs:#x}"
            );
        }
        // Le pont est toujours là, et la carte ne tient aucune ligne.
        carte.port_ecrire(0xCF8, 4, adresse(0, 0), &mut SansRam);
        assert_eq!(carte.port_lire(0xCFC, 4, &mut SansRam), Some(0x1237_8086));
        assert_eq!(carte.lignes(), 0);
    }

    /// **Les deux BAR** (`testTheBarsSayWhereAndHowLarge`) : la mémoire vidéo
    /// là où était déjà le cadre du démarrage, préchargeable, et les
    /// registres juste après. Et leur taille se mesure comme toujours : des
    /// uns écrits, le masque relu, l'adresse remise.
    #[test]
    fn the_bars_say_where_and_how_large() {
        let mut carte = machine();
        assert_eq!(BASE_DE_LA_MEMOIRE_VIDEO, 0xE000_0000);
        assert_eq!(BASE_DES_REGISTRES, 0xE100_0000);
        assert_eq!(configuration(&mut carte, 0x10), 0xE000_0008);
        assert_eq!(configuration(&mut carte, 0x18), 0xE100_0000);
        regler_configuration(&mut carte, 0x10, 0xFFFF_FFFF);
        assert_eq!(
            configuration(&mut carte, 0x10),
            0xFF00_0008,
            "seize mébioctets"
        );
        assert_eq!(
            configuration(&mut carte, 0x18),
            0xE100_0000,
            "l'autre BAR ne se mesure pas avec"
        );
        regler_configuration(&mut carte, 0x10, 0xE000_0008);
        regler_configuration(&mut carte, 0x18, 0xFFFF_FFFF);
        assert_eq!(
            configuration(&mut carte, 0x18),
            0xFFFF_F000,
            "quatre kibioctets"
        );
        assert_eq!(configuration(&mut carte, 0x10), 0xE000_0008);
        regler_configuration(&mut carte, 0x18, 0xE100_0000);
        assert_eq!(
            cadre_de(&carte).base(),
            0xE000_0000,
            "la mesure ne déplace rien"
        );
        assert_eq!(configuration(&mut carte, 0x18), 0xE100_0000);
        assert_eq!(carte.ecran().unwrap().base_des_registres(), 0xE100_0000);
    }

    /// **Le noyau peut déplacer les BAR**, et la carte le suit
    /// (`testMovedBarsAreFollowed`) : la mémoire vidéo répond à sa nouvelle
    /// adresse, plus à l'ancienne.
    #[test]
    fn moved_bars_are_followed() {
        let mut carte = machine();
        regler_configuration(&mut carte, 0x10, 0xF000_0008);
        regler_configuration(&mut carte, 0x18, 0xF100_0000);
        peindre(&mut carte, 0xF000_0010, 0x00AB_CDEF);
        assert_eq!(cadre_de(&carte).image().1[16..20], [0xEF, 0xCD, 0xAB, 0]);
        assert!(
            !carte.mem_ecrire(0xE000_0000, 4, 1, &mut SansRam),
            "l'ancienne adresse est vide"
        );
        assert_eq!(carte.mem_lire(0xE000_0000, 4), None);
        assert_eq!(
            carte.mem_lire(0xF100_0500, 2),
            Some(0xB0C5),
            "les registres aussi"
        );
        assert_eq!(carte.mem_lire(0xE100_0500, 2), None, "plus à l'ancienne");
        assert_eq!(cadre_de(&carte).base(), 0xF000_0000);
        // Les bits bas d'une BAR disent le type : l'adresse est alignée sur
        // la taille de la fenêtre.
        regler_configuration(&mut carte, 0x10, 0xD0FF_FFF8);
        assert_eq!(configuration(&mut carte, 0x10), 0xD000_0008);
        regler_configuration(&mut carte, 0x18, 0xD100_0FFF);
        assert_eq!(configuration(&mut carte, 0x18), 0xD100_0000);
        assert_eq!(carte.mem_lire(0xD000_0010, 4), Some(0x00AB_CDEF));
    }

    /// Un disque branché ne chasse pas la carte, avant comme après elle
    /// (`testAttachingADiskKeepsTheCard`).
    #[test]
    fn attaching_a_disk_keeps_the_card() {
        let mut carte = machine();
        carte.brancher_disque(8);
        assert_eq!(configuration(&mut carte, 0x00), 0x1111_1234);
        carte.port_ecrire(0xCF8, 4, adresse(3, 0), &mut SansRam);
        assert_eq!(carte.port_lire(0xCFC, 4, &mut SansRam), Some(0x1001_1AF4));
        let mut carte = Carte::nouvelle();
        carte.brancher_disque(8);
        assert!(carte.brancher_ecran(1024, 768));
        assert_eq!(configuration(&mut carte, 0x00), 0x1111_1234);
        carte.port_ecrire(0xCF8, 4, adresse(3, 0), &mut SansRam);
        assert_eq!(carte.port_lire(0xCFC, 4, &mut SansRam), Some(0x1001_1AF4));
        // Ce que le noyau règle sur l'un ne touche pas à l'autre.
        regler_configuration(&mut carte, 0x04, 0);
        assert_eq!(carte.pci.premier.commande, 0);
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 2, 5, &mut SansRam);
        assert_eq!(configuration(&mut carte, 0x04), 0, "la commande de l'écran");
        assert_eq!(carte.pci.premier.commande, 5);
    }

    /// **Ce que `bochs_hw_init` lit** (`testWhatThePilotReadsAtProbe`) :
    /// l'identifiant, la mémoire en unités de 64 Kio, la taille des registres
    /// étendus de QEMU. Et l'EDID absent : des zéros.
    #[test]
    fn what_the_pilot_reads_at_probe() {
        let mut carte = machine();
        assert_eq!(dispi(&mut carte, 0), 0xB0C5);
        assert_eq!(dispi(&mut carte, 10), 256, "seize mébioctets");
        assert_eq!(carte.mem_lire(BASE_DES_REGISTRES + 0x600, 4), Some(8));
        assert_eq!(
            carte.mem_lire(BASE_DES_REGISTRES + 0x604, 4),
            Some(0x1E1E_1E1E),
            "l'ordre des octets, au départ"
        );
        assert!(carte.mem_ecrire(BASE_DES_REGISTRES + 0x604, 4, 0xBEBE_BEBE, &mut SansRam));
        assert_eq!(
            carte.mem_lire(BASE_DES_REGISTRES + 0x604, 4),
            Some(0xBEBE_BEBE)
        );
        assert_eq!(
            carte.mem_lire(BASE_DES_REGISTRES, 8),
            Some(0),
            "pas d'en-tête EDID"
        );
        // L'EDID et les ports VGA se laissent écrire, sans effet.
        assert!(carte.mem_ecrire(BASE_DES_REGISTRES, 8, u64::MAX, &mut SansRam));
        assert!(carte.mem_ecrire(BASE_DES_REGISTRES + 0x400, 1, 0xFF, &mut SansRam));
        assert_eq!(carte.mem_lire(BASE_DES_REGISTRES, 8), Some(0));
        assert_eq!(carte.mem_lire(BASE_DES_REGISTRES + 0x400, 1), Some(0));
        // L'identifiant ne prend qu'une version connue ; la mémoire est en
        // lecture seule ; une profondeur nulle vaut huit bits.
        regler_dispi(&mut carte, 0, 0xB0C2);
        assert_eq!(dispi(&mut carte, 0), 0xB0C2);
        for refuse in [0xB0BF, 0xB0C6, 0x1234] {
            regler_dispi(&mut carte, 0, refuse);
            assert_eq!(dispi(&mut carte, 0), 0xB0C2, "{refuse:#x}");
        }
        regler_dispi(&mut carte, 0, 0xB0C0);
        assert_eq!(dispi(&mut carte, 0), 0xB0C0);
        regler_dispi(&mut carte, 10, 1);
        assert_eq!(dispi(&mut carte, 10), 256);
        regler_dispi(&mut carte, 3, 0);
        assert_eq!(dispi(&mut carte, 3), 8);
        // Au-delà du onzième registre : rien à lire, rien d'écrit.
        assert_eq!(carte.ecran().unwrap().lire_registre(11), 0);
        carte.ecran_mut().unwrap().ecrire_registre(11, 7);
        assert_eq!(carte.ecran().unwrap().lire_registre(11), 0);
    }

    /// **Les registres, à la largeur de l'accès.** Deux octets : un
    /// registre ; quatre ou plus : celui-là et le suivant, comme le pilote
    /// écrit `XRES` et `YRES` d'un mot. Un seul octet lu n'en rend qu'un.
    #[test]
    fn the_registers_follow_the_width_of_the_access() {
        let mut carte = machine();
        let a = |registre: u64| BASE_DES_REGISTRES + 0x500 + registre * 2;
        assert!(carte.mem_ecrire(a(1), 4, 0x0258_0320, &mut SansRam));
        assert_eq!((dispi(&mut carte, 1), dispi(&mut carte, 2)), (800, 600));
        assert_eq!(carte.mem_lire(a(1), 4), Some(0x0258_0320));
        assert_eq!(
            carte.mem_lire(a(1), 8),
            Some(0x0258_0320),
            "deux registres, pas quatre"
        );
        assert_eq!(carte.mem_lire(a(1), 1), Some(0x20), "un octet");
        assert_eq!(carte.mem_lire(a(0), 4), Some(0x0320_B0C5));
        // Deux octets n'écrivent qu'un registre.
        assert!(carte.mem_ecrire(a(1), 2, 0xFFFF_0400, &mut SansRam));
        assert_eq!((dispi(&mut carte, 1), dispi(&mut carte, 2)), (1024, 600));
        // Le dernier registre n'a pas de suivant.
        assert_eq!(carte.mem_lire(a(10), 4), Some(256));
        assert!(carte.mem_ecrire(a(9), 4, 0x0001_0007, &mut SansRam));
        assert_eq!((dispi(&mut carte, 9), dispi(&mut carte, 10)), (7, 256));
        // Juste après les registres DISPI, et juste avant : rien.
        assert_eq!(carte.mem_lire(a(11), 2), Some(0));
        assert_eq!(carte.mem_lire(BASE_DES_REGISTRES + 0x4FE, 2), Some(0));
        // Une largeur impossible n'est un accès à personne.
        assert_eq!(carte.mem_lire(a(0), 0), None);
        assert_eq!(carte.mem_lire(a(0), 9), None);
        assert!(!carte.mem_ecrire(a(1), 0, 5, &mut SansRam));
        assert!(!carte.mem_ecrire(a(1), 16, 5, &mut SansRam));
        assert_eq!(dispi(&mut carte, 1), 1024);
    }

    /// **Le mode que le pilote pose est celui que l'écran montre**, et
    /// éteindre la carte ramène le cadre du démarrage
    /// (`testTheModeThePilotSetsIsTheOneShown`).
    #[test]
    fn the_mode_the_pilot_sets_is_the_one_shown() {
        let mut carte = machine();
        let depart = cadre_de(&carte).mode_de_depart();
        assert_eq!(depart, mode(1024, 768, 4096, 0));
        assert_eq!(cadre_de(&carte).mode(), depart);
        regler_mode(&mut carte, 800, 600);
        assert_eq!(cadre_de(&carte).mode(), mode(800, 600, 3200, 0));
        regler_dispi(&mut carte, 4, 0);
        assert_eq!(cadre_de(&carte).mode(), depart);
        // **Seul le cadre linéaire en trente-deux bits se montre** : une
        // autre profondeur, ou la carte allumée sans le bit du cadre
        // linéaire, laisse l'image où elle était.
        regler_mode(&mut carte, 800, 600);
        regler_dispi(&mut carte, 3, 16);
        regler_dispi(&mut carte, 1, 640);
        assert_eq!(cadre_de(&carte).mode(), mode(800, 600, 3200, 0), "16 bits");
        regler_dispi(&mut carte, 3, 32);
        assert_eq!(cadre_de(&carte).mode().largeur, 640);
        regler_dispi(&mut carte, 4, 0);
        regler_dispi(&mut carte, 1, 320);
        regler_dispi(&mut carte, 2, 200);
        regler_dispi(&mut carte, 4, 0x01);
        assert_eq!(
            cadre_de(&carte).mode(),
            depart,
            "allumée, sans cadre linéaire"
        );
        regler_dispi(&mut carte, 4, 0x41);
        assert_eq!(cadre_de(&carte).mode(), mode(320, 200, 1280, 0));
    }

    /// **Changer de page** (`bochs_hw_setbase`,
    /// `testFlippingAPageMovesTheStart`) : la largeur virtuelle et les
    /// décalages disent où commence l'image montrée.
    #[test]
    fn flipping_a_page_moves_the_start() {
        let mut carte = machine();
        regler_mode(&mut carte, 640, 480);
        regler_dispi(&mut carte, 6, 640);
        regler_dispi(&mut carte, 8, 0);
        regler_dispi(&mut carte, 9, 480);
        assert_eq!(cadre_de(&carte).mode().debut, 480 * 640 * 4);
        // L'image montrée vient bien de là.
        peindre(
            &mut carte,
            BASE_DE_LA_MEMOIRE_VIDEO + 480 * 640 * 4,
            0x0012_3456,
        );
        assert_eq!(cadre_de(&carte).image().1[..4], [0x56, 0x34, 0x12, 0]);
        // Le décalage en X compte en pixels, sur la même ligne.
        regler_dispi(&mut carte, 8, 3);
        assert_eq!(cadre_de(&carte).mode().debut, (480 * 640 + 3) * 4);
        // Rallumée, la carte repart de la première page, comme QEMU.
        regler_dispi(&mut carte, 4, 0);
        regler_dispi(&mut carte, 4, 0x41);
        assert_eq!(cadre_de(&carte).mode().debut, 0);
        assert_eq!(
            (dispi(&mut carte, 8), dispi(&mut carte, 9)),
            (0, 0),
            "les décalages remis à zéro"
        );
        assert_eq!(
            (dispi(&mut carte, 6), dispi(&mut carte, 7)),
            (640, 480),
            "et la taille virtuelle à celle de l'image"
        );
        // Une ligne virtuelle plus longue que l'image : le décalage en Y
        // compte des lignes virtuelles, pas des lignes montrées.
        regler_dispi(&mut carte, 6, 1024);
        regler_dispi(&mut carte, 9, 2);
        regler_dispi(&mut carte, 8, 5);
        assert_eq!(
            cadre_de(&carte).mode(),
            mode(640, 480, 4096, (2 * 1024 + 5) * 4)
        );
    }

    /// **Une ligne virtuelle plus longue que l'image**
    /// (`testAWiderVirtualLineIsReadWithoutItsPadding`) : la vue en lit les
    /// pixels montrés, ligne à ligne, sans le remplissage.
    #[test]
    fn a_wider_virtual_line_is_read_without_its_padding() {
        let mut carte = machine();
        regler_mode(&mut carte, 8, 2);
        regler_dispi(&mut carte, 6, 16);
        // Deuxième ligne, premier pixel ; et un pixel dans le remplissage de
        // la première, que l'image ne doit pas montrer.
        peindre(&mut carte, BASE_DE_LA_MEMOIRE_VIDEO + 64, 0x0000_00AA);
        peindre(&mut carte, BASE_DE_LA_MEMOIRE_VIDEO + 32, 0x0000_00BB);
        let (mode, image) = cadre_de(&carte).image();
        assert_eq!(mode.octets_par_ligne, 64);
        assert_eq!(image.len(), 8 * 2 * 4);
        assert_eq!(image[32], 0xAA);
        assert_eq!(image.iter().filter(|&&octet| octet != 0).count(), 1);
        // Une largeur virtuelle plus courte que l'image ne raccourcit pas
        // les lignes.
        regler_dispi(&mut carte, 6, 4);
        assert_eq!(cadre_de(&carte).mode().octets_par_ligne, 32);
    }

    /// **Un mode qui ne tient pas dans la mémoire vidéo ne s'affiche pas**
    /// (`testAModeThatDoesNotFitIsRefused`) : l'écran garde ce qu'il
    /// montrait — un décalage de trop laisse le mode en place, une taille de
    /// trop laisse le cadre du démarrage, que la carte éteinte avait remis —,
    /// et la vue ne lit jamais au-delà des pixels.
    #[test]
    fn a_mode_that_does_not_fit_is_refused() {
        let mut carte = machine();
        regler_mode(&mut carte, 800, 600);
        regler_dispi(&mut carte, 9, 7000);
        assert_eq!(
            cadre_de(&carte).mode().debut,
            0,
            "le décalage de trop est refusé"
        );
        // Le dernier décalage qui tient : 16 Mio / 3 200 octets font 5 242
        // lignes, dont 600 montrées.
        regler_dispi(&mut carte, 9, 4642);
        assert_eq!(cadre_de(&carte).mode().debut, 4642 * 3200);
        regler_dispi(&mut carte, 9, 4643);
        assert_eq!(
            cadre_de(&carte).mode().debut,
            4642 * 3200,
            "une ligne de trop"
        );
        let depart = cadre_de(&carte).mode_de_depart();
        regler_mode(&mut carte, 4096, 4096);
        assert_eq!(cadre_de(&carte).mode(), depart);
        // Le plus grand que le registre peut dire : le compte ne fait pas le
        // tour, même là où un `usize` n'a que trente-deux bits.
        regler_mode(&mut carte, 0xFFFF, 0xFFFF);
        regler_dispi(&mut carte, 8, 0xFFFF);
        regler_dispi(&mut carte, 9, 0xFFFF);
        assert_eq!(cadre_de(&carte).mode(), depart);
        assert_eq!(cadre_de(&carte).image().1.len(), 1024 * 768 * 4);
        // Deux images de 1920 × 1080 tiennent, c'est ce que `bochs-drm`
        // exige de seize mébioctets.
        regler_mode(&mut carte, 1920, 1080);
        regler_dispi(&mut carte, 9, 1080);
        assert_eq!(cadre_de(&carte).mode(), mode(1920, 1080, 7680, 1080 * 7680));
    }

    /// Allumer la carte efface ce qu'elle va montrer, comme QEMU ; avec
    /// `NOCLEARMEM`, non (`testEnablingClearsUnlessAskedNotTo`).
    #[test]
    fn enabling_clears_unless_asked_not_to() {
        let mut carte = machine();
        peindre(&mut carte, BASE_DE_LA_MEMOIRE_VIDEO, 0x00FF_FFFF);
        // Le dernier pixel de l'image à venir, et le premier après elle.
        let fin = BASE_DE_LA_MEMOIRE_VIDEO + 640 * 480 * 4;
        peindre(&mut carte, fin - 4, 0x0011_1111);
        peindre(&mut carte, fin, 0x0022_2222);
        regler_mode(&mut carte, 640, 480);
        assert_eq!(cadre_de(&carte).image().1[..4], [0, 0, 0, 0]);
        assert_eq!(
            carte.mem_lire(fin - 4, 4),
            Some(0),
            "jusqu'au dernier pixel"
        );
        assert_eq!(
            carte.mem_lire(fin, 4),
            Some(0x0022_2222),
            "et pas un octet de plus"
        );
        regler_dispi(&mut carte, 4, 0);
        peindre(&mut carte, BASE_DE_LA_MEMOIRE_VIDEO, 0x00FF_FFFF);
        regler_dispi(&mut carte, 4, 0xC1);
        assert_eq!(cadre_de(&carte).image().1[..4], [0xFF, 0xFF, 0xFF, 0]);
        // Déjà allumée, la rallumer n'efface rien et ne remet pas la page.
        regler_dispi(&mut carte, 9, 2);
        regler_dispi(&mut carte, 4, 0x41);
        assert_eq!(
            carte.mem_lire(BASE_DE_LA_MEMOIRE_VIDEO, 4),
            Some(0x00FF_FFFF)
        );
        assert_eq!(dispi(&mut carte, 9), 2);
    }

    /// Sous `GETCAPS`, la taille et la profondeur se lisent à leur maximum
    /// (`testCapabilitiesReadTheMaximums`).
    #[test]
    fn capabilities_read_the_maximums() {
        let mut carte = machine();
        regler_dispi(&mut carte, 1, 800);
        regler_dispi(&mut carte, 2, 600);
        regler_dispi(&mut carte, 3, 24);
        regler_dispi(&mut carte, 4, 0x02);
        assert_eq!(dispi(&mut carte, 1), 2560);
        assert_eq!(dispi(&mut carte, 2), 1600);
        assert_eq!(dispi(&mut carte, 3), 32);
        assert_eq!(dispi(&mut carte, 0), 0xB0C5, "le reste se lit tel quel");
        assert_eq!(dispi(&mut carte, 4), 0x02);
        // Le bit retiré, ce que le pilote avait écrit est toujours là.
        regler_dispi(&mut carte, 4, 0);
        assert_eq!(
            (
                dispi(&mut carte, 1),
                dispi(&mut carte, 2),
                dispi(&mut carte, 3)
            ),
            (800, 600, 24)
        );
    }

    /// **Les mêmes registres par les ports** `0x1CE` et `0x1CF`, pour un
    /// pilote sans BAR2 : l'index, puis la donnée
    /// (`testTheSameRegistersThroughThePorts`).
    #[test]
    fn the_same_registers_through_the_ports() {
        let mut carte = machine();
        assert_eq!((PORT_INDEX, PORT_DONNEE), (0x1CE, 0x1CF));
        assert!(carte.port_ecrire(0x1CE, 2, 0, &mut SansRam));
        assert_eq!(carte.port_lire(0x1CF, 2, &mut SansRam), Some(0xB0C5));
        assert!(carte.port_ecrire(0x1CE, 2, 1, &mut SansRam));
        assert!(carte.port_ecrire(0x1CF, 2, 320, &mut SansRam));
        assert_eq!(carte.ecran().unwrap().lire_registre(1), 320);
        assert_eq!(dispi(&mut carte, 1), 320, "le même registre, par la BAR2");
        assert_eq!(carte.port_lire(0x1CE, 2, &mut SansRam), Some(1), "l'index");
        // À la largeur de l'accès : un `inb` rend l'octet bas, un `inl` les
        // seize bits ; un `outb` écrit un registre de huit bits, un `outl`
        // n'en garde que seize.
        carte.port_ecrire(0x1CE, 2, 0, &mut SansRam);
        assert_eq!(carte.port_lire(0x1CF, 1, &mut SansRam), Some(0xC5));
        assert_eq!(carte.port_lire(0x1CF, 4, &mut SansRam), Some(0xB0C5));
        carte.port_ecrire(0x1CE, 1, 0xFF02, &mut SansRam);
        assert_eq!(carte.port_lire(0x1CE, 2, &mut SansRam), Some(2));
        carte.port_ecrire(0x1CF, 4, 0x0001_0258, &mut SansRam);
        assert_eq!(dispi(&mut carte, 2), 600);
        assert_eq!(carte.port_lire(0x1CF, 3, &mut SansRam), None);
        // Un mode entier posé par les ports se montre comme par la BAR2.
        let mut par_les_ports = |registre: u32, valeur: u32| {
            assert!(carte.port_ecrire(0x1CE, 2, registre, &mut SansRam));
            assert!(carte.port_ecrire(0x1CF, 2, valeur, &mut SansRam));
        };
        for (registre, valeur) in [(4, 0), (3, 32), (1, 640), (2, 480), (4, 0x41)] {
            par_les_ports(registre, valeur);
        }
        assert_eq!(cadre_de(&carte).mode(), mode(640, 480, 2560, 0));
        // Le port voisin n'est à personne, et un index hors des registres ne
        // lit rien.
        assert_eq!(carte.port_lire(0x1CD, 2, &mut SansRam), None);
        assert_eq!(carte.port_lire(0x1D0, 2, &mut SansRam), None);
        carte.port_ecrire(0x1CE, 2, 0x20, &mut SansRam);
        assert_eq!(carte.port_lire(0x1CF, 2, &mut SansRam), Some(0));
    }

    /// **Les deux ports de l'écran sont des ports fixes quand il est
    /// branché**, et passent avant la fenêtre d'un disque posée dessus — et
    /// ne sont à personne sans écran, où la fenêtre les prend.
    #[test]
    fn the_screen_ports_are_fixed_only_when_there_is_a_screen() {
        let ouvrir = |carte: &mut Carte| {
            carte.brancher_disque(0x0102_0304);
            for (registre, largeur, valeur) in [(0x10, 4, 0x1C0), (0x04, 2, 1)] {
                carte.port_ecrire(0xCF8, 4, adresse(3, registre), &mut SansRam);
                carte.port_ecrire(0xCFC, largeur, valeur, &mut SansRam);
            }
        };
        let mut sans = Carte::nouvelle();
        assert_eq!(sans.port_lire(0x1CE, 2, &mut SansRam), None);
        assert!(!sans.port_ecrire(0x1CF, 2, 0, &mut SansRam));
        assert!(!sans.est_fixe(0x1CE) && !sans.est_fixe(0x1CF));
        ouvrir(&mut sans);
        assert!(sans.fenetre_au_port(0x1CE).is_some(), "la fenêtre le prend");
        let mut avec = machine();
        ouvrir(&mut avec);
        assert!(avec.est_fixe(0x1CE) && avec.est_fixe(0x1CF));
        assert!(!avec.est_fixe(0x1CD) && !avec.est_fixe(0x1D0));
        assert_eq!(avec.fenetre_au_port(0x1CE), None);
        assert_eq!(avec.fenetre_au_port(0x1CF), None);
        assert!(avec.fenetre_au_port(0x1CD).is_some());
        assert_eq!(avec.port_lire(0x1CF, 2, &mut SansRam), Some(0xB0C5));
        // Les ports fixes de toute carte le restent.
        for port in [0x60, 0x64, 0x70, 0x71, 0xCF8, 0xCFC, 0xCFF] {
            assert!(avec.est_fixe(port) && sans.est_fixe(port), "{port:#x}");
        }
        // Et sur les 65 536 ports, une carte avec écran et sans disque prend
        // exactement ceux-là. (Un écran d'un pixel : seize mébioctets par
        // port feraient un tébioctet à remettre à zéro.)
        let mut pris = Vec::new();
        for port in 0..=u16::MAX {
            let mut carte = Carte::nouvelle();
            carte.pci.ecran = Some(Ecran::nouveau(
                Cadre::nouveau(BASE_DE_LA_MEMOIRE_VIDEO, 1, 1, None),
                BASE_DES_REGISTRES,
            ));
            let lu = carte.port_lire(port, 1, &mut SansRam).is_some();
            assert_eq!(lu, carte.port_ecrire(port, 1, 0, &mut SansRam), "{port:#x}");
            assert_eq!(lu, carte.est_fixe(port), "{port:#x}");
            if lu {
                pris.push(port);
            }
        }
        assert_eq!(
            pris,
            [0x60, 0x64, 0x70, 0x71, 0x1CE, 0x1CF, 0xCF8, 0xCFC, 0xCFD, 0xCFE, 0xCFF]
        );
    }

    /// **Une machine avec écran le déclare et le route**
    /// (`testAMachineWithADisplayDeclaresItAndRoutesIt`). Ce que le chargeur
    /// annonce au noyau — l'adresse, la taille, la longueur d'une ligne —
    /// se lit sur le cadre ; et l'annonce doit être vraie : une écriture de
    /// l'invité à l'adresse annoncée atteint le cadre.
    #[test]
    fn a_machine_with_a_display_declares_it_and_routes_it() {
        let mut carte = Carte::nouvelle();
        assert!(carte.brancher_ecran(640, 480));
        let cadre = cadre_de(&carte);
        assert_eq!(cadre.mode_de_depart(), mode(640, 480, 2560, 0));
        assert_eq!(cadre.mode(), cadre.mode_de_depart());
        assert_eq!(cadre.base(), 0xE000_0000);
        assert_eq!(cadre.taille(), 16 << 20);
        assert_eq!(cadre.revision(), 0);
        let base = cadre.base();
        peindre(&mut carte, base, 0x00AB_CDEF);
        assert_eq!(cadre_de(&carte).image().1[..4], [0xEF, 0xCD, 0xAB, 0]);
        assert_eq!(cadre_de(&carte).octets()[..4], [0xEF, 0xCD, 0xAB, 0]);
        assert_eq!(carte.mem_lire(base, 4), Some(0x00AB_CDEF));
        assert_eq!(cadre_de(&carte).revision(), 1, "une écriture, une révision");
        assert_eq!(carte.mem_lire(base + 1, 2), Some(0xABCD));
        assert_eq!(cadre_de(&carte).revision(), 1, "lire ne change rien");
        // Rebranché : un écran neuf, sans rien de l'ancien.
        assert!(carte.brancher_ecran(800, 600));
        assert_eq!(cadre_de(&carte).mode_de_depart(), mode(800, 600, 3200, 0));
        assert_eq!(carte.mem_lire(base, 4), Some(0));
        // Un cadre qui ne tient pas dans seize mébioctets est refusé, et
        // l'écran d'avant reste.
        assert!(!carte.brancher_ecran(2560, 1640));
        assert!(!carte.brancher_ecran(u32::MAX, u32::MAX));
        assert_eq!(cadre_de(&carte).mode_de_depart().largeur, 800);
        assert!(
            carte.brancher_ecran(2560, 1638),
            "16 773 120 octets : tient"
        );
        // Seize mébioctets tout juste : tient ; une ligne de plus, non.
        assert!(!carte.brancher_ecran(2048, 2049));
        assert!(
            carte.brancher_ecran(2048, 2048),
            "16 777 216 octets : tient"
        );
        assert_eq!(cadre_de(&carte).mode_de_depart(), mode(2048, 2048, 8192, 0));
        assert!(carte.brancher_ecran(0, 0), "un pixel, comme le Swift");
        assert_eq!(cadre_de(&carte).mode_de_depart(), mode(1, 1, 4, 0));
    }

    /// **Sans écran demandé, rien ne change**
    /// (`testAMachineWithoutADisplayHasNone`) : ni cadre, ni carte sur le
    /// bus, ni tablette, ni adresse en mémoire.
    #[test]
    fn a_machine_without_a_display_has_none() {
        let mut carte = Carte::nouvelle();
        assert!(carte.ecran().is_none() && carte.tablette().is_none());
        assert_eq!(configuration(&mut carte, 0), 0xFFFF_FFFF, "00:02.0, vide");
        regler_configuration(&mut carte, 0x10, 0xF000_0000);
        assert_eq!(configuration(&mut carte, 0x10), 0xFFFF_FFFF);
        for adresse in [0xE000_0000, 0xE100_0500, 0xE101_0000, 0xF000_0000] {
            assert_eq!(carte.mem_lire(adresse, 4), None, "{adresse:#x}");
            assert!(!carte.mem_ecrire(adresse, 4, 1, &mut SansRam));
            assert!(!carte.mem_ecrire_bloc(adresse, &[1]));
            assert!(!carte.mem_lire_bloc(adresse, &mut [0]));
            assert_eq!(carte.region(adresse, 4), None);
        }
        assert!(!carte.toucher(0.5, 0.5, 1) && !carte.defiler(1));
        assert_eq!(carte.tenues(), (1 << 1) | (1 << 12), "ni la ligne 10");
        carte.port_ecrire(0xCF8, 4, 0, &mut SansRam);
        assert_eq!(carte, Carte::nouvelle(), "et rien n'a bougé");
    }

    /// **La RAM et le cadre ne se touchent pas**
    /// (`testWritingToRAMLeavesTheFrameAlone`, `testADisplayNeverOverlapsRAM`) :
    /// la carte ne prend en mémoire que ses trois fenêtres, à l'octet près,
    /// et tout le reste — la RAM d'abord — reste à la machine.
    #[test]
    fn the_card_takes_its_three_windows_and_nothing_else() {
        let mut carte = machine();
        // Une écriture ordinaire, dans la RAM : pas à la carte.
        assert!(!carte.mem_ecrire(0x1000, 4, 0xDEAD_BEEF, &mut SansRam));
        assert_eq!(carte.mem_lire(0x1000, 4), None);
        assert_eq!(cadre_de(&carte).revision(), 0);
        assert!(cadre_de(&carte).octets().iter().all(|&octet| octet == 0));
        let video = BASE_DE_LA_MEMOIRE_VIDEO;
        let registres = BASE_DES_REGISTRES;
        // La mémoire vidéo : seize mébioctets, puis les registres aussitôt.
        assert_eq!(carte.region(video - 1, 1), None);
        assert_eq!(carte.region(video - 1, 4), None, "à cheval sur le début");
        assert_eq!(carte.region(video, 4), Some(Region::MemoireVideo(0)));
        assert_eq!(
            carte.region(registres - 4, 4),
            Some(Region::MemoireVideo(MEMOIRE_VIDEO - 4))
        );
        assert_eq!(
            carte.region(registres - 2, 4),
            None,
            "à cheval sur deux fenêtres : ni l'une ni l'autre"
        );
        assert_eq!(
            carte.region(registres, 4),
            Some(Region::RegistresDeLEcran(0))
        );
        assert_eq!(
            carte.region(registres + 0xFFC, 4),
            Some(Region::RegistresDeLEcran(0xFFC))
        );
        assert_eq!(carte.region(registres + 0xFFD, 4), None);
        assert_eq!(carte.region(registres + 0x1000, 1), None);
        // La tablette : seize kibioctets à `0xE101_0000`, une fois sa
        // mémoire allumée par le noyau.
        let tablette = registres + 0x1_0000;
        assert_eq!(carte.region(tablette, 4), None, "éteinte");
        carte.port_ecrire(0xCF8, 4, adresse(7, 0x04), &mut SansRam);
        carte.port_ecrire(0xCFC, 2, 0x0006, &mut SansRam);
        assert_eq!(carte.region(tablette - 1, 1), None);
        assert_eq!(carte.region(tablette, 4), Some(Region::Tablette(0)));
        assert_eq!(
            carte.region(tablette + 0x3FFC, 4),
            Some(Region::Tablette(0x3FFC))
        );
        assert_eq!(carte.region(tablette + 0x3FFE, 4), None);
        assert_eq!(carte.region(tablette + 0x4000, 1), None);
        for ailleurs in [0, 0x10_0000, 0xDFFF_FFFC, 0xFEC0_0000, 1 << 32, u64::MAX] {
            assert_eq!(carte.region(ailleurs, 4), None, "{ailleurs:#x}");
        }
        // **La mémoire vidéo passe devant** : des registres posés par le
        // noyau au milieu d'elle ne lui volent rien.
        regler_configuration(&mut carte, 0x18, 0xE000_1000);
        assert_eq!(
            carte.region(0xE000_1500, 2),
            Some(Region::MemoireVideo(0x1500))
        );
    }

    /// **Un bloc d'un coup, et une seule révision** : la copie d'une ligne
    /// entière ne passe pas octet par octet.
    #[test]
    fn a_block_is_copied_in_one_go_and_counted_once() {
        let mut carte = machine();
        let ligne: Vec<u8> = (0..4096u32).map(|rang| (rang % 251) as u8 + 1).collect();
        let a = BASE_DE_LA_MEMOIRE_VIDEO + 4096 * 10;
        assert!(carte.mem_ecrire_bloc(a, &ligne));
        assert_eq!(cadre_de(&carte).revision(), 1, "une copie, une révision");
        assert_eq!(cadre_de(&carte).octets()[4096 * 10..4096 * 11], ligne[..]);
        assert_eq!(cadre_de(&carte).octets()[4096 * 10 - 1], 0);
        assert_eq!(cadre_de(&carte).octets()[4096 * 11], 0);
        let mut relue = vec![0; 4096];
        assert!(carte.mem_lire_bloc(a, &mut relue));
        assert_eq!(relue, ligne);
        assert_eq!(cadre_de(&carte).revision(), 1, "lire ne compte pas");
        // Un bloc vide ne change rien, et n'est dedans qu'à une adresse de
        // la mémoire vidéo.
        assert!(carte.mem_ecrire_bloc(a, &[]));
        assert_eq!(cadre_de(&carte).revision(), 1);
        assert!(!carte.mem_ecrire_bloc(0x1000, &[]));
        // Ce qui déborde de la mémoire vidéo n'est copié nulle part, même en
        // partie : ni au-delà de la fin, ni dans les registres.
        let fin = BASE_DES_REGISTRES;
        assert!(
            carte.mem_ecrire_bloc(fin - 4096, &ligne),
            "la dernière ligne"
        );
        assert!(!carte.mem_ecrire_bloc(fin - 4095, &ligne));
        assert!(!carte.mem_lire_bloc(fin - 4095, &mut relue));
        assert_eq!(relue, ligne, "un refus ne touche à rien");
        assert!(!carte.mem_ecrire_bloc(BASE_DES_REGISTRES + 0x500, &[1, 2]));
        assert!(!carte.mem_lire_bloc(BASE_DES_REGISTRES + 0x500, &mut [0; 2]));
        assert!(!carte.mem_ecrire_bloc(BASE_DE_LA_MEMOIRE_VIDEO - 1, &[1, 2]));
        assert_eq!(cadre_de(&carte).revision(), 2);
        // Et l'image copiée pour la vue est celle que l'invité a peinte.
        regler_mode(&mut carte, 1024, 768);
        assert!(carte.mem_ecrire_bloc(a, &ligne));
        let mut image = Vec::new();
        let mode = cadre_de(&carte).image_dans(&mut image);
        assert_eq!((mode.largeur, mode.hauteur), (1024, 768));
        assert_eq!(image.len(), 1024 * 768 * 4);
        assert_eq!(image[4096 * 10..4096 * 11], ligne[..]);
    }
}
