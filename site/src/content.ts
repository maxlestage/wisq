/// All copy lives here, in both languages, so components stay layout-only and
/// nothing can drift between versions: a missing translation is a type error
/// rather than an English string leaking into the French page.

export type Lang = "en" | "fr";

export interface Command {
  label: string;
  code: string;
  note?: string;
}

export interface Copy {
  nav: { install: string; how: string; source: string; language: string };
  /// The theme control. Every label is a real accessible name — the buttons
  /// show icons, and an icon with no name is a button a screen reader cannot
  /// announce.
  theme: { label: string; light: string; dark: string; auto: string };
  hero: { tagline: string; lede: string; ctaInstall: string; ctaSource: string; badge: string };
  modes: {
    title: string;
    remote: { name: string; head: string; body: string; points: string[] };
    local: { name: string; head: string; body: string; points: string[] };
  };
  compare: {
    title: string;
    lede: string;
    columns: [string, string, string];
    rows: [string, string, string][];
  };
  install: {
    title: string;
    lede: string;
    tabs: { iphone: string; mac: string; linux: string };
    iphone: { intro: string; commands: Command[] };
    mac: { intro: string; commands: Command[] };
    linux: { intro: string; commands: Command[] };
    releaseLink: string;
    copy: string;
    copied: string;
  };
  how: { title: string; steps: { title: string; body: string }[] };
  facts: { title: string; items: { value: string; label: string }[] };
  footer: {
    license: string;
    source: string;
    docs: string;
    note: string;
    /// A one-line description under the wordmark, for a reader who arrived at
    /// the footer without reading the page above it.
    tagline: string;
    groups: { product: string; documentation: string; project: string };
    links: {
      install: string;
      issues: string;
      contributing: string;
      security: string;
      changelog: string;
      privacy: string;
    };
    /// Stated because it is true and checkable, not as a slogan: a test fails
    /// the build if any third-party address appears in the built site.
    privacyNote: string;
    /// Who wrote this. Kept distinct from `attribution`, which credits the
    /// work of others: one line saying what is mine must never read as a
    /// claim over what is not.
    author: string;
    attribution: string;
    backToTop: string;
    version: string;
  };
  /// Navigation labels for the written pages, keyed by route.
  pages: {
    home: string;
    notFound: string;
    docs: string;
    protocol: string;
    architecture: string;
    faq: string;
    roadmap: string;
    releases: string;
    privacy: string;
    offline: string;
  };
  /// The install affordance. Two shapes, because the platforms differ: a
  /// browser that fires beforeinstallprompt gets a button, and iOS — which
  /// never fires it, and is the platform this project is about — gets the
  /// three taps that actually work there.
  pwa: {
    title: string;
    body: string;
    action: string;
    iosTitle: string;
    iosBody: string;
    dismiss: string;
  };
}

