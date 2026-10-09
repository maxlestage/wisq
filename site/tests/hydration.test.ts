/// **Ce que le module WebAssembly fait réellement dans une page.**
///
/// Tous les autres tests du front mesurent la *construction* : que le module
/// soit émis, qu'il pèse ce qu'il doit, qu'il soit précaché, que la page
/// l'importe, que son balisage pré-rendu soit le bon. Aucun ne dit qu'il
/// **arrive** — et c'est la première leçon de ce dépôt : un test qui vérifie
/// qu'une chose se construit ne dit rien de son arrivée. En #332, le wasm
/// publié n'importait pas `documentElement` ; tous les tests de forme étaient
/// verts, et seul un test qui appuyait sur le bouton l'a vu.
///
/// Ce fichier charge donc le vrai module, dans la vraie page construite, et
/// appuie sur les boutons. **Il prend la page pour unité, pas le propriétaire**
/// (#333) : il ne demande jamais si un comportement est porté par un îlot, par
/// une fonction du module ou par un script, il demande qu'il existe. C'est ce
/// qui a rendu visible chaque transfert pendant la migration, et c'est ce qui
/// rend visible aujourd'hui que **plus rien** n'est porté par un script :
/// `src/main.ts` est parti, et ces tests n'ont changé que leur façon de charger
/// la page.
///
/// Chaque test ouvre sa page dans un DOM neuf et démarre une instance neuve du
/// module (`tests/module.ts`), donc les scénarios sont indépendants — ce que la
/// première version de ce fichier ne pouvait pas offrir, et qui l'obligeait à
/// tenir trois gestes dans un seul test.

import { afterEach, describe, expect, test } from "bun:test";
import { catalogue, page } from "./catalogue";
import { cliquer, fermer, jusqua, ouvrir } from "./module";

afterEach(fermer);

const boutons = () => [...document.querySelectorAll("[data-theme-choice]")] as HTMLElement[];
const presse = () =>
  boutons()
    .filter((b) => b.getAttribute("aria-pressed") === "true")
    .map((b) => b.dataset.themeChoice);
const metas = () =>
  [...document.querySelectorAll('meta[name="theme-color"]')].map((m) => m.getAttribute("content"));

