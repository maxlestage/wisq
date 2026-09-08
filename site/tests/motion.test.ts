/// Le mouvement, exécuté plutôt que relu.
///
/// Le fichier d'à côté — `service-worker.test.ts` — raconte pourquoi : neuf
/// sabotages du worker avaient passé une suite entière de tests qui lisaient
/// son source comme du texte. Ce fichier-ci suit la même règle et appelle
/// `startMotion` pour de vrai, dans un DOM de fortune.
///
/// **Ce qu'il tient avant tout est une promesse de non-régression du site
/// entier** : aucun bloc ne doit être masqué quand personne ne peut le
/// révéler. Une feuille de style qui cacherait sans condition, plus un script
/// qui ne part pas, font une page blanche — et c'est le seul défaut de cette
/// tranche qui coûterait le site plutôt qu'une animation.

import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { startMotion } from "../src/motion";

/// Un élément : ce que `startMotion` en touche, et rien de plus.
///
/// **Il retient chaque texte qu'on lui pose et chaque variable qu'on lui
/// écrit.** Sans ça, un test ne voit que l'état final — et le premier jet de
/// ce fichier n'a pas su distinguer « le chiffre est monté proprement » de
/// « on lui a écrit NaN pendant une seconde avant de remettre le bon ». Les
/// images intermédiaires sont la moitié du comportement.
class FakeElement {
  dataset: Record<string, string> = {};
  /// Les variables CSS posées sur l'élément : `--step`, `--mx`, `--read`.
  /// Une feuille de style vaut ce que vaut ce que le script y écrit.
  props: Record<string, string> = {};
  style = {
    setProperty: (name: string, value: string) => {
      this.props[name] = value;
    },
  };
  children: FakeElement[] = [];
  listeners: Record<string, ((event: unknown) => void)[]> = {};
  attributes: Record<string, string> = {};
  className = "";
  written: string[] = [];
  /// Ce que cet élément est aux yeux de `closest` : « .card », « .cards ».
  kind = "";
  parent: FakeElement | null = null;
  box = { left: 0, top: 0 };
  scrollHeight = 0;
  #text = "";
  constructor(text = "") {
    this.#text = text;
  }
  get textContent() {
    return this.#text;
  }
  set textContent(value: string) {
    this.#text = value;
    this.written.push(value);
  }
  addEventListener(name: string, handler: (event: unknown) => void) {
    (this.listeners[name] ??= []).push(handler);
  }
  setAttribute(name: string, value: string) {
    this.attributes[name] = value;
  }
  appendChild(child: FakeElement) {
    this.children.push(child);
    child.parent = this;
  }
  getBoundingClientRect() {
    return this.box;
  }
  closest(selector: string): FakeElement | null {
    let node: FakeElement | null = this;
    while (node) {
      if (node.kind === selector) return node;
      node = node.parent;
    }
    return null;
  }
}

interface Observed {
  target: FakeElement;
  isIntersecting: boolean;
}

/// Un observateur qu'on déclenche à la main : le test décide quand un bloc
/// entre dans la vue, ce qu'aucun navigateur absent ne ferait pour lui.
class FakeObserver {
  static living: FakeObserver[] = [];
  watched: FakeElement[] = [];
  constructor(private readonly told: (entries: Observed[]) => void) {
    FakeObserver.living.push(this);
  }
  observe(target: FakeElement) {
    this.watched.push(target);
  }
  unobserve(target: FakeElement) {
    this.watched = this.watched.filter((seen) => seen !== target);
  }
  enter(target: FakeElement) {
    this.told([{ target, isIntersecting: true }]);
  }
}

/// Le nombre de cartes de la grille de test : **plus que le plafond de la
/// cascade**, sans quoi le plafond ne serait jamais atteint et le test ne
/// dirait rien de lui.
const CARDS = 10;

interface World {
  root: FakeElement;
  body: FakeElement;
  blocks: FakeElement[];
  facts: FakeElement[];
  cards: FakeElement;
  scroll: () => void;
  /// Le premier élément créé par le script, s'il en a créé un.
  made: FakeElement[];
}

