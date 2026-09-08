/// Le mouvement, et la règle qui le gouverne.
///
/// **Rien ici n'est porteur.** C'est la même règle que `main.ts` : un
/// navigateur sans `IntersectionObserver`, une personne qui a demandé moins
/// d'animation, un script qui ne part pas — chacun doit obtenir le site tel
/// qu'il est aujourd'hui, entier et lisible, pas une page vide en attente
/// d'être révélée.
///
/// C'est pour ça que **rien n'est caché par la feuille de style seule**. Les
/// règles qui masquent vivent toutes sous `[data-motion]`, un attribut que ce
/// fichier pose et que rien d'autre ne pose. Sans lui, il n'y a pas
/// d'animation *et* pas de contenu invisible — les deux d'un coup, ce qui est
/// la seule façon de ne pas transformer une panne de script en page blanche.
///
/// Le poids compte : `tests/build.test.ts` tient tout le JavaScript du site
/// sous huit kilooctets bruts, parce que React a coûté 65 794 octets gzippés
/// pour quatre comportements et qu'on ne recommence pas.

/// Ce qui se révèle en entrant dans la vue.
///
/// Deux formes de page, deux sélecteurs : les sections de l'accueil, et les
/// blocs d'un document. Écrits ici plutôt que posés à la construction — une
/// classe dans le HTML serait une promesse rendue à un lecteur sans script,
/// et elle ne lui sert à rien.
const REVEALED = "#main > section, .doc > .wrap > *";

/// Les grilles dont les enfants arrivent en cascade plutôt qu'ensemble.
const GRIDS = ".cards, .steps, .facts";

/// De combien on descend avant d'être remonté. Assez pour se voir, trop peu
/// pour déplacer la lecture.
const RISE = "0.6rem";

export function startMotion() {
  // **La demande de la personne passe avant tout le reste.** Un système réglé
  // sur « moins d'animation » n'obtient rien : ni mouvement, ni attribut, donc
  // pas une seule règle de masquage.
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
  // Sans observateur, on ne saurait pas quand révéler — donc on ne cache pas.
  if (!("IntersectionObserver" in window)) return;

  const root = document.documentElement;
  root.dataset.motion = "on";
  root.style.setProperty("--rise", RISE);

  revealOnScroll();
  markScroll(root);
  countFacts();
  followPointer();
  readingProgress();
}

/// Chaque bloc se lève une fois, quand il entre dans la vue.
function revealOnScroll() {
  const watcher = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        (entry.target as HTMLElement).dataset.revealed = "";
        // **Une fois, et on cesse de regarder.** Un bloc qui rejouerait à
        // chaque passage transformerait une page longue en clignotement.
        watcher.unobserve(entry.target);
      }
    },
    // Le bas de la fenêtre est trop tard : le bloc arriverait déjà lu.
    { rootMargin: "0px 0px -10% 0px" },
  );

  for (const block of document.querySelectorAll<HTMLElement>(REVEALED)) {
    block.dataset.reveal = "";
    watcher.observe(block);
  }

  // **La cascade.** Une grille entière qui apparaît d'un bloc se lit comme une
  // image ; ses cartes qui arrivent l'une après l'autre se lisent comme une
  // liste. Le rang est posé ici et la feuille de style en fait un retard.
  //
  // Il est **plafonné** : à la huitième carte le retard cesse de croître.
  // Sinon une grille longue ferait attendre sa fin plus d'une seconde, ce qui
  // n'est plus un rythme mais une latence.
  for (const grid of document.querySelectorAll<HTMLElement>(GRIDS)) {
    let rank = 0;
    for (const item of grid.children) {
      const cell = item as HTMLElement;
      cell.dataset.reveal = "";
      cell.style.setProperty("--step", String(Math.min(rank, 7)));
      watcher.observe(cell);
      rank += 1;
    }
  }
}

