# Tester wisq avec Ubuntu

Le parcours complet : un PC sous Ubuntu qui fait tourner une machine virtuelle,
un iPhone sur le même réseau qui la démarre, s'y connecte, y colle du texte, y
dépose un fichier et l'éteint. Chaque étape dit ce qu'elle exige et ce qui a
été vérifié — d'un conteneur Ubuntu 24.04 sans KVM, tout ne peut pas l'être,
et ce document ne le prétend pas.

## 1. L'application sur l'iPhone

wisq n'est pas sur l'App Store et le site ne le distribue pas. Trois voies,
de la plus confortable à la plus dépannée :

- **TestFlight** — l'application du jour, signée, installée sans câble et
  sans expirer au bout de sept jours. Le workflow *TestFlight* (onglet
  Actions → *TestFlight* → *Run workflow*) construit, signe et envoie ; le
  traitement par Apple prend quelques minutes, puis le build apparaît dans
  l'application TestFlight de l'iPhone. Demande un compte développeur payant
  et quatre secrets de dépôt, décrits dans l'en-tête de
  `.github/workflows/testflight.yml`.
- **Avec un Mac et Xcode** — iPhone branché en USB, mode développeur activé,
  puis `./scripts/install-ios.sh` (voir le script pour `--team`). Une app
  signée avec un compte personnel gratuit expire au bout de sept jours ;
  relancer le script la renouvelle.
- **L'IPA non signée** que chaque release publie
  (`wisq-vX.Y.Z-unsigned.ipa`), installée avec AltStore ou Sideloadly, qui la
  signent avec votre identifiant Apple. Attention à la date : la dernière
  release, v0.3.0, est du 24 août et **n'a pas** le canal display SPICE
  complet, l'envoi de fichiers, l'extinction par l'agent ni la machine
  suspendue. Pour essayer ce qui est décrit ici par cette voie, il faut une
  release plus récente.

## 2. L'hôte Ubuntu : libvirt et une VM invitée avec SPICE

```sh
sudo apt install qemu-system-x86 libvirt-daemon-system virtinst spice-vdagent
sudo usermod -aG libvirt "$USER"    # puis se reconnecter
```

Une VM Ubuntu invitée avec un affichage SPICE, l'agent invité (presse-papiers,
transfert de fichiers, redimensionnement) et l'ACPI pour s'éteindre poliment :

```sh
virt-install --name ubuntu-test --memory 2048 --vcpus 2 \
  --disk size=16 --os-variant ubuntu24.04 \
  --cdrom ~/ubuntu-24.04-desktop-amd64.iso \
  --graphics spice,listen=0.0.0.0 --video qxl \
  --channel spicevmc,target.type=virtio,target.name=com.redhat.spice.0
```

Dans l'invité, une fois installé : `sudo apt install spice-vdagent`. Sans lui,
le presse-papiers et le dépôt de fichiers n'ont personne pour répondre — l'envoi
d'un fichier le dit (« aucun agent ne tourne dans l'invité pour recevoir le
fichier »), le presse-papiers reste simplement muet — et le reste marche.

`listen=0.0.0.0` est ce qui laisse le téléphone se connecter depuis le réseau ;
sans lui, SPICE n'écoute que sur l'hôte. Pour VNC à la place :
`--graphics vnc,listen=0.0.0.0`.

*Non vérifié d'ici* : ce conteneur n'a pas de KVM. La ligne ci-dessus est
celle de la documentation de virt-install ; le port SPICE attribué se lit
ensuite avec `virsh domdisplay ubuntu-test`.

## 3. Le démon wisq-agent sur l'hôte

C'est lui qui permet au téléphone de démarrer la VM avant de s'y connecter, et
de l'éteindre après. Sans lui, wisq fonctionne — il faut juste que la VM soit
déjà démarrée, et le port se saisit à la main.

```sh
curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh -s -- --from-source --service
```