/// Le monde dans lequel `startMotion` s'exécute.
///
/// `reduced` et `observer` sont les deux interrupteurs qui décident si le
/// script a le droit de masquer quoi que ce soit ; `hover` dit si le pointeur
/// a une position au repos ; `doc` si la page est un document long.
function world(
  options: { reduced?: boolean; observer?: boolean; hover?: boolean; doc?: boolean } = {},
): World {
  const { reduced = false, observer = true, hover = true, doc = false } = options;
  const root = new FakeElement();
  root.scrollHeight = 3000;
  const body = new FakeElement();
  const blocks = [new FakeElement(), new FakeElement(), new FakeElement()];
  const facts = [new FakeElement("2318"), new FakeElement("hors ligne")];

  const cards = new FakeElement();
  cards.kind = ".cards";
  for (let rank = 0; rank < CARDS; rank += 1) {
    const card = new FakeElement();
    card.kind = ".card";
    card.parent = cards;
    // Une carte qui ne serait pas à l'origine de l'écran : sans ça, un halo
    // posé aux coordonnées brutes de la fenêtre passerait pour juste.
    card.box = { left: 30, top: 12 };
    cards.children.push(card);
  }

  const made: FakeElement[] = [];
  let onScroll = () => {};

  FakeObserver.living = [];
  const win: Record<string, unknown> = {
    matchMedia: (query: string) => ({
      matches: query.includes("reduced-motion") ? reduced : query.includes("hover") && hover,
    }),
    addEventListener: (name: string, handler: () => void) => {
      if (name === "scroll") onScroll = handler;
    },
    scrollY: 0,
    innerHeight: 800,
  };
  if (observer) win.IntersectionObserver = FakeObserver;

  (globalThis as Record<string, unknown>).window = win;
  (globalThis as Record<string, unknown>).IntersectionObserver = observer
    ? FakeObserver
    : undefined;
  (globalThis as Record<string, unknown>).document = {
    documentElement: root,
    body,
    createElement: () => {
      const born = new FakeElement();
      made.push(born);
      return born;
    },
    querySelector: (selector: string) => {
      if (selector === ".doc") return doc ? new FakeElement() : null;
      throw new Error(`sélecteur inattendu : ${selector}`);
    },
    // **Une correspondance exacte, et une erreur sinon.** Un faux qui devine
    // rendrait la mauvaise liste sans le dire le jour où un sélecteur change :
    // le test continuerait de passer en observant autre chose.
    querySelectorAll: (selector: string) => {
      if (selector === "#main > section, .doc > .wrap > *") return blocks;
      if (selector === ".cards, .steps, .facts") return [cards];
      if (selector === ".cards") return [cards];
      if (selector === ".fact .value") return facts;
      throw new Error(`sélecteur inattendu : ${selector}`);
    },
  };
  // **Une horloge qui avance par pas, pas un saut jusqu'à la fin.** Sauter
  // rendrait toutes les images intermédiaires invisibles, et un chiffre qui
  // afficherait n'importe quoi en chemin passerait pour correct.
  const began = performance.now();
  let elapsed = 0;
  (globalThis as Record<string, unknown>).requestAnimationFrame = (
    step: (now: number) => void,
  ) => {
    elapsed += 120;
    step(began + elapsed);
    return 0;
  };

  return { root, body, blocks, facts, cards, made, scroll: () => onScroll() };
}

/// Ce que la fenêtre voit d'elle-même, pendant un test.
function setWindow(field: string, value: unknown) {
  ((globalThis as Record<string, unknown>).window as Record<string, unknown>)[field] = value;
}

afterEach(() => {
  for (const name of ["window", "document", "IntersectionObserver", "requestAnimationFrame"]) {
    delete (globalThis as Record<string, unknown>)[name];
  }
});

