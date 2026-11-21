//! **Mettre un noyau Linux là où il s'attend à être**, au protocole de
//! démarrage 64 bits : le port de `LinuxBootProtocol.swift` et de
//! `X86BootLoader.swift`.
//!
//! Un noyau x86-64 ne se contente pas d'être copié quelque part : il exige une
//! adresse compatible avec son alignement, une zone réservée plus grande que
//! ce qu'il pèse, et une structure — la « page zéro » — où le chargeur écrit ce
//! qu'il a fait. RSI la lui désigne au moment du saut.

use crate::x86::GuestMemory;

use super::memoire;

/// Ce que l'en-tête de démarrage d'un `bzImage` dit de lui.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Protocole {
    pub version: u16,
    /// Les secteurs de `setup`, en octets : le code en mode réel, que ce
    /// chargeur saute.
    pub octets_de_setup: usize,
    /// Le noyau en mode protégé, qui suit.
    pub octets_proteges: usize,
    pub drapeaux: u8,
    pub drapeaux_etendus: u16,
    pub deplacable: bool,
    pub adresse_preferee: u64,
    pub taille_reservee: u32,
    pub limite_de_ligne: u32,
}

const SECTEURS_DE_SETUP: usize = 0x01F1;
const TAILLE_DU_SYSTEME: usize = 0x01F4;
const DRAPEAU_D_AMORCE: usize = 0x01FE;
const MAGIE: usize = 0x0202;
const VERSION: usize = 0x0206;
const DRAPEAUX: usize = 0x0211;
const DEPLACABLE: usize = 0x0234;
const DRAPEAUX_ETENDUS: usize = 0x0236;
const LIMITE_DE_LIGNE: usize = 0x0238;
const ADRESSE_PREFEREE: usize = 0x0258;
const TAILLE_RESERVEE: usize = 0x0260;
/// Où l'en-tête finit : ce qu'il faut d'octets pour le lire.
pub const OCTETS_D_EN_TETE: usize = 0x0264;

fn u16_a(octets: &[u8], ou: usize) -> u16 {
    u16::from_le_bytes([octets[ou], octets[ou + 1]])
}

fn u32_a(octets: &[u8], ou: usize) -> u32 {
    u32::from_le_bytes([octets[ou], octets[ou + 1], octets[ou + 2], octets[ou + 3]])
}

fn u64_a(octets: &[u8], ou: usize) -> u64 {
    u64::from(u32_a(octets, ou)) | (u64::from(u32_a(octets, ou + 4)) << 32)
}

impl Protocole {
    /// Lire l'en-tête, ou rien si ce n'est pas un noyau Linux pour PC.
    ///
    /// `total` est la taille du fichier quand on la connaît : un en-tête qui
    /// annonce plus que le fichier ne porte est un fichier tronqué, et il est
    /// refusé ici plutôt que chargé à moitié.
    pub fn lire(octets: &[u8], total: Option<usize>) -> Option<Self> {
        if octets.len() < OCTETS_D_EN_TETE {
            return None;
        }
        if u16_a(octets, DRAPEAU_D_AMORCE) != 0xAA55 || &octets[MAGIE..MAGIE + 4] != b"HdrS" {
            return None;
        }
        let version = u16_a(octets, VERSION);
        if version < 0x0200 {
            return None;
        }
        // Zéro secteur veut dire quatre : c'est le protocole, pas un choix.
        let secteurs = match octets[SECTEURS_DE_SETUP] {
            0 => 4,
            n => usize::from(n),
        };
        let octets_de_setup = (secteurs + 1) * 512;
        let octets_proteges = u32_a(octets, TAILLE_DU_SYSTEME) as usize * 16;
        if total.is_some_and(|total| octets_de_setup + octets_proteges > total) {
            return None;
        }
        Some(Self {
            version,
            octets_de_setup,
            octets_proteges,
            drapeaux: octets[DRAPEAUX],
            drapeaux_etendus: if version >= 0x020C {
                u16_a(octets, DRAPEAUX_ETENDUS)
            } else {
                0
            },
            deplacable: version >= 0x0205 && octets[DEPLACABLE] != 0,
            adresse_preferee: if version >= 0x020A {
                u64_a(octets, ADRESSE_PREFEREE)
            } else {
                0
            },
            taille_reservee: if version >= 0x020A {
                u32_a(octets, TAILLE_RESERVEE)
            } else {
                0
            },
            limite_de_ligne: if version >= 0x0206 {
                u32_a(octets, LIMITE_DE_LIGNE)
            } else {
                0
            },
        })
    }