`--from-source` construit le démon depuis master avec Rust (installez
`rustup.rs` d'abord) : le binaire de la release v0.3.0 est en retard sur le
démon d'aujourd'hui (l'état `starting`, libvirt injoignable distingué d'une VM
introuvable). `--service` l'installe en service systemd utilisateur ; le jeton
et le lien d'appairage se lisent dans `journalctl --user -u wisq-agent`.

Pour un premier contact sans aucune VM : `wisq-agent --demo` sert deux
machines factices avec de vraies transitions d'état.

*Vérifié d'ici, sur Ubuntu 24.04 avec `libvirt-clients` et le pilote de test
de libvirt* : le démon liste les domaines de `virsh`, répond `GET /v1/vms/{id}`,
refuse un jeton faux en 401, imprime un lien `wisq://agent?…` par interface.
Ce que le pilote de test ne peut pas montrer, ce sont les changements d'état
— il repart de zéro à chaque connexion, donc `start` et `stop` ne laissent pas
de trace ; sur un vrai libvirt ils en laissent, et la suite Rust les tient
contre un faux `virsh`.

## 4. L'appairage et la première connexion

1. Sur l'iPhone, dans wisq : **Importer depuis un agent**. Scanner le QR que le
   démon affiche (`qrencode` installé) ou coller le lien `wisq://`. Le jeton
   et l'empreinte TLS du démon voyagent dedans ; le téléphone épingle ce
   certificat, pas d'autorité.
2. La liste des VM de l'hôte apparaît ; en choisir une. Le protocole
   (SPICE ou VNC) et le port viennent du démon quand la VM tourne.
3. Se connecter. Si la VM est éteinte, wisq la démarre par l'agent et attend
   qu'elle annonce son port — `running` sans port n'est pas prête, c'est
   normal, ça dure des dizaines de secondes.

## 5. Ce qu'on essaie, dans l'ordre

| Geste | Où | Ce qui doit se passer |
|---|---|---|
| Connexion SPICE | liste → machine | l'écran de l'invité, curseur compris ; une fois `spice-vdagent` lancé, l'écran suit la taille du téléphone |
| Copier dans l'invité, coller sur le téléphone | n'importe quel texte | le presse-papiers traverse dans les deux sens |
| Envoyer un fichier | bouton ⬆ dans la barre de session | le fichier arrive là où `spice-vdagent` range ce qu'il reçoit (le dossier Téléchargements de la session), lu sur le téléphone par tranches de 64 Kio — un fichier de plusieurs Go passe |
| Éteindre | glissement sur la machine → Éteindre | arrêt ACPI ; l'invité met jusqu'à une minute ; s'il ne répond pas, wisq propose de couper |
| Changer de réseau en pleine session (Wi-Fi → 4G avec un tunnel, ou l'inverse) | réglages | wisq retente la connexion sur un budget borné, écran vierge puis l'invité revient ; ce que fait un verrouillage prolongé n'est pas écrit dans le code — à observer |
| Révoquer le jeton côté hôte | `rm ~/.wisq-agent/token`, puis relancer le démon | le démon lit le jeton au démarrage et en génère un autre s'il manque : l'ancien lien vaut 401, il faut réappairer. Supprimer le fichier sans relancer ne révoque rien |
| Un `.vv` de virt-manager | envoyer le fichier au téléphone (AirDrop, mail) | wisq l'ouvre dans l'éditeur, hôte et port remplis, avant d'enregistrer |

## 6. Quand ça ne marche pas

- **« aucun agent ne tourne dans l'invité »** — `spice-vdagent` n'est pas
  lancé dans la VM (ou le canal `spicevmc` manque dans sa définition).
- **Le téléphone ne voit pas l'hôte** — même réseau ? Le pare-feu d'Ubuntu
  (`ufw`) doit laisser passer 7442 (agent) et le port SPICE/VNC (5900+).
- **`running` sans jamais de port** — la VM n'a pas d'affichage SPICE/VNC, ou
  il écoute sur `127.0.0.1` : vérifier `virsh domdisplay`.
- **401 à chaque appel** — le jeton du lien n'est plus celui du fichier
  `~/.wisq-agent/token` (démon relancé après suppression) : réappairer.
