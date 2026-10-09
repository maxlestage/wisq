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

/// Un des trois protocoles de console : ce qu'il atteint, ce que wisq en parle,
/// et la réserve qui va avec. La réserve est un champ obligatoire et non une
/// option : les trois en ont une, et un protocole présenté sans la sienne se
/// lirait comme une promesse.
pub struct ProtocoleCopy {
    pub name: &'static str,
    pub reach: &'static str,
    pub points: &'static [&'static str],
    pub caveat: &'static str,
}

pub struct ProtocolesCopy {
    pub title: &'static str,
    pub lede: &'static str,
    pub items: &'static [ProtocoleCopy],
}

/// Les deux machines locales, côte à côte. Trois colonnes, comme la
/// comparaison avec UTM, et pour la même raison.
pub struct MachinesCopy {
    pub title: &'static str,
    pub lede: &'static str,
    pub columns: [&'static str; 3],
    pub rows: &'static [[&'static str; 3]],
    pub note: &'static str,
}

/// Un terme et ce qu'il veut dire : le toucher et la sécurité s'écrivent ainsi.
pub struct TraitCopy {
    pub term: &'static str,
    pub detail: &'static str,
}

pub struct TraitsCopy {
    pub title: &'static str,
    pub lede: &'static str,
    pub items: &'static [TraitCopy],
}

/// Où en est le projet. Deux listes, et la seconde n'est pas facultative :
/// une page qui ne dit que ce qui est fait laisse croire que c'est tout.
pub struct EtatCopy {
    pub title: &'static str,
    pub lede: &'static str,
    pub done_label: &'static str,
    pub done: &'static [&'static str],
    pub next_label: &'static str,
    pub next: &'static [&'static str],
}

