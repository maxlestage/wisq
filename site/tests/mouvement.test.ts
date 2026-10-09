/// Le mouvement, exécuté plutôt que relu — et exécuté dans le vrai module.
///
/// Ce fichier remplace `motion.test.ts`, qui appelait `startMotion` de
/// `src/motion.ts` dans un DOM de fortune. Le mouvement est en Rust maintenant,
/// dans le module wasm que la construction publie, donc c'est lui qui tourne
/// ici, sur les vraies pages de `dist`, dans happy-dom. Les scénarios sont ceux
/// de l'ancien fichier, un par un, et la règle qu'ils tiennent n'a pas bougé.
///
/// **Ce qu'il tient avant tout est une promesse de non-régression du site
/// entier** : aucun bloc ne doit être masqué quand personne ne peut le
/// révéler. Une feuille de style qui cacherait sans condition, plus un module
/// qui ne part pas, font une page blanche — et c'est le seul défaut de ce
/// domaine qui coûterait le site plutôt qu'une animation.
///
/// **Ce qui est maîtrisé, et rien d'autre.** L'observateur d'entrée dans la vue
/// est remplacé par un observateur qu'on déclenche à la main : happy-dom en
/// fournit un qui ne voit jamais rien entrer, puisqu'il ne met rien en page. Et
/// les mesures que happy-dom ne calcule pas — une hauteur de page, la boîte
/// d'un élément — sont posées sur l'élément concerné. Tout le reste est le
/// module tel qu'il est publié.

import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fermer, jusqua, ouvrir } from "./module";

afterEach(fermer);

/// L'entrée que le module reçoit. Elle doit être une instance de la classe que
/// le global nomme `IntersectionObserverEntry` : le module la reconnaît par
/// `instanceof`, comme il reconnaîtrait celle d'un navigateur.
class Entree {
  constructor(
    readonly target: Element,
    readonly isIntersecting: boolean,
  ) {}
}

/// Un observateur qu'on déclenche à la main : le test décide quand un bloc
/// entre dans la vue, ce qu'aucun navigateur absent ne ferait pour lui.
class Observateur {
  static vivants: Observateur[] = [];
  regardes: Element[] = [];
  constructor(private readonly rappel: (entrees: Entree[], o: Observateur) => void) {
    Observateur.vivants.push(this);
  }
  observe(cible: Element) {
    this.regardes.push(cible);
  }
  unobserve(cible: Element) {
    this.regardes = this.regardes.filter((c) => c !== cible);
  }
  disconnect() {
    this.regardes = [];
  }
  entrer(cible: Element) {
    this.rappel([new Entree(cible, true)], this);
  }
  sortir(cible: Element) {
    this.rappel([new Entree(cible, false)], this);
  }
  /// L'élément entre dans la vue pour **tous** ceux qui le regardent — un
  /// titre de section est regardé par la révélation et par le sommaire, et
  /// un navigateur les préviendrait tous les deux.
  static entrerPartout(cible: Element) {
    for (const o of Observateur.vivants.filter((o) => o.regardes.includes(cible))) o.entrer(cible);
  }
  /// Celui des observateurs qui regarde cet élément.
  static de(cible: Element): Observateur {
    const trouve = Observateur.vivants.find((o) => o.regardes.includes(cible));
    if (!trouve) throw new Error("aucun observateur ne regarde cet élément");
    return trouve;
  }
}

function observateurMaitrise() {
  Observateur.vivants = [];
  const g = globalThis as Record<string, unknown>;
  g.IntersectionObserver = Observateur;
  g.IntersectionObserverEntry = Entree;
  (window as unknown as Record<string, unknown>).IntersectionObserver = Observateur;
}

/// Une mesure que happy-dom ne calcule pas, posée sur l'élément lui-même.
function mesurer(element: Element, nom: string, valeur: () => unknown) {
  Object.defineProperty(element, nom, { configurable: true, get: valeur });
}

function boite(element: Element, b: { left?: number; top?: number; width?: number; height?: number }) {
  const r = { left: 0, top: 0, width: 0, height: 0, ...b };
  (element as unknown as { getBoundingClientRect: () => unknown }).getBoundingClientRect = () => ({
    ...r,
    x: r.left,
    y: r.top,
    right: r.left + r.width,
    bottom: r.top + r.height,
  });
}

const racine = () => document.documentElement;
const style = (e: Element, nom: string) => (e as HTMLElement).style.getPropertyValue(nom);
const defiler = () => window.dispatchEvent(new Event("scroll"));

