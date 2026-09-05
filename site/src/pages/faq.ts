import type { Doc } from "../doc";

export const faqEn: Doc = {
  title: "Questions",
  lede: "The ones worth answering plainly, including where wisq is weaker than the alternatives.",
  blocks: [
    { kind: "h2", text: "Does this need a jailbreak?" },
    {
      kind: "p",
      text:
        "No. Neither half of wisq does anything a normal application cannot. The remote side is a network client. The local side is an interpreter, which needs no executable memory and therefore no entitlement — the same ground iSH stands on.",
    },

    { kind: "h2", text: "Is it on the App Store?" },
    {
      kind: "p",
      text:
        "Not yet. The build is designed to be admissible — no JIT, no downloaded code, and no QEMU inside to carry GPL obligations — but designed to be admissible and accepted are different things. There is no public build yet.",
    },

    { kind: "h2", text: "Why not just ship QEMU?" },
    {
      kind: "p",
      text:
        "Two reasons, and the licence is the smaller one. QEMU is GPL, which constrains what an App Store binary can be; that is why UTM SE sits in a grey area. The larger reason is that a general emulator interpreting a modern desktop operating system on a phone is slow enough to be a demo rather than a tool. wisq splits the problem instead: the desktop runs where the silicon is, and what runs locally is a machine small enough to be genuinely fast.",
    },

    { kind: "h2", text: "How fast is the local machine, really?" },
    {
      kind: "p",
      text:
        "Around 160 million guest instructions a second, reaching a Linux login prompt after 44.6 million instructions — roughly a quarter of a second. That figure comes from an x86_64 Linux container, not from a phone: no iPhone has been in that measurement loop, and an A-series core is a different machine.",
    },

    { kind: "h2", text: "What can the local machine actually run?" },
    {
      kind: "p",
      text:
        "A real Linux kernel with a real shell, on a 32-bit RISC-V machine with no MMU and 64 MB of RAM. That is a working Unix — busybox, shell scripts, a compiler if you build one in. It is not a desktop, and it will not run anything compiled for x86 or ARM.",
    },

    { kind: "h2", text: "Can the local machine keep files?" },
    {
      kind: "p",
      text:
        "Two answers, and they are not the same thing. The machine itself is saved: set aside when the screen locks, it comes back with your shell exactly where it was, mid-command if that is where you left it — no second boot. And since recently it can also have a disk: a filesystem image you import, seen on /dev/vda, that the guest reads and writes, with those writes carried inside the snapshot. What wisq cannot do is put a block driver into the kernel you brought. Many rv32 nommu kernels have none, and one that has none will never touch the device — so wisq counts the requests and tells you at the end, instead of leaving you with a silent disk.",
    },

    { kind: "h2", text: "Is my connection encrypted?" },
    {
      kind: "p",
      text:
        "The agent side, yes: the daemon speaks TLS by default behind its mandatory token, with a self-signed certificate whose fingerprint travels in the pairing link — the app pins exactly that certificate, so there is no authority to run. The consoles themselves stay unencrypted by design, VNC and SPICE alike: for those, use a network you trust or a tunnel you already run.",
    },

    { kind: "h2", text: "Where are my passwords kept?" },
    {
      kind: "p",
      text:
        "In the iPhone Keychain, referenced by name from the machine list. The list itself is plain JSON and contains no secret, so it can be inspected, backed up or synced without leaking anything.",
    },

    { kind: "h2", text: "Do I need the agent?" },
    {
      kind: "p",
      text:
        "Only if you want a powered-off VM to boot when you tap it. Without it wisq connects to consoles that are already up, which is all a VNC client normally does.",
    },

    { kind: "h2", text: "Which hypervisors work?" },
    {
      kind: "p",
      text:
        "For connecting: anything with a VNC or SPICE console — which between them covers what nearly every hypervisor publishes. For booting on demand: the agent drives libvirt through the virsh command line, so anything libvirt manages — QEMU/KVM, Xen, LXC. Other backends are a small amount of code behind one interface.",
    },

    { kind: "h2", text: "Is there an Android version?" },
    {
      kind: "p",
      text:
        "No, and it is not planned. The parts that would port are already portable — the daemon and the interpreter are Rust with no platform dependencies — but the app is the product, and it is built for one platform properly rather than two badly.",
    },

    { kind: "h2", text: "What licence?" },
    {
      kind: "p",
      text:
        "None yet. Nothing here grants rights to reuse this code, and no licence has been chosen; that decision is still the author's to make. The RISC-V execution semantics are a port of mini-rv32ima by Charles Lohr (MIT), credited in NOTICE; no third-party code is vendored.",
    },

    { kind: "h2", text: "How do I report something?" },
    {
      kind: "p",
      text:
        "Get in touch. Wrong colours, a guest that connects but stays black, a protocol message the client rejects — those are bugs on our side and the kind that are hard to find without someone else's hardware.",
    },
  ],
};

