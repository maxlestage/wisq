//! **La page que le bureau local charge dans sa vue.**
//!
//! `web/host.js` est la boucle hôte : elle tient la RAM de l'invité, les
//! globales, la table des blocs et la correspondance, demande une traduction
//! quand elle tombe sur une adresse inconnue, et enchaîne. Ce module l'habille
//! de ce qu'il faut pour vivre dans un `WKWebView` : une page, un pont vers
//! l'application, et l'état de départ de la machine.
//!
//! **Pourquoi l'assemblage est en Rust plutôt qu'en Swift.** Ce sont des
//! chaînes de caractères, donc ça se teste — et ça ne se teste que là où il y a
//! un moteur JavaScript. Écrit en Swift, ce code ne serait exécuté par rien
//! avant un envoi TestFlight ; écrit ici, la page se construit, son script
//! s'exécute sous Bun avec un pont bouchonné, et on sait qu'elle tient avant
//! de la donner à un téléphone. Le côté Swift n'a plus qu'à l'appeler.

/// **La boucle hôte, telle qu'elle est écrite dans `web/host.js`.**
///
/// Elle est *incluse à la compilation*, pas recopiée : deux copies finiraient
/// par diverger, et celle qui ment serait celle que personne ne lit.
pub const HOST_SCRIPT: &str = include_str!("../../../web/host.js");

/// **Le cadre que le chargeur a déclaré au noyau**, tel que la vue doit le
/// peindre.
///
/// Les trois nombres viennent du `screen_info` que l'application remplit avant
/// de démarrer la machine : c'est elle qui décide où vit le tampon
/// d'affichage, donc c'est elle qui le dit à la page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Screen {
    /// L'adresse **invitée** du tampon d'affichage. Elle est repliée dans la
    /// RAM comme toutes les autres.
    pub base: u64,
    pub width: u32,
    pub height: u32,
}

