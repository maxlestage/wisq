//! La vie privée : ce que le site et l'application ne font pas.
//!
//! Des données, pas du balisage : `crate::doc` est le seul rendu, et une
//! traduction manquante ne compile pas.

use crate::doc::{Block, DlItem, Doc, Tone};

pub static PRIVACY_EN: Doc = Doc {
    title: "Privacy",
    lede: "What this site collects, in full: nothing. Here is what that means concretely, and what your browser keeps on its own.",
    blocks: &[
        Block::P("Most privacy pages describe what is collected and why it is fine. This one describes an absence, which is shorter and easier to verify — and verifiable is the point, because a claim nobody can check is worth nothing."),
        Block::H2("No analytics, no cookies, no third parties"),
        Block::P("There is no analytics script, no tag manager, no embedded video, no web font from someone else's server, and no social widget. The site sets no cookies of any kind — not for measurement and not for preferences."),
        Block::P("That is not a promise on our word. Every address the built site references is checked at build time, and a request to any host other than this one fails the build. You can confirm it yourself: open the developer tools, reload, and look at what was requested."),
        Block::H2("What your browser stores locally"),
        Block::P("Two small values, on your device, readable by nobody but you. They are never sent anywhere because there is nowhere to send them."),
        Block::Dl(&[DlItem { term: "The language you picked", detail: "So that choosing French once does not have to be repeated on every page. Stored under wisq.lang in local storage." }, DlItem { term: "Whether you dismissed the install banner", detail: "So that a banner you said no to stops asking. Stored under wisq.install.dismissed." }]),
        Block::P("The service worker also keeps a copy of the pages you have read, so the site works with no network. That cache lives on your device and is cleared with the site's data like anything else."),
        Block::P("Clearing site data in your browser removes all of it. Nothing is restored from anywhere, because nothing left."),
        Block::H2("What the host sees"),
        Block::P("The site is static files served by Heroku. Heroku receives the requests, and therefore sees what any web server sees: an IP address, a user agent, and which files were asked for. That is theirs, governed by Heroku's privacy statement, and outside what this project controls. It is stated here rather than omitted because omitting it would make the paragraph above misleading."),
        Block::H2("The app is a separate matter"),
        Block::P("wisq itself sends nothing to us either — there is no account, no telemetry, and no server of ours anywhere in the path. It talks to machines you already have, on addresses you type in. Passwords live in the iPhone Keychain; the machine list is plain JSON on your device and contains no secret."),
        Block::Note { tone: Tone::Warn, text: "One honest caveat about the app: plain TCP is a machine's default transport, so it speaks to that machine in the clear, and on an untrusted network that traffic is readable. It is a default, not a limit — the editor offers TLS, and TLS pinned to a certificate fingerprint, machine by machine, and it says under the picker which one a given machine will get. The host agent is a separate matter and speaks TLS on its own: a self-signed certificate whose SHA-256 travels in the pairing link and is pinned by the app." },
        Block::H2("Changes, and how to ask"),
        Block::P("If any of this ever stops being true, it changes here first and in the changelog at the same time. If something on this page is unclear or looks wrong, open an issue — that is a better outcome for everyone than a quiet assumption."),
    ],
};

pub static PRIVACY_FR: Doc = Doc {
    title: "Confidentialité",
    lede: "Ce que ce site collecte, en entier : rien. Voici ce que cela signifie concrètement, et ce que votre navigateur conserve de lui-même.",
    blocks: &[
        Block::P("La plupart des pages de confidentialité décrivent ce qui est collecté et pourquoi ce n'est pas grave. Celle-ci décrit une absence, ce qui est plus court et plus facile à vérifier — et la vérifiabilité est justement le sujet, car une affirmation que personne ne peut contrôler ne vaut rien."),
        Block::H2("Aucune mesure d'audience, aucun cookie, aucun tiers"),
        Block::P("Il n'y a pas de script de mesure, pas de gestionnaire de balises, pas de vidéo intégrée, pas de police web servie par quelqu'un d'autre, pas de widget social. Le site ne dépose aucun cookie — ni pour mesurer, ni pour des préférences."),
        Block::P("Ce n'est pas une promesse sur parole. Chaque adresse référencée par le site construit est vérifiée au build, et une requête vers un autre hôte que celui-ci fait échouer la construction. Vous pouvez le constater vous-même : ouvrez les outils de développement, rechargez, et regardez ce qui a été demandé."),
        Block::H2("Ce que votre navigateur garde en local"),
        Block::P("Deux petites valeurs, sur votre appareil, lisibles par personne d'autre que vous. Elles ne sont envoyées nulle part, faute d'un endroit où les envoyer."),
        Block::Dl(&[DlItem { term: "La langue que vous avez choisie", detail: "Pour que choisir le français une fois n'ait pas à être refait sur chaque page. Rangée sous wisq.lang dans le stockage local." }, DlItem { term: "Le fait que vous ayez écarté la bannière d'installation", detail: "Pour qu'une bannière refusée cesse de demander. Rangée sous wisq.install.dismissed." }]),
        Block::P("Le service worker conserve aussi une copie des pages que vous avez lues, pour que le site fonctionne sans réseau. Ce cache vit sur votre appareil et se vide avec les données du site, comme le reste."),
        Block::P("Effacer les données du site dans votre navigateur retire l'ensemble. Rien n'est restauré depuis ailleurs, puisque rien n'en est parti."),
        Block::H2("Ce que voit l'hébergeur"),
        Block::P("Le site est un ensemble de fichiers statiques servis par Heroku. Heroku reçoit les requêtes et voit donc ce que voit n'importe quel serveur web : une adresse IP, un agent utilisateur, et les fichiers demandés. Cela leur appartient, relève de la politique de confidentialité d'Heroku, et échappe à ce que ce projet contrôle. C'est dit ici plutôt qu'omis, car l'omettre rendrait le paragraphe précédent trompeur."),
        Block::H2("L'application est un sujet distinct"),
        Block::P("wisq ne nous envoie rien non plus — pas de compte, pas de télémétrie, aucun serveur à nous sur le chemin. L'application parle à des machines que vous possédez déjà, sur des adresses que vous saisissez. Les mots de passe vivent dans le trousseau de l'iPhone ; la liste des machines est du JSON sur votre appareil et ne contient aucun secret."),
        Block::Note { tone: Tone::Warn, text: "Une réserve honnête sur l'application : le TCP en clair est le transport par défaut d'une machine, et sur un réseau non fiable ce trafic est lisible. C'est un défaut, pas une limite — l'éditeur propose TLS, et TLS épinglé par empreinte de certificat, machine par machine, et il dit sous le sélecteur ce qu'une machine donnée obtiendra. Le démon hôte est un cas à part et parle TLS de lui-même : un certificat auto-signé dont l'empreinte SHA-256 voyage dans le lien d'appairage et que l'application épingle." },
        Block::H2("Changements, et comment demander"),
        Block::P("Si l'un de ces points cesse d'être vrai, cela change ici en premier et dans le journal des modifications en même temps. Si quelque chose sur cette page est flou ou paraît faux, ouvrez une issue — c'est un meilleur résultat pour tout le monde qu'une supposition silencieuse."),
    ],
};