describe("le mouvement", () => {
  /// **La promesse qui compte plus que l'animation elle-même.**
  test("une demande de moins d'animation ne masque rien du tout", () => {
    const stage = world({ reduced: true });
    startMotion();
    expect(stage.root.dataset.motion, "l'attribut qui arme les règles de masquage").toBeUndefined();
    for (const block of stage.blocks) {
      expect(block.dataset.reveal, "aucun bloc n'est marqué").toBeUndefined();
    }
  });

  /// Sans observateur, personne ne révélerait ce qu'on aurait caché.
  test("sans IntersectionObserver, rien n'est masqué non plus", () => {
    const stage = world({ observer: false });
    startMotion();
    expect(stage.root.dataset.motion).toBeUndefined();
    expect(stage.blocks[0].dataset.reveal).toBeUndefined();
  });

  test("autrement, les blocs se lèvent en entrant dans la vue", () => {
    const stage = world();
    startMotion();
    expect(stage.root.dataset.motion).toBe("on");
    expect(stage.blocks[0].dataset.reveal).toBe("");
    expect(stage.blocks[0].dataset.revealed, "pas encore vu").toBeUndefined();

    const watcher = FakeObserver.living[0];
    watcher.enter(stage.blocks[0]);
    expect(stage.blocks[0].dataset.revealed).toBe("");
    expect(stage.blocks[1].dataset.revealed, "les autres attendent leur tour").toBeUndefined();
    // **Une fois, et on cesse de regarder** : un bloc qui rejouerait à chaque
    // passage ferait clignoter une page longue.
    expect(watcher.watched).not.toContain(stage.blocks[0]);
  });

  test("l'en-tête se marque dès qu'on a quitté le haut", () => {
    const stage = world();
    startMotion();
    expect(stage.root.dataset.scrolled, "au repos, rien").toBeUndefined();
    setWindow("scrollY", 40);
    stage.scroll();
    expect(stage.root.dataset.scrolled).toBe("");
    setWindow("scrollY", 0);
    stage.scroll();
    expect(stage.root.dataset.scrolled, "revenu en haut, la marque part").toBeUndefined();
  });

  /// **Le chiffre finit exactement sur le sien.**
  ///
  /// Ce sont des affirmations qu'un test tient — le nombre de tests du dépôt,
  /// celui des portes d'intégration. Une animation qui laisserait 2317 à
  /// l'écran aurait introduit un mensonge que personne n'aurait écrit.
  test("un chiffre monte et s'arrête sur sa valeur, au caractère près", () => {
    const stage = world();
    startMotion();
    const watcher = FakeObserver.living[1];
    watcher.enter(stage.facts[0]);
    const fact = stage.facts[0];
    expect(fact.textContent).toBe("2318");
    expect(fact.written.length, "il faut plus d'une image, sinon rien ne monte")
      .toBeGreaterThan(2);
    // **Chaque image est un nombre honnête.** Le premier jet de ce test ne
    // regardait que la fin, et n'aurait pas vu une montée qui affiche « NaN »
    // pendant une seconde avant de remettre la bonne valeur.
    for (const seen of fact.written) {
      const value = Number(seen);
      expect(Number.isInteger(value), `image « ${seen} »`).toBe(true);
      expect(value).toBeGreaterThanOrEqual(0);
      expect(value).toBeLessThanOrEqual(2318);
    }
    // Et elle monte : la première image est sous la dernière.
    expect(Number(fact.written[0])).toBeLessThan(2318);
  });

  test("ce qui n'est pas un nombre n'est jamais réécrit", () => {
    const stage = world();
    startMotion();
    FakeObserver.living[1].enter(stage.facts[1]);
    expect(stage.facts[1].textContent).toBe("hors ligne");
    // **Pas une seule écriture** : rendre le texte d'origine à la fin ne suffit
    // pas, il ne doit jamais avoir été remplacé entre-temps.
    expect(stage.facts[1].written, "on n'y touche pas du tout").toEqual([]);
  });
});

/// **La cascade** : une grille entière qui apparaît d'un bloc se lit comme une
/// image, ses cartes l'une après l'autre se lisent comme une liste.
describe("la cascade", () => {
  test("chaque carte reçoit son rang, et le rang croît", () => {
    const stage = world();
    startMotion();
    const cards = stage.cards.children;
    expect(cards[0].props["--step"], "la première n'attend pas").toBe("0");
    expect(cards[1].props["--step"]).toBe("1");
    expect(cards[2].props["--step"]).toBe("2");
    // Et chacune est bien du travail que l'observateur surveille : un rang
    // posé sur une carte que personne ne révèle serait un retard sur rien.
    for (const card of cards) {
      expect(card.dataset.reveal, "la carte est marquée").toBe("");
      expect(FakeObserver.living[0].watched, "et observée").toContain(card);
    }
  });

  /// **Le plafond.** Sans lui, une grille de dix cartes ferait attendre sa
  /// dernière 630 ms après la première, et une de vingt une seconde et demie :
  /// ce n'est plus un rythme, c'est une latence.
  test("le retard cesse de croître à la huitième", () => {
    const stage = world();
    startMotion();
    const cards = stage.cards.children;
    expect(cards.length, "il faut dépasser le plafond pour le voir").toBeGreaterThan(8);
    expect(cards[7].props["--step"]).toBe("7");
    for (const late of cards.slice(8)) {
      expect(late.props["--step"], "au-delà, plus rien ne s'ajoute").toBe("7");
    }
  });

  test("une demande de calme ne pose aucun rang", () => {
    const stage = world({ reduced: true });
    startMotion();
    expect(stage.cards.children[0].props["--step"]).toBeUndefined();
  });
});

