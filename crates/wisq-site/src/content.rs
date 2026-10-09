//! Toute la copie, dans les deux langues, et la raison d'être de ce module est
//! la même que celle de `site/src/content.ts` qu'il a remplacé : les composants
//! restent de la mise en page, et rien ne peut dériver entre les versions. Il
//! en est la seule source depuis que le TypeScript est parti ; la construction
//! et les tests lisent ce qu'il dit dans le catalogue du pré-rendu.
//!
//! **La promesse de l'original devient ici une vraie garantie du compilateur.**
//! L'en-tête de `content.ts` disait : « une traduction manquante est une erreur de
//! type plutôt qu'une chaîne anglaise qui fuit dans la page française ». En
//! TypeScript c'était vrai par discipline de structure ; en Rust, `Copy` est un
//! `struct` sans valeur par défaut, donc une langue incomplète ne compile pas.

/// L'anglais est servi à la racine, le français sous `fr/`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lang {
    En,
    Fr,
}

impl Lang {
    /// Les deux langues, dans l'ordre où la construction écrit les pages.
    pub const ALL: [Lang; 2] = [Lang::En, Lang::Fr];

    /// Le code BCP 47 qui part dans `<html lang>`.
    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::Fr => "fr",
        }
    }

    /// Le préfixe d'adresse. Vide pour l'anglais : une langue qu'une URL ne
    /// sait pas exprimer est une langue que le web ne voit pas.
    pub fn prefix(self) -> &'static str {
        match self {
            Lang::En => "",
            Lang::Fr => "fr/",
        }
    }

    pub fn parse(code: &str) -> Option<Lang> {
        match code {
            "en" => Some(Lang::En),
            "fr" => Some(Lang::Fr),
            _ => None,
        }
    }

    pub fn copy(self) -> &'static Copy {
        match self {
            Lang::En => &EN,
            Lang::Fr => &FR,
        }
    }

    /// La copie de l'accueil. Voir `AccueilCopy` pour la raison de la
    /// séparation.
    pub fn accueil(self) -> &'static AccueilCopy {
        match self {
            Lang::En => &ACCUEIL_EN,
            Lang::Fr => &ACCUEIL_FR,
        }
    }
}

/// La bascule de thème. Chaque libellé est un nom accessible réel : les boutons
/// montrent des icônes, et une icône sans nom est un bouton qu'un lecteur
/// d'écran ne peut pas annoncer.
pub struct ThemeCopy {
    pub label: &'static str,
    pub light: &'static str,
    pub dark: &'static str,
    pub auto: &'static str,
}

/// Les libellés de navigation des pages, un par route.
pub struct PagesCopy {
    pub home: &'static str,
    pub not_found: &'static str,
    pub docs: &'static str,
    pub protocol: &'static str,
    pub architecture: &'static str,
    pub faq: &'static str,
    pub roadmap: &'static str,
    pub releases: &'static str,
    pub privacy: &'static str,
    pub offline: &'static str,
}

pub struct FooterGroups {
    pub product: &'static str,
    pub documentation: &'static str,
    pub project: &'static str,
}