describe("les réglages de l'en-tête, un îlot", () => {
  /// **La condition attend le changement, pas un état.** Le balisage pré-rendu
  /// part avec `auto` pressé — la seule réponse juste avant d'avoir lu le
  /// stockage. Attendre « un bouton pressé » rendrait la main avant l'effet.
  test("le choix mémorisé est celui qui apparaît pressé", async () => {
    await ouvrir("offline/index.html", { stockage: { "wisq.theme": "dark" } });
    expect(boutons().length, "trois boutons de thème").toBe(3);
    await jusqua(() => presse()[0] === "dark", "que l'effet relise le choix mémorisé");
    expect(presse()).toEqual(["dark"]);
  });

  /// **Et l'attente porte sur l'état pressé, pas seulement sur `data-theme`.**
  /// La version précédente attendait l'attribut — posé de façon synchrone dans
  /// le gestionnaire — puis lisait l'état pressé, qui demande un nouveau rendu
  /// de Yew. Elle est tombée au premier tour complet de la suite de cette
  /// tranche, avant qu'une ligne ne change, et passait trois fois sur trois
  /// seule : une course, que la charge de la suite entière faisait perdre.
  /// Yew 0.23 rend la main au navigateur entre deux tâches ; le nouveau rendu
  /// arrive après, et il faut l'attendre comme le reste.
  test("un clic applique, mémorise, déplace l'état pressé et repeint la barre", async () => {
    await ouvrir("offline/index.html");
    const { bar } = catalogue();
    cliquer(document.querySelector('[data-theme-choice="light"]')!);
    await jusqua(() => presse()[0] === "light", "que le clic déplace l'état pressé");
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
    expect(localStorage.getItem("wisq.theme")).toBe("light");
    // **Les deux métas suivent un choix explicite.** Sur `auto` elles suivent
    // le système par leur requête `media` ; sur un choix, les deux doivent
    // dire la couleur choisie, sinon la barre d'état est peinte pour un thème
    // que la page n'emploie pas. La première version Yew l'avait oublié.
    expect(metas()).toEqual([bar.light, bar.light]);

    cliquer(document.querySelector('[data-theme-choice="dark"]')!);
    await jusqua(() => presse()[0] === "dark", "que le second clic déplace l'état pressé");
    expect(metas()).toEqual([bar.dark, bar.dark]);
  });

  /// **Avec du mouvement, le thème s'ouvre en cercle.** La transition de vue
  /// est prêtée par le test — happy-dom n'en a pas — et elle fait ce qu'un
  /// navigateur fait : elle appelle le rappel, qui applique le thème, et rend
  /// une promesse de fin. Le module pose le centre du bouton et la classe qui
  /// choisit l'animation, puis la retire à la fin.
  test("avec du mouvement, le thème passe par une transition de vue, puis la referme", async () => {
    const vues: string[] = [];
    await ouvrir("offline/index.html", {
      avant: () => {
        (document as unknown as Record<string, unknown>).startViewTransition = (rappel: () => void) => {
          vues.push(document.documentElement.className);
          rappel();
          return { finished: Promise.resolve() };
        };
      },
    });
    await jusqua(() => document.documentElement.dataset.motion === "on", "que le mouvement démarre");
    cliquer(document.querySelector('[data-theme-choice="light"]')!);
    await jusqua(() => presse()[0] === "light", "que le clic déplace l'état pressé");
    expect(vues.length, "une transition par clic").toBe(1);
    expect(vues[0], "la classe est posée avant la photographie").toContain("bascule");
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
    expect(document.documentElement.style.getPropertyValue("--bx"), "le centre du bouton").not.toBe("");
    await jusqua(
      () => !document.documentElement.classList.contains("bascule"),
      "que la classe parte avec la fin de la transition",
    );
  });

  /// **Au calme, pas de cercle** : la transition existe dans ce navigateur, et
  /// le thème s'applique quand même d'un coup.
  test("au calme, le thème s'applique d'un coup, sans transition", async () => {
    let vues = 0;
    await ouvrir("offline/index.html", {
      calme: true,
      avant: () => {
        (document as unknown as Record<string, unknown>).startViewTransition = (rappel: () => void) => {
          vues += 1;
          rappel();
          return { finished: Promise.resolve() };
        };
      },
    });
    cliquer(document.querySelector('[data-theme-choice="dark"]')!);
    await jusqua(() => presse()[0] === "dark", "que le clic déplace l'état pressé");
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(vues, "aucune transition demandée").toBe(0);
  });

  /// `auto` est l'absence de choix, pas une troisième valeur stockée : sinon un
  /// lecteur revenu à `auto` resterait épinglé au thème du jour où il l'a fait.
  test("« automatique » retire la valeur au lieu de stocker « auto »", async () => {
    await ouvrir("offline/index.html", { stockage: { "wisq.theme": "dark" } });
    await jusqua(() => presse()[0] === "dark", "que l'effet relise le choix mémorisé");
    cliquer(document.querySelector('[data-theme-choice="auto"]')!);
    await jusqua(() => presse()[0] === "auto", "que le retour à « automatique » soit pressé");
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
    expect(localStorage.getItem("wisq.theme")).toBeNull();
    // Chaque méta reprend la couleur de sa propre requête.
    const { bar } = catalogue();
    expect(metas()).toEqual([bar.dark, bar.light]);
  });

  test("suivre un lien de langue mémorise le choix, sans empêcher la navigation", async () => {
    await ouvrir("docs/index.html");
    const lien = document.querySelector('.lang-switch a[hreflang="fr"]')!;
    const clic = new MouseEvent("click", { bubbles: true, cancelable: true });
    // L'îlot se rattache après l'hydratation ; on attend qu'il réponde.
    await jusqua(() => {
      lien.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      return localStorage.getItem("wisq.lang") === "fr";
    }, "que le clic sur FR mémorise la langue");
    lien.dispatchEvent(clic);
    expect(clic.defaultPrevented, "le lien doit rester un lien").toBe(false);
  });

  /// **Un îlot ne touche que sa racine.** Yew retire de la racine qu'il hydrate
  /// tout nœud que le composant ne réclame pas : hydraté sur `#root`, il aurait
  /// effacé la page. Le texte du document, lui, n'appartient à aucun îlot, et
  /// il doit être exactement celui que la construction a écrit.
  test("l'hydratation laisse le reste de la page tel qu'il est arrivé", async () => {
    await ouvrir("docs/index.html");
    const texte = document.querySelector("#main")!.textContent;
    const reglages = document.querySelector('[data-ilot="reglages"]')!;
    await jusqua(() => presse().length === 1, "que l'îlot soit hydraté");
    expect(document.querySelector("#main")!.textContent).toBe(texte);
    expect(reglages.querySelectorAll("button").length, "les trois boutons restent").toBe(3);
    expect(reglages.querySelectorAll(".lang-switch a").length, "les deux liens restent").toBe(2);
  });
});

