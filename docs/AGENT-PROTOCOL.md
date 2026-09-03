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
en supprimant le fichier **et en relançant le démon** — il lit le jeton une
fois au démarrage et en génère un autre s'il n'en trouve pas ; supprimer le
fichier sous un démon qui tourne ne change rien à ce qu'il accepte.

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

## Transport : TLS épinglé par le lien

Le démon parle TLS par défaut. Au premier lancement il se signe un certificat
(ECDSA P-256) et le conserve à côté du jeton dans `~/.wisq-agent` ; l'empreinte
SHA-256 du certificat (DER) voyage dans le lien d'appairage sous `fp=`, et
l'app épingle exactement ce certificat — pas d'autorité, pas de chaîne, pas de
vérification de nom. L'histoire de certificats d'un NAS familial, c'est de ne
pas en avoir : le lien qui porte déjà le jeton porte aussi la confiance.

Trois conséquences voulues. Le certificat ne tourne jamais tout seul — les
liens déjà imprimés doivent continuer de marcher ; supprimer les deux fichiers
`tls-*.der` est la rotation, et elle invalide les anciens liens à dessein. Il
n'expire pratiquement pas (année 9999), l'expiration étant une précaution du
monde des autorités qui, sous épinglage, ne saurait qu'échouer contre un démon
sain. Et un client en HTTP clair reçoit immédiatement un `426 Upgrade
Required` expliquant quoi faire, plutôt qu'un silence.

`--no-tls` repasse en HTTP clair : pour un client d'avant 0.3, ou un tunnel
(WireGuard, Tailscale) qui chiffre déjà. Un lien sans `fp=` signifie HTTP
clair ; une empreinte malformée est une erreur d'analyse, jamais un repli
silencieux vers le clair. Le jeton reste obligatoire dans tous les cas.

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
    "guestOS": "linux",
    "memoryKiB": 2097152,
    "maximumMemoryKiB": 2097152
  }
]
```

`state` ∈ `running` | `paused` | `stopped` | `starting` | `unknown`.

`memoryKiB` et `maximumMemoryKiB` sont **deux nombres, pas un**, parce que
libvirt en garde deux et qu'ils répondent à des questions différentes : le
maximum est ce avec quoi la machine a été construite et ne peut pas changer
pendant qu'elle tourne, la part courante est ce qu'elle a le droit d'utiliser
maintenant. Sur un domaine éteint, les deux viennent de sa définition — mesuré
sur libvirt 10.0.0, un domaine arrêté réglé par `virsh setmem --config 131072`
rend `{"maximumMemoryKiB":262144,"memoryKiB":131072}`.

Le backend libvirt les lit dans `virsh dominfo`, qui porte aussi l'état : c'est
**un seul appel** là où le démon en faisait un pour l'état seul.

Les deux sont **absents** quand le backend ne sait pas — un zéro se lirait
« aucune mémoire », l'absence se lit « je ne sais pas ». Un agent antérieur à
cette version n'en dit rien, et l'application affiche alors la ligne d'avant.

`consolePort` est absent tant que la VM n'est pas démarrée.

`consoleProtocol` ∈ `vnc` | `spice`. Le backend libvirt le lit dans
`virsh domdisplay --all`, qui rend une URI par affichage. **Les deux schémas ne
comptent pas pareil**, mesuré sur libvirt 10.0.0 plutôt que supposé :

| déclaration dans le domaine | `domdisplay` | ce que le démon publie |
|---|---|---|
| `graphics spice port='5901'` | `spice://localhost:5901` | `spice`, 5901 |
| `graphics vnc port='5903'` | `vnc://localhost:3` | `vnc`, 5903 (5900 + écran) |
| les deux | les deux lignes | `spice`, celui qui porte presse-papiers et fichiers |
| `spice` en TLS seul | `spice://localhost:-1?tls-port=5907` | rien : aucun port en clair |
| `spice` sur socket unix | `spice+unix:///tmp/s.sock` | rien : le téléphone ne peut pas le joindre |

Une VM `running` sans `consolePort` n'est donc pas forcément en train de
démarrer : elle peut n'avoir aucune console joignable depuis le réseau.

**`consoleProtocol` peut être présent sans `consolePort`.** Une VM arrêtée n'a
pas de port — libvirt en attribue un au démarrage du domaine — mais sa
définition dit déjà quelle console elle servira, et le backend libvirt la lit
avec `virsh dumpxml --inactive`. Sans cela le téléphone n'avait aucun
protocole à afficher pour une machine éteinte et en supposait un.

### Ce que `{id}` peut contenir

Le démon **refuse** tout identifiant qui n'est pas fait de lettres ASCII, de
chiffres, de points, de tirets ou de soulignés, qui commence par un tiret, qui
est vide, ou qui dépasse 255 octets. La réponse est alors
`404 identifiant de VM invalide`, sur les trois routes ci-dessous.

Ce n'est pas une coquetterie et ce n'est pas une liste de caractères qui ont
l'air louches. `VirshBackend` passe l'identifiant en argv — jamais par un shell
— donc un `; rm -rf /` n'est qu'un argument que `virsh` ne trouvera pas. Mais un
argument **qui commence par un tiret** n'est pas une donnée pour un analyseur
d'options : `virsh start --version` n'est pas une demande de démarrer un domaine
nommé `--version`. La liste blanche est là pour ça, et elle est blanche plutôt
que noire parce que deviner ce que l'analyseur d'un autre programme n'aime pas
est un pari qui vieillit mal.