/// Attendre un temps réel, borné : une montée de chiffre dure 900 ms d'horloge.
async function jusquaLent(condition: () => boolean, quoi: string) {
  for (let tour = 0; tour < 150; tour += 1) {
    if (condition()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`délai dépassé en attendant : ${quoi}`);
}

describe("le mouvement", () => {
  /// **La promesse qui compte plus que l'animation elle-même.**
  test("une demande de moins d'animation ne masque rien du tout", async () => {
    await ouvrir("index.html", { calme: true, avant: observateurMaitrise });
    expect(racine().dataset.motion, "l'attribut qui arme les règles de masquage").toBeUndefined();
    expect(document.querySelectorAll("[data-reveal]").length, "aucun bloc n'est marqué").toBe(0);
    // Ni épinglage piloté, ni roue détournée.
    expect(style(document.querySelector(".hero")!, "--ouverture")).toBe("");
    const roue = new WheelEvent("wheel", { deltaY: 200, bubbles: true, cancelable: true });
    document.body.dispatchEvent(roue);
    expect(roue.defaultPrevented, "la molette ne doit pas être reprise").toBe(false);
  });

  /// Sans observateur, personne ne révélerait ce qu'on aurait caché.
  test("sans IntersectionObserver, rien n'est masqué non plus", async () => {
    await ouvrir("docs/index.html", {
      avant: () => {
        delete (globalThis as Record<string, unknown>).IntersectionObserver;
        delete (window as unknown as Record<string, unknown>).IntersectionObserver;
      },
    });
    expect(racine().dataset.motion).toBeUndefined();
    expect(document.querySelectorAll("[data-reveal]").length).toBe(0);
  });

  test("autrement, les blocs se lèvent en entrant dans la vue", async () => {
    await ouvrir("docs/index.html", { avant: observateurMaitrise });
    expect(racine().dataset.motion).toBe("on");
    expect(style(racine(), "--rise")).not.toBe("");
    const blocs = [...document.querySelectorAll<HTMLElement>(".doc > .wrap > :not(.doc-head)")];
    expect(blocs.length, "un document a des blocs").toBeGreaterThan(5);
    for (const bloc of blocs) expect(bloc.dataset.reveal, "chaque bloc est inscrit").toBe("");
    // **Sauf l'en-tête**, qui entre mot par mot sous `html.entree`, avant la
    // première peinture. Révélé ici aussi, il serait peint, masqué par le
    // module, puis rejoué : un clignotement en haut de chaque page.
    expect(document.querySelector<HTMLElement>(".doc-head")!.dataset.reveal).toBeUndefined();

    const observateur = Observateur.de(blocs[0]!);
    observateur.entrer(blocs[0]!);
    expect(blocs[0]!.dataset.revealed).toBe("");
    expect(blocs[1]!.dataset.revealed, "les autres attendent leur tour").toBeUndefined();
    // **Une fois, et on cesse de regarder** : un bloc qui rejouerait à chaque
    // passage ferait clignoter une page longue.
    //
    // **Un booléen, et c'est le sabordage qui l'a imposé.** La première forme
    // était `expect(regardes).not.toContain(bloc)` : juste, mais un échec doit
    // imprimer l'élément, et bun imprime un élément happy-dom en parcourant
    // tout ce qu'il touche — une seconde sur un DOM de deux paragraphes,
    // plusieurs minutes et 5 Go sur une page du site. Le sabordage qui retirait
    // `unobserve` a passé la suite, verdict perdu dans l'impression.
    expect(observateur.regardes.includes(blocs[0]!), "le bloc révélé est encore observé").toBe(false);
  });

  /// L'ouverture a sa propre entrée : la révéler au défilement la ferait
  /// disparaître puis revenir au premier pixel.
  test("l'ouverture n'est pas une section qui attend d'être révélée", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    expect(document.querySelector<HTMLElement>(".hero")!.dataset.reveal).toBeUndefined();
    expect(document.querySelector<HTMLElement>("#modes")!.dataset.reveal).toBe("");
  });

  /// **L'en-tête s'efface en descendant et revient en remontant** — loin du
  /// haut seulement, et pas pour un tremblement de molette.
  test("l'en-tête s'efface quand on descend, revient quand on remonte", async () => {
    await ouvrir("docs/index.html", { avant: observateurMaitrise });
    window.scrollTo(0, 200);
    defiler();
    expect(racine().dataset.cache, "trop près du haut pour s'effacer").toBeUndefined();
    window.scrollTo(0, 900);
    defiler();
    expect(racine().dataset.cache, "on descend : il s'efface").toBe("");
    window.scrollTo(0, 897);
    defiler();
    expect(racine().dataset.cache, "trois pixels ne sont pas un sens").toBe("");
    window.scrollTo(0, 700);
    defiler();
    expect(racine().dataset.cache, "on remonte : il revient").toBeUndefined();
  });

  test("l'en-tête se marque dès qu'on a quitté le haut", async () => {
    await ouvrir("docs/index.html", { avant: observateurMaitrise });
    expect(racine().dataset.scrolled, "au repos, rien").toBeUndefined();
    window.scrollTo(0, 40);
    defiler();
    expect(racine().dataset.scrolled).toBe("");
    window.scrollTo(0, 0);
    defiler();
    expect(racine().dataset.scrolled, "revenu en haut, la marque part").toBeUndefined();
  });

  /// **Le chiffre finit exactement sur le sien.**
  ///
  /// Ce sont des affirmations qu'un test tient — le nombre de tests du dépôt,
  /// celui des portes d'intégration. Une animation qui laisserait un chiffre
  /// approché à l'écran aurait introduit un mensonge que personne n'aurait
  /// écrit. Et **chaque image est un nombre honnête** : une montée qui
  /// afficherait « NaN » pendant une seconde avant de remettre la bonne valeur
  /// passerait un test qui ne regarde que la fin.
  test("un chiffre monte et s'arrête sur sa valeur, au caractère près", async () => {
    const ecrits: string[] = [];
    await ouvrir("index.html", {
      avant: () => {
        observateurMaitrise();
        const cellule = document.querySelector(".fact .value")!;
        // Le descripteur est cherché le long de la chaîne : happy-dom le pose
        // sur `Element`, pas sur `Node`, et celui de `Node` rend une chaîne
        // vide pour un élément — le premier jet lisait donc « 0 ».
        let porteur: object | null = cellule;
        while (porteur && !Object.getOwnPropertyDescriptor(porteur, "textContent")) {
          porteur = Object.getPrototypeOf(porteur);
        }
        const proto = Object.getOwnPropertyDescriptor(porteur!, "textContent")!;
        Object.defineProperty(cellule, "textContent", {
          configurable: true,
          get() {
            return proto.get!.call(this);
          },
          set(v: string) {
            ecrits.push(v);
            proto.set!.call(this, v);
          },
        });
      },
    });
    const cellule = document.querySelector(".fact .value")!;
    const final = cellule.textContent!;
    expect(Number(final), "le premier chiffre de l'accueil est un entier").toBeGreaterThan(100);
    Observateur.de(cellule).entrer(cellule);
    await jusquaLent(() => ecrits.at(-1) === final && ecrits.length > 2, "la fin de la montée");
    expect(cellule.textContent).toBe(final);
    // happy-dom rend une image à chaque tour de boucle, pas toutes les 16 ms :
    // la montée en écrit des dizaines de milliers. Une seule assertion sur la
    // liste des fautives, plutôt qu'une par image.
    const fautives = ecrits.filter((vu) => {
      const valeur = Number(vu);
      return !Number.isInteger(valeur) || valeur < 0 || valeur > Number(final);
    });
    expect(fautives, "des images qui ne sont pas un nombre honnête").toEqual([]);
    expect(Number(ecrits[0]), "la première image est sous la dernière").toBeLessThan(Number(final));
  });

  /// « 0 avertissement » est un chiffre, et il ne monte pas : il n'y a rien à
  /// monter. Il ne doit pas être réécrit une seule fois.
  test("ce qui ne monte pas n'est jamais réécrit", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const zero = [...document.querySelectorAll(".fact .value")].find((v) => v.textContent === "0")!;
    expect(zero, "l'accueil publie un zéro").toBeDefined();
    let ecrit = false;
    new MutationObserver(() => {
      ecrit = true;
    }).observe(zero, { childList: true, characterData: true, subtree: true });
    Observateur.de(zero).entrer(zero);
    await new Promise((r) => setTimeout(r, 120));
    expect(ecrit, "on n'y touche pas du tout").toBe(false);
  });
});