describe("la langue de l'accueil", () => {
  /// La redirection est le seul comportement qui puisse agacer un lecteur, donc
  /// ses trois conditions sont vérifiées une par une : seulement depuis
  /// l'accueil anglais, seulement si rien n'a jamais été choisi, seulement
  /// pour un navigateur francophone.
  function francophone(remplace: { vers?: string }) {
    return () => {
      Object.defineProperty(navigator, "language", { value: "fr-FR", configurable: true });
      Object.defineProperty(location, "replace", {
        value: (href: string) => {
          remplace.vers = href;
        },
        configurable: true,
      });
    };
  }

  test("un navigateur francophone sur l'accueil anglais est envoyé au français", async () => {
    const remplace: { vers?: string } = {};
    await ouvrir("index.html", { avant: francophone(remplace) });
    expect(remplace.vers).toBe("https://example.test/fr/");
  });

  test("un lecteur qui a déjà choisi l'anglais est laissé tranquille", async () => {
    const remplace: { vers?: string } = {};
    await ouvrir("index.html", { stockage: { "wisq.lang": "en" }, avant: francophone(remplace) });
    expect(remplace.vers).toBeUndefined();
  });

  test("un lien profond partagé en anglais n'est pas redirigé", async () => {
    const remplace: { vers?: string } = {};
    await ouvrir("docs/index.html", { avant: francophone(remplace) });
    expect(remplace.vers).toBeUndefined();
  });

  test("l'accueil français ne renvoie nulle part", async () => {
    const remplace: { vers?: string } = {};
    await ouvrir("fr/index.html", { avant: francophone(remplace) });
    expect(remplace.vers).toBeUndefined();
  });
});