/// Ce que le bureau refuse de construire, et pourquoi.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// La RAM d'un invité confiné se replie par un masque, qui ne décrit un
    /// intervalle que sur une puissance de deux.
    RamIsNotAPowerOfTwo(u32),
    /// Le nom du canal est **recollé dans du JavaScript**. Tout ce qui n'est
    /// pas une lettre ou un chiffre pourrait en sortir et devenir du code —
    /// c'est la même faute que l'identifiant de VM recollé dans une ligne de
    /// commande, que ce dépôt a déjà payée une fois.
    ChannelIsNotAName(String),
    /// **Le cadre déborderait de la RAM de l'invité.** Au-dessus vit la
    /// correspondance adresse → indice : un cadre à cheval sur ce bord
    /// afficherait la table des blocs à l'écran, et l'invité la détruirait en
    /// peignant. C'est la même frontière que la lecture de la fenêtre et
    /// l'écriture de l'image gardent déjà, refusée ici **avant** que la page
    /// n'existe.
    ScreenDoesNotFit { folded: u64, bytes: u64, ram: u64 },
    /// Un cadre sans surface n'est pas un cadre.
    ScreenHasNoSurface { width: u32, height: u32 },
    /// **La ligne de commande ne tiendrait pas dans la page zéro.** Elle vit
    /// dedans, à `0x800` de son début, donc elle a la fin de cette page et rien
    /// de plus. Tronquer donnerait au noyau une ligne coupée au milieu d'un
    /// paramètre — qu'il accepterait sans rien dire.
    CommandLineDoesNotFit { bytes: usize, room: usize },
    /// **L'image de l'appelant déborderait de la RAM invitée.** Au-dessus vit
    /// la correspondance adresse → indice : l'écriture n'irait pas « un peu
    /// trop loin », elle irait dans la table que le module lit pour trouver ses
    /// régions. C'est la borne que `LocalDesktop.place` tenait déjà en Swift ;
    /// elle est ici pour que les trois refus soient rendus au même endroit,
    /// par le même pliage.
    ImageDoesNotFit { folded: u64, bytes: u64, ram: u64 },
    /// **L'image écraserait la page zéro.** Le noyau y lit sa carte e820, sa
    /// ligne de commande et son initramfs — avant d'exécuter une seule de ses
    /// propres instructions. Une image posée dessus le renverrait exactement à
    /// l'échec muet de `extend_brk` que #310 a corrigé, mais cette fois **par
    /// la faute de l'appelant** et sans rien qui le nomme.
    ImageWouldOverwriteTheBootPage { at: u64, bytes: u64 },
    /// **L'image serait repeinte par l'invité.** Le cadre est de la mémoire que
    /// la vue lit à chaque image et que le noyau croit à lui : des octets posés
    /// là survivraient jusqu'au premier `simpledrm`, puis disparaîtraient sous
    /// les pixels. Une panne de ce genre ne ressemble pas à une écriture
    /// perdue, elle ressemble à un noyau qui se corrompt tout seul.
    ImageWouldOverwriteTheFrame {
        at: u64,
        bytes: u64,
        frame: u64,
        frame_bytes: u64,
    },
    /// **Une archive de zéro octet.** Le noyau lirait une racine qui n'existe
    /// pas : `ramdisk_size` à zéro et `ramdisk_image` renseigné décrivent une
    /// archive vide, qu'il tente quand même de déballer.
    InitramfsHasNoBytes,
    /// **L'archive n'est pas là où le noyau pourrait la lire.** Trois bornes la
    /// tiennent, et aucune des trois ne se voit à l'exécution si elle est
    /// franchie : le sommet de la page zéro au-dessous, la base du cadre (ou le
    /// bout de la RAM) au-dessus, et la largeur de `ramdisk_image` — un `u32`,
    /// dont le demi-haut vit dans `ext_ramdisk_image` que cette page n'écrit
    /// pas. Tronquer donnerait au noyau une autre archive, à une autre adresse.
    InitramfsDoesNotFit {
        at: u64,
        bytes: u64,
        floor: u64,
        ceiling: u64,
    },
    /// **L'image écraserait l'archive.** C'est la mémoire que le noyau déballe
    /// pour s'en faire une racine : des octets posés dessus la lui donnent
    /// corrompue, et le symptôme est un cpio « invalid magic » qui ne nomme pas
    /// sa cause. Troisième région que la machine se donne à elle-même, après la
    /// page zéro et le cadre.
    ImageWouldOverwriteTheArchive {
        at: u64,
        bytes: u64,
        archive: u64,
        archive_bytes: u64,
    },
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::CommandLineDoesNotFit { bytes, room } => write!(
                out,
                "la ligne de commande fait {bytes} octets et la page zéro ne lui en \
                 laisse que {room}"
            ),
            Self::ImageDoesNotFit { folded, bytes, ram } => write!(
                out,
                "une image de {bytes} octets posée à {folded} déborde d'une RAM de {ram}"
            ),
            Self::ImageWouldOverwriteTheBootPage { at, bytes } => write!(
                out,
                "une image de {bytes} octets posée à {at} écraserait la page zéro, où le \
                 noyau lit sa carte mémoire"
            ),
            Self::ImageWouldOverwriteTheFrame {
                at,
                bytes,
                frame,
                frame_bytes,
            } => write!(
                out,
                "une image de {bytes} octets posée à {at} tombe dans le cadre, qui occupe \
                 {frame_bytes} octets à {frame}"
            ),
            Self::InitramfsHasNoBytes => {
                write!(out, "une archive de zéro octet n'est pas une racine")
            }
            Self::InitramfsDoesNotFit {
                at,
                bytes,
                floor,
                ceiling,
            } => write!(
                out,
                "une archive de {bytes} octets à {at} sort de ce qui lui est laissé, de \
                 {floor} à {ceiling}"
            ),
            Self::ImageWouldOverwriteTheArchive {
                at,
                bytes,
                archive,
                archive_bytes,
            } => write!(
                out,
                "une image de {bytes} octets posée à {at} tombe dans l'archive, qui occupe \
                 {archive_bytes} octets à {archive}"
            ),
            Self::RamIsNotAPowerOfTwo(pages) => write!(
                out,
                "la RAM d'un invité confiné doit être une puissance de deux de pages, pas {pages}"
            ),
            Self::ChannelIsNotAName(name) => write!(
                out,
                "le nom du canal ne peut porter que des lettres et des chiffres : « {name} »"
            ),
            Self::ScreenDoesNotFit { folded, bytes, ram } => write!(
                out,
                "le cadre occupe {bytes} octets à {folded} et déborde d'une RAM de {ram}"
            ),
            Self::ScreenHasNoSurface { width, height } => {
                write!(out, "un cadre de {width}×{height} n'a pas de surface")
            }
        }
    }
}

impl std::error::Error for Refusal {}

/// **La ligne de commande que le bureau donne au noyau.**
///
/// `earlycon` branche la console 8250 précoce sur `0x3f8` dès `setup_arch`,
/// bien avant `console_init` ; `console=ttyS0` fait de ce port **la** console,
/// donc celle que `/dev/console` ouvre pour `/init`.
///
/// **Les deux sont mesurés, pas choisis par analogie.** #306 a montré que sans
/// `console=ttyS0` le `write` de l'espace utilisateur rend bien 18 — le nombre
/// d'octets demandés — et que **le message ne sort pas** : `/dev/console` est
/// alors `tty0`, l'écran de texte factice, qui accepte les octets et les jette.
/// Et `keep_bootcon` n'y est **pas**, aussi par mesure : avec les deux, chaque
/// ligne de `printk` sort deux fois (367 contre 222), parce que les deux
/// consoles écrivent sur le même port. Sans lui, la bascule
/// `bootconsole [uart8250] disabled` est sans perte depuis que #305 a rendu au
/// port ses huit registres : 242 lignes contre 240.
pub const COMMAND_LINE: &str = "earlycon=uart8250,io,0x3f8 console=ttyS0";