    /// Le noyau offre-t-il un point d'entrée 64 bits ?
    pub fn entree_64_bits(&self) -> bool {
        self.drapeaux_etendus & 0x0001 != 0
    }

    pub fn architecture(&self) -> &'static str {
        if self.entree_64_bits() {
            "x86-64"
        } else {
            "x86"
        }
    }

    /// « 2.15 », comme la documentation du noyau l'écrit.
    pub fn version_dite(&self) -> String {
        format!("{}.{}", self.version >> 8, self.version & 0xFF)
    }

    pub fn octets_declares(&self) -> usize {
        self.octets_de_setup + self.octets_proteges
    }
}

/// Ce que le chargement a produit.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Placement {
    /// Où le noyau en mode protégé a été mis.
    pub adresse_du_noyau: u64,
    /// Combien d'octets lui sont réservés à partir de là — bien plus que ce
    /// qu'il pèse, parce qu'il se décompresse chez lui.
    pub octets_reserves: usize,
    /// Où la page zéro a été écrite. C'est ce que RSI portera.
    pub page_zero: u64,
    pub ligne_de_commande: u64,
    /// Où l'initramfs a été posé, et sa taille. Zéro quand il n'y en a pas.
    pub adresse_de_l_initramfs: u64,
    pub octets_de_l_initramfs: usize,
    /// Le point d'entrée 64 bits : le début du noyau, plus 0x200.
    pub entree: u64,
}

/// Pourquoi un fichier ne se charge pas.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Refus {
    /// Le fichier n'est pas un noyau Linux pour PC.
    PasUnNoyau,
    /// Le noyau n'offre pas de point d'entrée 64 bits.
    PasDEntree64Bits,
    /// Le protocole est trop ancien pour que ce chargeur sache quoi écrire.
    ProtocoleTropAncien(u16),
    /// La mémoire de l'invité ne suffit pas.
    MemoireInsuffisante { besoin: usize, disponible: usize },
    /// Le fichier est plus court que ce que son en-tête annonce.
    Tronque,
}

impl std::fmt::Display for Refus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PasUnNoyau => write!(f, "ce fichier n'est pas un noyau Linux pour PC"),
            Self::PasDEntree64Bits => write!(f, "ce noyau n'a pas de point d'entrée 64 bits"),
            Self::ProtocoleTropAncien(version) => write!(
                f,
                "protocole de démarrage {}.{} trop ancien (2.06 au moins)",
                version >> 8,
                version & 0xFF
            ),
            Self::MemoireInsuffisante { besoin, disponible } => write!(
                f,
                "mémoire insuffisante : {besoin} octets nécessaires, {disponible} disponibles"
            ),
            Self::Tronque => write!(f, "le fichier est plus court que son en-tête ne l'annonce"),
        }
    }
}

/// **L'écran qu'on annonce au noyau, ou rien** : `screen_info`, les
/// soixante-quatre premiers octets de la page zéro. XRGB8888, quatre octets
/// par pixel — voir `X86BootLoader.Framebuffer`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Ecran {
    /// L'adresse physique invitée du premier pixel.
    pub base: u64,
    pub largeur: usize,
    pub hauteur: usize,
}

impl Ecran {
    pub fn octets_par_ligne(&self) -> usize {
        self.largeur * 4
    }

    pub fn octets(&self) -> usize {
        self.octets_par_ligne() * self.hauteur
    }

    /// **Ce que `lfb_size` porte : la VRAM annoncée, en unités de 64 Kio**,
    /// arrondie vers le haut — le champ ne sait pas compter plus fin, et
    /// arrondir vers le bas annoncerait moins que le cadre.
    pub fn memoire_video_annoncee(&self) -> u32 {
        u32::try_from((self.octets() as u64).div_ceil(0x1_0000)).unwrap_or(u32::MAX)
    }
}