pub struct FooterCopy {
    /// Le nom accessible des deux groupes de liens — la bande sous l'en-tête et
    /// les colonnes au-dessus de la barre du bas. Les deux sont de la
    /// navigation, et un repère `nav` sans nom est un repère qu'un lecteur
    /// d'écran annonce « navigation » et rien de plus.
    pub docs: &'static str,
    pub groups: FooterGroups,
    pub note: &'static str,
    /// Une ligne sous le mot-symbole, pour qui arrive au pied sans avoir lu la
    /// page au-dessus.
    pub tagline: &'static str,
    /// Dit parce que c'est vrai et vérifiable, pas comme un slogan : un test
    /// fait échouer la construction si une adresse tierce apparaît dans le
    /// site construit.
    pub privacy_note: &'static str,
    /// Qui a écrit ceci. Tenu distinct de `attribution`, qui crédite le travail
    /// d'autrui : une ligne qui dit ce qui est à moi ne doit jamais se lire
    /// comme une revendication sur ce qui ne l'est pas.
    pub author: &'static str,
    pub attribution: &'static str,
    /// Ce par quoi la ligne de version se terminait était une licence. Il n'y en
    /// a pas, donc elle finit par le défaut nu — vrai quoi qu'on choisisse, et
    /// la ligne garde sa forme au lieu de s'arrêter après un numéro.
    pub rights: &'static str,
    /// Le droit d'auteur de la barre du bas. Un droit d'auteur n'est pas une
    /// licence : il dit qui a écrit ceci, ce qui est vrai et réglé, là où la
    /// licence disait ce que les autres peuvent en faire, ce qui ne l'est pas.
    pub copyright: &'static str,
    pub back_to_top: &'static str,
    pub version: &'static str,
}

/// L'invite d'installation. Deux formes, parce que les plateformes diffèrent :
/// un navigateur qui émet `beforeinstallprompt` reçoit un bouton, et iOS — qui
/// ne l'émet jamais, et qui est la plateforme dont ce projet parle — reçoit les
/// trois gestes qui marchent.
pub struct PwaCopy {
    pub title: &'static str,
    pub body: &'static str,
    pub action: &'static str,
    pub ios_title: &'static str,
    pub ios_body: &'static str,
    pub dismiss: &'static str,
}

/// Le héros de l'accueil : la phrase, ce qu'elle promet, et l'étiquette.
pub struct HeroCopy {
    pub tagline: &'static str,
    pub lede: &'static str,
    pub badge: &'static str,
}

/// Un des deux modes : distant ou local.
pub struct ModeCopy {
    pub name: &'static str,
    pub head: &'static str,
    pub body: &'static str,
    pub points: &'static [&'static str],
}

pub struct ModesCopy {
    pub title: &'static str,
    pub remote: ModeCopy,
    pub local: ModeCopy,
}

/// La comparaison avec UTM. Trois colonnes, et le type le dit : une ligne qui
/// en aurait deux ou quatre ne compile pas.
pub struct CompareCopy {
    pub title: &'static str,
    pub lede: &'static str,
    pub columns: [&'static str; 3],
    pub rows: &'static [[&'static str; 3]],
}

pub struct StepCopy {
    pub title: &'static str,
    pub body: &'static str,
}

/// Trois étapes, parce que l'appairage est ce qu'un lecteur doit croire avant
/// que le reste de la page compte.
pub struct HowCopy {
    pub title: &'static str,
    pub steps: &'static [StepCopy],
}

pub struct FactCopy {
    pub value: &'static str,
    pub label: &'static str,
}

/// **Ne pas incrémenter ces chiffres à la main en espérant.**
/// `site/tests/claims.test.ts` lit le dépôt et tombe dès qu'un chiffre cesse
/// d'être vrai — le nombre de tests en comptant `func test` sous `Tests/` et
/// `#[test]` sous `crates/`, les portes en lisant les jobs de la CI. Lancer
/// `bun test`, et il donne le nombre plutôt que de laisser le calculer.
pub struct FactsCopy {
    pub title: &'static str,
    pub items: &'static [FactCopy],
}

/// Les deux boutons du héros. Des liens vers des pages du site, pas des
/// actions : le site ne distribue rien, il explique.
pub struct CtaCopy {
    pub primary: &'static str,
    pub secondary: &'static str,
}

/// La bande qui défile sous le héros, et le nom de l'invitation à défiler.
///
/// **La bande est décorative et le dit** : elle répète en mots-clés ce que les
/// sections du dessous expliquent en phrases, donc un lecteur d'écran n'a rien
/// à y apprendre et elle part `aria-hidden`. Les mots sont quand même de la
/// copie, dans les deux langues, parce que « hors ligne » n'est pas « offline ».
pub struct BandeCopy {
    pub words: &'static [&'static str],
}