/// **La page zéro que le bureau tend au noyau, ligne de commande comprise.**
///
/// Un noyau Linux entré sans `boot_params` n'a pas de carte e820 : il retombe
/// sur les 640 kibioctets du repli BIOS-88, memblock n'a rien, et il s'arrête
/// dans `extend_brk` à sa 1067ᵉ région — **muet**, puisque sans ligne de
/// commande il n'a pas de console précoce non plus. C'est l'échec que le
/// montage de mesure a eu d'abord, et qui n'avait été corrigé **que** dans le
/// montage : `desktop::page` ne posait que RIP.
///
/// **La page n'est pas réécrite ici.** C'est `kernel_image::zero_page`, celle
/// que le montage emploie et que ses propres tests tiennent. En écrire une
/// troisième — après le Rust et `X86BootLoader` — serait #289 par
/// construction.
///
/// Ce que cette fonction ajoute est l'assemblage : la ligne vit **dans** la
/// page, à `COMMAND_LINE_AT − ZERO_PAGE_AT` de son début, soit `0x800`, parce
/// que c'est là que le montage la pose et que le champ `0x228` l'y désigne. Le
/// bureau a donc **un seul bloc de quatre kibioctets** à poser, à une seule
/// adresse — et `LocalDesktop.place` sait déjà le faire.
/// **La même, avec l'écran que le bureau déclare.**
///
/// #310 a donné au bureau sa page zéro et l'a bâtie avec `zero_page` — celle
/// d'une machine **sans cadre**. Or `page` accepte un `Screen` depuis le lot 8,
/// et `zero_page_with_screen` fait deux choses de plus :
///
/// - elle écrit `screen_info`, sans quoi le noyau ne sait pas qu'il y a un
///   écran et `simpledrm` ne se lie à rien ;
/// - elle **réserve le cadre dans la carte e820**, en type 2. Son commentaire
///   dit pourquoi : « l'allocateur ne consulte que cette carte ; sans l'entrée,
///   deux écritures se disputeraient les mêmes pages, et le bureau se
///   corromprait sous des causes sans rapport ».
///
/// Un bureau à écran qui amorçait un noyau lui tendait donc une carte où le
/// cadre est de la mémoire **libre**.
///
/// **Le plancher est le sommet de la page zéro**, et c'est le minimum
/// certainement juste : au-dessous vivent la page et sa ligne de commande, et
/// un cadre posé là les écraserait avec les pixels du bureau — en emportant la
/// carte mémoire que le noyau vient d'y lire. Ce plancher ne protège **pas**
/// l'image du noyau : elle est posée par l'application *après* que cette page
/// est bâtie, donc son étendue n'est pas connue ici.
///
/// Le chevauchement est donc refusé **de l'autre côté**, au moment où les
/// octets entrent : `placement` le nomme, et `LocalDesktop.place` le rend à
/// l'application. C'est le même recouvrement vu dans l'autre sens, et c'est le
/// seul endroit où les deux étendues sont connues en même temps.
pub fn boot_page_with_screen(
    pages: u32,
    command_line: &str,
    screen: Option<Screen>,
) -> Result<Vec<u8>, Refusal> {
    let Some(screen) = screen else {
        return boot_page(pages, command_line);
    };
    let page = boot_page(pages, command_line)?;
    let ram = u64::from(pages) * 65536;
    // **L'adresse du cadre est repliée avant d'être dite au noyau**, et ce
    // n'est pas une précaution : `web/host.js` la replie aux deux endroits qui
    // la lisent — `BigInt(screen.base) & BigInt(base - 1)` — donc c'est
    // l'adresse repliée qui désigne les octets que la vue peint réellement. Un
    // noyau à qui on donnerait l'adresse brute croirait son écran ailleurs, et
    // `simpledrm` écrirait dans une mémoire que personne n'affiche.
    //
    // **Et sans ce repli, le bureau ne pouvait pas bâtir sa page du tout** :
    // `lfb_base` est un `u32`, donc une adresse de noyau — celle de tous les
    // bureaux de `LocalDesktopTests` — était refusée. Rien ne l'avait vu parce
    // que le dépôt de cette page était inatteignable ; le premier appel réel
    // l'a trouvé.
    let screen = Screen {
        base: screen.base & (ram - 1),
        width: screen.width,
        height: screen.height,
    };
    // Le plancher : le premier octet que le cadre a le droit d'occuper.
    let floor = crate::kernel_image::ZERO_PAGE_AT + page.len() as u64;
    let inside =
        (crate::kernel_image::COMMAND_LINE_AT - crate::kernel_image::ZERO_PAGE_AT) as usize;
    match crate::kernel_image::zero_page_with_screen(
        ram,
        crate::kernel_image::COMMAND_LINE_AT as u32,
        screen,
        floor,
    ) {
        // **La ligne est remise dedans**, parce que `zero_page_with_screen`
        // part de `zero_page` et ne la connaît pas. Une seule écriture, au même
        // décalage que l'autre chemin : deux endroits qui la posent
        // divergeraient.
        Ok(mut built) => {
            built[inside..inside + command_line.len()].copy_from_slice(command_line.as_bytes());
            built[inside + command_line.len()] = 0;
            Ok(built)
        }
        Err(why) => Err(match why {
            crate::kernel_image::ScreenRefusal::Empty => Refusal::ScreenHasNoSurface {
                width: screen.width,
                height: screen.height,
            },
            // Tous les autres disent la même chose au bureau : le cadre ne
            // tient pas là où on le veut. Les nombres du refus de `kernel_image`
            // sont plus fins que ceux que `Refusal` sait porter ; ce qui compte
            // pour l'appelant est qu'il soit refusé, et son `Display` le dit.
            other => {
                let bytes = u64::from(screen.width).saturating_mul(u64::from(screen.height)) * 4;
                let _ = other;
                // `screen.base` est déjà replié ici, donc le nom du champ dit
                // vrai : c'est l'adresse qui a été jugée.
                Refusal::ScreenDoesNotFit {
                    folded: screen.base,
                    bytes,
                    ram,
                }
            }
        }),
    }
}