const en: Copy = {
  nav: { install: "Install", how: "How it works", source: "Source", language: "Language" },
  theme: { label: "Theme", light: "Light", dark: "Dark", auto: "Match system" },
  hero: {
    tagline: "Virtual machines on your iPhone.",
    lede:
      "Reach a VM running on your Mac, PC or NAS at full speed — or boot a real Linux kernel on the phone itself, offline.",
    ctaInstall: "Install",
    ctaSource: "View source",
    badge: "Apache-2.0 · Swift + Rust · open source",
  },
  modes: {
    title: "Two ways, one app",
    remote: {
      name: "Remote",
      head: "The VM runs where the silicon is",
      body:
        "A hand-written VNC client built for a phone: compressed encodings so it stays usable on cellular, and a touch model that actually hits small buttons.",
      points: [
        "ZRLE, Tight with JPEG, zlib — over session-lived streams",
        "Reconnects through cell handoffs, never retries a bad password",
        "Trackpad-style pointer with inertia, hardware keyboard support",
        "A host agent boots a powered-off VM when you tap it",
      ],
    },
    local: {
      name: "Local",
      head: "A real Linux kernel, on the phone",
      body:
        "An interpreted RISC-V machine boots Linux to a login prompt in a fraction of a second — around 160 million guest instructions a second. No JIT, so nothing about it fights the platform, and nothing about it needs a jailbreak.",
      points: [
        "rv32ima core, 64 MB, 8250 UART, CLINT timer",
        "Boots a stock Linux 6.1 nommu kernel to a login prompt",
        "Entirely offline — no server, no network",
        "CI boots that kernel on every commit, as a test",
      ],
    },
  },
  compare: {
    title: "Why not just use UTM?",
    lede:
      "UTM is excellent, and wisq borrows from its touch design. But iOS grants executable memory only to development-signed apps, so emulating a desktop OS on the phone is interpreted and an order of magnitude slow. That is a platform ceiling, not a code-quality one.",
    columns: ["Aspect", "UTM SE", "wisq"],
    rows: [
      ["Execution", "local QEMU, interpreted", "on the host — or a purpose-built local interpreter"],
      ["Speed", "very slow (no JIT on iOS)", "network-bound remote · ~1 s to a Linux shell locally"],
      ["App Store", "grey area, rule 4.7", "network client + interpreter, both clean"],
      ["License", "GPL (QEMU)", "Apache-2.0, all first-party code"],
    ],
  },
  install: {
    title: "Install",
    lede: "The agent installs in one line. The app sideloads until there is an App Store listing.",
    tabs: { iphone: "iPhone", mac: "Mac", linux: "Linux" },
    iphone: {
      intro:
        "Grab the unsigned IPA from the latest release and install it with AltStore or Sideloadly — they re-sign it with your own Apple ID. With a Mac and Xcode you can also build straight onto a connected phone.",
      commands: [
        {
          label: "Build onto a connected iPhone",
          code: "git clone https://github.com/maxlestage/wisq.git\ncd wisq && ./scripts/install-ios.sh",
          note: "Free personal signatures expire after 7 days; re-run to refresh.",
        },
      ],
    },
    mac: {
      intro:
        "The host agent is what lets the phone power VMs on. Homebrew keeps it updated and runs it as a service.",
      commands: [
        {
          label: "Homebrew",
          code:
            "brew tap maxlestage/wisq https://github.com/maxlestage/wisq.git\nbrew install maxlestage/wisq/wisq-agent\nbrew services start wisq-agent",
        },
        {
          label: "One-line installer",
          code:
            "curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh -s -- --service",
          note: "Installs a LaunchAgent; the pairing token lands in ~/Library/Logs/wisq-agent.log",
        },
      ],
    },
    linux: {
      intro: "Same installer, systemd instead of launchd. It drives libvirt through virsh when present.",
      commands: [
        {
          label: "One-line installer",
          code:
            "curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh -s -- --service",
          note: "Pairing token: journalctl --user -u wisq-agent",
        },
        {
          label: "Try it without a hypervisor",
          code: "wisq-agent --demo",
          note: "Two fake VMs with real state transitions.",
        },
      ],
    },
    releaseLink: "Download the latest release",
    copy: "Copy",
    copied: "Copied",
  },
  how: {
    title: "How pairing works",
    steps: [
      {
        title: "Run the agent",
        body:
          "It prints a wisq:// link per network interface — and a QR code when qrencode is installed. It also announces itself over Bonjour.",
      },
      {
        title: "Scan it",
        body:
          "Opening the link on the iPhone lands directly in the import screen, address and token filled in, already querying.",
      },
      {
        title: "Tap a VM",
        body:
          "Powered off? The agent boots it, wisq waits for the console and resolves the endpoint late — the port moves between boots.",
      },
    ],
  },
  facts: {
    title: "Built to be trusted",
    items: [
      { value: "181", label: "tests" },
      { value: "5", label: "blocking CI gates" },
      { value: "0", label: "warnings, strict concurrency" },
      { value: "1", label: "real kernel booted per CI run" },
    ],
  },
  footer: {
    license: "Apache-2.0",
    tagline:
      "Virtual machines on your iPhone: remote at full speed, or a real Linux kernel on the phone itself.",
    groups: { product: "Product", documentation: "Documentation", project: "Project" },
    links: {
      install: "Install",
      issues: "Issues",
      contributing: "Contributing",
      security: "Security",
      changelog: "Changelog",
      privacy: "Privacy",
    },
    privacyNote:
      "No analytics, no cookies, no third-party requests. This page loaded nothing from anyone else.",
    author: "Created and developed by",
    attribution: "RISC-V execution semantics ported from mini-rv32ima by Charles Lohr (MIT).",
    backToTop: "Back to top",
    version: "Version",
    source: "Source",
    docs: "Docs",
    note:
      "The agent speaks TLS by default, pinned by the pairing link — no certificate authority to run. Plain VNC itself stays unencrypted: trusted network or tunnel for the console.",
  },

  pages: {
    home: "Home",
    notFound: "Not found",
    docs: "Guide",
    protocol: "Agent protocol",
    architecture: "Architecture",
    faq: "Questions",
    roadmap: "Roadmap",
    releases: "Releases",
    privacy: "Privacy",
    offline: "Offline",
  },
  pwa: {
    title: "Keep wisq one tap away",
    body: "Install this site and it opens like an app, works without a network, and stops asking.",
    action: "Install",
    iosTitle: "Add to your Home Screen",
    iosBody: "Tap the Share button, then Add to Home Screen.",
    dismiss: "Not now",
  },
};