/// Tout ce que l'accueil dit, à part de la coquille.
///
/// **Séparé de `Copy`, et c'est une question de poids.** `Copy` est lu par les
/// deux îlots que le navigateur hydrate — les réglages de l'en-tête et l'invite
/// d'installation — donc tout ce qu'il contient entre dans le module wasm, dans
/// les deux langues : un `static` référencé l'est en entier. La copie de
/// l'accueil n'est lue que par le pré-rendu, et la tenir dans sa propre
/// structure suffit à la garder hors du module.
pub struct AccueilCopy {
    /// Le titre de l'onglet et des cartes de partage. L'accueil n'est pas un
    /// document, donc il n'a pas de `Doc` qui le porterait.
    pub title: &'static str,
    pub hero: HeroCopy,
    pub cta: CtaCopy,
    pub bande: BandeCopy,
    pub modes: ModesCopy,
    pub compare: CompareCopy,
    pub how: HowCopy,
    pub facts: FactsCopy,
}

pub struct Copy {
    pub language: &'static str,
    pub theme: ThemeCopy,
    pub pages: PagesCopy,
    pub footer: FooterCopy,
    pub pwa: PwaCopy,
}

/// Qui a écrit ceci, et la version que le pied annonce.
pub const AUTHOR: &str = "Maxime Nathan Lestage";
pub const AUTHOR_URL: &str = "https://github.com/maxlestage";
pub const SITE_VERSION: &str = "0.4.0";

pub static EN: Copy = Copy {
    language: "Language",
    theme: ThemeCopy {
        label: "Theme",
        light: "Light",
        dark: "Dark",
        auto: "Match system",
    },
    pages: PagesCopy {
        home: "Home",
        not_found: "Not found",
        docs: "Docs",
        protocol: "Agent protocol",
        architecture: "Architecture",
        faq: "Questions",
        roadmap: "Roadmap",
        releases: "Releases",
        privacy: "Privacy",
        offline: "Offline",
    },
    footer: FooterCopy {
        docs: "Site",
        groups: FooterGroups {
            product: "Product",
            documentation: "Documentation",
            project: "Project",
        },
        note: "The agent speaks TLS by default, pinned by the pairing link — no certificate authority to run. Plain VNC itself stays unencrypted: trusted network or tunnel for the console.",
        tagline: "Virtual machines on your iPhone: remote at full speed, or a real Linux kernel on the phone itself.",
        privacy_note: "No analytics, no cookies, no third-party requests. This page loaded nothing from anyone else.",
        author: "Designed and developed by",
        attribution: "RISC-V execution semantics ported from mini-rv32ima by Charles Lohr (MIT).",
        rights: "All rights reserved",
        copyright: "© 2026 Maxime Nathan Lestage",
        back_to_top: "Back to top",
        version: "Version",
    },
    pwa: PwaCopy {
        title: "Keep wisq one tap away",
        body: "Install this site and it opens like an app, works without a network, and stops asking.",
        action: "Install",
        ios_title: "Add to your Home Screen",
        ios_body: "Tap the Share button, then Add to Home Screen.",
        dismiss: "Not now",
    },
};

