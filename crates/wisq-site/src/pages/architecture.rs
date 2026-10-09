//! L'architecture : ce qui tourne où, et pourquoi.
//!
//! Des données, pas du balisage : `crate::doc` est le seul rendu, et une
//! traduction manquante ne compile pas.

use crate::doc::{Block, Doc};

pub static ARCHITECTURE_EN: Doc = Doc {
    title: "Architecture",
    lede: "The decisions that hold the rest up, and the reasoning behind each — including the ones that cost a rewrite to learn.",
    blocks: &[
        Block::P("Most of wisq is unremarkable. These are the parts that are not: places where the obvious approach is wrong, and where knowing why saves the next person a day."),
        Block::H2("Rust, and one hybrid app"),
        Block::P("Everything is Rust except the phone app, which is hybrid. The host daemon and the RISC-V interpreter are Rust — a program with no interface, and a loop over a byte array; neither has a reason to carry a language runtime. The app is the exception because it has to be: the interface, the touch model and the remote desktop client are built on UIKit and Network.framework, which belong to the platform they target. So the app is a Swift shell around a Rust core, and the seam between them is a C ABI of 36 functions, all declared in one file."),
        Block::P("The question for anything new is which of those two it looks like, not which language is nicer to write."),
        Block::H2("No JIT, and never was"),
        Block::P("iOS grants executable memory only to development-signed applications. Every emulator on the App Store is therefore an interpreter, and the ones that pretend otherwise are not on the App Store. That is not a limitation wisq works around — it is the premise. The work went into making the interpreter fast instead."),
        Block::Table { columns: &["Change", "Effect"], rows: &[&["Register file off a Swift array", "2.7× — the optimiser reloaded the buffer after every opaque call"], &["Branch-free immediate sign extension", "+8% — loads and stores are 47% of a Linux boot"], &["Mapped guest RAM instead of cleared", "construction 33–194 ms → under 0.1 ms"], &["Explicit thread quality of service", "keeps the interpreter off efficiency cores"]] },
        Block::P("Three other attempts were measured and reverted: moving cold opcodes out of line cost 9%, unconditional register write-back cost 3%, and a denser dispatch table gained nothing. A negative measurement is worth as much as a positive one and both are in the history."),
        Block::H2("The pixel format is negotiated for rendering, not for the network"),
        Block::P("An RFB client may ask the server for whatever pixel layout it wants. The tempting choice is the one that sends the fewest bytes; the right choice is the one the phone can hand to the graphics stack without touching it. wisq asks for 32 bits little-endian with red at 16, green at 8 and blue at 0, which lands in memory as B, G, R, X — exactly what Core Graphics reads as byteOrder32Little with the first component skipped."),
        Block::H2("CPIXEL is not TPIXEL"),
        Block::P("ZRLE packs colours as CPIXEL, three bytes in the negotiated byte order — B, G, R for the format above. Tight packs them as TPIXEL, which is always R, G, B regardless of what was negotiated. Swapping the two produces a picture that is entirely readable and entirely the wrong colour, with no error anywhere. It is the single easiest way to lose an afternoon in this codebase."),
        Block::H2("zlib streams live as long as the session"),
        Block::P("The compressed encodings share dictionaries across rectangles: a stream is opened once and fed for the life of the connection. One mis-parsed byte does not corrupt one rectangle, it corrupts every frame after it. This is why reconnection builds fresh streams rather than reusing the old ones, and why the decoder is tested against fixtures produced by a reference zlib rather than by itself."),
        Block::H2("The console is incremental"),
        Block::P("The obvious way to render a serial console is to keep every byte and re-derive the visible text on each arrival. That is work proportional to the whole history per chunk — quadratic in the output. Measured: 2 000 lines cost 36.7 seconds of processing, against 0.22 now. The emulator stayed fast while the interface melted, which reads to the user as the VM being slow."),
        Block::P("Being incremental also fixed a real defect. The escape parser now keeps its state between chunks, so a sequence split across two writes is recognised instead of being printed as text."),
        Block::H2("The touch model is the product"),
        Block::P("A desktop drawn on a phone is unusable if the pointer is your fingertip. wisq draws a virtual cursor on its own layer, offset from the finger, with inertia — so small buttons are reachable and you can see what you are about to hit. Press and release are spaced 50 ms apart and ordered, because guests drop clicks that arrive in the same millisecond."),
        Block::H2("Determinism where it can be had"),
        Block::P("The local machine's virtual clock advances with executed instructions rather than wall time. The same kernel image therefore boots identically on every device and in CI, which is what makes a boot usable as a test — and what lets a benchmark compare two interpreters honestly, because the instruction counts have to match before the throughputs mean anything."),
    ],
};