const fr: Copy = {
  nav: { install: "Installer", how: "Fonctionnement", source: "Sources", language: "Langue" },
  theme: { label: "Thème", light: "Clair", dark: "Sombre", auto: "Selon le système" },
  hero: {
    tagline: "Des machines virtuelles sur votre iPhone.",
    lede:
      "Atteignez à pleine vitesse une VM qui tourne sur votre Mac, PC ou NAS — ou faites démarrer un vrai noyau Linux sur le téléphone lui-même, hors ligne.",
    ctaInstall: "Installer",
    ctaSource: "Voir les sources",
    badge: "Apache-2.0 · Swift + Rust · open source",
  },
  modes: {
    title: "Deux voies, une application",
    remote: {
      name: "Distant",
      head: "La VM tourne là où il y a du silicium",
      body:
        "Un client VNC écrit à la main pour un téléphone : des encodages compressés pour rester utilisable en 4G, et un modèle tactile qui atteint vraiment les petits boutons.",
      points: [
        "ZRLE, Tight avec JPEG, zlib — sur des flux persistants",
        "Reconnexion aux changements de réseau, jamais sur un mot de passe refusé",
        "Pointeur type trackpad avec inertie, clavier matériel géré",
        "Un agent hôte démarre une VM éteinte quand vous la tapez",
      ],
    },
    local: {
      name: "Local",
      head: "Un vrai noyau Linux, sur le téléphone",
      body:
        "Une machine RISC-V interprétée amène Linux jusqu'à l'invite de connexion en une fraction de seconde — environ 160 millions d'instructions invitées par seconde. Sans JIT, donc rien n'entre en conflit avec la plateforme, et rien n'exige de jailbreak.",
      points: [
        "Cœur rv32ima, 64 Mo, UART 8250, minuteur CLINT",
        "Démarre un noyau Linux 6.1 nommu standard jusqu'à l'invite",
        "Entièrement hors ligne — aucun serveur, aucun réseau",
        "La CI démarre ce noyau à chaque commit, comme test",
      ],
    },
  },
  compare: {
    title: "Pourquoi pas simplement UTM ?",
    lede:
      "UTM est excellent, et wisq lui emprunte son modèle tactile. Mais iOS n'accorde de mémoire exécutable qu'aux applications signées pour le développement : émuler un OS de bureau sur le téléphone y est interprété, donc lent d'un ordre de grandeur. C'est un plafond de plateforme, pas de qualité de code.",
    columns: ["Critère", "UTM SE", "wisq"],
    rows: [
      ["Exécution", "QEMU local, interprété", "sur l'hôte — ou un interprète local dédié"],
      ["Vitesse", "très lente (pas de JIT sur iOS)", "limitée par le réseau · ~1 s jusqu'au shell en local"],
      ["App Store", "zone grise, règle 4.7", "client réseau + interprète, tous deux propres"],
      ["Licence", "GPL (QEMU)", "Apache-2.0, tout le code est premier parti"],
    ],
  },
  install: {
    title: "Installer",
    lede:
      "L'agent s'installe en une ligne. L'application se sideload tant qu'il n'y a pas de fiche App Store.",
    tabs: { iphone: "iPhone", mac: "Mac", linux: "Linux" },
    iphone: {
      intro:
        "Récupérez l'IPA non signé de la dernière release et installez-le avec AltStore ou Sideloadly — ils le re-signent avec votre Apple ID. Avec un Mac et Xcode, vous pouvez aussi compiler directement sur le téléphone branché.",
      commands: [
        {
          label: "Compiler sur l'iPhone branché",
          code: "git clone https://github.com/maxlestage/wisq.git\ncd wisq && ./scripts/install-ios.sh",
          note: "Les signatures personnelles gratuites expirent au bout de 7 jours ; relancez pour renouveler.",
        },
      ],
    },
    mac: {
      intro:
        "L'agent hôte est ce qui permet au téléphone d'allumer les VM. Homebrew le tient à jour et le lance en service.",
      commands: [
        {
          label: "Homebrew",
          code:
            "brew tap maxlestage/wisq https://github.com/maxlestage/wisq.git\nbrew install maxlestage/wisq/wisq-agent\nbrew services start wisq-agent",
        },
        {
          label: "Installeur en une ligne",
          code:
            "curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh -s -- --service",
          note: "Installe un LaunchAgent ; le jeton d'appairage atterrit dans ~/Library/Logs/wisq-agent.log",
        },
      ],
    },
    linux: {
      intro:
        "Le même installeur, systemd au lieu de launchd. Il pilote libvirt via virsh quand il est présent.",
      commands: [
        {
          label: "Installeur en une ligne",
          code:
            "curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh -s -- --service",
          note: "Jeton d'appairage : journalctl --user -u wisq-agent",
        },
        {
          label: "Essayer sans hyperviseur",
          code: "wisq-agent --demo",
          note: "Deux VM factices avec de vraies transitions d'état.",
        },
      ],
    },
    releaseLink: "Télécharger la dernière release",
    copy: "Copier",
    copied: "Copié",
  },
  how: {
    title: "L'appairage",
    steps: [
      {
        title: "Lancez l'agent",
        body:
          "Il affiche un lien wisq:// par interface réseau — et un QR code si qrencode est installé. Il s'annonce aussi en Bonjour.",
      },
      {
        title: "Scannez-le",
        body:
          "Ouvrir le lien sur l'iPhone atterrit directement dans l'écran d'import, adresse et jeton remplis, interrogation déjà lancée.",
      },
      {
        title: "Tapez une VM",
        body:
          "Éteinte ? L'agent la démarre, wisq attend sa console et résout l'adresse tardivement — le port change d'un démarrage à l'autre.",
      },
    ],
  },
  facts: {
    title: "Fait pour inspirer confiance",
    items: [
      { value: "181", label: "tests" },
      { value: "5", label: "portes CI bloquantes" },
      { value: "0", label: "avertissement, concurrence stricte" },
      { value: "1", label: "vrai noyau démarré par exécution CI" },
    ],
  },
  footer: {
    license: "Apache-2.0",
    tagline:
      "Des machines virtuelles sur votre iPhone : à distance à pleine vitesse, ou un vrai noyau Linux sur le téléphone lui-même.",
    groups: { product: "Produit", documentation: "Documentation", project: "Projet" },
    links: {
      install: "Installer",
      issues: "Signalements",
      contributing: "Contribuer",
      security: "Sécurité",
      changelog: "Journal",
      privacy: "Confidentialité",
    },
    privacyNote:
      "Aucune mesure d'audience, aucun cookie, aucune requête tierce. Cette page n'a rien chargé chez qui que ce soit.",
    author: "Créé et développé par",
    attribution: "Sémantique d'exécution RISC-V portée de mini-rv32ima, de Charles Lohr (MIT).",
    backToTop: "Haut de page",
    version: "Version",
    source: "Sources",
    docs: "Docs",
    note:
      "L'agent parle TLS par défaut, épinglé par le lien d'appairage — aucune autorité de certification à exploiter. Le VNC nu reste non chiffré : réseau de confiance ou tunnel pour la console.",
  },

  pages: {
    home: "Accueil",
    notFound: "Page introuvable",
    docs: "Guide",
    protocol: "Protocole de l'agent",
    architecture: "Architecture",
    faq: "Questions",
    roadmap: "Feuille de route",
    releases: "Versions",
    privacy: "Confidentialité",
    offline: "Hors ligne",
  },
  pwa: {
    title: "Gardez wisq à une touche",
    body: "Installez ce site : il s'ouvre comme une application, fonctionne sans réseau, et cesse de demander.",
    action: "Installer",
    iosTitle: "Ajouter à l'écran d'accueil",
    iosBody: "Touchez le bouton Partager, puis « Sur l'écran d'accueil ».",
    dismiss: "Plus tard",
  },
};

export const copy: Record<Lang, Copy> = { en, fr };

export const REPO = "https://github.com/maxlestage/wisq";

/// The author, as the repository already states it in NOTICE and LICENSE.
/// One place, so the site cannot disagree with the copyright line.
export const AUTHOR = "Maxime Nathan Lestage";
export const AUTHOR_URL = "https://github.com/maxlestage";
export const RELEASES = `${REPO}/releases/latest`;
export const DOCS = `${REPO}/tree/master/docs`;
export const ISSUES = `${REPO}/issues`;
export const CONTRIBUTING = `${REPO}/blob/master/CONTRIBUTING.md`;
export const SECURITY = `${REPO}/blob/master/SECURITY.md`;
export const CHANGELOG = `${REPO}/blob/master/CHANGELOG.md`;

/// The version the footer shows. Checked against CHANGELOG.md by a test, so it
/// cannot quietly describe a release the repository does not have.
export const SITE_VERSION = "0.3.0";
