# Protocole de l'agent hôte

L'agent est un petit démon installé sur la machine qui fait tourner les VM
(libvirt, QEMU direct, Proxmox…). Il n'existe que pour une chose : permettre à
l'iPhone d'allumer une VM avant de s'y connecter, puis d'apprendre sur quel port
sa console écoute.

Sans agent, wisq fonctionne — il faut simplement que la VM soit déjà démarrée.

## Transport

HTTP/1.1 sur TLS, port 7442 par défaut. Toutes les routes sont préfixées par
`/v1`. Authentification par jeton porteur :

```
Authorization: Bearer <jeton>
```

Le jeton est généré par l'agent à l'installation et transmis au téléphone par
QR code. Il n'y a pas de compte, pas de mot de passe : un jeton, révocable.

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

L'agent s'annonce en Bonjour sous `_wisq-agent._tcp`, ce qui permet à
l'application de proposer les hôtes du réseau local sans saisie d'adresse.
`NSBonjourServices` de l'`Info.plist` déclare ce service ainsi que `_rfb._tcp`,
utilisé pour repérer les serveurs VNC déjà présents.

## Implémentation

Le client (`AgentClient`) est écrit. Le démon ne l'est pas encore — voir
`docs/ROADMAP.md`, lot 4. L'intention est un binaire Swift unique s'appuyant sur
libvirt quand il est présent, et sur un lancement QEMU direct sinon.
