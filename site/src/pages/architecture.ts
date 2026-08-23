import type { Doc } from "../doc";

export const architectureEn: Doc = {
  title: "Architecture",
  lede: "The decisions that hold the rest up, and the reasoning behind each — including the ones that cost a rewrite to learn.",
  blocks: [
    {
      kind: "p",
      text:
        "Most of wisq is unremarkable. These are the parts that are not: places where the obvious approach is wrong, and where knowing why saves the next person a day.",
    },

    { kind: "h2", text: "Two languages, split by shape" },
    {
      kind: "p",
      text:
        "Swift holds the app, the interface and the remote desktop client — work built on Network.framework that belongs on the platform it targets. Rust holds the host daemon and the RISC-V interpreter: a program with no interface, and a loop over a byte array. Neither has a reason to carry a language runtime.",
    },
    {
      kind: "p",
      text:
        "The question for anything new is which of those two it looks like, not which language is nicer to write.",
    },

    { kind: "h2", text: "No JIT, and never was" },
    {
      kind: "p",
      text:
        "iOS grants executable memory only to development-signed applications. Every emulator on the App Store is therefore an interpreter, and the ones that pretend otherwise are not on the App Store. That is not a limitation wisq works around — it is the premise. The work went into making the interpreter fast instead.",
    },
    {
      kind: "table",
      columns: ["Change", "Effect"],
      rows: [
        ["Register file off a Swift array", "2.7× — the optimiser reloaded the buffer after every opaque call"],
        ["Branch-free immediate sign extension", "+8% — loads and stores are 47% of a Linux boot"],
        ["Mapped guest RAM instead of cleared", "construction 33–194 ms → under 0.1 ms"],
        ["Explicit thread quality of service", "keeps the interpreter off efficiency cores"],
      ],
    },
    {
      kind: "p",
      text:
        "Three other attempts were measured and reverted: moving cold opcodes out of line cost 9%, unconditional register write-back cost 3%, and a denser dispatch table gained nothing. A negative measurement is worth as much as a positive one and both are in the history.",
    },

    { kind: "h2", text: "The pixel format is negotiated for rendering, not for the network" },
    {
      kind: "p",
      text:
        "An RFB client may ask the server for whatever pixel layout it wants. The tempting choice is the one that sends the fewest bytes; the right choice is the one the phone can hand to the graphics stack without touching it. wisq asks for 32 bits little-endian with red at 16, green at 8 and blue at 0, which lands in memory as B, G, R, X — exactly what Core Graphics reads as byteOrder32Little with the first component skipped.",
    },

    { kind: "h2", text: "CPIXEL is not TPIXEL" },
    {
      kind: "p",
      text:
        "ZRLE packs colours as CPIXEL, three bytes in the negotiated byte order — B, G, R for the format above. Tight packs them as TPIXEL, which is always R, G, B regardless of what was negotiated. Swapping the two produces a picture that is entirely readable and entirely the wrong colour, with no error anywhere. It is the single easiest way to lose an afternoon in this codebase.",
    },

    { kind: "h2", text: "zlib streams live as long as the session" },
    {
      kind: "p",
      text:
        "The compressed encodings share dictionaries across rectangles: a stream is opened once and fed for the life of the connection. One mis-parsed byte does not corrupt one rectangle, it corrupts every frame after it. This is why reconnection builds fresh streams rather than reusing the old ones, and why the decoder is tested against fixtures produced by a reference zlib rather than by itself.",
    },

    { kind: "h2", text: "The console is incremental" },
    {
      kind: "p",
      text:
        "The obvious way to render a serial console is to keep every byte and re-derive the visible text on each arrival. That is work proportional to the whole history per chunk — quadratic in the output. Measured: 2 000 lines cost 36.7 seconds of processing, against 0.22 now. The emulator stayed fast while the interface melted, which reads to the user as the VM being slow.",
    },
    {
      kind: "p",
      text:
        "Being incremental also fixed a real defect. The escape parser now keeps its state between chunks, so a sequence split across two writes is recognised instead of being printed as text.",
    },

    { kind: "h2", text: "The touch model is the product" },
    {
      kind: "p",
      text:
        "A desktop drawn on a phone is unusable if the pointer is your fingertip. wisq draws a virtual cursor on its own layer, offset from the finger, with inertia — so small buttons are reachable and you can see what you are about to hit. Press and release are spaced 50 ms apart and ordered, because guests drop clicks that arrive in the same millisecond.",
    },

    { kind: "h2", text: "Determinism where it can be had" },
    {
      kind: "p",
      text:
        "The local machine's virtual clock advances with executed instructions rather than wall time. The same kernel image therefore boots identically on every device and in CI, which is what makes a boot usable as a test — and what lets a benchmark compare two interpreters honestly, because the instruction counts have to match before the throughputs mean anything.",
    },
  ],
};