pub static ARCHITECTURE_FR: Doc = Doc {
    title: "Architecture",
    lede: "Les décisions qui portent le reste, et le raisonnement derrière chacune — y compris celles qu'il a fallu réécrire pour comprendre.",
    blocks: &[
        Block::P("L'essentiel de wisq est sans surprise. Voici les parties qui ne le sont pas : là où l'approche évidente est fausse, et où savoir pourquoi épargne une journée à la personne suivante."),
        Block::H2("Du Rust, et une application hybride"),
        Block::P("Tout est en Rust sauf l'application mobile, qui est hybride. Le démon hôte et l'interpréteur RISC-V sont en Rust — un programme sans interface, et une boucle sur un tableau d'octets ; ni l'un ni l'autre n'a de raison d'embarquer un runtime de langage. L'application fait exception parce qu'elle le doit : l'interface, le modèle tactile et le client de bureau distant reposent sur UIKit et Network.framework, qui appartiennent à la plateforme qu'ils visent. C'est donc une coquille Swift autour d'un cœur Rust, et la couture entre les deux est une ABI C de 36 fonctions, toutes déclarées dans un seul fichier."),
        Block::P("Pour toute nouveauté, la question est de savoir à laquelle des deux formes elle ressemble, pas quel langage est plus agréable à écrire."),
        Block::H2("Pas de JIT, et il n'y en a jamais eu"),
        Block::P("iOS n'accorde de mémoire exécutable qu'aux applications signées en développement. Tout émulateur sur l'App Store est donc un interpréteur, et ceux qui prétendent le contraire ne sont pas sur l'App Store. Ce n'est pas une limite que wisq contourne — c'est sa prémisse. Le travail est allé à rendre l'interpréteur rapide."),
        Block::Table { columns: &["Changement", "Effet"], rows: &[&["Registres hors du tableau Swift", "2,7× — l'optimiseur rechargeait le tampon après chaque appel opaque"], &["Extension de signe sans branchement", "+8 % — loads et stores font 47 % d'un boot Linux"], &["RAM invitée mappée au lieu d'effacée", "construction 33–194 ms → moins de 0,1 ms"], &["QoS explicite sur le fil d'émulation", "évite que l'interpréteur soit posé sur un cœur d'efficience"]] },
        Block::P("Trois autres tentatives ont été mesurées puis abandonnées : sortir les opcodes froids hors ligne coûtait 9 %, l'écriture arrière inconditionnelle 3 %, et une table de répartition plus dense ne rapportait rien. Une mesure négative vaut autant qu'une positive, et les deux sont dans l'historique."),
        Block::H2("Le format de pixels est négocié pour le rendu, pas pour le réseau"),
        Block::P("Un client RFB peut demander au serveur la disposition de pixels qu'il veut. Le choix tentant est celui qui envoie le moins d'octets ; le bon est celui que le téléphone peut remettre à la pile graphique sans y toucher. wisq demande du 32 bits petit-boutiste avec le rouge en 16, le vert en 8 et le bleu en 0, ce qui arrive en mémoire sous la forme B, G, R, X — exactement ce que Core Graphics lit en byteOrder32Little avec la première composante ignorée."),
        Block::H2("CPIXEL n'est pas TPIXEL"),
        Block::P("ZRLE encode les couleurs en CPIXEL, trois octets dans l'ordre négocié — B, G, R pour le format ci-dessus. Tight les encode en TPIXEL, qui est toujours R, G, B quel que soit ce qui a été négocié. Intervertir les deux produit une image parfaitement lisible et parfaitement fausse de couleur, sans la moindre erreur nulle part. C'est le moyen le plus simple de perdre un après-midi dans ce dépôt."),
        Block::H2("Les flux zlib vivent aussi longtemps que la session"),
        Block::P("Les encodages compressés partagent leurs dictionnaires d'un rectangle à l'autre : un flux est ouvert une fois et alimenté pendant toute la vie de la connexion. Un octet mal analysé ne corrompt pas un rectangle, il corrompt toutes les images suivantes. D'où des flux neufs à chaque reconnexion plutôt que réutilisés, et un décodeur éprouvé contre des fixtures produites par un zlib de référence plutôt que par lui-même."),
        Block::H2("La console est incrémentale"),
        Block::P("La façon évidente de rendre une console série est de garder chaque octet et de re-dériver le texte visible à chaque arrivée. C'est un travail proportionnel à tout l'historique par morceau — quadratique dans la sortie. Mesuré : 2 000 lignes coûtaient 36,7 secondes de traitement, contre 0,22 aujourd'hui. L'émulateur restait rapide pendant que l'interface fondait, ce que l'utilisateur lit comme une VM lente."),
        Block::P("Être incrémental a aussi corrigé un vrai défaut : l'analyseur d'échappements garde maintenant son état entre les morceaux, donc une séquence coupée entre deux écritures est reconnue au lieu d'être imprimée telle quelle."),
        Block::H2("Le modèle tactile est le produit"),
        Block::P("Un bureau dessiné sur un téléphone est inutilisable si le pointeur est le bout du doigt. wisq dessine un curseur virtuel sur sa propre couche, décalé du doigt, avec de l'inertie — les petits boutons deviennent atteignables et l'on voit ce qu'on s'apprête à toucher. Appui et relâchement sont espacés de 50 ms et ordonnés, parce que les invités perdent les clics qui arrivent dans la même milliseconde."),
        Block::H2("Du déterminisme là où il est possible"),
        Block::P("L'horloge virtuelle de la machine locale avance avec les instructions exécutées, pas avec le temps réel. La même image de noyau démarre donc à l'identique sur chaque appareil et en intégration continue, ce qui rend un démarrage utilisable comme test — et permet à un banc de comparer honnêtement deux interpréteurs, car les comptes d'instructions doivent coïncider avant que les débits veuillent dire quelque chose."),
    ],
};