La règle est écrite ici parce que ce paragraphe est le contrat entre les deux
implémentations. Elle a longtemps été appliquée par le seul démon : le
téléphone laissait enregistrer une machine que l'agent refuserait toujours, et
ne le disait qu'à la première tentative de connexion.
`Validation.validatedVMIdentifier` la tient côté Swift, et les deux suites
jouent la même liste de cas.

### `GET /v1/vms/{id}`

Le même objet, pour une seule VM. C'est la route que le client interroge en
boucle pendant un démarrage (`AgentClient.waitUntilRunning`).

### `POST /v1/vms/{id}/start`

Démarre la VM et **répond immédiatement**, sans attendre l'invité : un démarrage
prend des dizaines de secondes et une requête HTTP maintenue ouverte aussi
longtemps ne survit pas à un changement de cellule réseau.

L'état renvoyé est celui que le backend peut observer à cet instant, et les deux
que wisq fournit ne disent pas la même chose. Le backend de démonstration rend
`starting`. `VirshBackend` ne le peut pas : libvirt n'a pas cet état — un
domaine est `running` dès qu'il existe, pendant que son invité monte encore son
affichage — et aucun état que `virsh` sait rendre ne signifie « en train de
démarrer ». (Le démon lit cet état dans `virsh dominfo`, qui porte au passage
les deux chiffres de mémoire ; le vocabulaire est celui de `virsh domstate`,
qu'il remplace.) Ce paragraphe promettait `starting` tout court ; c'était vrai d'une
implémentation sur deux.

**Un client ne doit donc pas lire l'état seul.** Une VM est prête quand elle est
`running` **et** qu'elle annonce un port de console. Les deux moitiés comptent :
`running` sans port est l'état normal de tout démarrage réel, et ouvrir une
console dessus vise un port qui n'écoute pas encore. C'est la règle que
`AgentVM.isReadyForConsole` applique et que `AgentClient.waitUntilRunning`
attend ; un agent tiers doit publier son port au même moment, pas avant.

### `POST /v1/vms/{id}/stop`

```json
{ "force": false }
```

`force: false` envoie un arrêt ACPI, `force: true` coupe l'alimentation. Comme
`start`, la réponse est **immédiate** et porte l'état observable à cet instant —
et les deux valeurs ne mènent pas au même endroit :

- **`force: true`** est le cordon d'alimentation. `virsh destroy` retire le
  domaine, et la lecture suivante dit `stopped`.
- **`force: false`** est le bouton. libvirt envoie l'ACPI et rend la main ; le
  domaine est **encore `running`**, sa console encore ouverte, jusqu'à ce que
  l'invité en décide autrement. Il peut y mettre une minute, et il peut ne
  jamais répondre du tout — un invité sans gestionnaire ACPI ignore la demande,
  et rien dans le protocole ne peut le forcer.

Un client doit donc sonder jusqu'à `stopped` plutôt que croire la réponse, de la
même façon qu'il sonde jusqu'à `running` plus un port pour un démarrage. Le
backend de démonstration modélise les deux : il ignorait `force` et répondait
`stopped` aux deux, ce qui apprenait le contraire de ce qui se passe.

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
servir quatre routes ; il en fait aujourd'hui **1,7 Mo** en un seul fichier
statique (musl) qui tourne sur n'importe quel Linux, Alpine compris — mesuré
sur le binaire que la release publie, TLS et appairage compris. Ce paragraphe
a longtemps dit « moins de 600 Ko » : c'était vrai avant que le démon
n'apprenne le TLS, et personne n'avait re-mesuré.

Zéro dépendance, délibérément. Un programme qu'on installe par un `curl | sh`
est un programme dont on hérite les dépendances, et le protocole ci-dessus est
assez petit pour qu'un serveur HTTP/1.1 et un écrivain JSON écrits à la main
représentent moins de code que la glu qu'un framework demanderait.

Les pièces :

- `http.rs`, un serveur HTTP/1.1 sur la bibliothèque standard, un fil par
  connexion, avec des plafonds sur les en-têtes et le corps, et le cadrage
  strict (chunked refusé en 501, Content-Length répété ou signé refusé) ;
- `service.rs`, le routage du protocole ci-dessus, jeton comparé en temps
  constant, identifiant de VM validé à la frontière ;
- `backend.rs`, deux backends : `VirshBackend` pilote libvirt via la CLI
  `virsh` (pas de liaison C, dégradation propre si libvirt est absent), et
  `DemoBackend` sert deux VM factices avec de vraies transitions d'état ;
- `tls.rs`, le certificat auto-signé persistant et sa clé (mode 600 dès le
  premier octet), et `pairing.rs`, les liens `wisq://` imprimés au lancement ;
- `vm.rs`, l'écrivain et le lecteur JSON écrits à la main.

**Le format de fil est gardé par un test qui traverse les deux langages** : la
suite Swift lance le vrai binaire Rust sur un port éphémère et l'interroge avec
le même `AgentClient` que l'application embarque. C'est le seul endroit où une
divergence entre les deux moitiés du protocole peut se voir, et depuis qu'elles
ne sont plus écrites dans la même langue, c'est le test qui compte.

```sh
cargo run -p wisq-agent -- --demo   # essai sans libvirt
cargo run -p wisq-agent             # libvirt via virsh, port 7442
```