/// La page zéro fait exactement quatre kibioctets, et le noyau la lit
/// jusqu'au bout.
pub const TAILLE_DE_LA_PAGE_ZERO: usize = 4096;
/// `VIDEO_TYPE_VLFB` : le seul type pour lequel le noyau décale `lfb_size`.
pub const TYPE_VIDEO_CADRE_LINEAIRE: u8 = 0x23;
/// Où la carte mémoire vit dans la page zéro : le nombre d'entrées, puis la
/// table, vingt octets par entrée.
pub const COMPTE_E820: usize = 0x1E8;
pub const TABLE_E820: usize = 0x2D0;
pub const E820_UTILISABLE: u32 = 1;
pub const E820_RESERVE: u32 = 2;
/// Le trou sous le mégaoctet : la mémoire vidéo et le BIOS y vivaient, et un
/// noyau s'attend à ce qu'il soit là.
pub const DEBUT_DU_PREMIER_TROU: u64 = 0x0009_FC00;
/// Où on met la page zéro et la ligne de commande : sous le mégaoctet, hors du
/// chemin du noyau.
pub const PAGE_ZERO: u64 = 0x1_0000;
pub const LIGNE_DE_COMMANDE: u64 = 0x2_0000;
/// Ce qu'on dit au noyau, par défaut : la console sur le port série, et
/// `earlyprintk` pour qu'un démarrage qui échoue à mi-chemin dise où il en
/// était.
pub const LIGNE_PAR_DEFAUT: &str = "console=ttyS0,115200 earlyprintk=serial,ttyS0,115200,keep";
/// Le protocole 2.06 est le premier où `cmdline_size` existe.
pub const PLUS_ANCIEN_PROTOCOLE: u16 = 0x0206;

fn ecrire16(page: &mut [u8], ou: usize, valeur: u16) {
    page[ou..ou + 2].copy_from_slice(&valeur.to_le_bytes());
}

fn ecrire32(page: &mut [u8], ou: usize, valeur: u32) {
    page[ou..ou + 4].copy_from_slice(&valeur.to_le_bytes());
}

fn ecrire64(page: &mut [u8], ou: usize, valeur: u64) {
    page[ou..ou + 8].copy_from_slice(&valeur.to_le_bytes());
}