describe("la cascade", () => {
  test("chaque carte reçoit son rang, et le rang croît", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const etapes = [...document.querySelectorAll<HTMLElement>(".steps > *")];
    expect(etapes.map((e) => style(e, "--step"))).toEqual(["0", "1", "2"]);
  });

  /// **Le plafond.** Sans lui, une grille longue ferait attendre sa fin plus
  /// d'une seconde. Aucune grille du site n'a encore huit cartes : celle-ci est
  /// ajoutée à la page avant que le module ne démarre, pour que le plafond
  /// soit atteint et que le test dise quelque chose de lui.
  test("le retard cesse de croître à la huitième", async () => {
    await ouvrir("docs/index.html", {
      avant: () => {
        observateurMaitrise();
        const grille = document.createElement("div");
        grille.className = "cards";
        for (let i = 0; i < 10; i += 1) grille.appendChild(document.createElement("article"));
        document.querySelector("#main")!.appendChild(grille);
      },
    });
    const rangs = [...document.querySelectorAll<HTMLElement>(".cards > *")].map((c) => style(c, "--step"));
    expect(rangs).toEqual(["0", "1", "2", "3", "4", "5", "6", "7", "7", "7"]);
  });
});

describe("la cascade, partout", () => {
  /// Depuis qu'il y a plus à lire, tout ce qui est une liste arrive élément par
  /// élément : les points d'un document, les lignes d'un tableau, le sommaire,
  /// les colonnes du pied, et les lettres du nom qui le termine.
  test("les listes d'un document, ses tableaux et le pied reçoivent leur rang", async () => {
    await ouvrir("docs/index.html", { avant: observateurMaitrise });
    for (const selecteur of [".doc-list", ".sommaire ol", ".footer-groups", ".pied-geant"]) {
      const enfants = [...document.querySelector(selecteur)!.children] as HTMLElement[];
      expect(enfants.length, `${selecteur} a des enfants`).toBeGreaterThan(1);
      expect(enfants.map((e) => style(e, "--step")).slice(0, 2), selecteur).toEqual(["0", "1"]);
      expect(enfants.every((e) => e.dataset.reveal === ""), `${selecteur} : inscrits`).toBe(true);
    }
  });
});

