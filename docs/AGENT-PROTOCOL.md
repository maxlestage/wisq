# Protocole de l'agent hôte

L'agent est un petit démon installé sur la machine qui fait tourner les VM
(libvirt, QEMU direct, Proxmox…). Il n'existe que pour une chose : permettre à
l'iPhone d'allumer une VM avant de s'y connecter, puis d'apprendre sur quel port
sa console écoute.

Sans agent, wisq fonctionne — il faut simplement que la VM soit déjà démarrée.

## Transport

HTTP/1.1, port 7442 par défaut. Toutes les routes sont préfixées par `/v1`.
Authentification par jeton porteur :

```
Authorization: Bearer <jeton>
```

Le jeton est généré au premier lancement, conservé dans `~/.wisq-agent/token`
(mode 600). Il n'y a pas de compte, pas de mot de passe : un jeton, révocable
en supprimant le fichier.

## Appairage

Au lancement, le démon imprime un lien d'appairage par interface réseau :

```
wisq://agent?host=nas.local&port=7442&token=…&name=nas
```

Ouvert sur l'iPhone — scanné depuis le QR que le démon affiche quand
`qrencode` est installé, ou collé — le lien ouvre wisq directement sur l'écran
d'import, adresse et jeton remplis, interrogation lancée. Le format est défini
par `AgentPairing` (WisqCore), partagé par les deux côtés pour que génération
et analyse ne puissent pas diverger.

La v1 parle en clair : le TLS auto-hébergé sans dépendance est un chantier à
part entière, et le jeton reste obligatoire. À réserver au réseau local ou à un
tunnel existant (WireGuard, Tailscale) — la même consigne que pour le VNC non
chiffré. Le TLS avec épinglage est prévu ; `TransportSecurity.tlsPinned` existe
déjà côté client.

## Routes

### `GET /v1/vms`

```json
[
  {
    "id": "debian-13",
    "name": "Debian 13",
    "state": "running",
    "consoleProtocol": "vnc",
    "consolePort": 5901,
    "guestOS": "linux"
  }
]
```

`state` ∈ `running` | `paused` | `stopped` | `starting` | `unknown`.

`consolePort` est absent tant que la VM n'est pas démarrée.

### `GET /v1/vms/{id}`

Le même objet, pour une seule VM. C'est la route que le client interroge en
boucle pendant un démarrage (`AgentClient.waitUntilRunning`).

### `POST /v1/vms/{id}/start`

Démarre la VM. Répond immédiatement avec l'état `starting` — le démarrage d'un
invité prend des dizaines de secondes et une requête HTTP maintenue ouverte
aussi longtemps ne survit pas à un changement de cellule réseau.

### `POST /v1/vms/{id}/stop`

```json
{ "force": false }
```

`force: false` envoie un arrêt ACPI, `force: true` coupe l'alimentation.

## Erreurs

Tout code hors 2xx porte un corps JSON :

```json
{ "error": "domaine introuvable : debian-13" }
```

Le message est affiché tel quel à l'utilisateur, il doit donc être lisible.

## Découverte

L'agent s'annonce en Bonjour sous `_wisq-agent._tcp`, au mieux des outils
présents (`avahi-publish-service` sur Linux, `dns-sd` sur macOS) — et
silencieusement pas du tout sinon : une commodité absente ne doit jamais
empêcher le démon de servir. Le nom annoncé est le nom d'hôte, si bien que
l'application propose `<nom>.local` sans résoudre d'enregistrement SRV.
L'écran d'import affiche les agents détectés ; une tape remplit l'adresse.

## Implémentation

Le démon est en **Rust** (`crates/wisq-agent`), le client en **Swift** — ils
n'ont pas les mêmes contraintes. Le démon s'installe sur un NAS ou un portable
et n'a ni interface ni framework de plateforme : rien qui justifie d'embarquer
un runtime de langage. Statiquement lié au runtime Swift il pesait 58 Mo pour
servir quatre routes ; il en fait aujourd'hui moins de 600 Ko, en un seul
fichier statique qui tourne sur n'importe quel Linux, Alpine compris.

Zéro dépendance, délibérément. Un programme qu'on installe par un `curl | sh`
est un programme dont on hérite les dépendances, et le protocole ci-dessus est
assez petit pour qu'un serveur HTTP/1.1 et un écrivain JSON écrits à la main
représentent moins de code que la glu qu'un framework demanderait.

Trois pièces :

- `http.rs`, un serveur HTTP/1.1 sur la bibliothèque standard, un fil par
  connexion, avec des plafonds sur les en-têtes et le corps ;
- `service.rs`, le routage du protocole ci-dessus, jeton comparé en temps
  constant ;
- `backend.rs`, deux backends : `VirshBackend` pilote libvirt via la CLI
  `virsh` (pas de liaison C, dégradation propre si libvirt est absent), et
  `DemoBackend` sert deux VM factices avec de vraies transitions d'état.

**Le format de fil est gardé par un test qui traverse les deux langages** : la
suite Swift lance le vrai binaire Rust sur un port éphémère et l'interroge avec
le même `AgentClient` que l'application embarque. C'est le seul endroit où une
divergence entre les deux moitiés du protocole peut se voir, et depuis qu'elles
ne sont plus écrites dans la même langue, c'est le test qui compte.

```sh
cargo run -p wisq-agent -- --demo   # essai sans libvirt
cargo run -p wisq-agent             # libvirt via virsh, port 7442
```
