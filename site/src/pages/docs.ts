import type { Doc } from "../doc";

export const docsEn: Doc = {
  title: "Guide",
  lede: "How the two halves work, and what each one asks of you: a VM on your own hardware, or Linux on the phone itself.",
  blocks: [
    {
      kind: "p",
      text:
        "wisq does two separate things, and which one you want decides everything that follows. Reaching a virtual machine that runs on a Mac, a PC or a NAS gives you a full desktop at the speed of that machine. Booting Linux on the phone itself gives you a shell with no network at all. Neither needs a jailbreak.",
    },

    { kind: "h2", text: "Remote: a VM on your own hardware" },
    {
      kind: "p",
      text:
        "wisq speaks two console protocols. RFB 3.8 — VNC — reaches anything that exposes a VNC console: QEMU, libvirt, VirtualBox, Proxmox, a Raspberry Pi running x11vnc, a Mac sharing its screen. SPICE reaches what libvirt hosts usually publish instead, and carries more: sound both ways, the clipboard, and its own image codecs.",
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
        "The agent speaks TLS by default: a self-signed certificate whose fingerprint travels in the pairing link, pinned by the app, so there is no certificate authority in the picture. Run it with --no-tls only for a tunnel that already encrypts. The console itself is a different matter — plain VNC and plain SPICE are unencrypted by design, so use a network you trust or a tunnel you already run, WireGuard or Tailscale.",
    },

    { kind: "h2", text: "The agent: turning a VM on before connecting" },
    {
      kind: "p",
      text:
        "Without the agent wisq still works, as long as the VM is already running. The agent is what turns \"one more VNC client\" into \"my machines, from my phone\": tapping a powered-off VM boots it, waits for its console and connects to whatever port it landed on.",
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
        "Optional: import a filesystem or installer image too, of any size, and pick it under the kernel as its disk. The guest sees it on /dev/vda.",
        "Tap boot. The console appears as the kernel writes to its UART.",
      ],
    },
    {
      kind: "p",
      text:
        "The virtual clock advances with executed instructions rather than wall time, so the same image boots the same way on every device — which is also what makes the boot testable in CI.",
    },
    {
      kind: "p",
      text:
        "About the disk: wisq emulates the device, and cannot add a block driver to the kernel you brought. Many rv32 nommu kernels have none, and one that has none will never touch it — so the device counts its requests, and wisq tells you at the end of the session rather than leaving you with a disk that is silent for a reason you cannot see. The image is read in place, whatever its size — there is no ceiling any more. What the guest writes goes into a layer beside it (a sparse file plus a one-bit-per-sector map), written as it happens, so it survives suspension and restarts; the file you imported never changes.",
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
  lede: "Comment fonctionnent les deux moitiés, et ce que chacune demande : une VM sur votre matériel, ou Linux sur le téléphone lui-même.",
  blocks: [
    {
      kind: "p",
      text:
        "wisq fait deux choses distinctes, et savoir laquelle vous voulez décide de tout le reste. Atteindre une machine virtuelle qui tourne sur un Mac, un PC ou un NAS donne un bureau complet à la vitesse de cette machine. Démarrer Linux sur le téléphone lui-même donne un shell sans le moindre réseau. Ni l'un ni l'autre n'exige de jailbreak.",
    },

    { kind: "h2", text: "Distant : une VM sur votre matériel" },
    {
      kind: "p",
      text:
        "wisq parle deux protocoles de console. RFB 3.8 — VNC — atteint tout ce qui expose une console VNC : QEMU, libvirt, VirtualBox, Proxmox, un Raspberry Pi sous x11vnc, un Mac qui partage son écran. SPICE atteint ce que les hôtes libvirt publient plutôt d'habitude, et transporte davantage : le son dans les deux sens, le presse-papiers, et ses propres codecs d'image.",
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
        "L'agent parle TLS par défaut : un certificat auto-signé dont l'empreinte voyage dans le lien d'appairage, épinglé par l'application, donc aucune autorité de certification dans le tableau. Ne le lancez avec --no-tls que derrière un tunnel qui chiffre déjà. La console, elle, est une autre affaire : le VNC nu et le SPICE nu ne sont pas chiffrés par construction — réseau de confiance, ou tunnel que vous exploitez déjà, WireGuard ou Tailscale.",
    },

    { kind: "h2", text: "L'agent : allumer une VM avant de s'y connecter" },
    {
      kind: "p",
      text:
        "Sans agent, wisq fonctionne — il faut simplement que la VM soit déjà démarrée. L'agent est ce qui transforme « un client VNC de plus » en « mes machines, depuis mon téléphone » : toucher une VM éteinte la démarre, attend sa console et s'y connecte sur le port qu'elle a obtenu.",
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
        "Facultatif : importez aussi une image de système de fichiers ou d'installation, de n'importe quelle taille, et choisissez-la sous le noyau comme son disque. L'invité la voit sur /dev/vda.",
        "Touchez démarrer. La console apparaît au fil de ce que le noyau écrit sur son UART.",
      ],
    },
    {
      kind: "p",
      text:
        "L'horloge virtuelle avance avec les instructions exécutées et non avec le temps réel : la même image démarre donc de la même façon sur chaque appareil — ce qui est aussi ce qui rend ce démarrage testable en intégration continue.",
    },
    {
      kind: "p",
      text:
        "À propos du disque : wisq émule le périphérique, et ne peut pas ajouter un pilote bloc au noyau que vous apportez. Beaucoup de noyaux rv32 nommu n'en ont pas, et un noyau qui n'en a pas n'y touchera jamais — alors le périphérique compte ses requêtes, et wisq vous le dit à la fin de la session plutôt que de vous laisser devant un disque muet pour une raison invisible. L'image est lue sur place, quelle que soit sa taille — il n'y a plus de plafond. Ce que l'invité écrit va dans une couche à côté (un fichier épars et une carte d'un bit par secteur), posée au fil des écritures, donc elle survit aux suspensions et aux redémarrages ; le fichier importé ne change jamais.",
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