/// **Charger le noyau dans la mémoire de l'invité**, et rendre où tout a
/// atterri. `ram` est la RAM de la machine, trou non compris.
pub fn charger(
    noyau: &[u8],
    memoire: &mut GuestMemory,
    ram: u64,
    ligne: &str,
    initramfs: Option<&[u8]>,
    ecran: Option<Ecran>,
) -> Result<Placement, Refus> {
    // L'en-tête se lit sans juger la taille du fichier : un noyau coupé —
    // un téléchargement interrompu — est bien un noyau, et le dire « pas un
    // noyau » enverrait chercher le mauvais fichier. Il est refusé plus bas,
    // par son nom.
    let en_tete = Protocole::lire(noyau, None).ok_or(Refus::PasUnNoyau)?;
    if en_tete.version < PLUS_ANCIEN_PROTOCOLE {
        return Err(Refus::ProtocoleTropAncien(en_tete.version));
    }
    if !en_tete.entree_64_bits() {
        return Err(Refus::PasDEntree64Bits);
    }
    if noyau.len() < en_tete.octets_declares() {
        return Err(Refus::Tronque);
    }

    // Où le noyau va. Un noyau déplaçable accepte n'importe quelle adresse
    // alignée ; les autres exigent la leur. On prend l'adresse préférée dans
    // les deux cas, ce qui est toujours valable.
    let adresse_du_noyau = en_tete.adresse_preferee;
    let reserves = en_tete.taille_reservee as usize;
    let plages = memoire::plages(ram);
    let etendue = memoire.bytes.len();
    let haut = adresse_du_noyau as usize + reserves;
    if haut > etendue {
        return Err(Refus::MemoireInsuffisante {
            besoin: haut,
            disponible: etendue,
        });
    }
    let protege =
        &noyau[en_tete.octets_de_setup..en_tete.octets_de_setup + en_tete.octets_proteges];
    if !memoire::poser(memoire, adresse_du_noyau, protege) {
        return Err(Refus::MemoireInsuffisante {
            besoin: adresse_du_noyau as usize + protege.len(),
            disponible: etendue,
        });
    }

    // La page zéro : quatre kibioctets de zéros, dans lesquels on recopie
    // l'en-tête de setup **à ses propres décalages**. Le noyau relit ses
    // champs là où il les a écrits, pas ailleurs.
    let mut page = vec![0u8; TAILLE_DE_LA_PAGE_ZERO];
    page[SECTEURS_DE_SETUP..OCTETS_D_EN_TETE]
        .copy_from_slice(&noyau[SECTEURS_DE_SETUP..OCTETS_D_EN_TETE]);

    // `type_of_loader` à 0xFF : « un chargeur non enregistré ». Le laisser à
    // zéro ferait croire au noyau qu'il a été lancé par LILO.
    page[0x210] = 0xFF;
    // LOADED_HIGH et CAN_USE_HEAP ; le reste tel que le noyau l'a écrit.
    page[0x211] = (page[0x211] & !0x80) | 0x01 | 0x80;
    ecrire32(&mut page, 0x214, adresse_du_noyau as u32);

    // **L'initramfs, posé en haut de la mémoire**, aligné sur une page, sous le
    // trou quand il y en a un : son adresse s'écrit sur trente-deux bits, et
    // la page zéro est le seul endroit où dire au décompresseur que ces
    // octets-là ne sont pas libres.
    let mut adresse_de_l_initramfs = 0u64;
    let mut octets_de_l_initramfs = 0usize;
    match initramfs {
        Some(archive) if !archive.is_empty() => {
            let sommet = plages[0].end;
            let taille = archive.len() as u64;
            // **Un initramfs plus grand que la mémoire est un refus, pas un
            // accès hors mémoire.**
            let debut = if taille <= sommet {
                (sommet - taille) & !0xFFF
            } else {
                0
            };
            if taille > sommet || debut < adresse_du_noyau + reserves as u64 {
                return Err(Refus::MemoireInsuffisante {
                    besoin: reserves + archive.len(),
                    disponible: etendue,
                });
            }
            memoire::poser(memoire, debut, archive);
            ecrire32(&mut page, 0x218, debut as u32);
            ecrire32(&mut page, 0x21C, archive.len() as u32);
            adresse_de_l_initramfs = debut;
            octets_de_l_initramfs = archive.len();
        }
        _ => {
            ecrire32(&mut page, 0x218, 0);
            ecrire32(&mut page, 0x21C, 0);
        }
    }
    ecrire32(&mut page, 0x228, LIGNE_DE_COMMANDE as u32);

    // **L'écran, s'il y en a un.** Les décalages viennent de `struct
    // screen_info` et ne se déduisent d'aucune règle.
    if let Some(ecran) = ecran {
        page[0x0F] = TYPE_VIDEO_CADRE_LINEAIRE;
        ecrire16(&mut page, 0x12, ecran.largeur as u16);
        ecrire16(&mut page, 0x14, ecran.hauteur as u16);
        ecrire16(&mut page, 0x16, 32);
        ecrire32(&mut page, 0x18, ecran.base as u32);
        ecrire32(&mut page, 0x1C, ecran.memoire_video_annoncee());
        ecrire16(&mut page, 0x24, ecran.octets_par_ligne() as u16);
        // XRGB8888 : bleu en bas, puis vert, puis rouge, l'octet inutilisé en
        // haut.
        page[0x26] = 8;
        page[0x27] = 16;
        page[0x28] = 8;
        page[0x29] = 8;
        page[0x2A] = 8;
        page[0x2B] = 0;
        page[0x2C] = 8;
        page[0x2D] = 24;
    }

    // **La carte mémoire. Sans elle, le noyau croit qu'il n'a aucune RAM** et
    // s'arrête. Ce qui est sous le trou du premier mégaoctet, tout le reste
    // sous le trou des périphériques, puis la RAM qui reprend au-dessus de
    // quatre gibioctets.
    let mut entrees: Vec<(u64, u64, u32)> = vec![(0, DEBUT_DU_PREMIER_TROU, E820_UTILISABLE)];
    let sommet = plages[0].end;
    if sommet > 0x10_0000 {
        entrees.push((0x10_0000, sommet - 0x10_0000, E820_UTILISABLE));
    }
    for au_dessus in plages.iter().skip(1) {
        entrees.push((
            au_dessus.start,
            au_dessus.end - au_dessus.start,
            E820_UTILISABLE,
        ));
    }
    // **Un écran non réservé est de la mémoire que le noyau donnera à
    // quelqu'un d'autre.**
    if let Some(ecran) = ecran {
        entrees.push((ecran.base, ecran.octets() as u64, E820_RESERVE));
    }
    page[COMPTE_E820] = entrees.len() as u8;
    for (rang, (debut, longueur, genre)) in entrees.iter().enumerate() {
        let ou = TABLE_E820 + rang * 20;
        ecrire64(&mut page, ou, *debut);
        ecrire64(&mut page, ou + 8, *longueur);
        ecrire32(&mut page, ou + 16, *genre);
    }
    memoire::poser(memoire, PAGE_ZERO, &page);

    // La ligne de commande, terminée par un zéro, et pas plus longue que ce
    // que le noyau accepte : au-delà, il la tronquerait sans le dire.
    let mut texte = ligne.as_bytes().to_vec();
    texte.truncate(en_tete.limite_de_ligne as usize);
    texte.push(0);
    memoire::poser(memoire, LIGNE_DE_COMMANDE, &texte);

    Ok(Placement {
        adresse_du_noyau,
        octets_reserves: reserves,
        page_zero: PAGE_ZERO,
        ligne_de_commande: LIGNE_DE_COMMANDE,
        adresse_de_l_initramfs,
        octets_de_l_initramfs,
        // L'entrée 64 bits est à 0x200 du début du noyau en mode protégé.
        entree: adresse_du_noyau + 0x200,
    })
}