pub fn boot_page(pages: u32, command_line: &str) -> Result<Vec<u8>, Refusal> {
    if pages == 0 || !pages.is_power_of_two() {
        return Err(Refusal::RamIsNotAPowerOfTwo(pages));
    }
    let inside =
        (crate::kernel_image::COMMAND_LINE_AT - crate::kernel_image::ZERO_PAGE_AT) as usize;
    // La fin de la page, moins l'octet nul qui termine la ligne.
    let room = 4096 - inside - 1;
    if command_line.len() > room {
        return Err(Refusal::CommandLineDoesNotFit {
            bytes: command_line.len(),
            room,
        });
    }
    let mut page = crate::kernel_image::zero_page(
        u64::from(pages) * 65536,
        crate::kernel_image::COMMAND_LINE_AT as u32,
    );
    page[inside..inside + command_line.len()].copy_from_slice(command_line.as_bytes());
    page[inside + command_line.len()] = 0;
    Ok(page)
}

/// **Dire au noyau du bureau où est sa racine.**
///
/// `kernel_image::declare_ramdisk` existe depuis #304 et le montage de mesure
/// l'appelle quand `WISQ_INITRAMFS` en demande une. #306 a mesuré ce qu'elle
/// donne : `WISQ-USERSPACE-OK` sur le fil, entre `Run /init as init process` et
/// la panique. **Le bureau ne l'appelait pas.** Sans les deux champs —
/// `ramdisk_image` à `0x218`, `ramdisk_size` à `0x21c` — le noyau traverse tous
/// ses `initcall`, arrive dans `prepare_namespace`, et meurt sur « VFS: Unable
/// to mount root fs on unknown-block(0,0) ». C'est l'échec que #304 a corrigé
/// **dans le montage seulement**.
///
/// **La page n'est pas rebâtie, deux champs sont écrits.** C'est la leçon de
/// #311 : un chemin qui repart de `zero_page` perd ce que l'autre y avait mis.
/// Et c'est aussi ce que `declare_ramdisk` dit de lui-même — l'écran et
/// l'archive sont deux champs sans rapport, et une fonction qui poserait les
/// deux ensemble se dédoublerait au premier cas qui n'en veut qu'un.
///
/// **Les deux bornes viennent d'ici et pas de l'appelant.** Le montage passe le
/// sommet de ce qu'il a chargé ; le bureau ne le connaît pas — l'application
/// pose l'image du noyau *après* que cette page est bâtie. Le plancher est donc
/// le **sommet de la page zéro**, le minimum certainement juste : au-dessous
/// vivent la page et sa ligne de commande, et une archive posée là les
/// écraserait avec le cpio. Le plafond est la **base du cadre** quand il y en a
/// un, le bout de la RAM sinon : une archive peut tenir dans la mémoire et
/// déborder sur l'écran, exactement le piège que #251 a payé pour le cadre.
///
/// Qu'une archive chevauche l'**image du noyau** est refusé de l'autre côté,
/// par `placement`, au moment où les octets entrent — comme pour le cadre
/// depuis #312.
pub fn declare_initramfs(
    page: &mut [u8],
    pages: u32,
    screen: Option<Screen>,
    initramfs: crate::kernel_image::Ramdisk,
) -> Result<(), Refusal> {
    if pages == 0 || !pages.is_power_of_two() {
        return Err(Refusal::RamIsNotAPowerOfTwo(pages));
    }
    let ram = u64::from(pages) * 65536;
    // Le premier octet que l'archive a le droit d'occuper : le sommet de la
    // page, lu sur la page qu'on nous donne plutôt que posé en constante.
    let floor = crate::kernel_image::ZERO_PAGE_AT + page.len() as u64;
    let ceiling = match screen {
        None => ram,
        Some(screen) => screen.base & (ram - 1),
    };
    // **Repliée, comme toutes les adresses invitées de ce module.** Et c'est
    // l'adresse *repliée* qui est écrite dans la page : le noyau lira la même
    // que celle où l'application a posé les octets.
    let folded = crate::kernel_image::Ramdisk {
        at: initramfs.at & (ram - 1),
        bytes: initramfs.bytes,
    };
    match crate::kernel_image::declare_ramdisk(page, folded, floor, ceiling) {
        Ok(()) => Ok(()),
        Err(crate::kernel_image::RamdiskRefusal::Empty) => Err(Refusal::InitramfsHasNoBytes),
        // Les trois autres disent la même chose au bureau : l'archive n'est pas
        // là où le noyau pourrait la lire. Les nombres des deux bornes sont
        // plus utiles à l'appelant que la distinction entre elles, et le
        // `Display` les dit.
        Err(_) => Err(Refusal::InitramfsDoesNotFit {
            at: folded.at,
            bytes: folded.bytes,
            floor,
            ceiling,
        }),
    }
}