describe("le sommaire", () => {
  /// **Il suit la lecture** : le titre qui entre dans le haut de la fenêtre
  /// devient la section lue, et un seul lien la porte.
  test("la section qui entre dans la vue devient la section lue", async () => {
    await ouvrir("docs/index.html", { avant: observateurMaitrise });
    const liens = [...document.querySelectorAll<HTMLAnchorElement>(".sommaire a")];
    expect(liens.length, "le guide a un sommaire").toBeGreaterThan(2);
    const titre = (lien: HTMLAnchorElement) =>
      document.getElementById(lien.getAttribute("href")!.slice(1))!;
    // Des rangs, jamais des éléments : comparer deux éléments happy-dom fait
    // parcourir tout l'arbre à `toEqual`, et l'imprimer en cas d'échec coûte
    // des gigaoctets — la leçon du test de révélation, plus haut.
    const lus = () =>
      liens.flatMap((l, i) => (l.getAttribute("aria-current") === "location" ? [i] : []));

    Observateur.entrerPartout(titre(liens[1]!));
    expect(lus()).toEqual([1]);
    Observateur.entrerPartout(titre(liens[2]!));
    expect(lus(), "la précédente rend la main").toEqual([2]);
    expect(style(document.querySelector(".sommaire ol")!, "--y"), "le trait est posé").not.toBe("");
  });

  /// Chaque lien du sommaire mène à un titre qui existe : un sommaire qui
  /// pointerait dans le vide serait pire que pas de sommaire.
  test("chaque entrée mène à un titre de la page", async () => {
    await ouvrir("fr/architecture/index.html", { avant: observateurMaitrise });
    const liens = [...document.querySelectorAll<HTMLAnchorElement>(".sommaire a")];
    expect(liens.length).toBeGreaterThan(2);
    for (const lien of liens) {
      const cible = document.getElementById(lien.getAttribute("href")!.slice(1));
      expect(cible?.tagName ?? "absent", lien.getAttribute("href")!).toBe("H2");
    }
  });
});

