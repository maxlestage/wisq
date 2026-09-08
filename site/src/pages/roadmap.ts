import type { Doc } from "../doc";

export const roadmapEn: Doc = {
  title: "Roadmap",
  lede: "What is next, in the order it matters — and what is deliberately not planned.",
  blocks: [
    {
      kind: "p",
      text:
        "Nothing here has a date. The order reflects what would make wisq better for someone using it today, not what is most interesting to build.",
    },

    {
      kind: "note",
      tone: "info",
      text: "Shipped since this page was written: TLS for the agent (the daemon signs its own certificate and the pairing link pins it), a real VT100 cell grid for the local console, SPICE in full, and persistence for the local machine. What follows is what remains.",
    },

    { kind: "h2", text: "Done since" },
    {
      kind: "dl",
      items: [
        {
          term: "SPICE",
          detail:
            "Complete, and hand-written like the VNC client beside it: display, cursor and input channels on their own connections, sound in both directions, the clipboard through the main channel's agent, and the codecs SPICE invented for itself — LZ, GLZ, QUIC and LZ4 — plus the drawing operations a real desktop leans on.",
        },
        {
          term: "Persistence for the local machine",
          detail:
            "Solved by saving the machine rather than giving it a disk. The whole state below the kernel — RAM, registers, the timer, the bytes queued for the UART — is written out and restored exactly, so the guest comes back mid-syscall if that is where it was.",
        },
        {
          term: "The x86-64 core",
          detail:
            "It runs a stock Alpine kernel and its init — four billion instructions, with no program dying — to the initramfs rescue shell, exactly where QEMU lands on the same images. Nine hardware corpora hold it, and the reference is not a specification read wrong: it is a real processor, asked what it produced.",
        },
        {
          term: "A virtual disk for the local machine",
          detail:
            "This page said it was the wrong plan, and the reasoning was right on the facts and wrong on the conclusion. rv32 nommu kernels do often lack a block driver — but wisq was offering nothing to find: no interrupt controller a device could point at, and a device tree frozen in a blob that could not grow a node. Both are gone. Either machine now takes a disk image, the guest sees it on /dev/vda, and what it writes survives a suspension inside the snapshot. What wisq still cannot do is put the block driver into a kernel you brought: if yours has none, nothing will touch the device — so the device counts its requests, and wisq says so at the end rather than leaving you with a silent disk.",
        },
      ],
    },

    { kind: "h2", text: "Next" },
    {
      kind: "dl",
      items: [
        {
          term: "The local desktop, through WebAssembly",
          detail:
            "The work in progress, and the largest of it. iOS allows no JIT, with one exception: a WKWebView may compile WebAssembly, which is data rather than code. So a translator turns regions of x86-64 instructions into modules WebKit compiles. What is measured: 9980 entry regions out of 10 116 translate on a real Alpine kernel, and the emitter holds 247 million instructions a second under JavaScriptCore against 49.3 for the Rust interpreter. What is not: it boots no kernel. A region that translates is not a region that runs, and two whole mechanisms are missing — paging and interrupts. A guest address today is folded by a mask rather than mapped through tables; writing CR3 and CR0 is refused rather than faked, because a kernel that believed it was paging would fail very far from the cause. A probe put a number on what real paging would cost: between 1 % and 29 % of throughput, depending on the access pattern.",
        },
        {
          term: "Booting from the image you bring",
          detail:
            "An installation image carries its kernel, its initramfs and the recipe that says how to start them — paths and command line. wisq can now read those inside it: ISO 9660, names as Rock Ridge gives them, and the recipes of syslinux, grub and systemd-boot. What is missing is the wiring: the app reads the image and still refuses it, saying what it is. The command line is read, never invented — a kernel started without its own does not find its root, and the failure lands far from its cause.",
        },
        {
          term: "RDP",
          detail:
            "The one that matters for Windows guests, and now the only console protocol wisq does not speak. Larger than SPICE by a good margin, and worth doing only properly — the client carries a deliberate stub that refuses rather than pretending.",
        },
        {
          term: "More agent backends",
          detail:
            "The agent drives libvirt through virsh. Proxmox and plain QEMU without libvirt are both a small amount of code behind the existing interface.",
        },
      ],
    },

    { kind: "h2", text: "Not planned" },
    {
      kind: "dl",
      items: [
        {
          term: "An Android app",
          detail:
            "The portable parts are already portable, but the product is the iPhone app. One platform done properly beats two done badly.",
        },
        {
          term: "Emulating a desktop operating system locally",
          detail:
            "Without a JIT this is a demonstration, not a tool. That is the ceiling wisq is built to avoid rather than to hit.",
        },
        {
          term: "A hosted service",
          detail:
            "wisq talks to machines you already have. There is no account, no server of ours in the path, and nothing to subscribe to.",
        },
      ],
    },

    {
      kind: "note",
      tone: "info",
      text:
        "Roadmap items are not promises. If one of these matters to you, an issue saying why is worth more than a vote — it changes the order.",
    },
  ],
};

