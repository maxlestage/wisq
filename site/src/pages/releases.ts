import type { Doc } from "../doc";

/// Versions listed on the page. A test checks each one has a dated section in
/// CHANGELOG.md, so this page cannot quietly fall behind the repository.
export const RELEASED_VERSIONS = ["0.3.0", "0.2.0", "0.1.1", "0.1.0"] as const;

export const releasesEn: Doc = {
  title: "Releases",
  lede: "What changed, and why. Every version attaches the agent for Linux and macOS and an unsigned IPA.",
  blocks: [
    {
      kind: "p",
      text:
        "Versions follow semantic versioning. Before 1.0.0 a minor version may break an API — the changelog says when one does.",
    },

    { kind: "h2", text: "0.3.0" },
    {
      kind: "p",
      text:
        "The local machine now runs a Rust interpreter, and the agent no longer talks in the clear. The rv32ima core exists twice — Swift and Rust — and a differential test boots the same kernel through both, comparing retired instructions and console bytes at every checkpoint, which is what makes preferring the faster one a measurement rather than a taste.",
    },
    {
      kind: "ul",
      items: [
        "The Rust core is the default and what the app ships: about 8% faster over a full boot. WISQ_SWIFT_CORE=1 returns to the Swift one; a missing library stops the build with the command to run, so which interpreter ships never depends on what the build machine happened to have.",
        "That differential test found a real defect on the day it was written: the Rust bus answered CLINT mtime from a snapshot taken before the step advanced the clock, so the guest read a clock behind its own machine — by a whole idle period after a wait-for-interrupt jump.",
        "The core is proven where it runs: an XCFramework with device, simulator and macOS slices, and a real Linux kernel booted through the C ABI inside a booted iPhone simulator on every commit.",
        "The agent speaks TLS. A self-signed certificate on first run, its SHA-256 fingerprint carried in the wisq:// pairing link, pinned by the app — no authority to operate. A malformed fingerprint is an error, never a silent downgrade to plain HTTP.",
        "The local console is a real terminal: cursor addressing, erases, scroll region, alternate screen, deferred wrap. Editors, pagers and top now behave instead of smearing.",
        "The site is bilingual throughout, with a light/dark/system theme control and a privacy page that can be checked rather than believed.",
      ],
    },

    { kind: "h2", text: "0.2.0" },
    {
      kind: "p",
      text:
        "The local machine got about three times faster: 55 to 163 million guest instructions a second, boot to a login prompt from 0.81 s to 0.27 s, for the same 44.6 million instructions. The semantics did not move — only the cost of running them.",
    },
    {
      kind: "ul",
      items: [
        "The register file moved off a Swift array, which the optimiser was reloading after every opaque call. That alone was 2.7×.",
        "Immediates are sign-extended by an arithmetic shift rather than a test-and-OR, removing a branch from the paths that are 85% of a boot.",
        "Guest RAM is mapped rather than allocated and cleared: construction went from 33–194 ms to under 0.1 ms, and the app no longer commits 64 MB before the guest has touched a page.",
        "The emulation thread declares its quality of service, so the scheduler stops parking an interpreter on an efficiency core.",
        "The console became incremental. The old one re-derived the visible text on every arrival — quadratic in the output, 36.7 s of processing for 2 000 lines against 0.22 s now.",
      ],
    },

    { kind: "h2", text: "0.1.1" },
    {
      kind: "p",
      text:
        "A fix for a defect found by downloading the release and running it: the Linux agent was dynamically linked, so it needed libswiftCore.so on the target machine and died on its first line anywhere that had never installed a Swift toolchain.",
    },
    {
      kind: "ul",
      items: [
        "The Linux binary is statically linked and verified under an empty environment in the release job itself, so a regression fails the release rather than the user.",
        "The installer runs the downloaded binary before installing it and falls back to a source build if it will not start.",
      ],
    },

    { kind: "h2", text: "0.1.0" },
    {
      kind: "p",
      text:
        "The first release: the VNC client, the local RISC-V machine, the host agent, and the project foundations.",
    },
    {
      kind: "ul",
      items: [
        "A hand-written RFB 3.8 client — handshake, DES authentication, Raw, CopyRect, RRE, Hextile, zlib, ZRLE and Tight with JPEG, over session-lived zlib streams.",
        "Continuous updates, server cursor drawn locally, desktop resize, clipboard, and reconnection that never retries an authentication failure.",
        "An interpreted rv32ima machine that boots a real Linux 6.1 nommu kernel to a shell.",
        "The host agent, boot-before-connect, wisq:// pairing links and Bonjour discovery.",
        "Apache-2.0, a changelog, a release workflow, and CI that boots a real kernel as a test.",
      ],
    },
  ],
};