/// **Les délais de systemd, allongés à dix minutes** : ceux que
/// `IsoBoot.patience` ajoute à la ligne d'une image. Un système qui n'a pas
/// systemd les ignore ; une image qui fixe déjà les siens les garde.
pub const PATIENCE: [&str; 2] = [
    "systemd.default_device_timeout_sec=600",
    "systemd.default_timeout_start_sec=600",
];

/// **La ligne de commande d'une image démarrée par sa recette** — celle de
/// l'application, pour que les deux machines démarrent la même chose :
/// `IsoBoot.commandLine(from:)`. Les mots de la recette, sans les vides
/// (`omittingEmptySubsequences`, pour qu'une recette à espaces doublés donne
/// la même ligne) et sans `quiet` ; la patience de systemd ; puis
/// [`LIGNE_PAR_DEFAUT`] en dernier, parce que Linux retient le dernier
/// `console=`. `console=tty0` vient après, de [`ligne_sous_ecran`], comme
/// devant toute autre ligne.
pub fn ligne_d_une_image(recette: &str) -> String {
    let mots: Vec<&str> = recette
        .split(' ')
        .filter(|mot| !mot.is_empty() && *mot != "quiet")
        .collect();
    let mut ligne: Vec<&str> = mots.clone();
    for reglage in PATIENCE {
        let cle = reglage.split('=').next().unwrap_or(reglage);
        if !mots.iter().any(|mot| {
            mot.strip_prefix(cle)
                .is_some_and(|reste| reste.starts_with('='))
        }) {
            ligne.push(reglage);
        }
    }
    ligne.push(LIGNE_PAR_DEFAUT);
    ligne.join(" ")
}

/// **`console=tty0` devant la ligne quand un écran est branché**, pour que la
/// console du noyau y paraisse aussi : `X86Machine.commandLine(_:withScreen:)`,
/// que `X86Machine.load` applique à **toute** ligne, celle par défaut comprise
/// — et que [`Machine::charger`](super::Machine::charger) applique de même.
/// Une ligne qui a déjà `console=tty0` passe telle quelle.
pub fn ligne_sous_ecran(ligne: &str, ecran: bool) -> String {
    if ecran && !ligne.split(' ').any(|mot| mot == "console=tty0") {
        format!("console=tty0 {ligne}")
    } else {
        ligne.to_string()
    }
}

/// **La ligne que le noyau lira** : celle que [`charger`] a posée dans la
/// mémoire de l'invité, à `placement.ligne_de_commande`, jusqu'à son zéro.
/// C'est ce que `wisq-pc` affiche : la lire là, plutôt que la recalculer à
/// côté, ne laisse pas l'affichage dire autre chose que ce que la machine a
/// posé. `None` quand elle n'y est pas — hors de la RAM, sans zéro, ou pas
/// en UTF-8.
pub fn ligne_posee(ram: &[u8], placement: &Placement) -> Option<String> {
    let octets = ram.get(usize::try_from(placement.ligne_de_commande).ok()?..)?;
    let fin = octets.iter().position(|octet| *octet == 0)?;
    String::from_utf8(octets[..fin].to_vec()).ok()
}