/// **Ce que l'appelant n'a pas le droit d'écrire, et pourquoi.**
///
/// `LocalDesktop.place` est le seul chemin par lequel des octets entrent dans
/// la mémoire de l'invité depuis l'application. Il tenait **une** borne — la
/// fin de la RAM, au-dessus de laquelle vit la correspondance — et laissait
/// passer deux écritures qui détruisent la machine aussi sûrement :
///
/// - **la page zéro**, que le noyau lit avant sa première instruction ;
/// - **le cadre**, que la vue repeint à chaque image.
///
/// #311 l'a dit en finissant : « un cadre qui chevaucherait l'image du noyau
/// reste une faute de l'appelant que rien ne refuse encore ». Le refus est ici
/// et pas de l'autre côté du pont parce que c'est ici que vit le risque — le
/// pliage par masque et deux additions qui peuvent déborder. En Swift, un
/// `Int` **piégerait** là où on veut un refus nommé, et `LocalDesktop.swift`
/// n'est de surcroît typé que sur `Cœur (Apple)` : une faute d'arithmétique y
/// resterait invisible sur cette machine.
///
/// **`boots` décide si la page zéro existe.** Un programme jugé sur ses
/// registres n'en a pas ; lui interdire `0x9000` serait un refus sans objet, et
/// un refus sans objet apprend aux appelants à contourner les refus.
///
/// **Les deux intervalles sont comparés demi-ouverts**, `a < b + lb &&
/// b < a + la`, ce qui est juste à l'octet des deux côtés : un voisin immédiat
/// passe, un chevauchement d'un seul octet tombe.
pub fn placement(
    pages: u32,
    screen: Option<Screen>,
    initramfs: Option<crate::kernel_image::Ramdisk>,
    boots: bool,
    at: u64,
    bytes: u64,
) -> Result<(), Refusal> {
    if pages == 0 || !pages.is_power_of_two() {
        return Err(Refusal::RamIsNotAPowerOfTwo(pages));
    }
    let ram = u64::from(pages) * 65536;
    // **L'adresse se replie, parce que la RAM d'un invité confiné est adressée
    // par un masque.** `0x1_0000_9000` et `0x9000` désignent le même octet sur
    // une machine de 64 Mio ; comparer les adresses brutes laisserait passer la
    // même écriture sous un autre nom.
    let folded = at & (ram - 1);
    // **Écrit en soustrayant**, comme le fait déjà `place` : `folded + bytes`
    // enroulerait pour une taille proche du maximum, l'intervalle paraîtrait
    // fini avant la page zéro, et l'image passerait. `folded` est toujours plus
    // petit que `ram`, donc la soustraction est sûre.
    if bytes > ram - folded {
        return Err(Refusal::ImageDoesNotFit { folded, bytes, ram });
    }
    // Une image vide ne couvre aucun octet : elle n'écrase rien.
    if bytes == 0 {
        return Ok(());
    }
    if boots {
        let zero = crate::kernel_image::ZERO_PAGE_AT;
        if folded < zero + 4096 && zero < folded + bytes {
            return Err(Refusal::ImageWouldOverwriteTheBootPage { at: folded, bytes });
        }
    }
    if let Some(screen) = screen {
        let frame = screen.base & (ram - 1);
        // La même saturation que `page` emploie, et pour la même raison : deux
        // dimensions de deux puissance trente et un donnent exactement deux
        // puissance soixante-quatre, qui enroule à **zéro** en release — et un
        // cadre de taille nulle ne protégerait plus rien.
        let frame_bytes = u64::from(screen.width)
            .saturating_mul(u64::from(screen.height))
            .saturating_mul(4);
        // Un cadre sans surface n'a rien à protéger. `page` l'a déjà refusé
        // avant que la vue n'existe ; ici, le taire vaut mieux que refuser une
        // écriture au nom d'un cadre qui n'en est pas un.
        if frame_bytes > 0 && folded < frame.saturating_add(frame_bytes) && frame < folded + bytes {
            return Err(Refusal::ImageWouldOverwriteTheFrame {
                at: folded,
                bytes,
                frame,
                frame_bytes,
            });
        }
    }
    if let Some(archive) = initramfs {
        let at = archive.at & (ram - 1);
        // Une archive de zéro octet n'occupe rien — `declare_initramfs` l'a
        // déjà refusée, et refuser ici au nom d'une archive qui n'en est pas
        // une serait un refus sans objet.
        if archive.bytes > 0 && folded < at.saturating_add(archive.bytes) && at < folded + bytes {
            return Err(Refusal::ImageWouldOverwriteTheArchive {
                at: folded,
                bytes,
                archive: at,
                archive_bytes: archive.bytes,
            });
        }
    }
    Ok(())
}