export const releasesFr: Doc = {
  title: "Versions",
  lede: "Ce qui a changé, et pourquoi. Chaque version attache l'agent pour Linux et macOS ainsi qu'une IPA non signée.",
  blocks: [
    {
      kind: "p",
      text:
        "Les versions suivent le versionnage sémantique. Avant 1.0.0, une version mineure peut rompre une API — le journal le signale quand c'est le cas.",
    },

    { kind: "h2", text: "0.3.0" },
    {
      kind: "p",
      text:
        "La machine locale tourne désormais sur un interpréteur Rust, et l'agent ne parle plus en clair. Le cœur rv32ima existe en double — Swift et Rust — et un test différentiel démarre le même noyau à travers les deux, en comparant les instructions retirées et les octets de console à chaque point de contrôle : c'est ce qui fait de la préférence pour le plus rapide une mesure et non un goût.",
    },
    {
      kind: "ul",
      items: [
        "Le cœur Rust est le défaut et ce que l'application embarque : environ 8 % plus rapide sur un démarrage complet. WISQ_SWIFT_CORE=1 rend le cœur Swift ; une bibliothèque absente arrête la construction avec la commande à lancer, pour que l'interprète expédié ne dépende jamais de ce que la machine de build avait sous la main.",
        "Ce test différentiel a trouvé un vrai défaut le jour où il a été écrit : le bus Rust répondait aux lectures CLINT mtime avec un instantané pris avant que le pas n'avance l'horloge, donc l'invité lisait une horloge en retard sur sa propre machine — de toute une période d'inactivité après un réveil de WFI.",
        "Le cœur est prouvé là où il tourne : un XCFramework avec les tranches appareil, simulateur et macOS, et un vrai noyau Linux démarré à travers l'ABI C dans un iPhone simulé, à chaque commit.",
        "L'agent parle TLS. Un certificat auto-signé au premier lancement, son empreinte SHA-256 portée par le lien d'appairage wisq://, épinglée par l'application — aucune autorité à opérer. Une empreinte malformée est une erreur, jamais un repli silencieux vers HTTP en clair.",
        "La console locale est un vrai terminal : adressage curseur, effacements, région de défilement, écran alterné, retour à la ligne différé. Les éditeurs, les pagers et top se comportent enfin au lieu de baver.",
        "Le site est bilingue de bout en bout, avec un contrôle de thème clair/sombre/système et une page vie privée vérifiable plutôt que déclarative.",
      ],
    },

    { kind: "h2", text: "0.2.0" },
    {
      kind: "p",
      text:
        "La machine locale est environ trois fois plus rapide : de 55 à 163 millions d'instructions invitées par seconde, un démarrage jusqu'à l'invite de connexion passé de 0,81 s à 0,27 s, pour les mêmes 44,6 millions d'instructions. La sémantique n'a pas bougé — seulement son coût.",
    },
    {
      kind: "ul",
      items: [
        "Le fichier de registres a quitté le tableau Swift, que l'optimiseur rechargeait après chaque appel opaque. 2,7× à lui seul.",
        "Les immédiats sont étendus en signe par un décalage arithmétique plutôt qu'un test-et-OR, ce qui retire un branchement des chemins qui font 85 % d'un démarrage.",
        "La RAM invitée est mappée au lieu d'être allouée puis effacée : la construction passe de 33–194 ms à moins de 0,1 ms, et l'application n'engage plus 64 Mo avant que l'invité n'ait touché une page.",
        "Le fil d'émulation déclare sa qualité de service, pour que l'ordonnanceur cesse de poser un interpréteur sur un cœur d'efficience.",
        "La console est devenue incrémentale. L'ancienne re-dérivait le texte visible à chaque arrivée — quadratique dans la sortie, 36,7 s de traitement pour 2 000 lignes contre 0,22 s aujourd'hui.",
      ],
    },

    { kind: "h2", text: "0.1.1" },
    {
      kind: "p",
      text:
        "Un correctif pour un défaut trouvé en téléchargeant la release et en la lançant : l'agent Linux était lié dynamiquement, réclamait donc libswiftCore.so sur la machine cible et mourait à sa première ligne partout où aucune toolchain Swift n'avait jamais été installée.",
    },
    {
      kind: "ul",
      items: [
        "Le binaire Linux est lié statiquement et vérifié sous environnement vide dans le job de release lui-même : une régression fait échouer la release, pas l'utilisateur.",
        "L'installeur lance le binaire téléchargé avant de l'installer et retombe sur une construction depuis les sources s'il ne démarre pas.",
      ],
    },

    { kind: "h2", text: "0.1.0" },
    {
      kind: "p",
      text:
        "La première version : le client VNC, la machine RISC-V locale, l'agent hôte et les fondations du projet.",
    },
    {
      kind: "ul",
      items: [
        "Un client RFB 3.8 écrit à la main — poignée de main, authentification DES, Raw, CopyRect, RRE, Hextile, zlib, ZRLE et Tight avec JPEG, sur des flux zlib qui vivent le temps de la session.",
        "Mises à jour continues, curseur serveur dessiné localement, redimensionnement, presse-papiers, et une reconnexion qui ne réessaie jamais après un échec d'authentification.",
        "Une machine rv32ima interprétée qui amène un vrai noyau Linux 6.1 nommu jusqu'à un shell.",
        "L'agent hôte, le démarrage-avant-connexion, les liens d'appairage wisq:// et la découverte Bonjour.",
        "Apache-2.0, un journal des modifications, un workflow de release, et une CI qui démarre un vrai noyau comme test.",
      ],
    },
  ],
};
