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
/// **Il retient chaque texte qu'on lui pose.** Sans ça, un test ne voit que
/// l'état final — et le premier jet de ce fichier n'a pas su distinguer « le
/// chiffre est monté proprement » de « on lui a écrit NaN pendant une seconde
/// avant de remettre le bon ». Les images intermédiaires sont la moitié du
/// comportement.
class FakeElement {
  dataset: Record<string, string> = {};
  style = { setProperty() {} };
  written: string[] = [];
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

interface World {
  root: FakeElement;
  blocks: FakeElement[];
  facts: FakeElement[];
  scroll: () => void;
}

/// Le monde dans lequel `startMotion` s'exécute.
///
/// `reduced` et `observer` sont les deux interrupteurs qui décident si le
/// script a le droit de masquer quoi que ce soit.
function world(options: { reduced?: boolean; observer?: boolean } = {}): World {
  const { reduced = false, observer = true } = options;
  const root = new FakeElement();
  const blocks = [new FakeElement(), new FakeElement(), new FakeElement()];
  const facts = [new FakeElement("2318"), new FakeElement("hors ligne")];
  let onScroll = () => {};

  FakeObserver.living = [];
  const win: Record<string, unknown> = {
    matchMedia: (query: string) => ({ matches: reduced && query.includes("reduced-motion") }),
    addEventListener: (name: string, handler: () => void) => {
      if (name === "scroll") onScroll = handler;
    },
    scrollY: 0,
  };
  if (observer) win.IntersectionObserver = FakeObserver;

  (globalThis as Record<string, unknown>).window = win;
  (globalThis as Record<string, unknown>).IntersectionObserver = observer
    ? FakeObserver
    : undefined;
  (globalThis as Record<string, unknown>).document = {
    documentElement: root,
    querySelectorAll: (selector: string) => (selector.includes(".fact") ? facts : blocks),
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

  return {
    root,
    blocks,
    facts,
    scroll: () => onScroll(),
  };
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
    ((globalThis as Record<string, unknown>).window as Record<string, unknown>).scrollY = 40;
    stage.scroll();
    expect(stage.root.dataset.scrolled).toBe("");
    ((globalThis as Record<string, unknown>).window as Record<string, unknown>).scrollY = 0;
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
});