/// **La lueur qui suit le pointeur.**
///
/// Deux nombres posés sur la carte survolée, dont la feuille de style fait le
/// centre d'un halo. Un seul écouteur pour toute la grille — un par carte
/// serait douze écouteurs pour un effet qui n'en demande qu'un.
///
/// **Rien sur un écran tactile.** Un doigt n'a pas de position au repos : le
/// halo resterait figé là où l'on a touché, ce qui est pire que pas de halo du
/// tout. `(hover: hover)` est la question exacte à poser — pas la largeur de
/// l'écran, qu'un portable à écran tactile démentirait.
function followPointer() {
  if (!window.matchMedia?.("(hover: hover)").matches) return;
  for (const grid of document.querySelectorAll<HTMLElement>(".cards")) {
    grid.addEventListener("pointermove", (event) => {
      const card = (event.target as HTMLElement | null)?.closest<HTMLElement>(".card");
      if (!card) return;
      const box = card.getBoundingClientRect();
      card.style.setProperty("--mx", `${event.clientX - box.left}px`);
      card.style.setProperty("--my", `${event.clientY - box.top}px`);
    });
  }
}

/// **Où l'on en est dans un document.**
///
/// Les pages écrites sont longues — la feuille de route, l'architecture, le
/// protocole — et une barre de défilement de navigateur est fine, grise et
/// souvent cachée. Celle-ci est posée par le script, donc elle n'existe que
/// là où quelque chose peut la remplir.
///
/// **Elle est décorative et le dit** : `aria-hidden`. Un lecteur d'écran
/// annonce déjà la position dans le document, et une seconde voix qui répète
/// « douze pour cent » à chaque défilement serait du bruit.
function readingProgress() {
  const doc = document.querySelector<HTMLElement>(".doc");
  if (!doc) return;
  const bar = document.createElement("div");
  bar.className = "reading-progress";
  bar.setAttribute("aria-hidden", "true");
  document.body.appendChild(bar);

  const draw = () => {
    const room = document.documentElement.scrollHeight - window.innerHeight;
    // Une page plus courte que la fenêtre n'a pas de progression : la barre
    // resterait pleine, ce qui dirait quelque chose de faux.
    const part = room > 0 ? Math.min(1, Math.max(0, window.scrollY / room)) : 0;
    bar.style.setProperty("--read", String(part));
  };
  draw();
  window.addEventListener("scroll", draw, { passive: true });
  window.addEventListener("resize", draw, { passive: true });
}

/// L'en-tête se pose sur la page dès qu'on a quitté le haut.
function markScroll(root: HTMLElement) {
  const mark = () => {
    if (window.scrollY > 8) root.dataset.scrolled = "";
    else delete root.dataset.scrolled;
  };
  mark();
  window.addEventListener("scroll", mark, { passive: true });
}

/// Les chiffres de l'accueil montent jusqu'à leur valeur.
///
/// **Ils finissent exactement sur le texte d'origine**, remis tel quel à la
/// dernière image plutôt que reconstruit : ce sont des affirmations qu'un test
/// tient — le nombre de tests, celui des portes d'intégration — et un chiffre
/// approché serait un mensonge que l'animation aurait introduit.
function countFacts() {
  const values = document.querySelectorAll<HTMLElement>(".fact .value");
  if (values.length === 0) return;

  const watcher = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      watcher.unobserve(entry.target);
      const cell = entry.target as HTMLElement;
      const final = cell.textContent ?? "";
      const target = Number(final);
      // Ce qui n'est pas un entier ordinaire ne compte pas : on le laisse.
      if (!Number.isInteger(target) || target <= 0) continue;
      climb(cell, target, final);
    }
  });
  for (const value of values) watcher.observe(value);
}

function climb(cell: HTMLElement, target: number, final: string) {
  const started = performance.now();
  const step = (now: number) => {
    const part = Math.min(1, (now - started) / 900);
    if (part >= 1) {
      // Le texte d'origine, à l'octet près.
      cell.textContent = final;
      return;
    }
    // Vite au début, lent à la fin : la valeur se lit avant de s'arrêter.
    cell.textContent = String(Math.round(target * (1 - (1 - part) ** 3)));
    requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}
