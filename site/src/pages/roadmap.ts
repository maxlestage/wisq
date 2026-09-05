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