describe("le curseur", () => {
  const bouger = (cible: EventTarget, x: number, y: number, pointerType = "mouse") =>
    cible.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: x, clientY: y, pointerType }));

  test("l'anneau arrive sous la flèche, grossit sur un lien, se resserre quand on presse", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const anneau = document.querySelector<HTMLElement>(".curseur")!;
    expect(anneau !== null, "l'anneau est posé par le module").toBe(true);
    expect(anneau.getAttribute("aria-hidden"), "décoratif, et il le dit").toBe("true");
    expect(anneau.dataset.visible, "invisible avant le premier mouvement").toBeUndefined();

    bouger(document.querySelector("h2")!, 70, 50);
    expect(anneau.dataset.visible).toBe("");
    // **Le premier mouvement le pose sous la flèche**, sans le faire traverser
    // l'écran depuis l'origine.
    expect(anneau.style.transform).toBe("translate3d(70px,50px,0)");
    expect(anneau.dataset.lien, "un titre ne se clique pas").toBeUndefined();

    bouger(document.querySelector(".site-nav a")!, 300, 20);
    expect(anneau.dataset.lien, "au-dessus d'un lien").toBe("");
    // Puis il rattrape la flèche, image après image, et s'y arrête.
    await jusqua(() => anneau.style.transform === "translate3d(300px,20px,0)", "le rattrapage");

    document.body.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
    expect(anneau.dataset.presse).toBe("");
    document.body.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
    expect(anneau.dataset.presse).toBeUndefined();
  });

  /// Un stylet ou un doigt sur un écran hybride ne déplace pas l'anneau : il
  /// marquerait l'endroit d'un toucher, pas d'une flèche.
  test("seulement à la souris", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const anneau = document.querySelector<HTMLElement>(".curseur")!;
    bouger(document.body, 70, 50, "touch");
    bouger(document.body, 70, 50, "pen");
    expect(anneau.dataset.visible).toBeUndefined();
  });
});

describe("la bande", () => {
  /// Une piste mesurée : happy-dom ne met rien en page, donc la largeur est
  /// posée — deux fois les mots, quatre mille pixels, un tour de deux mille.
  function mesurees() {
    observateurMaitrise();
    for (const piste of document.querySelectorAll(".bande-piste")) {
      mesurer(piste, "scrollWidth", () => 4000);
    }
  }
  const recul = (piste: Element) => Number.parseInt(style(piste, "--d") || "0", 10);

  test("elle avance seule, et le défilement la pousse dans son sens", async () => {
    await ouvrir("index.html", { avant: mesurees });
    const bandes = [...document.querySelectorAll(".bande")];
    expect(bandes.length, "la bande de l'accueil et celle du pied").toBe(2);
    const piste = bandes[0]!.querySelector(".bande-piste")!;
    expect(style(piste, "--d"), "immobile tant qu'elle n'est pas visible").toBe("");

    Observateur.de(bandes[0]!).entrer(bandes[0]!);
    await jusqua(() => recul(piste) < -1, "qu'elle avance");

    // On descend : l'élan s'ajoute, et elle penche dans le sens du défilement.
    window.scrollTo(0, 400);
    defiler();
    await jusqua(() => Number(style(piste, "--penche")) > 0, "la pente vers le bas");

    // On remonte fort : elle repart à l'envers.
    window.scrollTo(0, 0);
    defiler();
    await jusqua(() => Number(style(piste, "--penche")) < 0, "la pente vers le haut");
    const avant = recul(piste);
    await jusqua(() => recul(piste) > avant, "qu'elle recule");
  });

  /// **Hors de la vue, elle ne coûte rien.** Une bande qu'on ne voit plus
  /// n'a aucune raison de réclamer une image par rafraîchissement d'écran ; le
  /// sabordage qui gardait la boucle en vie a survécu tant que ce test
  /// n'existait pas.
  test("hors de la vue, la boucle s'arrête", async () => {
    await ouvrir("index.html", { avant: mesurees });
    const bande = document.querySelector(".bande")!;
    const piste = bande.querySelector(".bande-piste")!;
    Observateur.de(bande).entrer(bande);
    await jusqua(() => recul(piste) < -1, "qu'elle avance");
    Observateur.de(bande).sortir(bande);
    // Une dernière image peut encore passer : on la laisse passer, puis plus rien.
    await new Promise((r) => setTimeout(r, 120));
    const arretee = style(piste, "--d");
    await new Promise((r) => setTimeout(r, 300));
    expect(style(piste, "--d"), "elle a continué hors de la vue").toBe(arretee);
  });
});