/// **La lueur qui suit le pointeur.**
describe("la lueur", () => {
  /// Les coordonnées sont **relatives à la carte**, pas à la fenêtre : la
  /// feuille de style les lit comme le centre d'un dégradé posé sur la carte.
  test("le halo se pose là où est le pointeur, dans la carte", () => {
    const stage = world();
    startMotion();
    const card = stage.cards.children[3];
    const heard = stage.cards.listeners.pointermove;
    expect(heard?.length, "un seul écouteur pour toute la grille").toBe(1);
    heard[0]({ target: card, clientX: 130, clientY: 62 });
    // 130 − 30 et 62 − 12 : la carte n'est pas à l'origine de l'écran.
    expect(card.props["--mx"]).toBe("100px");
    expect(card.props["--my"]).toBe("50px");
  });

  test("le fond de la grille n'allume rien", () => {
    const stage = world();
    startMotion();
    const grid = stage.cards;
    grid.listeners.pointermove[0]({ target: grid, clientX: 5, clientY: 5 });
    for (const card of grid.children) {
      expect(card.props["--mx"], "aucune carte n'a été touchée").toBeUndefined();
    }
  });

  /// **Rien sur un écran tactile.** Un doigt n'a pas de position au repos : le
  /// halo resterait figé là où l'on a touché, ce qui est pire que pas de halo.
  test("sans pointeur qui survole, pas même un écouteur", () => {
    const stage = world({ hover: false });
    startMotion();
    expect(stage.cards.listeners.pointermove, "rien n'écoute").toBeUndefined();
    // Le reste du mouvement, lui, a bien eu lieu : c'est la lueur seule qui
    // s'abstient, pas la page.
    expect(stage.root.dataset.motion).toBe("on");
    expect(stage.cards.children[0].dataset.reveal).toBe("");
  });
});

/// **Où l'on en est dans un document.**
describe("la barre de lecture", () => {
  test("elle n'existe pas là où il n'y a pas de document", () => {
    const stage = world({ doc: false });
    startMotion();
    expect(stage.made, "rien n'a été créé").toEqual([]);
    expect(stage.body.children, "et rien n'a été posé dans la page").toEqual([]);
  });

  test("sur un document, elle se remplit avec le défilement", () => {
    const stage = world({ doc: true });
    startMotion();
    const bar = stage.made[0];
    expect(bar, "une barre a été créée").toBeDefined();
    expect(stage.body.children, "et posée dans la page").toContain(bar);
    // **Décorative, et elle le dit** : un lecteur d'écran annonce déjà la
    // position dans le document ; une seconde voix serait du bruit.
    expect(bar.attributes["aria-hidden"]).toBe("true");
    expect(bar.className).toBe("reading-progress");

    // 3000 de page, 800 de fenêtre : 2200 de course.
    expect(bar.props["--read"], "en haut, rien n'est lu").toBe("0");
    setWindow("scrollY", 1100);
    stage.scroll();
    expect(bar.props["--read"]).toBe("0.5");
    setWindow("scrollY", 5000);
    stage.scroll();
    expect(bar.props["--read"], "au-delà du bas, elle reste pleine sans déborder").toBe("1");
  });

  /// Une page plus courte que la fenêtre n'a pas de progression. Une division
  /// par une course nulle ou négative rendrait `Infinity` ou un nombre négatif,
  /// et la barre dirait quelque chose de faux dès la première image.
  test("une page plus courte que la fenêtre reste à zéro", () => {
    const stage = world({ doc: true });
    stage.root.scrollHeight = 400;
    startMotion();
    const bar = stage.made[0];
    expect(bar.props["--read"]).toBe("0");
    setWindow("scrollY", 40);
    stage.scroll();
    expect(bar.props["--read"], "et elle y reste").toBe("0");
  });
});

describe("la feuille de style", () => {
  const css = readFileSync(join(import.meta.dir, "..", "src", "styles.css"), "utf8");

  /// **Aucune règle ne masque sans que le script l'ait armée.**
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

  /// **Les valeurs par défaut sont celles du repos.** Le script pose ses
  /// variables après coup ; entre la première peinture et sa première image,
  /// c'est la valeur de repli qui s'affiche. Un `--read` par défaut à 1
  /// ferait clignoter une barre pleine sur chaque document.
  test("les variables du script se replient sur l'immobile", () => {
    expect(css, "une barre sans valeur est vide, pas pleine").toContain("scaleX(var(--read, 0))");
    expect(css, "une carte sans rang n'attend pas").toContain("var(--step, 0)");
  });
});