pub static FR: Copy = Copy {
    language: "Langue",
    theme: ThemeCopy {
        label: "Thème",
        light: "Clair",
        dark: "Sombre",
        auto: "Selon le système",
    },
    pages: PagesCopy {
        home: "Accueil",
        not_found: "Introuvable",
        docs: "Docs",
        protocol: "Protocole de l'agent",
        architecture: "Architecture",
        faq: "Questions",
        roadmap: "Feuille de route",
        releases: "Versions",
        privacy: "Vie privée",
        offline: "Hors ligne",
    },
    footer: FooterCopy {
        docs: "Site",
        groups: FooterGroups {
            product: "Produit",
            documentation: "Documentation",
            project: "Projet",
        },
        note: "L'agent parle TLS par défaut, épinglé par le lien d'appairage — aucune autorité de certification à exploiter. Le VNC nu reste non chiffré : réseau de confiance ou tunnel pour la console.",
        tagline: "Des machines virtuelles sur votre iPhone : à distance à pleine vitesse, ou un vrai noyau Linux sur le téléphone lui-même.",
        privacy_note: "Aucune mesure d'audience, aucun cookie, aucune requête tierce. Cette page n'a rien chargé chez qui que ce soit.",
        author: "Conçu et développé par",
        attribution: "Sémantique d'exécution RISC-V portée de mini-rv32ima, de Charles Lohr (MIT).",
        rights: "Tous droits réservés",
        copyright: "© 2026 Maxime Nathan Lestage",
        back_to_top: "Haut de page",
        version: "Version",
    },
    pwa: PwaCopy {
        title: "Gardez wisq à une touche",
        body: "Installez ce site : il s'ouvre comme une application, fonctionne sans réseau, et cesse de demander.",
        action: "Installer",
        ios_title: "Ajouter à l'écran d'accueil",
        ios_body: "Touchez le bouton Partager, puis « Sur l'écran d'accueil ».",
        dismiss: "Plus tard",
    },
};

pub static ACCUEIL_EN: AccueilCopy = AccueilCopy {
    title: "wisq — virtual machines on your iPhone",
    hero: HeroCopy {
        tagline: "Virtual machines on your iPhone.",
        lede: "Reach a VM running on your Mac, PC or NAS at full speed — or boot a real Linux kernel on the phone itself, offline.",
        badge: "Rust · hybrid mobile app · iOS 17+",
    },
    cta: CtaCopy {
        primary: "Read the guide",
        secondary: "What's new",
    },
    bande: BandeCopy {
        words: &["VNC", "SPICE", "RDP", "RISC-V", "x86-64", "Linux on the phone", "Offline", "Rust", "iOS 17+"],
    },
    modes: ModesCopy {
        title: "Two ways, one app",
        remote: ModeCopy {
            name: "Remote",
            head: "The VM runs where the silicon is",
            body: "Three hand-written clients built for a phone — VNC, SPICE and RDP, no library between them and the wire: compressed encodings so it stays usable on cellular, a touch model that actually hits small buttons, and it opens the .vv and .rdp files your hypervisors hand out.",
            points: &["VNC: ZRLE, Tight with JPEG, zlib — over session-lived streams", "SPICE: the complete display channel — LZ, QUIC, GLZ, LZ4, JPEG — cursor, input, sound both ways, clipboard, file drop into the guest", "Reconnects through cell handoffs, never retries a bad password", "A host agent boots a powered-off VM when you tap it — and shuts it down, politely or hard, when you ask", "wisq-agent bureau builds the machine from an installation image: the qcow2 disk, the image booted first, a SPICE desktop with a generated password, the tablet, the sound and the guest agent channel — one command, then the desktop is on the phone"],
        },
        local: ModeCopy {
            name: "Local",
            head: "A real Linux kernel, on the phone",
            body: "An interpreted RISC-V machine boots Linux to a login prompt in a fraction of a second — around 160 million guest instructions a second. No JIT, so nothing about it fights the platform, and nothing about it needs a jailbreak. And the machine survives iOS: set aside when the screen locks, it resumes your shell right where it was. An x86-64 core stands beside it, running a stock Alpine kernel and its init.",
            points: &["rv32ima core, 64 MB by default and up to 2 GB, 8250 UART, CLINT timer", "Boots a stock Linux 6.1 nommu kernel to a login prompt", "A disk on /dev/vda for either machine — a filesystem or installer image you import, of any size, read in place; what the guest writes goes into a layer beside it that survives suspension and restarts, and the file you imported never changes. wisq cannot add a block driver to a kernel you bring: if none touches the device, it says so", "x86-64 core: runs a stock Alpine kernel and its init, 4 billion instructions, no program dying — to the initramfs rescue shell, exactly where QEMU lands on the same images", "Ten hardware corpora hold that core: the reference is a real processor, asked what it produced", "Entirely offline — no server, no network", "CI boots that kernel on every commit, as a test"],
        },
    },
    compare: CompareCopy {
        title: "Why not just use UTM?",
        lede: "UTM is excellent, and wisq borrows from its touch design. But iOS grants executable memory only to development-signed apps, so emulating a desktop OS on the phone is interpreted and an order of magnitude slow. That is a platform ceiling, not a code-quality one.",
        columns: ["Aspect", "UTM SE", "wisq"],
        rows: &[["Execution", "local QEMU, interpreted", "on the host — or a purpose-built local interpreter"], ["Speed", "very slow (no JIT on iOS)", "network-bound remote · ~1 s to a Linux shell locally"], ["App Store", "grey area, rule 4.7", "network client + interpreter, both clean"], ["License", "GPL (QEMU)", "no QEMU inside, so no copyleft to carry"]],
    },
    how: HowCopy {
        title: "How pairing works",
        steps: &[StepCopy { title: "Run the agent", body: "It prints a wisq:// link per network interface — and a QR code when qrencode is installed. It also announces itself over Bonjour." }, StepCopy { title: "Scan it", body: "Opening the link on the iPhone lands directly in the import screen, address and token filled in, already querying." }, StepCopy { title: "Tap a VM", body: "Powered off? The agent boots it, wisq waits for the console and resolves the endpoint late — the port moves between boots." }],
    },
    facts: FactsCopy {
        title: "Built to be trusted",
        items: &[FactCopy { value: "2628", label: "tests" }, FactCopy { value: "7", label: "blocking CI gates" }, FactCopy { value: "0", label: "warnings, strict concurrency" }, FactCopy { value: "1", label: "real kernel booted per CI run" }],
    },
};

