import type { Doc } from "../doc";

export const protocolEn: Doc = {
  title: "Agent protocol",
  lede: "Four routes behind a bearer token. Small enough to read in one sitting, and implemented twice so it cannot drift.",
  blocks: [
    {
      kind: "p",
      text:
        "The agent is a small daemon installed on the machine that runs the VMs. It exists for one thing: letting the phone power a VM on before connecting to it, then learning which port its console landed on. Everything else wisq does works without it.",
    },

    { kind: "h2", text: "Transport" },
    {
      kind: "p",
      text:
        "HTTP/1.1, port 7442 by default, every route under /v1. Authentication is a bearer token, compared in constant time — it is a credential on a network the daemon does not control, and a byte-at-a-time comparison leaks its prefix to anyone patient enough to measure.",
    },
    { kind: "code", code: "Authorization: Bearer <token>" },
    {
      kind: "p",
      text:
        "The token is generated from the operating system's random source on first start and kept in ~/.wisq-agent/token with owner-only permissions. There is no account and no password: one token, revoked by deleting the file.",
    },
    {
      kind: "note",
      tone: "warn",
      text:
        "The daemon speaks TLS by default. It signs its own certificate on first run and keeps it beside the token; the certificate's SHA-256 fingerprint travels in the pairing link, and the app pins exactly that certificate — no authority, no chain, no name checks. A plain-HTTP client gets an immediate 426 telling it what to do, and --no-tls turns encryption off for a tunnel that already provides it. The token stays mandatory either way.",
    },

    { kind: "h2", text: "Routes" },
    {
      kind: "h3", text: "GET /v1/vms",
    },
    {
      kind: "code",
      caption: "Every machine the backend can see",
      code:
        '[\n  {\n    "id": "debian-13",\n    "name": "Debian 13",\n    "state": "running",\n    "consoleProtocol": "vnc",\n    "consolePort": 5901,\n    "guestOS": "linux"\n  }\n]',
    },
    {
      kind: "p",
      text:
        "state is one of running, paused, stopped, starting or unknown. consolePort and consoleProtocol are absent until the console exists — which is exactly what the client polls for.",
    },
    { kind: "h3", text: "GET /v1/vms/{id}" },
    {
      kind: "p",
      text:
        "The same object for one machine. This is the route the client polls during a boot, and a 404 with a readable message when the identifier is unknown.",
    },
    { kind: "h3", text: "POST /v1/vms/{id}/start" },
    {
      kind: "p",
      text:
        "Starts the machine and answers immediately with state starting. Booting a guest takes tens of seconds, and an HTTP request held open that long does not survive a phone moving between cells.",
    },
    { kind: "h3", text: "POST /v1/vms/{id}/stop" },
    { kind: "code", code: '{ "force": false }' },
    {
      kind: "p",
      text:
        "false sends an ACPI shutdown, true pulls the power cord. An empty body means false.",
    },

    { kind: "h2", text: "Errors" },
    {
      kind: "p",
      text:
        "Anything outside 2xx carries a JSON body. The message is shown to the person using the app, so it has to read like a sentence.",
    },
    { kind: "code", code: '{ "error": "VM introuvable : debian-13" }' },

    { kind: "h2", text: "Pairing" },
    {
      kind: "p",
      text:
        "On start the daemon prints one link per reachable address. Opened on the iPhone, the link lands on the import screen with the address and token filled in and the query already running.",
    },
    { kind: "code", code: "wisq://agent?host=nas&port=7442&token=…&name=nas" },
    {
      kind: "p",
      text:
        "Loopback addresses are never offered: a link to 127.0.0.1 is useless from a phone. The daemon also advertises itself over Bonjour as _wisq-agent._tcp, at best effort — avahi-publish-service on Linux, dns-sd on macOS, and silently nothing otherwise. A convenience that is missing must never stop the daemon serving.",
    },

    { kind: "h2", text: "Implementation" },
    {
      kind: "p",
      text:
        "The daemon is Rust, the client is Swift. They do not have the same constraints: a program with no interface and no platform framework has no reason to carry a language runtime. Statically linked against Swift's it was a 58 MB download to serve four routes; it is now 582 KB, one static binary that runs on any Linux including Alpine.",
    },
    {
      kind: "p",
      text:
        "Zero dependencies, deliberately. This is a program people install with a piped shell script, so its dependencies become theirs — and the protocol above is small enough that a hand-written HTTP/1.1 server and JSON writer are less code than the glue a framework would need.",
    },
    {
      kind: "p",
      text:
        "The wire format is guarded by a test that crosses both languages: the Swift suite launches the real Rust binary on an ephemeral port and queries it with the same client the app embeds, and parses the daemon's pairing links with the app's own parser. That is the only place a divergence between the two halves can show up.",
    },
    {
      kind: "code",
      caption: "Trying it without a hypervisor",
      code: "cargo run -p wisq-agent -- --demo",
    },
  ],
};