export const architectureFr: Doc = {
  title: "Architecture",
  lede: "Les décisions qui portent le reste, et le raisonnement derrière chacune — y compris celles qu'il a fallu réécrire pour comprendre.",
  blocks: [
    {
      kind: "p",
      text:
        "L'essentiel de wisq est sans surprise. Voici les parties qui ne le sont pas : là où l'approche évidente est fausse, et où savoir pourquoi épargne une journée à la personne suivante.",
    },

    { kind: "h2", text: "Deux langages, répartis par forme" },
    {
      kind: "p",
      text:
        "Swift tient l'application, l'interface et le client de bureau distant — du travail bâti sur Network.framework, qui appartient à la plateforme qu'il vise. Rust tient le démon hôte et l'interpréteur RISC-V : un programme sans interface, et une boucle sur un tableau d'octets. Ni l'un ni l'autre n'a de raison d'embarquer un runtime de langage.",
    },
    {
      kind: "p",
      text:
        "Pour toute nouveauté, la question est de savoir à laquelle des deux formes elle ressemble, pas quel langage est plus agréable à écrire.",
    },

    { kind: "h2", text: "Pas de JIT, et il n'y en a jamais eu" },
    {
      kind: "p",
      text:
        "iOS n'accorde de mémoire exécutable qu'aux applications signées en développement. Tout émulateur sur l'App Store est donc un interpréteur, et ceux qui prétendent le contraire ne sont pas sur l'App Store. Ce n'est pas une limite que wisq contourne — c'est sa prémisse. Le travail est allé à rendre l'interpréteur rapide.",
    },
    {
      kind: "table",
      columns: ["Changement", "Effet"],
      rows: [
        ["Registres hors du tableau Swift", "2,7× — l'optimiseur rechargeait le tampon après chaque appel opaque"],
        ["Extension de signe sans branchement", "+8 % — loads et stores font 47 % d'un boot Linux"],
        ["RAM invitée mappée au lieu d'effacée", "construction 33–194 ms → moins de 0,1 ms"],
        ["QoS explicite sur le fil d'émulation", "évite que l'interpréteur soit posé sur un cœur d'efficience"],
      ],
    },
    {
      kind: "p",
      text:
        "Trois autres tentatives ont été mesurées puis abandonnées : sortir les opcodes froids hors ligne coûtait 9 %, l'écriture arrière inconditionnelle 3 %, et une table de répartition plus dense ne rapportait rien. Une mesure négative vaut autant qu'une positive, et les deux sont dans l'historique.",
    },

    { kind: "h2", text: "Le format de pixels est négocié pour le rendu, pas pour le réseau" },
    {
      kind: "p",
      text:
        "Un client RFB peut demander au serveur la disposition de pixels qu'il veut. Le choix tentant est celui qui envoie le moins d'octets ; le bon est celui que le téléphone peut remettre à la pile graphique sans y toucher. wisq demande du 32 bits petit-boutiste avec le rouge en 16, le vert en 8 et le bleu en 0, ce qui arrive en mémoire sous la forme B, G, R, X — exactement ce que Core Graphics lit en byteOrder32Little avec la première composante ignorée.",
    },

    { kind: "h2", text: "CPIXEL n'est pas TPIXEL" },
    {
      kind: "p",
      text:
        "ZRLE encode les couleurs en CPIXEL, trois octets dans l'ordre négocié — B, G, R pour le format ci-dessus. Tight les encode en TPIXEL, qui est toujours R, G, B quel que soit ce qui a été négocié. Intervertir les deux produit une image parfaitement lisible et parfaitement fausse de couleur, sans la moindre erreur nulle part. C'est le moyen le plus simple de perdre un après-midi dans ce dépôt.",
    },

    { kind: "h2", text: "Les flux zlib vivent aussi longtemps que la session" },
    {
      kind: "p",
      text:
        "Les encodages compressés partagent leurs dictionnaires d'un rectangle à l'autre : un flux est ouvert une fois et alimenté pendant toute la vie de la connexion. Un octet mal analysé ne corrompt pas un rectangle, il corrompt toutes les images suivantes. D'où des flux neufs à chaque reconnexion plutôt que réutilisés, et un décodeur éprouvé contre des fixtures produites par un zlib de référence plutôt que par lui-même.",
    },

    { kind: "h2", text: "La console est incrémentale" },
    {
      kind: "p",
      text:
        "La façon évidente de rendre une console série est de garder chaque octet et de re-dériver le texte visible à chaque arrivée. C'est un travail proportionnel à tout l'historique par morceau — quadratique dans la sortie. Mesuré : 2 000 lignes coûtaient 36,7 secondes de traitement, contre 0,22 aujourd'hui. L'émulateur restait rapide pendant que l'interface fondait, ce que l'utilisateur lit comme une VM lente.",
    },
    {
      kind: "p",
      text:
        "Être incrémental a aussi corrigé un vrai défaut : l'analyseur d'échappements garde maintenant son état entre les morceaux, donc une séquence coupée entre deux écritures est reconnue au lieu d'être imprimée telle quelle.",
    },

    { kind: "h2", text: "Le modèle tactile est le produit" },
    {
      kind: "p",
      text:
        "Un bureau dessiné sur un téléphone est inutilisable si le pointeur est le bout du doigt. wisq dessine un curseur virtuel sur sa propre couche, décalé du doigt, avec de l'inertie — les petits boutons deviennent atteignables et l'on voit ce qu'on s'apprête à toucher. Appui et relâchement sont espacés de 50 ms et ordonnés, parce que les invités perdent les clics qui arrivent dans la même milliseconde.",
    },

    { kind: "h2", text: "Du déterminisme là où il est possible" },
    {
      kind: "p",
      text:
        "L'horloge virtuelle de la machine locale avance avec les instructions exécutées, pas avec le temps réel. La même image de noyau démarre donc à l'identique sur chaque appareil et en intégration continue, ce qui rend un démarrage utilisable comme test — et permet à un banc de comparer honnêtement deux interpréteurs, car les comptes d'instructions doivent coïncider avant que les débits veuillent dire quelque chose.",
    },
  ],
};