/// **La page complète, prête à être chargée dans un `WKWebView`.**
///
/// - `pages` : la RAM de l'invité, en pages de 64 Kio, **puissance de deux**.
/// - `entry` : l'adresse où la machine commence.
/// - `channel` : le nom du gestionnaire de messages que l'application déclare.
/// - `boot` : où l'application a posé la page zéro, ou `None` quand il n'y en
///   a pas. Le pilote met alors RSI dessus — c'est par là qu'un noyau
///   x86-64 lit sa carte e820, sa ligne de commande et son initramfs, et sans
///   elle il s'arrête muet dans `extend_brk`. `boot_page` la fabrique.
///
/// **Le pont est asynchrone, et c'est imposé, pas choisi.** Une vue ne peut pas
/// appeler l'application et attendre : elle poste un message et reçoit la
/// réponse plus tard, par un appel de l'application vers la vue. La boucle
/// hôte est écrite pour ça depuis le début — `translate` rend une promesse.
///
/// **Ce que l'application doit fournir**, et rien d'autre :
/// - un gestionnaire de messages nommé `channel`, qui reçoit
///   `{ id, address, slot, octets }` pour une traduction et `{ stopped, at }`
///   quand la machine s'arrête ;
/// - un appel à `wisqTranslated(id, octets)` pour répondre, `octets` étant un
///   tableau de nombres ou `null` si l'émetteur refuse franchement ;
/// - un appel à `wisqNeedsMore(id)` quand l'émetteur a manqué d'octets — la vue
///   redemande alors **une** fois avec une fenêtre plus large ;
/// - un appel à `wisqRun()` pour lancer la machine.
///
/// **La demande porte les octets, et c'est le point qui a manqué le plus
/// longtemps.** La RAM de l'invité vit dans la vue ; l'application ne l'a pas.
/// Une demande qui ne porterait que l'adresse obligerait l'application à
/// chercher le code dans l'image qu'elle a chargée — juste pour le noyau,
/// **faux en silence** pour un module que l'invité charge lui-même.
///
/// **Ils traversent en base64, et le sens inverse pas.** Ce n'est pas une
/// incohérence : vers la vue, ce qui coûte est l'analyse d'une source
/// JavaScript, où un littéral de tableau gagne (mesuré,
/// `scripts/wasm-crossing-probe.ts`). Depuis la vue, ce qui coûte est la
/// sérialisation de `postMessage` — une seule chaîne contre quatre mille
/// nombres à emballer. **Ce second compromis n'est pas mesuré** : il demande un
/// vrai `WKWebView`, et rien ici n'en a.
pub fn page(
    pages: u32,
    entry: u64,
    channel: &str,
    screen: Option<Screen>,
    boot: Option<u64>,
) -> Result<String, Refusal> {
    if pages == 0 || !pages.is_power_of_two() {
        return Err(Refusal::RamIsNotAPowerOfTwo(pages));
    }
    if channel.is_empty() || !channel.chars().all(|glyph| glyph.is_ascii_alphanumeric()) {
        return Err(Refusal::ChannelIsNotAName(channel.to_string()));
    }
    // **Le cadre est jugé ici, avant que la page n'existe.** `host.js` le juge
    // une seconde fois à la construction de la machine, et ce n'est pas une
    // redondance inutile : celle-ci refuse en Rust, avec un nom, quand l'autre
    // ne peut que lever dans une vue que personne ne regarde.
    let frame = match screen {
        None => String::new(),
        Some(screen) => {
            if screen.width == 0 || screen.height == 0 {
                return Err(Refusal::ScreenHasNoSurface {
                    width: screen.width,
                    height: screen.height,
                });
            }
            let ram = u64::from(pages) * 65536;
            let folded = screen.base & (ram - 1);
            // **La surface peut déborder de soixante-quatre bits**, et c'est un
            // débordement qui *accepterait* au lieu de refuser : deux
            // dimensions de deux puissance trente et un donnent exactement deux
            // puissance soixante-quatre, qui enroule à **zéro** en release. Un
            // cadre impossible passerait alors la garde. `saturating_mul` rend
            // un nombre au moins aussi grand que le vrai, ce qui suffit pour
            // refuser — et un cadre de cette taille n'a pas de vrai nombre à
            // annoncer.
            let bytes = u64::from(screen.width)
                .saturating_mul(u64::from(screen.height))
                .saturating_mul(4);
            if folded.saturating_add(bytes) > ram {
                return Err(Refusal::ScreenDoesNotFit { folded, bytes, ram });
            }
            // **Le canvas est dans le corps de la page, pas fabriqué par le
            // script.** Ses dimensions sont alors lisibles dans la page
            // elle-même, et elles sont celles que ce refus vient de valider —
            // un canvas construit à la volée les tiendrait d'une variable, et
            // plus rien ne dirait laquelle.
            format!(
                "<canvas id=\"wisqEcran\" width=\"{}\" height=\"{}\"></canvas>\n",
                screen.width, screen.height
            )
        }
    };
    Ok(format!(
        "<!doctype html>\n\
         <meta charset=\"utf-8\">\n\
         <title>wisq</title>\n\
         {frame}\
         <script type=\"module\">\n\
         {HOST_SCRIPT}\n\
         {}\n\
         </script>\n",
        driver(pages, entry, channel, screen, boot)
    ))
}