export const faqFr: Doc = {
  title: "Questions",
  lede: "Celles qui méritent une réponse franche, y compris là où wisq est plus faible que les solutions existantes.",
  blocks: [
    { kind: "h2", text: "Faut-il un jailbreak ?" },
    {
      kind: "p",
      text:
        "Non. Aucune des deux moitiés de wisq ne fait quoi que ce soit qu'une application ordinaire ne puisse faire. Le côté distant est un client réseau. Le côté local est un interpréteur, qui n'a besoin d'aucune mémoire exécutable et donc d'aucune autorisation particulière — le terrain sur lequel iSH se tient déjà.",
    },

    { kind: "h2", text: "Est-ce sur l'App Store ?" },
    {
      kind: "p",
      text:
        "Pas encore. La construction est pensée pour être recevable — pas de JIT, pas de code téléchargé, et pas de QEMU dedans pour porter des obligations GPL — mais pensée pour être recevable et acceptée sont deux choses différentes. Il n'y a pas encore de version publique.",
    },

    { kind: "h2", text: "Pourquoi ne pas simplement embarquer QEMU ?" },
    {
      kind: "p",
      text:
        "Deux raisons, et la licence est la moindre. QEMU est sous GPL, ce qui contraint ce qu'un binaire App Store peut être ; c'est pourquoi UTM SE occupe une zone grise. La raison plus lourde est qu'un émulateur généraliste interprétant un système de bureau moderne sur un téléphone est lent au point d'être une démonstration plutôt qu'un outil. wisq découpe le problème autrement : le bureau tourne là où il y a du silicium, et ce qui tourne localement est une machine assez petite pour être réellement rapide.",
    },

    { kind: "h2", text: "Quelle est vraiment la vitesse de la machine locale ?" },
    {
      kind: "p",
      text:
        "Environ 160 millions d'instructions invitées par seconde, avec une invite de connexion Linux atteinte après 44,6 millions d'instructions — de l'ordre du quart de seconde. Ce chiffre vient d'un conteneur Linux x86_64, pas d'un téléphone : aucun iPhone n'est passé par cette boucle de mesure, et un cœur A-series est une autre machine.",
    },

    { kind: "h2", text: "Que peut réellement faire tourner la machine locale ?" },
    {
      kind: "p",
      text:
        "Un vrai noyau Linux avec un vrai shell, sur une machine RISC-V 32 bits sans MMU et 64 Mo de RAM. C'est un Unix qui fonctionne — busybox, scripts shell, un compilateur si vous en intégrez un. Ce n'est pas un bureau, et cela n'exécutera rien de compilé pour x86 ou ARM.",
    },

    { kind: "h2", text: "La machine locale peut-elle garder des fichiers ?" },
    {
      kind: "p",
      text:
        "Deux réponses, et ce n'est pas la même chose. La machine elle-même est sauvée : mise de côté quand l'écran se verrouille, elle revient avec votre shell exactement où il était, au milieu d'une commande si c'est là que vous l'avez laissée — pas de second démarrage. Et depuis peu elle peut aussi avoir un disque : une image de système de fichiers que vous importez, vue sur /dev/vda, que l'invité lit et écrit, et dont les écritures voyagent dans l'instantané. Ce que wisq ne peut pas faire, c'est mettre un pilote bloc dans le noyau que vous apportez. Beaucoup de noyaux rv32 nommu n'en ont pas, et un noyau qui n'en a pas ne touchera jamais le périphérique — alors wisq compte les requêtes et vous le dit à la fin, au lieu de vous laisser devant un disque muet.",
    },

    { kind: "h2", text: "Ma connexion est-elle chiffrée ?" },
    {
      kind: "p",
      text:
        "Côté agent, oui : le démon parle TLS par défaut derrière son jeton obligatoire, avec un certificat auto-signé dont l'empreinte voyage dans le lien d'appairage — l'app épingle exactement ce certificat, donc aucune autorité à exploiter. Les consoles elles-mêmes restent non chiffrées par construction, VNC comme SPICE : pour elles, réseau de confiance ou tunnel existant.",
    },

    { kind: "h2", text: "Où sont conservés mes mots de passe ?" },
    {
      kind: "p",
      text:
        "Dans le trousseau de l'iPhone, référencés par nom depuis la liste des machines. La liste elle-même est du JSON simple et ne contient aucun secret : elle peut être inspectée, sauvegardée ou synchronisée sans rien divulguer.",
    },

    { kind: "h2", text: "L'agent est-il nécessaire ?" },
    {
      kind: "p",
      text:
        "Seulement si vous voulez qu'une VM éteinte démarre quand vous la touchez. Sans lui, wisq se connecte à des consoles déjà actives, ce que fait normalement tout client VNC.",
    },

    { kind: "h2", text: "Quels hyperviseurs fonctionnent ?" },
    {
      kind: "p",
      text:
        "Pour se connecter : tout ce qui expose une console VNC ou SPICE — ce qui couvre à elles deux ce que publie presque tout hyperviseur. Pour démarrer à la demande : l'agent pilote libvirt via la ligne de commande virsh, donc tout ce que libvirt gère — QEMU/KVM, Xen, LXC. D'autres backends représentent peu de code derrière une seule interface.",
    },

    { kind: "h2", text: "Y a-t-il une version Android ?" },
    {
      kind: "p",
      text:
        "Non, et ce n'est pas prévu. Les parties qui se porteraient sont déjà portables — le démon et l'interpréteur sont en Rust sans dépendance de plateforme — mais l'application est le produit, et elle est faite correctement pour une plateforme plutôt que mal pour deux.",
    },

    { kind: "h2", text: "Quelle licence ?" },
    {
      kind: "p",
      text:
        "Aucune pour l'instant. Rien ici n'accorde de droits de réutilisation, et aucune licence n'a été choisie ; la décision appartient encore à l'auteur. La sémantique d'exécution RISC-V est un portage de mini-rv32ima de Charles Lohr (MIT), créditée dans NOTICE ; aucun code tiers n'est embarqué.",
    },

    { kind: "h2", text: "Comment signaler quelque chose ?" },
    {
      kind: "p",
      text:
        "Écrivez-moi. Des couleurs fausses, un invité qui se connecte mais reste noir, un message de protocole que le client refuse — ce sont des défauts de notre côté, et le genre qu'on ne trouve pas sans le matériel de quelqu'un d'autre.",
    },
  ],
};