/// Une ligne par page écrite, sous son nom de navigation. Les champs sont
/// nommés plutôt que rangés dans une liste : une page ajoutée au site sans sa
/// ligne ici ne compile pas, et l'accueil ne peut pas oublier une page.
pub struct ExplorerCopy {
    pub title: &'static str,
    pub docs: &'static str,
    pub protocol: &'static str,
    pub architecture: &'static str,
    pub faq: &'static str,
    pub roadmap: &'static str,
    pub releases: &'static str,
    pub privacy: &'static str,
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
    pub protocoles: ProtocolesCopy,
    pub machines: MachinesCopy,
    pub compare: CompareCopy,
    pub toucher: TraitsCopy,
    pub how: HowCopy,
    pub securite: TraitsCopy,
    pub facts: FactsCopy,
    pub etat: EtatCopy,
    pub explorer: ExplorerCopy,
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
    protocoles: ProtocolesCopy {
        title: "Three protocols, written for a phone",
        lede: "Each client is written by hand against its specification, with no library between wisq and the wire — so compression, input timing and reconnection are designed for a phone on a cellular link rather than inherited from a desktop viewer. Use whichever your host already speaks.",
        items: &[
            ProtocoleCopy {
                name: "VNC",
                reach: "QEMU, libvirt, VirtualBox, Proxmox, x11vnc, a Mac sharing its screen — anything with a VNC console.",
                points: &["RFB 3.8 with VNC password authentication", "Raw, CopyRect, RRE, Hextile, zlib, ZRLE, and Tight with JPEG — over zlib streams that live as long as the session", "Continuous updates, the server's cursor drawn on the phone, desktop resize, clipboard", "A low-bandwidth mode that asks for the encodings that compress hardest"],
                caveat: "Plain VNC travels in the clear. Each machine can be reached over TLS instead, pinned to a fingerprint you enter if you want it to be — or keep it inside a tunnel you already run.",
            },
            ProtocoleCopy {
                name: "SPICE",
                reach: "What libvirt and QEMU publish for a desktop guest — and what wisq-agent bureau sets up for you.",
                points: &["Main, display, inputs and cursor channels, the pointer on a connection of its own so it keeps moving while the screen is busy", "LZ, GLZ with its window, QUIC, LZ4, JPEG and the palette forms; draw operations, video streams, three caches", "Sound both ways, the clipboard, and a file sent from the phone into the guest", ".vv connection files open straight into a machine"],
                caveat: "The clipboard, file transfer and a screen that follows the phone's size need spice-vdagent running in the guest; without it, wisq says so rather than failing quietly.",
            },
            ProtocoleCopy {
                name: "RDP",
                reach: "Windows guests, and the .rdp files their hosts hand out.",
                points: &["Negotiation, MCS, key exchange, licensing and capabilities", "RLE bitmaps and input", "Measured against a real server: it opens a session, negotiates and paints the screen"],
                caveat: "Historic RDP security only, for now: it does not authenticate the server, and a host that requires NLA — modern Windows does by default — is refused by name rather than worked around. NLA is on the roadmap.",
            },
        ],
    },
    machines: MachinesCopy {
        title: "Two machines in your pocket",
        lede: "Both are interpreters — no JIT, no special entitlement — and both boot a real, unmodified Linux kernel on the phone, with no network and no host. wisq reads the file you hand it and picks the core itself: twenty-one architecture families recognised, two executed.",
        columns: ["", "RISC-V", "x86-64"],
        rows: &[
            ["Processor", "rv32ima, one hart", "64-bit x86, with SSE2 and the x87 stack"],
            ["Memory", "64 MB by default, up to 2 GB", "what the phone can spare — at most two gigabytes less than it has"],
            ["Devices", "8250 UART, CLINT timer, virtio disk", "16550 UART, 8259 and 8253, PCI, virtio disk"],
            ["Boots", "a stock Linux 6.1 nommu kernel, to its login prompt", "a stock Alpine kernel and its initramfs, to the rescue shell"],
            ["Clock", "counts executed instructions, so every boot is identical", "the same rule: the 8253 ticks on instructions, not on wall time"],
            ["Disk", "an image you import, on /dev/vda, read in place", "the same, over virtio-mmio"],
            ["Checked by", "a second interpreter, in Swift, compared at every checkpoint in CI", "a real processor: same bytes, same state, and its answer is the reference"],
        ],
        note: "Speed figures on this site come from a Linux container, not from an iPhone: the code path is the one the phone runs, the silicon is not.",
    },
    compare: CompareCopy {
        title: "Why not just use UTM?",
        lede: "UTM is excellent, and wisq borrows from its touch design. But iOS grants executable memory only to development-signed apps, so emulating a desktop OS on the phone is interpreted and an order of magnitude slow. That is a platform ceiling, not a code-quality one.",
        columns: ["Aspect", "UTM SE", "wisq"],
        rows: &[["Execution", "local QEMU, interpreted", "on the host — or a purpose-built local interpreter"], ["Speed", "very slow (no JIT on iOS)", "network-bound remote · ~0.3 s to a Linux login prompt locally"], ["App Store", "grey area, rule 4.7", "network client + interpreter, both clean"], ["License", "GPL (QEMU)", "no QEMU inside, so no copyleft to carry"]],
    },
    toucher: TraitsCopy {
        title: "Made for a thumb",
        lede: "A desktop expects a mouse, and a keyboard with keys a phone never shows. The touch model is where a phone client is won or lost, so every part of it is a setting rather than a guess.",
        items: &[
            TraitCopy { term: "Trackpad or direct touch", detail: "Move the pointer like a laptop trackpad, at a speed you set, or put it straight under your finger." },
            TraitCopy { term: "Gestures you choose", detail: "Long press, two-finger tap, two- and three-finger pans: each can click left, right or middle, drag, scroll, move the screen or bring up the keyboard. Out of the box, a long press and a two-finger tap right-click, two fingers scroll and three move the screen." },
            TraitCopy { term: "Inertia, and a click a guest can see", detail: "The pointer and the wheel coast after your finger lifts, and every synthesised click holds the button for 50 ms — a guest that samples its input on a timer sees nothing shorter." },
            TraitCopy { term: "A key bar", detail: "Esc and Tab, sticky Ctrl, Alt, Shift and ⌘, the arrows, Home, End, Page Up, Page Down and Delete — and F1 to F12 one tap away." },
            TraitCopy { term: "Hardware keyboards", detail: "Keys travel as X11 keysyms; ⌘ becomes the guest's Super key, or Control if your muscle memory is macOS." },
            TraitCopy { term: "The screen", detail: "Fit, 1:1 with panning, or fill; ask the server to match the phone's resolution; a JPEG quality for cellular; and a screen that stays awake for the length of a session." },
        ],
    },
    how: HowCopy {
        title: "How pairing works",
        steps: &[StepCopy { title: "Run the agent", body: "It prints a wisq:// link per network interface — and a QR code when qrencode is installed. It also announces itself over Bonjour." }, StepCopy { title: "Scan it", body: "Opening the link on the iPhone lands directly in the import screen, address and token filled in, already querying." }, StepCopy { title: "Tap a VM", body: "Powered off? The agent boots it, wisq waits for the console and resolves the endpoint late — the port moves between boots." }],
    },
    securite: TraitsCopy {
        title: "Security without a certificate authority",
        lede: "Nothing here asks you to run a PKI, and nothing pretends to protect what it does not.",
        items: &[
            TraitCopy { term: "TLS by default, pinned", detail: "The agent makes its own certificate; its SHA-256 fingerprint travels in the pairing link, and the app pins it. --no-tls exists for a tunnel that already encrypts." },
            TraitCopy { term: "A token kept like a key", detail: "Generated once, readable by its owner only, and every route is behind it. Revoking a phone is deleting one file and restarting the agent." },
            TraitCopy { term: "Passwords in the Keychain", detail: "A console password lives in the iPhone Keychain, never in the machine list." },
            TraitCopy { term: "No silent downgrade", detail: "A setting wisq cannot read falls back to its default — except a machine's protocol and security, where a fallback would mean a plain connection nobody asked for." },
            TraitCopy { term: "Consoles, said plainly", detail: "Plain VNC and SPICE are unencrypted by design, and RDP's historic security does not authenticate the server. The guide says so where you set them up." },
            TraitCopy { term: "No telemetry", detail: "The app connects to the machines and agents you add, and to nothing else. This site has no analytics, no cookies and no third party, and a test fails the build if one appears." },
        ],
    },
    facts: FactsCopy {
        title: "Built to be trusted",
        items: &[FactCopy { value: "2628", label: "tests" }, FactCopy { value: "7", label: "blocking CI gates" }, FactCopy { value: "0", label: "warnings, strict concurrency" }, FactCopy { value: "1", label: "real kernel booted per CI run" }],
    },
    etat: EtatCopy {
        title: "Where it stands",
        lede: "Everything on the first list is implemented, tested and green in CI. The second is what is not — written down rather than left to be discovered.",
        done_label: "Done",
        done: &["VNC: RFB 3.8, every common encoding, clipboard, desktop resize", "SPICE: display, input, cursor, sound both ways, clipboard, file transfer", "RDP: a session that negotiates, paints and takes input", "Reconnection through network changes, never on a refused password", "A configurable touch model, a key bar, hardware keyboards", "wisq-agent: boot and shut down, pairing link, QR, Bonjour, TLS", "wisq-agent bureau: a SPICE desktop from an installation image", "Local RISC-V: a real kernel, a disk, suspend and resume", "Local x86-64: an Alpine kernel and its initramfs, a disk, the keyboard", "A Rust VM core, compared with the Swift one in CI"],
        next_label: "Not yet",
        next: &["RDP: NLA/CredSSP, virtual channels, the cursor, resizing mid-session", "Showing the x86-64 screen: the framebuffer is declared and filled by the guest, the view is still to write", "Recording a console's certificate fingerprint from the connection itself", "A licence: none is chosen, so the source is there to read, not to reuse"],
    },
    explorer: ExplorerCopy {
        title: "Go further",
        docs: "Connect to a VM, pair the agent, boot Linux on the phone — step by step, and what to do when it does not work.",
        protocol: "The agent's HTTP API: routes, errors, pairing links and TLS — enough to write your own client.",
        architecture: "The decisions that hold the project up, and why each one was made.",
        faq: "Jailbreak, App Store, speed, hypervisors, licence: the questions people actually ask.",
        roadmap: "What is done, what comes next, and what stands in the way.",
        releases: "Every published version, and what it changed.",
        privacy: "What this site and the app keep, where, and what they never collect.",
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
    protocoles: ProtocolesCopy {
        title: "Trois protocoles, écrits pour un téléphone",
        lede: "Chaque client est écrit à la main d'après sa spécification, sans bibliothèque entre wisq et le fil — la compression, le rythme des entrées et la reconnexion sont donc pensés pour un téléphone en 4G, au lieu d'être hérités d'une visionneuse de bureau. Prenez celui que votre hôte parle déjà.",
        items: &[
            ProtocoleCopy {
                name: "VNC",
                reach: "QEMU, libvirt, VirtualBox, Proxmox, x11vnc, un Mac qui partage son écran — tout ce qui expose une console VNC.",
                points: &["RFB 3.8 avec l'authentification VNC par mot de passe", "Raw, CopyRect, RRE, Hextile, zlib, ZRLE, et Tight avec JPEG — sur des flux zlib qui vivent aussi longtemps que la session", "Mises à jour continues, curseur du serveur dessiné sur le téléphone, redimensionnement du bureau, presse-papiers", "Un mode bas débit qui demande les encodages qui compressent le plus"],
                caveat: "Le VNC nu circule en clair. Chaque machine peut être jointe en TLS à la place, épinglé sur une empreinte que vous saisissez si vous le voulez — ou rester dans un tunnel que vous avez déjà.",
            },
            ProtocoleCopy {
                name: "SPICE",
                reach: "Ce que libvirt et QEMU publient pour un invité de bureau — et ce que wisq-agent bureau installe pour vous.",
                points: &["Canaux principal, display, entrées et curseur, le pointeur sur une connexion à lui pour qu'il bouge encore quand l'écran est occupé", "LZ, GLZ et sa fenêtre, QUIC, LZ4, JPEG et les formes à palette ; opérations de dessin, flux vidéo, trois caches", "Le son dans les deux sens, le presse-papiers, et un fichier envoyé du téléphone vers l'invité", "Les fichiers de connexion .vv s'ouvrent directement en machine"],
                caveat: "Le presse-papiers, l'envoi de fichiers et un écran qui suit la taille du téléphone demandent spice-vdagent dans l'invité ; sans lui, wisq le dit au lieu d'échouer en silence.",
            },
            ProtocoleCopy {
                name: "RDP",
                reach: "Les invités Windows, et les fichiers .rdp que leurs hôtes remettent.",
                points: &["Négociation, MCS, échange de clés, licence et capacités", "Bitmaps RLE et entrées", "Mesuré contre un vrai serveur : il ouvre une session, négocie et peint l'écran"],
                caveat: "Seulement la sécurité historique de RDP, pour l'instant : elle n'authentifie pas le serveur, et un hôte qui exige NLA — ce que Windows fait par défaut aujourd'hui — est refusé en le nommant plutôt que contourné. NLA est sur la feuille de route.",
            },
        ],
    },
    machines: MachinesCopy {
        title: "Deux machines dans la poche",
        lede: "Toutes deux sont des interprètes — sans JIT, sans autorisation particulière — et toutes deux démarrent un vrai noyau Linux, non modifié, sur le téléphone, sans réseau ni hôte. wisq lit le fichier que vous lui donnez et choisit le cœur tout seul : vingt et une familles d'architectures reconnues, deux exécutées.",
        columns: ["", "RISC-V", "x86-64"],
        rows: &[
            ["Processeur", "rv32ima, un seul hart", "x86 64 bits, avec SSE2 et la pile x87"],
            ["Mémoire", "64 Mo par défaut, jusqu'à 2 Go", "ce que le téléphone peut céder — au plus deux gigaoctets de moins qu'il n'en a"],
            ["Périphériques", "UART 8250, minuteur CLINT, disque virtio", "UART 16550, 8259 et 8253, PCI, disque virtio"],
            ["Démarre", "un noyau Linux 6.1 nommu standard, jusqu'à son invite de connexion", "un noyau Alpine standard et son initramfs, jusqu'au shell de secours"],
            ["Horloge", "compte les instructions exécutées, donc chaque démarrage est identique", "la même règle : le 8253 avance sur les instructions, pas sur le temps réel"],
            ["Disque", "une image que vous importez, sur /dev/vda, lue sur place", "la même chose, par virtio-mmio"],
            ["Vérifié par", "un second interprète, en Swift, comparé à chaque point de contrôle en CI", "un vrai processeur : mêmes octets, même état, et sa réponse fait référence"],
        ],
        note: "Les vitesses citées sur ce site viennent d'un conteneur Linux, pas d'un iPhone : le chemin de code est celui que le téléphone exécute, le silicium ne l'est pas.",
    },
    compare: CompareCopy {
        title: "Pourquoi pas simplement UTM ?",
        lede: "UTM est excellent, et wisq lui emprunte son modèle tactile. Mais iOS n'accorde de mémoire exécutable qu'aux applications signées pour le développement : émuler un OS de bureau sur le téléphone y est interprété, donc lent d'un ordre de grandeur. C'est un plafond de plateforme, pas de qualité de code.",
        columns: ["Critère", "UTM SE", "wisq"],
        rows: &[["Exécution", "QEMU local, interprété", "sur l'hôte — ou un interprète local dédié"], ["Vitesse", "très lente (pas de JIT sur iOS)", "limitée par le réseau · ~0,3 s jusqu'à l'invite Linux en local"], ["App Store", "zone grise, règle 4.7", "client réseau + interprète, tous deux propres"], ["Licence", "GPL (QEMU)", "pas de QEMU dedans, donc pas de copyleft à porter"]],
    },
    toucher: TraitsCopy {
        title: "Fait pour un pouce",
        lede: "Un bureau attend une souris, et un clavier aux touches qu'un téléphone n'affiche jamais. Le modèle tactile est l'endroit où un client mobile se gagne ou se perd, donc chacune de ses parties est un réglage plutôt qu'un pari.",
        items: &[
            TraitCopy { term: "Trackpad ou toucher direct", detail: "Déplacez le pointeur comme sur le trackpad d'un portable, à la vitesse que vous réglez, ou mettez-le directement sous votre doigt." },
            TraitCopy { term: "Des gestes que vous choisissez", detail: "Appui long, tape à deux doigts, glissés à deux et trois doigts : chacun peut faire un clic gauche, droit ou milieu, glisser, défiler, déplacer l'écran ou appeler le clavier. D'origine, l'appui long et la tape à deux doigts font un clic droit, deux doigts défilent et trois déplacent l'écran." },
            TraitCopy { term: "L'inertie, et un clic qu'un invité voit", detail: "Le pointeur et la molette continuent sur leur lancée quand le doigt se lève, et chaque clic synthétisé tient le bouton 50 ms — un invité qui échantillonne ses entrées sur un minuteur ne voit rien de plus court." },
            TraitCopy { term: "Une barre de touches", detail: "Échap et Tab, Ctrl, Alt, Maj et ⌘ collantes, les flèches, Début, Fin, Page préc., Page suiv. et Suppr — et F1 à F12 à une tape." },
            TraitCopy { term: "Les claviers matériels", detail: "Les touches voyagent en keysyms X11 ; ⌘ devient la touche Super de l'invité, ou Contrôle si vos réflexes sont ceux de macOS." },
            TraitCopy { term: "L'écran", detail: "Ajusté, 1:1 avec déplacement, ou rempli ; demander au serveur la résolution du téléphone ; une qualité JPEG pour la 4G ; et un écran qui reste allumé le temps d'une session." },
        ],
    },
    how: HowCopy {
        title: "L'appairage",
        steps: &[StepCopy { title: "Lancez l'agent", body: "Il affiche un lien wisq:// par interface réseau — et un QR code si qrencode est installé. Il s'annonce aussi en Bonjour." }, StepCopy { title: "Scannez-le", body: "Ouvrir le lien sur l'iPhone atterrit directement dans l'écran d'import, adresse et jeton remplis, interrogation déjà lancée." }, StepCopy { title: "Tapez une VM", body: "Éteinte ? L'agent la démarre, wisq attend sa console et résout l'adresse tardivement — le port change d'un démarrage à l'autre." }],
    },
    securite: TraitsCopy {
        title: "La sécurité sans autorité de certification",
        lede: "Rien ici ne vous demande d'opérer une PKI, et rien ne prétend protéger ce qu'il ne protège pas.",
        items: &[
            TraitCopy { term: "TLS par défaut, épinglé", detail: "L'agent fabrique son propre certificat ; son empreinte SHA-256 voyage dans le lien d'appairage, et l'application l'épingle. --no-tls existe pour un tunnel qui chiffre déjà." },
            TraitCopy { term: "Un jeton gardé comme une clé", detail: "Engendré une fois, lisible par son seul propriétaire, et toutes les routes sont derrière lui. Révoquer un téléphone, c'est effacer un fichier et relancer l'agent." },
            TraitCopy { term: "Les mots de passe dans le trousseau", detail: "Le mot de passe d'une console vit dans le trousseau de l'iPhone, jamais dans la liste des machines." },
            TraitCopy { term: "Aucune rétrogradation silencieuse", detail: "Un réglage que wisq ne sait pas lire revient à sa valeur par défaut — sauf le protocole et la sécurité d'une machine, où un repli voudrait dire une connexion en clair que personne n'a demandée." },
            TraitCopy { term: "Les consoles, dites franchement", detail: "VNC et SPICE nus ne sont pas chiffrés, par conception, et la sécurité historique de RDP n'authentifie pas le serveur. Le guide le dit là où vous les configurez." },
            TraitCopy { term: "Aucune télémétrie", detail: "L'application se connecte aux machines et aux agents que vous ajoutez, et à rien d'autre. Ce site n'a ni mesure d'audience, ni cookie, ni tiers, et un test fait échouer la construction s'il en apparaît un." },
        ],
    },
    facts: FactsCopy {
        title: "Fait pour inspirer confiance",
        items: &[FactCopy { value: "2628", label: "tests" }, FactCopy { value: "7", label: "portes CI bloquantes" }, FactCopy { value: "0", label: "avertissement, concurrence stricte" }, FactCopy { value: "1", label: "vrai noyau démarré par exécution CI" }],
    },
    etat: EtatCopy {
        title: "Où en est le projet",
        lede: "Tout ce qui est dans la première liste est implémenté, testé et vert en CI. La seconde dit ce qui ne l'est pas — écrit plutôt que laissé à découvrir.",
        done_label: "Fait",
        done: &["VNC : RFB 3.8, tous les encodages courants, presse-papiers, redimensionnement", "SPICE : affichage, entrées, curseur, son dans les deux sens, presse-papiers, envoi de fichiers", "RDP : une session qui négocie, peint et prend les entrées", "La reconnexion aux changements de réseau, jamais sur un mot de passe refusé", "Un modèle tactile réglable, une barre de touches, les claviers matériels", "wisq-agent : démarrer et éteindre, lien d'appairage, QR, Bonjour, TLS", "wisq-agent bureau : un bureau SPICE à partir d'une image d'installation", "RISC-V local : un vrai noyau, un disque, la suspension et la reprise", "x86-64 local : un noyau Alpine et son initramfs, un disque, le clavier", "Un cœur de VM en Rust, comparé à celui en Swift en CI"],
        next_label: "Pas encore",
        next: &["RDP : NLA/CredSSP, les canaux virtuels, le curseur, le redimensionnement en cours de session", "Afficher l'écran du x86-64 : le cadre est déclaré et rempli par l'invité, la vue reste à écrire", "Relever l'empreinte du certificat d'une console depuis la connexion elle-même", "Une licence : aucune n'est choisie, donc le source est là pour être lu, pas réutilisé"],
    },
    explorer: ExplorerCopy {
        title: "Pour aller plus loin",
        docs: "Se connecter à une VM, appairer l'agent, démarrer Linux sur le téléphone — pas à pas, et quoi faire quand ça ne marche pas.",
        protocol: "L'API HTTP de l'agent : routes, erreurs, liens d'appairage et TLS — de quoi écrire votre propre client.",
        architecture: "Les décisions qui tiennent le projet debout, et pourquoi chacune a été prise.",
        faq: "Jailbreak, App Store, vitesse, hyperviseurs, licence : les questions qu'on pose vraiment.",
        roadmap: "Ce qui est fait, ce qui vient, et ce qui barre la route.",
        releases: "Chaque version publiée, et ce qu'elle a changé.",
        privacy: "Ce que ce site et l'application gardent, où, et ce qu'ils ne collectent jamais.",
    },
};
