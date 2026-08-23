import type { Doc } from "../doc";

export const docsEn: Doc = {
  title: "Guide",
  lede: "From an empty phone to a running VM, both ways round: one on your own hardware, one on the phone itself.",
  blocks: [
    {
      kind: "p",
      text:
        "wisq does two separate things, and which one you want decides everything that follows. Reaching a virtual machine that runs on a Mac, a PC or a NAS gives you a full desktop at the speed of that machine. Booting Linux on the phone itself gives you a shell with no network at all. Neither needs a jailbreak.",
    },

    { kind: "h2", text: "Getting the app" },
    {
      kind: "p",
      text:
        "There is no App Store listing yet. Every release attaches an unsigned IPA you can sideload, and the repository builds and installs straight to a connected iPhone if you have Xcode.",
    },
    {
      kind: "code",
      caption: "Build and install onto a connected iPhone",
      code: "git clone https://github.com/maxlestage/wisq.git\ncd wisq\n./scripts/install-ios.sh",
    },
    {
      kind: "p",
      text:
        "For sideloading instead, download wisq-<version>-unsigned.ipa from the releases page and install it with AltStore or Sideloadly. An unsigned build signed with a free Apple ID expires after seven days and has to be refreshed; that is Apple's rule, not ours.",
    },

    { kind: "h2", text: "Remote: a VM on your own hardware" },
    {
      kind: "p",
      text:
        "wisq speaks RFB 3.8, the VNC protocol. Anything that exposes a VNC console works: QEMU, libvirt, VirtualBox, Proxmox, a Raspberry Pi running x11vnc, a Mac sharing its screen.",
    },
    {
      kind: "code",
      caption: "Two ways to get a console worth connecting to",
      code:
        "qemu-system-x86_64 -m 2048 -vnc :1 -hda disk.qcow2\n\n# or expose a display that already exists\nx11vnc -display :0 -rfbport 5901",
    },
    {
      kind: "ol",
      items: [
        "In wisq, tap + and give the machine a name.",
        "Enter the host and port. A VNC display of :1 means port 5901 — the port is 5900 plus the display number.",
        "Enter the password if the server asks for one; it is stored in the iPhone Keychain, never in the machine list.",
        "Tap the machine to connect.",
      ],
    },
    {
      kind: "note",
      tone: "warn",
      text:
        "Plain VNC is unencrypted, and so is the agent in this version. Use it on a network you trust, or through a tunnel you already run — WireGuard or Tailscale. TLS with certificate pinning is on the roadmap and the client already carries the setting.",
    },

    { kind: "h2", text: "The agent: turning a VM on before connecting" },
    {
      kind: "p",
      text:
        "Without the agent wisq still works, as long as the VM is already running. The agent is what turns \"one more VNC client\" into \"my machines, from my phone\": tapping a powered-off VM boots it, waits for its console and connects to whatever port it landed on.",
    },
    {
      kind: "code",
      caption: "Install on the machine that runs the VMs",
      code: "curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh\n\n# or, with Homebrew\nbrew tap maxlestage/wisq https://github.com/maxlestage/wisq.git\nbrew install maxlestage/wisq/wisq-agent",
    },
    {
      kind: "p",
      text:
        "Run it with --service and it installs a launchd job on macOS or a systemd user unit on Linux, so it survives a reboot. Run it with --demo first if you want to see the phone side working before pointing it at a hypervisor: it serves two fake VMs with real state transitions.",
    },
    {
      kind: "p",
      text:
        "On first start the daemon prints a pairing link per reachable address, and a QR code when qrencode is installed. Open one on the iPhone — scan it, or paste it — and wisq lands on the import screen with the address and token already filled in.",
    },
    {
      kind: "code",
      caption: "What the daemon prints",
      code:
        "wisq-agent en écoute sur le port 7442 (virsh)\njeton : k3f9x2m8q1w7e4r6t5y0u8i2o4p6a1s3\nappairage :\n  wisq://agent?host=nas&port=7442&token=…&name=nas",
    },
    {
      kind: "p",
      text:
        "The token is generated once and kept in ~/.wisq-agent/token with owner-only permissions. Revoking access is deleting that file and restarting the daemon.",
    },

    { kind: "h2", text: "Local: Linux on the phone itself" },
    {
      kind: "p",
      text:
        "The local machine is an interpreted RISC-V computer — one rv32ima hart, 64 MB of RAM, an 8250 UART, a CLINT timer. It boots a real Linux kernel to a login prompt in a fraction of a second, with no network and no host.",
    },
    {
      kind: "ol",
      items: [
        "Get an rv32ima nommu kernel image. Ready-made ones live in the mini-rv32ima project.",
        "Put it somewhere the Files app can reach — iCloud Drive, or On My iPhone.",
        "In wisq, open the local machine screen and import the image.",
        "Tap boot. The console appears as the kernel writes to its UART.",
      ],
    },
    {
      kind: "p",
      text:
        "The virtual clock advances with executed instructions rather than wall time, so the same image boots the same way on every device — which is also what makes the boot testable in CI.",
    },

    { kind: "h2", text: "When something does not work" },
    {
      kind: "dl",
      items: [
        {
          term: "The screen stays black after connecting",
          detail:
            "The server accepted the connection but is not sending updates. Check that the VNC server is attached to a display that exists — a headless QEMU with no -vga will connect and show nothing.",
        },
        {
          term: "Colours look wrong",
          detail:
            "Report it. wisq negotiates a pixel format for rendering rather than accepting the server's, and a mismatch is a bug on our side, not a setting on yours.",
        },
        {
          term: "The agent says a domain is unknown",
          detail:
            "The daemon asks libvirt through virsh, so it sees exactly what `virsh list --all` sees — and as the user the daemon runs as. A VM defined for root is invisible to a daemon running as you.",
        },
        {
          term: "The pairing link does nothing",
          detail:
            "The link only opens wisq if the app is installed. On a fresh phone, install first, then scan.",
        },
        {
          term: "The local kernel boots and then stops printing",
          detail:
            "That is usually the login prompt, which ends without a newline. Type into it — the console is two-way.",
        },
      ],
    },
  ],
};