/// **Ce que la page fait de l'écran de l'invité.**
///
/// **Peindre est séparé de la boucle qui peint, et ce n'est pas du confort.**
/// `requestAnimationFrame` ne tourne que dans une vue que le système considère
/// comme affichée. Un `WKWebView` construit sans être ajouté à une fenêtre —
/// exactement ce que fait `LocalDesktopTests` — pourrait n'en voir aucune, et
/// un test qui attendrait une image n'aurait alors rien à attendre. `wisqPaint`
/// se laisse donc appeler à la main, et la boucle ne fait que l'appeler.
///
/// **Rien ne traverse vers l'application.** Le cadre vit dans la mémoire de la
/// vue, le canvas aussi : la conversion se fait sur place. C'est la seule
/// raison pour laquelle un affichage est possible — trois mégaoctets par image
/// ne passeraient jamais un pont de messages.
fn painter(screen: Screen) -> String {
    format!(
        r#"
// **L'écran.** Le canvas est dans le corps de la page, à ses dimensions ; le
// contexte peut être refusé, et un refus muet donnerait un écran noir qu'on
// mettrait sur le compte de la machine.
const écran = document.getElementById("wisqEcran");
if (écran === null) {{
  throw new Error("la page déclare un cadre mais pas de canvas");
}}
const pinceau = écran.getContext("2d");
if (pinceau === null) {{
  throw new Error("la vue n'accorde pas de contexte 2d");
}}
// **Une seule ImageData, réutilisée.** En construire une par image
// allouerait {octets} octets soixante fois par seconde ; et `putImageData`
// n'accepte de toute façon que celle que le contexte a rendue.
const image = pinceau.createImageData({width}, {height});

// Peindre une image, tout de suite, quel que soit l'état de la machine.
//
// **Elle rend le nombre de pixels**, et ce n'est pas décoratif : une fonction
// qui ne rend rien ne se distingue pas d'une fonction qui n'a rien fait. C'est
// le seul moyen, depuis l'application, de savoir qu'une image est passée.
window.wisqPaint = () => {{
  const pixels = vm.paint(image.data);
  pinceau.putImageData(image, 0, 0);
  return pixels;
}};

let enMarche = false;
const boucle = () => {{
  if (!enMarche) return;
  window.wisqPaint();
  requestAnimationFrame(boucle);
}};

window.wisqAfficher = () => {{
  if (enMarche) return;
  enMarche = true;
  requestAnimationFrame(boucle);
}};

window.wisqCesser = () => {{
  enMarche = false;
  window.wisqPaint();
}};
"#,
        width = screen.width,
        height = screen.height,
        octets = u64::from(screen.width) * u64::from(screen.height) * 4,
    )
}