describe("la lueur", () => {
  test("le halo se pose là où est le pointeur, dans la carte", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const carte = document.querySelector(".card")!;
    // Une carte qui ne serait pas à l'origine de l'écran : sans ça, un halo
    // posé aux coordonnées brutes de la fenêtre passerait pour juste.
    boite(carte, { left: 30, top: 12, width: 300, height: 200 });
    carte.querySelector("h3")!.dispatchEvent(
      new PointerEvent("pointermove", { bubbles: true, clientX: 70, clientY: 50 }),
    );
    expect(style(carte, "--mx")).toBe("40px");
    expect(style(carte, "--my")).toBe("38px");
  });

  /// **La carte s'incline vers le pointeur**, puis se redresse quand il part.
  /// Au milieu du bord droit, l'axe est vertical et l'angle plein.
  test("la carte s'enfonce sous le pointeur, et se redresse", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const carte = document.querySelector(".cards > .card")!;
    boite(carte, { left: 0, top: 0, width: 300, height: 200 });
    carte.querySelector("p")!.dispatchEvent(
      new PointerEvent("pointermove", { bubbles: true, clientX: 300, clientY: 100 }),
    );
    expect([style(carte, "--ax"), style(carte, "--ay"), style(carte, "--aa")]).toEqual(["0", "1000", "60"]);
    carte.dispatchEvent(new PointerEvent("pointerleave"));
    expect(style(carte, "--aa"), "le pointeur parti, elle se redresse").toBe("0");
  });
});

describe("la barre de lecture", () => {
  test("elle n'existe pas là où il n'y a pas de document", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    expect(document.querySelector(".reading-progress")).toBeNull();
  });

  test("sur un document, elle se remplit avec le défilement — en millièmes", async () => {
    await ouvrir("docs/index.html", {
      avant: () => {
        observateurMaitrise();
        mesurer(document.documentElement, "scrollHeight", () => innerHeight + 2000);
      },
    });
    const barre = document.querySelector(".reading-progress")!;
    expect(barre.getAttribute("aria-hidden"), "décorative, et elle le dit").toBe("true");
    expect(style(barre, "--read")).toBe("0");
    window.scrollTo(0, 500);
    defiler();
    expect(style(barre, "--read")).toBe("250");
  });

  test("une page plus courte que la fenêtre reste à zéro", async () => {
    await ouvrir("offline/index.html", {
      avant: () => {
        observateurMaitrise();
        mesurer(document.documentElement, "scrollHeight", () => innerHeight - 100);
      },
    });
    window.scrollTo(0, 40);
    defiler();
    expect(style(document.querySelector(".reading-progress")!, "--read")).toBe("0");
  });
});

describe("l'ouverture", () => {
  /// **La scène suit le défilement.** La section fait deux écrans de haut et
  /// en a parcouru un tiers : la poussière est en route, la marque n'est pas
  /// encore là, la lumière n'est pas passée. Puis la course s'achève, et tout
  /// est à l'état final.
  test("la progression suit la course de la section épinglée", async () => {
    let haut = -400;
    await ouvrir("index.html", {
      avant: () => {
        observateurMaitrise();
        const section = document.querySelector(".hero")!;
        (section as unknown as { getBoundingClientRect: () => unknown }).getBoundingClientRect = () => ({
          top: haut, left: 0, width: 1280, height: innerHeight + 1200, bottom: 0, right: 0, x: 0, y: haut,
        });
      },
    });
    const section = document.querySelector(".hero")!;
    await jusqua(() => style(section, "--ouverture") !== "", "la première image de l'ouverture");
    expect(style(section, "--ouverture")).toBe("333");
    expect(style(section, "--forme"), "la marque n'est pas encore formée").toBe("0");
    expect(style(section, "--lueur"), "la lumière n'est pas passée").toBe("0");

    haut = -1200;
    defiler();
    await jusqua(() => style(section, "--ouverture") === "1000", "la fin de la course");
    expect(style(section, "--forme")).toBe("1000");
    expect(style(section, "--lueur")).toBe("1000");
  });

  /// Sans course — un écran trop court pour épingler, ou la page au repos —,
  /// la scène est directement à son état final.
  test("une section sans course est à l'état final", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const section = document.querySelector(".hero")!;
    await jusqua(() => style(section, "--forme") !== "", "la première image de l'ouverture");
    expect(style(section, "--forme")).toBe("1000");
  });
});

describe("les aimants", () => {
  test("un bouton suit le pointeur, puis est relâché", async () => {
    await ouvrir("index.html", { avant: observateurMaitrise });
    const bouton = document.querySelector("[data-aimant]")!;
    boite(bouton, { left: 0, top: 0, width: 100, height: 40 });
    bouton.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: 100, clientY: 50 }));
    // Moins d'un tiers du chemin : 50 × 0,3 et 30 × 0,35, arrondis.
    expect(style(bouton, "--mx")).toBe("15px");
    expect(style(bouton, "--my")).toBe("11px");
    document.body.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: 600, clientY: 600 }));
    expect(style(bouton, "--mx"), "hors du bouton, il revient").toBe("");
  });
});

