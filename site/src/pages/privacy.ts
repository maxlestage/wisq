import type { Doc } from "../doc";

export const privacyEn: Doc = {
  title: "Privacy",
  lede: "What this site collects, in full: nothing. Here is what that means concretely, and what your browser keeps on its own.",
  blocks: [
    {
      kind: "p",
      text:
        "Most privacy pages describe what is collected and why it is fine. This one describes an absence, which is shorter and easier to verify — and verifiable is the point, because a claim nobody can check is worth nothing.",
    },

    { kind: "h2", text: "No analytics, no cookies, no third parties" },
    {
      kind: "p",
      text:
        "There is no analytics script, no tag manager, no embedded video, no web font from someone else's server, and no social widget. The site sets no cookies of any kind — not for measurement and not for preferences.",
    },
    {
      kind: "p",
      text:
        "That is not a promise on our word. Every address the built site references is checked at build time, and a request to any host other than this one fails the build. You can confirm it yourself: open the developer tools, reload, and look at what was requested.",
    },

    { kind: "h2", text: "What your browser stores locally" },
    {
      kind: "p",
      text:
        "Two small values, on your device, readable by nobody but you. They are never sent anywhere because there is nowhere to send them.",
    },
    {
      kind: "dl",
      items: [
        {
          term: "The language you picked",
          detail:
            "So that choosing French once does not have to be repeated on every page. Stored under wisq.lang in local storage.",
        },
        {
          term: "Whether you dismissed the install banner",
          detail:
            "So that a banner you said no to stops asking. Stored under wisq.install.dismissed.",
        },
      ],
    },
    {
      kind: "p",
      text:
        "The service worker also keeps a copy of the pages you have read, so the site works with no network. That cache lives on your device and is cleared with the site's data like anything else.",
    },
    {
      kind: "p",
      text:
        "Clearing site data in your browser removes all of it. Nothing is restored from anywhere, because nothing left.",
    },

    { kind: "h2", text: "What the host sees" },
    {
      kind: "p",
      text:
        "The site is static files served by GitHub Pages. GitHub receives the requests, and therefore sees what any web server sees: an IP address, a user agent, and which files were asked for. That is theirs, governed by GitHub's privacy statement, and outside what this project controls. It is stated here rather than omitted because omitting it would make the paragraph above misleading.",
    },

    { kind: "h2", text: "The app is a separate matter" },
    {
      kind: "p",
      text:
        "wisq itself sends nothing to us either — there is no account, no telemetry, and no server of ours anywhere in the path. It talks to machines you already have, on addresses you type in. Passwords live in the iPhone Keychain; the machine list is plain JSON on your device and contains no secret.",
    },
    {
      kind: "note",
      tone: "warn",
      text:
        "One honest caveat about the app, repeated from the questions page because it belongs here too: version 1 speaks to your machines in the clear. That traffic is between you and your own hardware, but on an untrusted network it is readable. Use a network you trust or a tunnel you already run.",
    },

    { kind: "h2", text: "Changes, and how to ask" },
    {
      kind: "p",
      text:
        "If any of this ever stops being true, it changes here first and in the changelog at the same time. If something on this page is unclear or looks wrong, open an issue — that is a better outcome for everyone than a quiet assumption.",
    },
  ],
};

export const privacyFr: Doc = {
  title: "Confidentialité",
  lede: "Ce que ce site collecte, en entier : rien. Voici ce que cela signifie concrètement, et ce que votre navigateur conserve de lui-même.",
  blocks: [
    {
      kind: "p",
      text:
        "La plupart des pages de confidentialité décrivent ce qui est collecté et pourquoi ce n'est pas grave. Celle-ci décrit une absence, ce qui est plus court et plus facile à vérifier — et la vérifiabilité est justement le sujet, car une affirmation que personne ne peut contrôler ne vaut rien.",
    },

    { kind: "h2", text: "Aucune mesure d'audience, aucun cookie, aucun tiers" },
    {
      kind: "p",
      text:
        "Il n'y a pas de script de mesure, pas de gestionnaire de balises, pas de vidéo intégrée, pas de police web servie par quelqu'un d'autre, pas de widget social. Le site ne dépose aucun cookie — ni pour mesurer, ni pour des préférences.",
    },
    {
      kind: "p",
      text:
        "Ce n'est pas une promesse sur parole. Chaque adresse référencée par le site construit est vérifiée au build, et une requête vers un autre hôte que celui-ci fait échouer la construction. Vous pouvez le constater vous-même : ouvrez les outils de développement, rechargez, et regardez ce qui a été demandé.",
    },

    { kind: "h2", text: "Ce que votre navigateur garde en local" },
    {
      kind: "p",
      text:
        "Deux petites valeurs, sur votre appareil, lisibles par personne d'autre que vous. Elles ne sont envoyées nulle part, faute d'un endroit où les envoyer.",
    },
    {
      kind: "dl",
      items: [
        {
          term: "La langue que vous avez choisie",
          detail:
            "Pour que choisir le français une fois n'ait pas à être refait sur chaque page. Rangée sous wisq.lang dans le stockage local.",
        },
        {
          term: "Le fait que vous ayez écarté la bannière d'installation",
          detail:
            "Pour qu'une bannière refusée cesse de demander. Rangée sous wisq.install.dismissed.",
        },
      ],
    },
    {
      kind: "p",
      text:
        "Le service worker conserve aussi une copie des pages que vous avez lues, pour que le site fonctionne sans réseau. Ce cache vit sur votre appareil et se vide avec les données du site, comme le reste.",
    },
    {
      kind: "p",
      text:
        "Effacer les données du site dans votre navigateur retire l'ensemble. Rien n'est restauré depuis ailleurs, puisque rien n'en est parti.",
    },

    { kind: "h2", text: "Ce que voit l'hébergeur" },
    {
      kind: "p",
      text:
        "Le site est un ensemble de fichiers statiques servis par GitHub Pages. GitHub reçoit les requêtes et voit donc ce que voit n'importe quel serveur web : une adresse IP, un agent utilisateur, et les fichiers demandés. Cela leur appartient, relève de la politique de confidentialité de GitHub, et échappe à ce que ce projet contrôle. C'est dit ici plutôt qu'omis, car l'omettre rendrait le paragraphe précédent trompeur.",
    },

    { kind: "h2", text: "L'application est un sujet distinct" },
    {
      kind: "p",
      text:
        "wisq ne nous envoie rien non plus — pas de compte, pas de télémétrie, aucun serveur à nous sur le chemin. L'application parle à des machines que vous possédez déjà, sur des adresses que vous saisissez. Les mots de passe vivent dans le trousseau de l'iPhone ; la liste des machines est du JSON sur votre appareil et ne contient aucun secret.",
    },
    {
      kind: "note",
      tone: "warn",
      text:
        "Une réserve honnête sur l'application, reprise de la page des questions parce qu'elle a sa place ici aussi : la version 1 parle à vos machines en clair. Ce trafic est entre vous et votre propre matériel, mais il est lisible sur un réseau non fiable. Utilisez un réseau de confiance ou un tunnel que vous exploitez déjà.",
    },

    { kind: "h2", text: "Changements, et comment demander" },
    {
      kind: "p",
      text:
        "Si l'un de ces points cesse d'être vrai, cela change ici en premier et dans le journal des modifications en même temps. Si quelque chose sur cette page est flou ou paraît faux, ouvrez une issue — c'est un meilleur résultat pour tout le monde qu'une supposition silencieuse.",
    },
  ],
};