export const docsFr: Doc = {
  title: "Guide",
  lede: "D'un téléphone vide à une VM qui tourne, dans les deux sens : l'une sur votre matériel, l'autre sur le téléphone lui-même.",
  blocks: [
    {
      kind: "p",
      text:
        "wisq fait deux choses distinctes, et savoir laquelle vous voulez décide de tout le reste. Atteindre une machine virtuelle qui tourne sur un Mac, un PC ou un NAS donne un bureau complet à la vitesse de cette machine. Démarrer Linux sur le téléphone lui-même donne un shell sans le moindre réseau. Ni l'un ni l'autre n'exige de jailbreak.",
    },

    { kind: "h2", text: "Obtenir l'application" },
    {
      kind: "p",
      text:
        "Il n'y a pas encore de fiche App Store. Chaque release attache une IPA non signée que vous pouvez sideloader, et le dépôt sait construire et installer directement sur un iPhone connecté si vous avez Xcode.",
    },
    {
      kind: "code",
      caption: "Construire et installer sur un iPhone connecté",
      code: "git clone https://github.com/maxlestage/wisq.git\ncd wisq\n./scripts/install-ios.sh",
    },
    {
      kind: "p",
      text:
        "Pour sideloader plutôt, téléchargez wisq-<version>-unsigned.ipa depuis la page des releases et installez-la avec AltStore ou Sideloadly. Une compilation non signée avec un identifiant Apple gratuit expire au bout de sept jours et doit être rafraîchie ; c'est la règle d'Apple, pas la nôtre.",
    },

    { kind: "h2", text: "Distant : une VM sur votre matériel" },
    {
      kind: "p",
      text:
        "wisq parle RFB 3.8, le protocole VNC. Tout ce qui expose une console VNC convient : QEMU, libvirt, VirtualBox, Proxmox, un Raspberry Pi sous x11vnc, un Mac qui partage son écran.",
    },
    {
      kind: "code",
      caption: "Deux façons d'obtenir une console à laquelle se connecter",
      code:
        "qemu-system-x86_64 -m 2048 -vnc :1 -hda disk.qcow2\n\n# ou exposer un affichage qui existe déjà\nx11vnc -display :0 -rfbport 5901",
    },
    {
      kind: "ol",
      items: [
        "Dans wisq, touchez + et nommez la machine.",
        "Saisissez l'hôte et le port. Un affichage VNC :1 signifie le port 5901 — le port vaut 5900 plus le numéro d'affichage.",
        "Saisissez le mot de passe si le serveur en demande un ; il est rangé dans le trousseau de l'iPhone, jamais dans la liste des machines.",
        "Touchez la machine pour vous connecter.",
      ],
    },
    {
      kind: "note",
      tone: "warn",
      text:
        "Le VNC nu n'est pas chiffré, et l'agent de cette version non plus. À réserver à un réseau de confiance ou à un tunnel que vous exploitez déjà — WireGuard, Tailscale. Le TLS avec épinglage de certificat est à la feuille de route et le client en porte déjà le réglage.",
    },

    { kind: "h2", text: "L'agent : allumer une VM avant de s'y connecter" },
    {
      kind: "p",
      text:
        "Sans agent, wisq fonctionne — il faut simplement que la VM soit déjà démarrée. L'agent est ce qui transforme « un client VNC de plus » en « mes machines, depuis mon téléphone » : toucher une VM éteinte la démarre, attend sa console et s'y connecte sur le port qu'elle a obtenu.",
    },
    {
      kind: "code",
      caption: "À installer sur la machine qui fait tourner les VM",
      code: "curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh\n\n# ou, avec Homebrew\nbrew tap maxlestage/wisq https://github.com/maxlestage/wisq.git\nbrew install maxlestage/wisq/wisq-agent",
    },
    {
      kind: "p",
      text:
        "Avec --service, il installe un job launchd sur macOS ou une unité systemd utilisateur sur Linux, et survit donc à un redémarrage. Avec --demo, il sert deux VM factices aux transitions d'état réelles : de quoi vérifier le côté téléphone avant de le pointer vers un hyperviseur.",
    },
    {
      kind: "p",
      text:
        "Au premier lancement, le démon imprime un lien d'appairage par adresse joignable, et un QR code si qrencode est installé. Ouvrez-en un sur l'iPhone — scanné ou collé — et wisq arrive sur l'écran d'import, adresse et jeton déjà remplis.",
    },
    {
      kind: "code",
      caption: "Ce que le démon imprime",
      code:
        "wisq-agent en écoute sur le port 7442 (virsh)\njeton : k3f9x2m8q1w7e4r6t5y0u8i2o4p6a1s3\nappairage :\n  wisq://agent?host=nas&port=7442&token=…&name=nas",
    },
    {
      kind: "p",
      text:
        "Le jeton est généré une fois et conservé dans ~/.wisq-agent/token, lisible par son seul propriétaire. Révoquer un accès, c'est supprimer ce fichier et relancer le démon.",
    },

    { kind: "h2", text: "Local : Linux sur le téléphone lui-même" },
    {
      kind: "p",
      text:
        "La machine locale est un ordinateur RISC-V interprété — un hart rv32ima, 64 Mo de RAM, un UART 8250, un minuteur CLINT. Elle amène un vrai noyau Linux jusqu'à l'invite de connexion en une fraction de seconde, sans réseau et sans hôte.",
    },
    {
      kind: "ol",
      items: [
        "Procurez-vous une image de noyau rv32ima nommu. Le projet mini-rv32ima en propose des prêtes à l'emploi.",
        "Placez-la où l'app Fichiers peut la lire — iCloud Drive, ou Sur mon iPhone.",
        "Dans wisq, ouvrez l'écran de machine locale et importez l'image.",
        "Touchez démarrer. La console apparaît au fil de ce que le noyau écrit sur son UART.",
      ],
    },
    {
      kind: "p",
      text:
        "L'horloge virtuelle avance avec les instructions exécutées et non avec le temps réel : la même image démarre donc de la même façon sur chaque appareil — ce qui est aussi ce qui rend ce démarrage testable en intégration continue.",
    },

    { kind: "h2", text: "Quand quelque chose ne marche pas" },
    {
      kind: "dl",
      items: [
        {
          term: "L'écran reste noir après connexion",
          detail:
            "Le serveur a accepté la connexion mais n'envoie pas de mise à jour. Vérifiez que le serveur VNC est attaché à un affichage qui existe — un QEMU sans -vga se connecte et ne montre rien.",
        },
        {
          term: "Les couleurs sont fausses",
          detail:
            "Signalez-le. wisq négocie un format de pixels pour le rendu au lieu d'accepter celui du serveur : un décalage est un défaut de notre côté, pas un réglage du vôtre.",
        },
        {
          term: "L'agent dit qu'un domaine est introuvable",
          detail:
            "Le démon interroge libvirt via virsh : il voit exactement ce que voit `virsh list --all`, et sous l'utilisateur qui le fait tourner. Une VM définie pour root est invisible à un démon lancé sous votre compte.",
        },
        {
          term: "Le lien d'appairage ne fait rien",
          detail:
            "Le lien n'ouvre wisq que si l'application est installée. Sur un téléphone neuf : installez d'abord, scannez ensuite.",
        },
        {
          term: "Le noyau local démarre puis cesse d'écrire",
          detail:
            "C'est généralement l'invite de connexion, qui se termine sans saut de ligne. Tapez dedans — la console fonctionne dans les deux sens.",
        },
      ],
    },
  ],
};