pub static ACCUEIL_FR: AccueilCopy = AccueilCopy {
    title: "wisq — des machines virtuelles sur votre iPhone",
    hero: HeroCopy {
        tagline: "Des machines virtuelles sur votre iPhone.",
        lede: "Atteignez à pleine vitesse une VM qui tourne sur votre Mac, PC ou NAS — ou faites démarrer un vrai noyau Linux sur le téléphone lui-même, hors ligne.",
        badge: "Rust · application mobile hybride · iOS 17+",
    },
    cta: CtaCopy {
        primary: "Lire le guide",
        secondary: "Les nouveautés",
    },
    bande: BandeCopy {
        words: &["VNC", "SPICE", "RDP", "RISC-V", "x86-64", "Linux sur le téléphone", "Hors ligne", "Rust", "iOS 17+"],
    },
    modes: ModesCopy {
        title: "Deux voies, une application",
        remote: ModeCopy {
            name: "Distant",
            head: "La VM tourne là où il y a du silicium",
            body: "Trois clients écrits à la main pour un téléphone — VNC, SPICE et RDP, sans bibliothèque entre eux et le fil : des encodages compressés pour rester utilisable en 4G, un modèle tactile qui atteint vraiment les petits boutons, et l'ouverture des fichiers .vv et .rdp que vos hyperviseurs remettent.",
            points: &["VNC : ZRLE, Tight avec JPEG, zlib — sur des flux persistants", "SPICE : canal display complet — LZ, QUIC, GLZ, LZ4, JPEG — curseur, entrées, son dans les deux sens, presse-papiers, dépôt de fichiers dans l'invité", "Reconnexion aux changements de réseau, jamais sur un mot de passe refusé", "Un agent hôte démarre une VM éteinte quand vous la tapez — et l'éteint, poliment ou de force, quand vous le demandez", "wisq-agent bureau construit la machine autour d'une image d'installation : le disque qcow2, l'image amorcée en premier, un bureau SPICE avec mot de passe engendré, la tablette, le son et le canal de l'agent invité — une commande, et le bureau est sur le téléphone"],
        },
        local: ModeCopy {
            name: "Local",
            head: "Un vrai noyau Linux, sur le téléphone",
            body: "Une machine RISC-V interprétée amène Linux jusqu'à l'invite de connexion en une fraction de seconde — environ 160 millions d'instructions invitées par seconde. Sans JIT, donc rien n'entre en conflit avec la plateforme, et rien n'exige de jailbreak. Et la machine survit à iOS : mise de côté quand l'écran se verrouille, elle reprend votre shell là où il était. Un cœur x86-64 l'accompagne, qui fait tourner un noyau Alpine standard et son init.",
            points: &["Cœur rv32ima, 64 Mo par défaut et jusqu'à 2 Go, UART 8250, minuteur CLINT", "Démarre un noyau Linux 6.1 nommu standard jusqu'à l'invite", "Un disque sur /dev/vda pour les deux machines — une image de système de fichiers ou d'installation que vous importez, de n'importe quelle taille, lue sur place ; ce que l'invité écrit va dans une couche à côté qui survit aux suspensions et aux redémarrages, et le fichier importé ne change jamais. wisq ne peut pas ajouter un pilote bloc à un noyau que vous apportez : si personne ne touche le périphérique, il le dit", "Cœur x86-64 : fait tourner un noyau Alpine standard et son init, 4 milliards d'instructions, sans qu'un programme meure — jusqu'au shell de secours de l'initramfs, exactement là où QEMU arrive sur les mêmes images", "Dix corpus matériels tiennent ce cœur : la référence est un vrai processeur, à qui l'on demande ce qu'il a produit", "Entièrement hors ligne — aucun serveur, aucun réseau", "La CI démarre ce noyau à chaque commit, comme test"],
        },
    },
    compare: CompareCopy {
        title: "Pourquoi pas simplement UTM ?",
        lede: "UTM est excellent, et wisq lui emprunte son modèle tactile. Mais iOS n'accorde de mémoire exécutable qu'aux applications signées pour le développement : émuler un OS de bureau sur le téléphone y est interprété, donc lent d'un ordre de grandeur. C'est un plafond de plateforme, pas de qualité de code.",
        columns: ["Critère", "UTM SE", "wisq"],
        rows: &[["Exécution", "QEMU local, interprété", "sur l'hôte — ou un interprète local dédié"], ["Vitesse", "très lente (pas de JIT sur iOS)", "limitée par le réseau · ~1 s jusqu'au shell en local"], ["App Store", "zone grise, règle 4.7", "client réseau + interprète, tous deux propres"], ["Licence", "GPL (QEMU)", "pas de QEMU dedans, donc pas de copyleft à porter"]],
    },
    how: HowCopy {
        title: "L'appairage",
        steps: &[StepCopy { title: "Lancez l'agent", body: "Il affiche un lien wisq:// par interface réseau — et un QR code si qrencode est installé. Il s'annonce aussi en Bonjour." }, StepCopy { title: "Scannez-le", body: "Ouvrir le lien sur l'iPhone atterrit directement dans l'écran d'import, adresse et jeton remplis, interrogation déjà lancée." }, StepCopy { title: "Tapez une VM", body: "Éteinte ? L'agent la démarre, wisq attend sa console et résout l'adresse tardivement — le port change d'un démarrage à l'autre." }],
    },
    facts: FactsCopy {
        title: "Fait pour inspirer confiance",
        items: &[FactCopy { value: "2628", label: "tests" }, FactCopy { value: "7", label: "portes CI bloquantes" }, FactCopy { value: "0", label: "avertissement, concurrence stricte" }, FactCopy { value: "1", label: "vrai noyau démarré par exécution CI" }],
    },
};
