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

    { kind: "h2", text: "Next" },
    {
      kind: "dl",
      items: [
        {
          term: "TLS for the agent, with pinning",
          detail:
            "The one deliberate weakness in version 1. The client already carries the setting; what is missing is a certificate story that does not require the person installing a daemon on a NAS to also run a certificate authority.",
        },
        {
          term: "The Rust interpreter inside the app",
          detail:
            "The core exists, is measurably faster than the Swift one, and CI already cross-compiles it for a real device target. What remains is packaging it as an XCFramework and switching the app over — small work, but work that has to be done on a Mac.",
        },
        {
          term: "A VT100 cell grid for the local console",
          detail:
            "The console today strips escape sequences and applies carriage returns and backspaces. That is readable, and it is not a terminal. Anything full-screen — an editor, a pager, top — needs a real grid.",
        },
      ],
    },

    { kind: "h2", text: "After that" },
    {
      kind: "dl",
      items: [
        {
          term: "SPICE",
          detail:
            "The natural second protocol: it is what libvirt hosts expose alongside VNC, and it carries audio and clipboard properly. The client already has the slot.",
        },
        {
          term: "RDP",
          detail:
            "The one that matters for Windows guests. Larger than SPICE by a good margin, and worth doing only properly.",
        },
        {
          term: "More agent backends",
          detail:
            "Proxmox and plain QEMU without libvirt are both a small amount of code behind the existing interface.",
        },
        {
          term: "Persistent local machines",
          detail:
            "The local Linux machine starts fresh every time. A writable disk image would make it somewhere you can keep things.",
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

    { kind: "h2", text: "Ensuite" },
    {
      kind: "dl",
      items: [
        {
          term: "TLS pour l'agent, avec épinglage",
          detail:
            "La seule faiblesse assumée de la version 1. Le client en porte déjà le réglage ; ce qui manque est une histoire de certificats qui n'oblige pas la personne installant un démon sur un NAS à exploiter aussi une autorité de certification.",
        },
        {
          term: "L'interpréteur Rust dans l'application",
          detail:
            "Le cœur existe, il est mesurablement plus rapide que celui en Swift, et la CI le compile déjà pour une cible appareil réelle. Reste à l'empaqueter en XCFramework et à basculer l'application — peu de travail, mais du travail qui se fait sur un Mac.",
        },
        {
          term: "Une grille VT100 pour la console locale",
          detail:
            "La console retire aujourd'hui les séquences d'échappement et applique retours chariot et retours arrière. C'est lisible, et ce n'est pas un terminal. Tout ce qui occupe l'écran — un éditeur, un pager, top — réclame une vraie grille.",
        },
      ],
    },

    { kind: "h2", text: "Plus tard" },
    {
      kind: "dl",
      items: [
        {
          term: "SPICE",
          detail:
            "Le deuxième protocole naturel : c'est ce que les hôtes libvirt exposent à côté de VNC, et il transporte correctement le son et le presse-papiers. Le client en a déjà l'emplacement.",
        },
        {
          term: "RDP",
          detail:
            "Celui qui compte pour les invités Windows. Nettement plus gros que SPICE, et à ne faire que bien.",
        },
        {
          term: "D'autres backends d'agent",
          detail:
            "Proxmox et QEMU nu sans libvirt représentent tous deux peu de code derrière l'interface existante.",
        },
        {
          term: "Des machines locales persistantes",
          detail:
            "La machine Linux locale repart de zéro à chaque fois. Une image disque inscriptible en ferait un endroit où l'on peut garder des choses.",
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