describe("le défilement lissé", () => {
  /// Chaque position que le module demande, dans l'ordre.
  const demandes: number[] = [];

  function longue() {
    observateurMaitrise();
    mesurer(document.documentElement, "scrollHeight", () => innerHeight + 4000);
    demandes.length = 0;
    const aller = window.scrollTo.bind(window);
    window.scrollTo = ((options: ScrollToOptions) => {
      demandes.push(options.top ?? 0);
      aller(options);
    }) as typeof window.scrollTo;
  }

  /// **Les touches de modification, posées sur l'événement.** La spécification
  /// fait hériter `WheelEvent` de `MouseEvent`, donc de `ctrlKey` et
  /// `shiftKey` ; happy-dom le fait hériter de `UIEvent`, et ces champs n'y
  /// existent pas — mesuré, `ctrlKey` y vaut `undefined`. Le premier jet de ce
  /// test a cru que le module reprenait un zoom au clavier : c'était
  /// l'environnement qui ne savait pas dire « ctrl ».
  function roue(init: { deltaY: number; deltaX?: number; ctrlKey?: boolean; shiftKey?: boolean }) {
    const e = new WheelEvent("wheel", { ...init, bubbles: true, cancelable: true });
    for (const cle of ["ctrlKey", "shiftKey", "metaKey"] as const) {
      Object.defineProperty(e, cle, { value: Boolean(init[cle as keyof typeof init]) });
    }
    return e;
  }

  test("la molette est reprise, et la page glisse jusqu'à la cible", async () => {
    await ouvrir("index.html", { avant: longue });
    const cran = roue({ deltaY: 300 });
    document.body.dispatchEvent(cran);
    expect(cran.defaultPrevented, "le cran doit être repris pour être lissé").toBe(true);
    await jusquaLent(() => scrollY === 300, "que la page atteigne la cible");
    // **Elle glisse** : des positions intermédiaires, croissantes, sinon c'est
    // un saut, et le module n'aurait rien lissé.
    const entre = demandes.filter((y) => y > 0 && y < 300);
    expect(entre.length, "aucune position intermédiaire").toBeGreaterThan(3);
    expect([...entre].sort((a, b) => a - b), "la page recule en chemin").toEqual(entre);
    expect(demandes.at(-1)).toBe(300);
  });

  test("le zoom, le défilement horizontal et une majuscule restent au navigateur", async () => {
    await ouvrir("index.html", { avant: longue });
    for (const init of [
      { deltaY: 300, ctrlKey: true },
      { deltaY: 10, deltaX: 300 },
      { deltaY: 300, shiftKey: true },
    ]) {
      const cran = roue(init);
      document.body.dispatchEvent(cran);
      expect(cran.defaultPrevented, JSON.stringify(init)).toBe(false);
    }
  });
});