/// **Des initramfs mis bout à bout**, comme un chargeur les pose en
/// mémoire : chacun commence sur un multiple de quatre octets, des zéros
/// devant pour l'aligner (`IsoBoot.extractInitrds`). Le noyau lit la suite
/// comme une seule archive.
pub fn initramfs_bout_a_bout(parties: &[Vec<u8>]) -> Vec<u8> {
    let mut tout = Vec::with_capacity(parties.iter().map(|partie| partie.len() + 3).sum());
    for partie in parties {
        tout.resize(tout.len().div_ceil(4) * 4, 0);
        tout.extend_from_slice(partie);
    }
    tout
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **La ligne posée, lue jusqu'à son zéro** : `ligne_posee` rend ce que
    /// `charger` a écrit dans la RAM de l'invité, et rien quand l'adresse sort
    /// de la RAM, quand aucun zéro ne la termine ou quand ce n'est pas de
    /// l'UTF-8.
    #[test]
    fn the_posed_line_is_read_up_to_its_zero() {
        let placement = |ou: u64| Placement {
            adresse_du_noyau: 0,
            octets_reserves: 0,
            page_zero: 0,
            ligne_de_commande: ou,
            adresse_de_l_initramfs: 0,
            octets_de_l_initramfs: 0,
            entree: 0,
        };
        let mut ram = vec![0xAAu8; 64];
        ram[8..30].copy_from_slice(b"console=tty0 ttyS0\0xyz");
        assert_eq!(
            ligne_posee(&ram, &placement(8)).as_deref(),
            Some("console=tty0 ttyS0")
        );
        assert_eq!(ligne_posee(&ram, &placement(26)).as_deref(), Some(""));
        // Hors de la RAM, ou sans zéro jusqu'au bout : rien.
        assert_eq!(ligne_posee(&ram, &placement(64)), None);
        assert_eq!(ligne_posee(&ram, &placement(1 << 40)), None);
        assert_eq!(ligne_posee(&ram, &placement(30)), None);
        // Pas de l'UTF-8 : rien.
        ram[40] = 0xFF;
        ram[41] = 0;
        assert_eq!(ligne_posee(&ram, &placement(40)), None);
    }

    /// **La ligne de Void Xfce, comme l'application la fait** : `quiet`
    /// parti, la patience ajoutée, la console série en dernier — et une image
    /// qui fixe déjà un délai le garde.
    #[test]
    fn the_line_of_an_image_is_the_apps() {
        let recette = "root=live:CDLABEL=VOID_LIVE init=/sbin/init ro quiet rd.luks=0";
        let attendue = "root=live:CDLABEL=VOID_LIVE init=/sbin/init ro rd.luks=0 \
             systemd.default_device_timeout_sec=600 systemd.default_timeout_start_sec=600 \
             console=ttyS0,115200 earlyprintk=serial,ttyS0,115200,keep";
        assert_eq!(ligne_d_une_image(recette), attendue);
        // Des espaces doublés, en tête et en queue : les mots vides partent,
        // comme sous `omittingEmptySubsequences`, et la ligne est la même.
        let espacee = "  root=live:CDLABEL=VOID_LIVE  init=/sbin/init ro   quiet rd.luks=0 ";
        assert_eq!(ligne_d_une_image(espacee), attendue);
        let deja = "ro systemd.default_timeout_start_sec=90 console=tty0";
        assert_eq!(
            ligne_d_une_image(deja),
            "ro systemd.default_timeout_start_sec=90 console=tty0 \
             systemd.default_device_timeout_sec=600 \
             console=ttyS0,115200 earlyprintk=serial,ttyS0,115200,keep"
        );
        // Un mot qui commence comme la clé sans en être une ne compte pas.
        assert!(ligne_d_une_image("systemd.default_timeout_start_secx=1")
            .contains("systemd.default_timeout_start_sec=600"));
    }

    /// **`console=tty0` devant, sous un écran seulement**, et une fois : une
    /// ligne qui l'a déjà, même ailleurs que devant, passe telle quelle ; un
    /// mot qui ne fait que le contenir ne compte pas.
    #[test]
    fn a_screen_puts_tty0_in_front_of_any_line() {
        assert_eq!(ligne_sous_ecran("console=ttyS0", false), "console=ttyS0");
        assert_eq!(
            ligne_sous_ecran("console=ttyS0", true),
            "console=tty0 console=ttyS0"
        );
        assert_eq!(
            ligne_sous_ecran("ro console=tty0 console=ttyS0", true),
            "ro console=tty0 console=ttyS0"
        );
        assert_eq!(
            ligne_sous_ecran("xconsole=tty0", true),
            "console=tty0 xconsole=tty0"
        );
    }

    /// **Chaque initramfs commence sur quatre octets** : 5 octets, puis 3,
    /// puis 1, rangés à 0, 8 et 12 ; un seul passe tel quel.
    #[test]
    fn initramfs_are_laid_end_to_end_on_four_bytes() {
        let tout = initramfs_bout_a_bout(&[vec![1; 5], vec![2; 3], vec![3]]);
        assert_eq!(tout, [1, 1, 1, 1, 1, 0, 0, 0, 2, 2, 2, 0, 3]);
        assert_eq!(initramfs_bout_a_bout(&[vec![7; 6]]), vec![7; 6]);
    }
}