export const protocolFr: Doc = {
  title: "Protocole de l'agent",
  lede: "Quatre routes derrière un jeton porteur. Assez petit pour se lire d'une traite, et implémenté deux fois pour ne pas pouvoir diverger.",
  blocks: [
    {
      kind: "p",
      text:
        "L'agent est un petit démon installé sur la machine qui fait tourner les VM. Il n'existe que pour une chose : permettre au téléphone d'allumer une VM avant de s'y connecter, puis d'apprendre sur quel port sa console écoute. Tout le reste de wisq fonctionne sans lui.",
    },

    { kind: "h2", text: "Transport" },
    {
      kind: "p",
      text:
        "HTTP/1.1, port 7442 par défaut, toutes les routes sous /v1. L'authentification est un jeton porteur, comparé en temps constant — c'est une crédence sur un réseau que le démon ne contrôle pas, et une comparaison octet par octet en fuit le préfixe à qui sait mesurer.",
    },
    { kind: "code", code: "Authorization: Bearer <jeton>" },
    {
      kind: "p",
      text:
        "Le jeton est tiré de la source aléatoire du système au premier lancement et conservé dans ~/.wisq-agent/token, lisible par son seul propriétaire. Pas de compte, pas de mot de passe : un jeton, révocable en supprimant le fichier.",
    },
    {
      kind: "note",
      tone: "warn",
      text:
        "Le démon parle TLS par défaut. Il signe son propre certificat au premier lancement et le garde à côté du jeton ; l'empreinte SHA-256 du certificat voyage dans le lien d'appairage, et l'app épingle exactement ce certificat — pas d'autorité, pas de chaîne, pas de vérification de nom. Un client en HTTP clair reçoit immédiatement un 426 qui lui dit quoi faire, et --no-tls coupe le chiffrement pour un tunnel qui le fournit déjà. Le jeton reste obligatoire dans tous les cas.",
    },

    { kind: "h2", text: "Routes" },
    { kind: "h3", text: "GET /v1/vms" },
    {
      kind: "code",
      caption: "Toutes les machines que le backend voit",
      code:
        '[\n  {\n    "id": "debian-13",\n    "name": "Debian 13",\n    "state": "running",\n    "consoleProtocol": "vnc",\n    "consolePort": 5901,\n    "guestOS": "linux"\n  }\n]',
    },
    {
      kind: "p",
      text:
        "state vaut running, paused, stopped, starting ou unknown. consolePort et consoleProtocol sont absents tant que la console n'existe pas — c'est précisément ce que le client attend en interrogeant.",
    },
    { kind: "h3", text: "GET /v1/vms/{id}" },
    {
      kind: "p",
      text:
        "Le même objet pour une seule machine. C'est la route que le client interroge en boucle pendant un démarrage, et un 404 au message lisible quand l'identifiant est inconnu.",
    },
    { kind: "h3", text: "POST /v1/vms/{id}/start" },
    {
      kind: "p",
      text:
        "Démarre la machine et répond immédiatement avec l'état starting. Le démarrage d'un invité prend des dizaines de secondes, et une requête HTTP maintenue ouverte aussi longtemps ne survit pas à un téléphone qui change de cellule.",
    },
    { kind: "h3", text: "POST /v1/vms/{id}/stop" },
    { kind: "code", code: '{ "force": false }' },
    {
      kind: "p",
      text:
        "false envoie un arrêt ACPI, true coupe l'alimentation. Un corps vide vaut false.",
    },

    { kind: "h2", text: "Erreurs" },
    {
      kind: "p",
      text:
        "Tout code hors 2xx porte un corps JSON. Le message est affiché à la personne qui utilise l'application : il doit se lire comme une phrase.",
    },
    { kind: "code", code: '{ "error": "VM introuvable : debian-13" }' },

    { kind: "h2", text: "Appairage" },
    {
      kind: "p",
      text:
        "Au lancement, le démon imprime un lien par adresse joignable. Ouvert sur l'iPhone, le lien arrive sur l'écran d'import, adresse et jeton remplis, interrogation déjà lancée.",
    },
    { kind: "code", code: "wisq://agent?host=nas&port=7442&token=…&name=nas" },
    {
      kind: "p",
      text:
        "Les adresses de boucle locale ne sont jamais proposées : un lien vers 127.0.0.1 ne sert à rien depuis un téléphone. Le démon s'annonce aussi en Bonjour sous _wisq-agent._tcp, au mieux des outils présents — avahi-publish-service sur Linux, dns-sd sur macOS, et silencieusement rien sinon. Une commodité absente ne doit jamais empêcher le démon de servir.",
    },

    { kind: "h2", text: "Implémentation" },
    {
      kind: "p",
      text:
        "Le démon est en Rust, le client en Swift. Ils n'ont pas les mêmes contraintes : un programme sans interface ni framework de plateforme n'a aucune raison d'embarquer un runtime de langage. Statiquement lié à celui de Swift, il pesait 58 Mo pour servir quatre routes ; il en fait 582 Ko, un seul fichier statique qui tourne sur n'importe quel Linux, Alpine compris.",
    },
    {
      kind: "p",
      text:
        "Zéro dépendance, délibérément. C'est un programme qu'on installe par un script shell dans un tube : ses dépendances deviennent celles de l'utilisateur — et le protocole ci-dessus est assez petit pour qu'un serveur HTTP/1.1 et un écrivain JSON écrits à la main pèsent moins que la glu qu'un framework demanderait.",
    },
    {
      kind: "p",
      text:
        "Le format de fil est gardé par un test qui traverse les deux langages : la suite Swift lance le vrai binaire Rust sur un port éphémère et l'interroge avec le client que l'application embarque, puis analyse les liens d'appairage du démon avec le parseur de l'app. C'est le seul endroit où une divergence entre les deux moitiés peut se voir.",
    },
    {
      kind: "code",
      caption: "L'essayer sans hyperviseur",
      code: "cargo run -p wisq-agent -- --demo",
    },
  ],
};