describe("la feuille de style", () => {
  const css = readFileSync(join(import.meta.dir, "..", "src", "styles.css"), "utf8");

  /// **Aucune règle ne masque sans que le module l'ait armée.**
  ///
  /// C'est la garde qui empêche une page blanche : si une règle de masquage
  /// s'échappait de `[data-motion]`, un lecteur sans JavaScript verrait un site
  /// vide au lieu du site.
  test("tout ce qui masque est sous [data-motion]", () => {
    const hiding = css
      .split("\n")
      .filter((line) => line.includes("[data-reveal]") && !line.includes("[data-revealed]"));
    expect(hiding.length, "des règles de masquage doivent exister, sinon ce test est creux")
      .toBeGreaterThan(0);
    for (const line of hiding) {
      expect(line, "une règle de masquage hors de [data-motion]").toContain("[data-motion]");
    }
  });

  /// À l'impression il n'y a pas de défilement : ce qui attend d'entrer dans la
  /// vue n'y entrerait jamais.
  test("l'impression rend tout visible", () => {
    expect(css).toContain("@media print");
    const printed = css.slice(css.indexOf("@media print"));
    expect(printed).toContain("[data-reveal] { opacity: 1");
  });

  /// **Rien ne clignote sans fin chez quelqu'un qui a demandé le calme.**
  ///
  /// C'est précisément ce que `prefers-reduced-motion` existe pour empêcher :
  /// une animation infinie qu'on ne peut pas arrêter. Le curseur du nom, le
  /// grain, la goutte de l'ouverture et la bande en sont — et ne sont
  /// acceptables que parce qu'ils vivent sous `[data-motion]`, un attribut que
  /// le module refuse de poser dans ce cas-là. **Cette garde a déplacé la
  /// bande** : le premier jet la posait sous `html.entree`.
  test("aucune animation infinie n'échappe à [data-motion]", () => {
    const lines = css.split("\n");
    const forever = lines
      .map((line, index) => ({ line, index }))
      .filter(({ line }) => line.includes("infinite"));
    expect(forever.length, "il doit en exister, sinon ce test est creux").toBeGreaterThan(2);
    for (const { index } of forever) {
      // **La ligne elle-même compte** : une règle écrite sur une seule ligne
      // échappait au premier jet, qui cherchait le sélecteur au-dessus.
      const upTo = lines.slice(0, index + 1).reverse();
      const selector = upTo.find((line) => line.includes("{"));
      expect(selector, "une déclaration sans règle au-dessus").toBeDefined();
      expect(selector, "une animation infinie hors de [data-motion]").toContain("[data-motion]");
    }
  });

  /// **Et aucune animation ne part sans l'une des trois portes.** Les
  /// animations finies de l'ouverture — le titre, le rideau — partent avant le
  /// module, donc sous une classe que le script de la tête pose et qu'il ne
  /// pose pas quand on a demandé le calme ; les transitions de page sont dans
  /// une requête qui exige `no-preference`. Une animation hors de ces portes
  /// jouerait chez tout le monde.
  test("toute animation passe par [data-motion], html.entree, html.rideau ou ::view-transition", () => {
    const lines = css.split("\n");
    const animated = lines
      .map((line, index) => ({ line, index }))
      .filter(({ line }) => /^\s*animation\s*:/.test(line) && !/animation\s*:\s*none/.test(line));
    expect(animated.length, "il doit en exister, sinon ce test est creux").toBeGreaterThan(5);
    for (const { line, index } of animated) {
      const selector = lines.slice(0, index + 1).reverse().find((l) => l.includes("{"))!;
      expect(
        /\[data-motion\]|html\.entree|html\.rideau|::view-transition/.test(selector),
        `« ${line.trim()} » sous « ${selector.trim()} » ne passe par aucune porte`,
      ).toBe(true);
    }
  });

  /// **Les valeurs par défaut sont celles du repos.** Le module pose ses
  /// variables après coup ; entre la première peinture et sa première image,
  /// c'est la valeur de repli qui s'affiche. Une `--read` par défaut pleine
  /// ferait clignoter une barre pleine sur chaque document, une `--forme` par
  /// défaut nulle ferait disparaître la marque de qui n'a pas le module.
  test("les variables du module se replient sur l'immobile", () => {
    expect(css, "une barre sans valeur est vide, pas pleine").toContain(
      "scaleX(calc(var(--read, 0) / 1000))",
    );
    expect(css, "une carte sans rang n'attend pas").toContain("var(--step, 0)");
    expect(css, "une marque sans module est entière").toContain("var(--forme, 1000)");
    expect(css, "une ouverture sans module est achevée").toContain("var(--ouverture, 1000)");
    expect(css, "une lumière sans module est passée").toContain("var(--lueur, 1000)");
  });

  /// **Un jeton appelé sans être déclaré ne colore rien, et ne se voit pas.**
  ///
  /// `var(--absent)` sans repli rend la déclaration entière invalide au calcul.
  /// Le filet de l'en-tête appelait `var(--rule)`, déclaré nulle part, et son
  /// `box-shadow` était tombé en entier sans que rien le dise. Les deux sens
  /// comptent : `--ease` avait été déclaré sans être appelé. Un appel *avec*
  /// repli est hors du premier sens : c'est le module qui pose ces valeurs, et
  /// le repli est ce qui rend leur absence sûre.
  test("aucun jeton n'est appelé sans être déclaré, ni déclaré sans être appelé", () => {
    const declared = new Set([...css.matchAll(/^\s*(--[a-z-]+):/gm)].map((match) => match[1]!));
    const bare = new Set<string>();
    const called = new Set<string>();
    for (const match of css.matchAll(/var\((--[a-z-]+)\s*(,?)/g)) {
      called.add(match[1]!);
      if (!match[2]) bare.add(match[1]!);
    }

    expect(declared.size, "la palette doit exister, sinon ce test est creux").toBeGreaterThan(5);
    expect(bare.size, "des appels sans repli doivent exister").toBeGreaterThan(5);

    for (const name of bare) {
      expect(declared.has(name), `${name} est appelé sans repli et déclaré nulle part`).toBe(true);
    }
    for (const name of declared) {
      expect(called.has(name), `${name} est déclaré et personne ne l'emploie`).toBe(true);
    }
  });
});