export const roadmapFr: Doc = {
  title: "Feuille de route",
  lede: "La suite, dans l'ordre qui compte — et ce qui n'est délibérément pas prévu.",
  blocks: [
    {
      kind: "p",
      text:
        "Rien ici n'a de date. L'ordre reflète ce qui améliorerait wisq pour quelqu'un qui s'en sert aujourd'hui, pas ce qui serait le plus intéressant à construire.",
    },

    {
      kind: "note",
      tone: "info",
      text: "Livré depuis l'écriture de cette page : le TLS de l'agent (le démon signe son propre certificat et le lien d'appairage l'épingle), une vraie grille VT100 pour la console locale, SPICE en entier, et la persistance de la machine locale. Ce qui suit est ce qui reste.",
    },

    { kind: "h2", text: "Fait depuis" },
    {
      kind: "dl",
      items: [
        {
          term: "SPICE",
          detail:
            "Complet, et écrit à la main comme le client VNC d'à côté : canaux affichage, curseur et entrées sur leurs propres connexions, le son dans les deux sens, le presse-papiers par l'agent du canal principal, et les codecs que SPICE s'est inventés — LZ, GLZ, QUIC et LZ4 — plus les opérations de dessin sur lesquelles un vrai bureau s'appuie.",
        },
        {
          term: "La persistance de la machine locale",
          detail:
            "Résolue en sauvant la machine plutôt qu'en lui donnant un disque. Tout l'état sous le noyau — la RAM, les registres, le timer, les octets en attente sur l'UART — est écrit puis restauré à l'identique, si bien que l'invité revient au milieu d'un appel système si c'est là qu'il était.",
        },
        {
          term: "Le cœur x86-64",
          detail:
            "Il fait tourner un noyau Alpine standard et son init — quatre milliards d'instructions, sans qu'un programme meure — jusqu'au shell de secours de l'initramfs, exactement là où QEMU arrive sur les mêmes images. Neuf corpus matériels le tiennent, et la référence n'est pas une spécification lue de travers : c'est un vrai processeur, à qui l'on demande ce qu'il a produit.",
        },
        {
          term: "Un disque virtuel pour la machine locale",
          detail:
            "Cette page disait que c'était le mauvais plan, et le raisonnement était juste sur les faits et faux sur la conclusion. Les noyaux rv32 nommu manquent souvent de pilote bloc — mais wisq n'offrait rien à trouver : aucun contrôleur d'interruption qu'un périphérique puisse désigner, et un arbre de périphériques figé dans un blob où aucun nœud ne pouvait pousser. Les deux ont disparu. Les deux machines prennent maintenant une image de disque, l'invité la voit sur /dev/vda, et ce qu'il y écrit survit à une suspension, dans l'instantané. Ce que wisq ne peut toujours pas faire, c'est mettre le pilote bloc dans un noyau que vous apportez : si le vôtre n'en a pas, personne ne touchera le périphérique — alors le périphérique compte ses requêtes, et wisq le dit à la fin plutôt que de vous laisser devant un disque muet.",
        },
      ],
    },

    { kind: "h2", text: "Ensuite" },
    {
      kind: "dl",
      items: [
        {
          term: "Le bureau local, par WebAssembly",
          detail:
            "Le travail en cours, et le plus gros. iOS n'autorise aucun JIT, avec une exception : un WKWebView peut compiler du WebAssembly, qui est une donnée et non du code. Un traducteur transforme donc des régions d'instructions x86-64 en modules que WebKit compile. Ce qui est mesuré : 9980 régions d'entrée sur 10 116 se traduisent sur un vrai noyau Alpine, et l'émetteur tient 247 millions d'instructions par seconde sous JavaScriptCore contre 49,3 pour l'interpréteur Rust. Ce qui ne l'est pas : ça ne démarre aucun noyau. Une région qui se traduit n'est pas une région qui s'exécute, et il manque deux mécanismes entiers — la pagination et les interruptions. Une adresse invitée est aujourd'hui repliée par un masque au lieu d'être traduite par des tables ; écrire CR3 et CR0 est refusé plutôt que simulé, parce qu'un noyau qui croirait paginer tomberait en panne très loin de la cause. Une sonde a chiffré ce que coûterait la vraie pagination : entre 1 % et 29 % du débit selon le motif d'accès.",
        },
        {
          term: "Démarrer depuis l'image que vous apportez",
          detail:
            "Une image d'installation porte son noyau, son initramfs et la recette qui dit comment les démarrer — chemins et ligne de commande. wisq sait maintenant les y lire : ISO 9660, les noms rendus par Rock Ridge, et les recettes de syslinux, de grub et de systemd-boot. Ce qui manque est le branchement : l'application lit l'image mais la refuse encore, en disant ce qu'elle est. La ligne de commande se lit et ne s'invente pas — un noyau démarré sans la sienne ne trouve pas sa racine, et la panne tombe loin de sa cause.",
        },
        {
          term: "RDP",
          detail:
            "Celui qui compte pour les invités Windows, et désormais le seul protocole de console que wisq ne parle pas. Nettement plus gros que SPICE, et à ne faire que bien — le client porte une ébauche délibérée qui refuse au lieu de faire semblant.",
        },
        {
          term: "D'autres backends d'agent",
          detail:
            "L'agent pilote libvirt via virsh. Proxmox et QEMU nu sans libvirt représentent tous deux peu de code derrière l'interface existante.",
        },
      ],
    },

    { kind: "h2", text: "Non prévu" },
    {
      kind: "dl",
      items: [
        {
          term: "Une application Android",
          detail:
            "Les parties portables le sont déjà, mais le produit est l'application iPhone. Une plateforme faite correctement vaut mieux que deux faites mal.",
        },
        {
          term: "Émuler un système de bureau en local",
          detail:
            "Sans JIT, c'est une démonstration et non un outil. C'est le plafond que wisq est construit pour éviter, pas pour l'atteindre.",
        },
        {
          term: "Un service hébergé",
          detail:
            "wisq parle à des machines que vous avez déjà. Pas de compte, aucun serveur à nous sur le chemin, et rien à quoi s'abonner.",
        },
      ],
    },

    {
      kind: "note",
      tone: "info",
      text:
        "Les points de cette feuille de route ne sont pas des promesses. Si l'un d'eux vous importe, une issue expliquant pourquoi vaut mieux qu'un vote — elle change l'ordre.",
    },
  ],
};