describe("l'invite d'installation, un îlot", () => {
  const banniere = () => document.querySelector<HTMLElement>("[data-install]")!;
  const variante = (v: string) =>
    document.querySelector(`[data-install-variant="${v}"]`)!.hasAttribute("hidden");

  function signal() {
    const evenement = new Event("beforeinstallprompt", { cancelable: true }) as Event & {
      prompt: () => Promise<void>;
      userChoice: Promise<{ outcome: string }>;
    };
    let rejouee = false;
    evenement.prompt = async () => {
      rejouee = true;
    };
    evenement.userChoice = Promise.resolve({ outcome: "accepted" });
    return { evenement, rejouee: () => rejouee };
  }

  test("rien n'est montré à un navigateur qui ne propose jamais l'installation", async () => {
    await ouvrir("index.html");
    await jusqua(() => presse().length === 1, "que les îlots soient hydratés");
    expect(banniere().hasAttribute("hidden")).toBe(true);
  });

  /// L'événement est retenu et la formulation de Chromium montrée — et celle
  /// d'iOS reste masquée : dire « touchez le bouton Partager » à un lecteur qui
  /// n'en a pas serait pire que de se taire.
  test("beforeinstallprompt révèle la bannière, sa formulation et son bouton", async () => {
    await ouvrir("index.html");
    const { evenement, rejouee } = signal();
    await jusqua(() => {
      window.dispatchEvent(evenement);
      return !banniere().hasAttribute("hidden");
    }, "que beforeinstallprompt révèle l'invite");
    expect(evenement.defaultPrevented, "l'invite du navigateur doit être retenue").toBe(true);
    expect(variante("prompt")).toBe(false);
    expect(variante("ios")).toBe(true);
    const accepter = document.querySelector<HTMLElement>("[data-install-accept]")!;
    expect(accepter.hasAttribute("hidden")).toBe(false);

    // Le bouton rejoue l'invite retenue, et la bannière part quand le lecteur
    // a répondu.
    cliquer(accepter);
    await jusqua(() => banniere().hasAttribute("hidden"), "que la réponse masque l'invite");
    expect(rejouee(), "l'invite retenue n'a pas été rejouée").toBe(true);
  });

  test("le renvoi masque l'invite, et elle ne revient pas", async () => {
    await ouvrir("index.html");
    const { evenement } = signal();
    await jusqua(() => {
      window.dispatchEvent(evenement);
      return !banniere().hasAttribute("hidden");
    }, "que beforeinstallprompt révèle l'invite");
    cliquer(document.querySelector("[data-install-dismiss]")!);
    await jusqua(() => banniere().hasAttribute("hidden"), "que le renvoi masque l'invite");
    expect(localStorage.getItem("wisq.install.dismissed")).toBe("1");

    // Une seconde visite : la même page, le même événement, et toujours rien.
    await ouvrir("index.html", { stockage: { "wisq.install.dismissed": "1" } });
    await jusqua(() => presse().length === 1, "que les îlots soient hydratés");
    window.dispatchEvent(signal().evenement);
    await new Promise((r) => setTimeout(r, 20));
    expect(banniere().hasAttribute("hidden")).toBe(true);
  });

  /// **Sur iOS, la formulation tout de suite, et aucun bouton.** Safari n'émet
  /// jamais `beforeinstallprompt` : il n'y a rien à attendre, et aucune API à
  /// appeler — les trois gestes sont toute la fonctionnalité.
  test("sur iPhone, les trois gestes, sans bouton", async () => {
    await ouvrir("index.html", {
      avant: () =>
        Object.defineProperty(navigator, "userAgent", {
          value: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
          configurable: true,
        }),
    });
    await jusqua(() => !banniere().hasAttribute("hidden"), "que l'invite iOS se montre");
    expect(variante("ios")).toBe(false);
    expect(variante("prompt")).toBe(true);
    expect(document.querySelector("[data-install-accept]")!.hasAttribute("hidden")).toBe(true);
  });
});

/// **Toutes les pages, pas une.** Les deux îlots sont dans la coquille, donc
/// sur chaque page ; une page dont l'un manquerait — une route rendue hors de
/// la coquille, un document d'une version précédente — garderait l'autre, et
/// c'est ce que vérifie `navigateur.rs`. Ce test-ci vérifie qu'aucune page
/// construite n'en manque.
test("chaque page construite porte ses deux îlots", () => {
  for (const { file, markup } of catalogue().pages) {
    expect(markup, `${file} : réglages`).toContain('data-ilot="reglages"');
    expect(markup, `${file} : invite`).toContain('data-ilot="installation"');
  }
  expect(page("home", "en").markup).toContain('data-theme-choice="auto" aria-pressed="true"');
});