/// **Le pilote : ce qui relie la boucle hôte au pont de l'application.**
///
/// Séparé de la page pour qu'un test puisse l'exécuter sans HTML autour — un
/// moteur JavaScript en ligne de commande n'a pas de `WKWebView`, mais il sait
/// très bien bouchonner `window.webkit.messageHandlers`.
pub fn driver(
    pages: u32,
    entry: u64,
    channel: &str,
    screen: Option<Screen>,
    boot: Option<u64>,
) -> String {
    // **Ce que la page fait de l'écran, et rien si elle n'en a pas.** Une
    // machine sans cadre est un cas réel — un démarrage jugé sur ses registres
    // n'a pas besoin d'être regardé — et un canvas qu'on peindrait pour rien
    // coûterait une image par rafraîchissement.
    let (declared, painting) = match screen {
        // **Deux fonctions vides, et elles disent quelque chose.** Sans cadre
        // il n'y a rien à montrer, et `wisqRun` a un seul chemin plutôt qu'un
        // test sur l'existence d'une globale. `wisqPaint`, lui, n'est pas
        // déclaré : l'appeler doit lever, pas ne rien faire.
        None => (
            String::new(),
            r#"
// Aucun cadre déclaré : il n'y a rien à peindre.
window.wisqAfficher = () => {};
window.wisqCesser = () => {};
"#
            .to_string(),
        ),
        Some(screen) => (
            format!(
                ", screen: {{ base: {}n, width: {}, height: {} }}",
                screen.base, screen.width, screen.height
            ),
            painter(screen),
        ),
    };
    // **RSI, et seulement si l'application a posé une page zéro.**
    //
    // Le protocole de démarrage x86-64 de Linux passe l'adresse de
    // `boot_params` dans RSI, et rien d'autre : le noyau lit par là sa carte
    // e820, sa ligne de commande et son initramfs. Le montage de mesure le
    // fait depuis #257 ; la page du bureau ne posait que RIP, et un noyau
    // entré ainsi s'arrête muet dans `extend_brk` à sa 1067ᵉ région.
    //
    // **Le numéro six est le registre, pas un emplacement nommé.** `SLOTS` ne
    // nomme que ce qui n'est pas un registre général — RIP, les drapeaux,
    // l'horloge ; les seize registres sont les seize premières globales, dans
    // l'ordre du codage x86 : rax, rcx, rdx, rbx, rsp, rbp, **rsi**, rdi.
    //
    // Et rien n'est écrit quand rien n'a été posé : les programmes jugés sur
    // leurs registres n'ont pas de `boot_params`, et leur en inventer un leur
    // ferait lire une adresse que personne n'a remplie.
    let amorce = match boot {
        None => String::new(),
        Some(at) => format!("vm.globals[6].value = {at}n; // RSI : la page zéro\n"),
    };
    format!(
        r#"
// **Le pont vers l'application.** Une vue ne peut pas appeler l'hôte et
// attendre : elle poste, et l'hôte rappelle. Chaque demande porte donc un
// numéro, et sa promesse attend dans `waiting` jusqu'à ce qu'il revienne.
// **Tout ce qui suit est sous garde, et ça manquait.**
//
// Une erreur à l'évaluation de ce module — un canvas absent, un contexte
// refusé, une RAM que la boucle hôte n'accepte pas — tuait le module en
// silence. La vue finissait quand même de charger, `load()` rendait la main,
// et l'appel suivant partait sur une page à moitié installée. L'application
// n'apprenait la panne que par le symptôme, plusieurs appels plus loin.
//
// Ce qui doit sortir d'ici est sur `window` ; le reste n'est vu que d'ici,
// donc l'enfermer dans un bloc ne coûte rien.
window.wisqFailure = null;
try {{

const bridge = window.webkit.messageHandlers.{channel};
let ticket = 0;
const waiting = new Map();

// Appelé par l'application quand la traduction est prête. `octets` est un
// tableau de nombres, ou `null` si l'émetteur a refusé franchement la région.
window.wisqTranslated = (id, octets) => {{
  const settle = waiting.get(id);
  if (settle === undefined) return;
  waiting.delete(id);
  settle(octets === null ? null : Uint8Array.from(octets));
}};

// Appelé quand l'émetteur a manqué d'octets plutôt que refusé : la vue
// redemande alors une fois, avec une fenêtre plus large.
window.wisqNeedsMore = id => {{
  const settle = waiting.get(id);
  if (settle === undefined) return;
  waiting.delete(id);
  settle("encore");
}};

const translate = (address, slot, code) => new Promise(settle => {{
  const id = ++ticket;
  waiting.set(id, settle);
  // **Les octets partent en base64.** Une seule chaîne à sérialiser plutôt que
  // quatre mille nombres à emballer un par un — le compromis inverse de celui
  // du retour, où c'est l'analyse d'une source JavaScript qui coûte. Concaténé
  // par tranches : passer seize kibioctets à `String.fromCharCode` en une fois
  // dépasse la pile d'arguments.
  let binaire = "";
  for (let at = 0; at < code.length; at += 4096) {{
    binaire += String.fromCharCode.apply(null, code.subarray(at, at + 4096));
  }}
  // L'adresse part en **texte** : un entier de soixante-quatre bits ne
  // traverse pas JSON sans perdre ses bits de poids fort.
  bridge.postMessage({{
    kind: "traduire",
    id,
    address: address.toString(),
    slot,
    octets: btoa(binaire),
  }});
}});

const vm = machine({{ translate, pages: {pages}{declared} }});
vm.globals[SLOTS.rip].value = {entry}n;
{amorce}
window.wisqMachine = vm;
{painting}
window.wisqRun = async () => {{
  window.wisqAfficher();
  const why = await vm.run();
  // **Cesser peint une dernière fois.** Sans ça, la dernière image montrée
  // serait celle d'avant l'arrêt : on regarderait un écran qui n'est pas
  // l'état dans lequel la machine s'est arrêtée.
  window.wisqCesser();
  bridge.postMessage({{ kind: "arrêt", stopped: why.stopped, at: why.at.toString() }});
  return why.stopped;
}};

}} catch (raison) {{
  // **Retenue plutôt que perdue.** `load()` la lit et refuse, au lieu de
  // laisser l'application découvrir la panne trois appels plus loin.
  window.wisqFailure = String(raison && raison.message ? raison.message : raison);
}}
"#
    )
}
