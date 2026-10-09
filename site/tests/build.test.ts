import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, normalize } from "node:path";
import { catalogue, page } from "./catalogue";
import { siteURL } from "../src/site-url";

/// The built artefact, not the source. `bun run build` must run before this;
/// CI does exactly that.
const dist = join(import.meta.dir, "..", "dist");
const read = (relative: string) => readFileSync(join(dist, relative), "utf8");

/// Ce que le site déclare de lui-même — routes, langues, copie, couleurs de
/// barre —, lu dans le catalogue du pré-rendu plutôt que dans une copie : voir
/// `tests/catalogue.ts`.
const { langs: LANGS, routes: ROUTES, bar: BAR, author: AUTHOR, copy } = catalogue();

/// Every document the build writes: each route, in each language. Tests that
/// used to walk the routes walk this instead, or they check half the site.
const BUILT = catalogue().pages.map((p) => ({
  route: { id: p.route },
  lang: p.lang,
  file: p.file,
  sentence: p.sentence,
}));

/// Un élément `div` entier à partir de sa balise ouvrante, refermé là où la
/// profondeur revient à zéro.
function element(html: string, debut: number): string {
  let profondeur = 0;
  const balise = /<\/?div\b[^>]*>/g;
  balise.lastIndex = debut;
  for (let m = balise.exec(html); m; m = balise.exec(html)) {
    profondeur += m[0].startsWith("</") ? -1 : 1;
    if (profondeur === 0) return html.slice(debut, m.index + m[0].length);
  }
  throw new Error("élément non refermé");
}

/// Le texte d'un fragment de HTML, balises retirées et entités rendues : ce
/// qu'un lecteur lit, et ce qu'un moteur de recherche indexe.
function text(html: string): string {
  return html
    .replace(/<[^>]+>/g, "")
    .replace(/&#x27;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

/// The stylesheet's name is hashed, so tests that read the CSS have to find it
/// rather than assume it.
function styleFile(): string {
  const name = readdirSync(dist).find((entry) => entry.endsWith(".css"));
  if (!name) throw new Error("aucune feuille de style dans dist");
  return name;
}

/// Les jetons d'un bloc de la feuille construite, lus par le début de son
/// sélecteur. Minifiée, la feuille écrit `:root{`, `:root:not([data-theme=light]){`
/// et `:root[data-theme=dark]{` — trois préfixes distincts, donc trois blocs
/// qu'on peut lire séparément et comparer.
function tokensOf(css: string, selector: string): Record<string, string> {
  const at = css.indexOf(selector);
  expect(at, `bloc « ${selector} » absent de la feuille de style`).toBeGreaterThan(-1);
  const body = css.slice(at + selector.length, css.indexOf("}", at));
  const tokens = Object.fromEntries(
    [...body.matchAll(/(--[a-z-]+):([^;]+)/g)].map((match) => [match[1]!, match[2]!.trim()]),
  );
  expect(Object.keys(tokens).length, `aucun jeton dans « ${selector} »`).toBeGreaterThan(0);
  return tokens;
}

/// Les deux fichiers du front en Yew : le module et la colle qui le démarre.
function frontFiles(): { wasm: string; glue: string } {
  const noms = readdirSync(dist).filter((entry) => entry.startsWith("wisq-"));
  const wasm = noms.filter((n) => n.endsWith(".wasm"));
  const glue = noms.filter((n) => n.endsWith(".js"));
  if (wasm.length !== 1 || glue.length !== 1) {
    throw new Error(`front : ${wasm.length} wasm et ${glue.length} colle(s), il en faut un de chaque`);
  }
  return { wasm: wasm[0]!, glue: glue[0]! };
}

function pngSize(relative: string): { width: number; height: number } {
  const bytes = readFileSync(join(dist, relative));
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (const [index, byte] of signature.entries()) {
    expect(bytes[index], `${relative} n'est pas un PNG`).toBe(byte);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

describe("built output", () => {
  test("the build ran", () => {
    expect(
      existsSync(join(dist, "index.html")),
      "dist/index.html manquant : lancez `bun run build`",
    ).toBe(true);
  });

  /// **Le seul JavaScript publié est la colle du module, et le service worker.**
  ///
  /// Le site a expédié React hydratant (65 794 octets gzippés), puis un script
  /// DOM d'un kilooctet, puis les deux à la fois pendant la migration. Il n'en
  /// reste aucun : le comportement entier est dans le module wasm, et ce test
  /// tombe le jour où un script reparaît à côté — React compris, puisque c'est
  /// la seule façon dont il pourrait revenir.
  test("aucun script ne voyage à côté du module", () => {
    const { glue } = frontFiles();
    const scripts = readdirSync(dist).filter((n) => n.endsWith(".js")).sort();
    expect(scripts).toEqual([glue, "sw.js"].sort());
    for (const { file } of BUILT) {
      const html = read(file);
      const charges = [...html.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1]);
      expect(charges, `${file} charge un script`).toEqual([]);
    }
    for (const marker of ["useState", "react-dom", "React"]) {
      expect(read(glue).includes(marker), `la colle contient « ${marker} »`).toBe(false);
    }
  });

  /// **La police variable voyage comme fichier, et ça tient à une
  /// substitution plutôt qu'à un réglage.**
  ///
  /// Bun 1.3.11 intègre tout `url()` d'une feuille de style en data URI base64,
  /// et `loader: { ".woff2": "file" }` n'y change rien — essayé, mesuré, le
  /// data URI est revenu. Pour le serveur de développement c'est le bon
  /// comportement. Pour le site publié non : la feuille de style est un `link`
  /// bloquant dans la tête, donc l'intégration mettait 90 Kio de police sur le
  /// chemin critique — styles.css passait de 27 à 135 Kio — et vidait
  /// `font-display: swap` de son sens, puisqu'il n'y a rien à échanger quand la
  /// police arrive dans ce qui bloque la peinture.
  ///
  /// Le plafond de la feuille de style est là pour ça : il n'y en avait aucun,
  /// et c'est précisément l'absence de plafond qui laissait une régression de
  /// 108 Kio passer sans bruit.
  test("la police est un fichier à part, et son poids est dit", () => {
    const style = readFileSync(join(dist, styleFile()));
    const css = style.toString("utf8");
    expect(css, "la police est repassée en ligne dans la feuille de style").not.toContain(
      "data:font",
    );
    // 23 717 octets avec la palette violette et l'accueil enrichi ; 29 755 avec
    // le mouvement de #337 — l'aurore, le code qui se tape, le sommaire, les
    // cartes qui s'inclinent, le curseur, la bande pilotée, le nom géant du
    // pied. 32 043 avec la seconde vague — la bascule de thème en cercle, les
    // titres mot par mot, le retour en haut, les rangs et le nom que le
    // défilement fait glisser. Le plafond suit une décision mesurée, pas une
    // dérive.
    expect(style.byteLength, "feuille de style").toBeLessThan(35_000);

    const face = css.slice(css.indexOf("@font-face"));
    const src = face.match(/url\(\.\/([^)]+\.woff2)\)/);
    expect(src, "la déclaration @font-face ne pointe sur aucun fichier").not.toBeNull();

    const font = readFileSync(join(dist, src![1]!));
    expect(font.subarray(0, 4).toString("latin1"), "ce n'est pas un woff2").toBe("wOF2");
    // 90 104 octets mesurés pour le sous-ensemble latin — accents français
    // compris, c'est ce qui a écarté le latin-ext. C'est le plus gros actif du
    // site, et le plafond est là pour que ça reste une décision.
    expect(font.byteLength, "la police").toBeLessThan(100_000);

    // Hors ligne, une police absente ne casse rien : elle change le dessin,
    // ce qui est pire, parce que personne ne le signale.
    expect(read("sw.js"), "la police doit être précachée").toContain(`"./${src![1]!}"`);
  });

  /// **Le front en Yew a son plafond, et il ne monte plus avec la prose.**
  ///
  /// Le roadmap porte une section « Le site — l'hydratation retirée », où React
  /// hydratant coûtait 65 794 octets gzip par page et où le code DOM qui l'a
  /// remplacé en coûtait 1 062. Passer à Yew est revenu sur cette décision, et
  /// le prix a été mesuré à chaque tranche :
  ///
  /// | | brut | gzip |
  /// | --- | --- | --- |
  /// | une page portée, thème seul (#331) | 253 728 | 106 392 |
  /// | toutes les pages, hydratées entières | 351 822 | 148 277 |
  /// | **deux îlots, tout le mouvement** | **261 252** | **112 436** |
  ///
  /// La deuxième ligne est celle que l'ancien plafond annonçait — « chaque
  /// tranche qui porte des pages le relèvera » — et elle a été refusée : un
  /// module qui hydrate la page entière doit porter tout ce qu'elle affiche
  /// pour pouvoir le comparer, soit la prose des dix pages dans les deux
  /// langues, téléchargée par chaque lecteur pour un texte que sa page avait
  /// déjà. Seuls deux endroits ont un état ; seuls deux sont hydratés. Le reste
  /// du coût est le mouvement — ouverture, poussière, défilement lissé,
  /// aimants —, et il tient en 7 524 octets bruts au-dessus de la première
  /// page portée.
  ///
  /// **Le plafond ne bouge donc plus avec le contenu**, seulement avec le code :
  /// une page de plus n'ajoute rien au module, et `le module ne porte la prose
  /// d'aucune page` le vérifie.
  ///
  /// **Et ces chiffres dépendent de la machine, ce que « mesuré » ne dit pas.**
  /// Le même source, lu des deux côtés, à deux commits :
  ///
  /// | source | wasm brut | wasm gzip | colle brute | colle gzip |
  /// | --- | --- | --- | --- | --- |
  /// | `a6ce835`, le coureur de la CI | 261 548 | — | — | — |
  /// | `a6ce835`, ce conteneur (rustc 1.99.0) | 261 240 | 110 947 | 56 272 | 9 494 |
  /// | `3914022`, le coureur de la CI | 276 907 | — | — | — |
  /// | `3914022`, ce conteneur (rustc 1.99.0) | 276 599 | 117 213 | 58 869 | 9 763 |
  ///
  /// **L'écart du module est de 308 octets exactement aux deux commits**, sur
  /// deux modules que quinze kilooctets séparent. Un écart constant, donc pas
  /// proportionnel au code : ce n'est pas « la compilation est différente », c'est
  /// quelque chose de taille fixe.
  ///
  /// **Et le module porte bien l'identité de sa chaîne**, ce qui est montré et
  /// non supposé : il embarque le hash de commit de rustc dans les chemins de la
  /// bibliothèque standard que ses messages de panique citent —
  /// `/rustc/b940084d7eb6a299eb4bfeb8e34901bc051e7ac4/library/core/src/…`, le
  /// hash de `rustc 1.99.0`. C'est la même famille de cause que l'en-tête de
  /// `check-agent-size.sh` a établie pour le démon : « les octets d'écart
  /// séparaient deux versions de rustc, pas deux machines ».
  /// `.github/workflows/site.yml` n'épingle aucune version, donc l'écart est
  /// attendu. **Les 308 eux-mêmes ne sont pas expliqués** : le module du coureur
  /// n'est pas récupérable d'ici, donc on ne peut pas le confronter octet par
  /// octet. C'est écrit comme une mesure reproductible, pas comme une cause.
  ///
  /// **Ce qui N'est PAS établi, et le dire vaut mieux que l'inverse.** La taille
  /// de la colle n'a jamais été mesurée sur le coureur : la construction n'imprime
  /// que celle du module. Et son nom ne peut pas en tenir lieu — il est adressé
  /// par contenu, mais la construction y substitue le nom du `.wasm`, donc deux
  /// colles identiques portent des noms différents dès que le module diffère. Un
  /// premier jet de cette note concluait de deux noms que la colle était
  /// identique « à l'octet » : c'était un témoin qui n'en était pas.
  ///
  /// **Le gzip bouge cinq fois plus que le brut**, et c'est mesuré deux fois :
  /// 1 489 octets contre 308 à `a6ce835`, 1 505 contre 308 à `3914022`. La
  /// compression amplifie un remaniement que le brut dissimule, donc c'est le
  /// chiffre gzip qu'il faut regarder le jour où un plafond rougit — l'inverse de
  /// l'intuition.
  ///
  /// **Pourquoi aucune garde ne tient ces chiffres exactement.** Elle serait
  /// rouge sur une machine ou sur l'autre pour un module parfaitement sain.
  /// Ce qui *est* vérifié : la marge de chaque borne, sur `3914022`, contre
  /// l'écart de 1 505 au pire.
  ///
  /// | borne | marge | d'après |
  /// | --- | --- | --- |
  /// | wasm brut, 285 000 | 8 093 | le coureur, qui est le plus gros des deux |
  /// | wasm gzip, 123 000 | 5 787 | ce conteneur — le coureur ne l'imprime pas |
  /// | colle brute, 60 000 | **1 131** | ce conteneur, seule mesure |
  /// | colle gzip, 11 000 | 1 237 | ce conteneur, seule mesure |
  ///
  /// **Les deux bornes de la colle sont donc sous l'écart du module**, et c'est
  /// la seule chose inquiétante ici : si la colle bouge d'une chaîne à l'autre
  /// autant que le module, elles peuvent basculer sans que personne touche au
  /// code. On ne sait pas si elle bouge — voir ci-dessus, elle n'est mesurée que
  /// d'un côté. C'est nommé plutôt que corrigé : relever une borne est une
  /// décision de budget, et la prendre sans la mesure serait deviner.
  test("le front en WebAssembly reste dans son budget", () => {
    const { wasm, glue } = frontFiles();
    const octets = (nom: string) => readFileSync(join(dist, nom));
    const w = octets(wasm);
    const g = octets(glue);
    const wgz = Bun.gzipSync(w).byteLength;
    const ggz = Bun.gzipSync(g).byteLength;

    // Le module. Mesuré 261 252 / 112 436 après `wasm-opt -Oz` ; 271 558 /
    // 116 280 avec les cinq comportements de #337 — le sommaire qui suit la
    // lecture, le curseur, la bande que le défilement pousse, l'inclinaison
    // des cartes, l'en-tête qui s'efface ; 276 591 / 118 718 avec la seconde
    // vague — la bascule de thème en cercle, le retour en haut, les aimants de
    // la navigation. Du code, pas du contenu : la règle du paragraphe
    // au-dessus tient.
    expect(w.byteLength, "wasm brut").toBeLessThan(285_000);
    expect(wgz, "wasm gzippé").toBeLessThan(123_000);
    // La colle de wasm-bindgen. Mesurée 58 869 / 9 763 dans ce conteneur sur
    // `3914022` — le chiffre d'avant, 56 272 / 9 635, avait deux vagues de
    // comportements de retard, et rien ne le tenait. Elle ne bouge qu'avec
    // la surface de `web-sys` que le front emploie, et le mouvement en emploie
    // beaucoup plus que la bascule de thème seule — observateurs, toile,
    // molette, pointeur, défilement.
    expect(g.byteLength, "colle brute").toBeLessThan(60_000);
    expect(ggz, "colle gzippée").toBeLessThan(11_000);

    // **Et `wasm-opt` doit vraiment être passé.** Sans lui le module fait
    // 294 274 octets — mesuré sur la sortie de wasm-bindgen —, ce qui franchit
    // le plafond du haut : une construction qui sauterait l'étape sans le dire
    // tomberait ici plutôt que d'expédier 33 Ko de plus.
    expect(w.byteLength, "le module n'a pas l'air optimisé").toBeLessThan(294_274);
  });

  /// **Le câblage du module, mesuré sur l'artefact.**
  ///
  /// Un module qui pèse 112 Ko et que personne ne charge est pire qu'un module
  /// absent : il passe tous les tests de taille. Ce test suit la chaîne de bout
  /// en bout sur chaque page construite — la colle importée et démarrée, les
  /// deux fichiers demandés dès la tête, la colle qui nomme le wasm, et les deux
  /// dans le précache.
  test("chaque page charge son module, et le demande tôt", () => {
    const { wasm, glue } = frontFiles();
    for (const { file } of BUILT) {
      const html = read(file);
      expect(html, `${file} : la colle n'est pas importée`).toContain(`${glue}";demarrer()`);
      // Le navigateur cherche les deux pendant qu'il lit le corps, au lieu
      // d'attendre que la colle s'exécute pour découvrir le wasm.
      expect(html, `${file} : la colle n'est pas préchargée`).toMatch(
        new RegExp(`<link rel="modulepreload" href="[./]*${glue}"`),
      );
      expect(html, `${file} : le wasm n'est pas préchargé, ou sans crossorigin`).toMatch(
        new RegExp(`<link rel="preload" href="[./]*${wasm}" as="fetch" type="application/wasm" crossorigin`),
      );
    }

    // La colle nomme le module : sans ça elle chargerait un nom disparu.
    expect(read(glue), "la colle ne nomme pas le wasm").toContain(wasm);

    // Hors ligne, un front absent n'est pas une page dégradée : c'est une page
    // dont les îlots ne répondent plus.
    const sw = read("sw.js");
    for (const actif of [wasm, glue]) {
      expect(sw, `${actif} doit être précaché`).toContain(`"./${actif}"`);
    }
  });

  /// **Les marqueurs d'hydratation ne vivent que dans les îlots.** La page est
  /// rendue sans eux, et chaque îlot avec : là où il y a un marqueur, il y a
  /// une racine que le module reprend, et nulle part ailleurs. Un marqueur hors
  /// d'un îlot voudrait dire qu'une région se croit hydratée — ou que le
  /// pré-rendu a cessé de distinguer les deux.
  test("les marqueurs d'hydratation ne vivent que dans les îlots", () => {
    for (const { file } of BUILT) {
      const html = read(file);
      const racine = html.match(/<div id="root"[^>]*>([\s\S]*)<\/div>\s*<script/)![1]!;
      const ilots = [...racine.matchAll(/<div data-ilot="(\w+)"/g)];
      expect(ilots.map((m) => m[1]), `${file} : les deux îlots`).toEqual(["reglages", "installation"]);
      // Retirer chaque îlot entier — jusqu'à la balise qui referme sa racine,
      // comptée, pas devinée : l'îlot des réglages contient des `div` et des
      // marqueurs imbriqués, et une expression qui s'arrêterait au premier
      // marqueur de fin s'arrêterait au milieu.
      let dehors = racine;
      for (const m of ilots) dehors = dehors.replace(element(racine, m.index!), "");
      expect(dehors.includes("<!--"), `${file} : un marqueur hors d'un îlot`).toBe(false);
      // Et chaque îlot l'est, pas seulement l'un des deux : le module refuse
      // d'hydrater une racine qui ne commence pas par le marqueur d'ouverture.
      for (const m of ilots) {
        expect(
          racine.slice(m.index!).match(/^<div data-ilot="\w+"[^>]*>(<!--<\[\]>-->)?/)![1],
          `${file} : l'îlot « ${m[1]} » ne commence pas par un marqueur`,
        ).toBe("<!--<[]>-->");
      }
    }
  });

  /// **Le module porte le comportement du site, pas sa prose.**
  ///
  /// Un lecteur de l'accueil a longtemps téléchargé la politique de vie
  /// privée, la FAQ, la feuille de route et la note d'architecture, en anglais
  /// *et* en français — 61 Ko bruts, mesurés, dans le script partagé de
  /// l'époque. Le défaut est revenu sous une autre forme pendant la migration :
  /// hydrater la page entière demandait au module de porter tout ce qu'elle
  /// affiche, soit 97 Ko de prose de plus. Ce test parcourt les vraies pages et
  /// tombe si une phrase de l'une d'elles est dans le module — ou une phrase de
  /// l'accueil, ou du pied.
  test("le module ne porte la prose d'aucune page", () => {
    const { wasm, glue } = frontFiles();
    const module = readFileSync(join(dist, wasm)).toString("utf8") + read(glue);
    const phrases: [string, string][] = [];
    for (const { route, lang, sentence } of BUILT) {
      if (sentence) phrases.push([`${lang}/${route.id}`, sentence]);
    }
    for (const lang of LANGS) {
      phrases.push([`${lang}/accueil`, copy[lang]!.hero.lede]);
      phrases.push([`${lang}/accroche`, copy[lang]!.hero.tagline]);
      phrases.push([`${lang}/pied`, copy[lang]!.footer.copyright]);
    }
    expect(phrases.length, "il faut des phrases, sinon ce test est creux").toBeGreaterThan(20);
    for (const [ou, phrase] of phrases) {
      expect(module.includes(phrase.slice(0, 32)), `${ou} : la prose est dans le module`).toBe(false);
    }
  });

  /// The two tests that stood here guarded the JSON copy of each document,
  /// embedded beside the markup because hydration had to read exactly what the
  /// build rendered. Nothing reads one now, so the payload is gone, and with it
  /// both hazards. What replaces them is the claim the payload existed to
  /// support, checked against the markup that now carries it alone: the words
  /// are in the page.
  test("every written page carries its prose in its markup", () => {
    let checked = 0;
    for (const { file, sentence } of BUILT) {
      if (!sentence) continue;
      // Yew escapes `<`, `>`, `&` and `"` in text. The longest run that contains
      // nothing an escaper touches is in the file verbatim, and it is still
      // long enough that no other page could contain it by accident.
      const plain = sentence
        .split(/[<>&"']/)
        .reduce((longest, part) => (part.length > longest.length ? part : longest), "");
      if (plain.length < 20) continue;
      expect(read(file).includes(plain), `${file} : la prose n'est pas dans le balisage`).toBe(true);
      checked += 1;
    }
    expect(checked, "les dix-huit documents").toBe(18);
  });

  /// And the payload is really gone, on every page, rather than gone from the
  /// one page someone happened to open.
  test("no page ships a document payload any more", () => {
    for (const { file } of BUILT) {
      expect(
        read(file).includes('<script type="application/json" id="doc">'),
        `${file} : le document JSON est revenu`,
      ).toBe(false);
    }
  });

  test("every route produced a document", () => {
    for (const { route, lang, file } of BUILT) {
      void route;
      void lang;
      expect(existsSync(join(dist, file)), `${file} manquant`).toBe(true);
    }
  });

  test("the page is readable before any JavaScript loads", () => {
    // The whole point of pre-rendering: content in the first response. The
    // headline is set word by word for its entrance, so it is read as text —
    // tags out — which is also how a reader and a search engine read it.
    const home = text(read("index.html"));
    expect(home).toContain("Virtual machines on your iPhone.");
    expect(home).toContain("A real Linux kernel, on the phone");

    const privacy = read("privacy/index.html");
    expect(privacy).toContain("No analytics");
  });

  /// **Les titres de section aussi, et le sommaire le recoupe.** Chaque `h2`
  /// de l'accueil et des pages écrites est découpé en mots pour monter un à un.
  /// Le texte, balises retirées, doit rester le titre : le sommaire porte le
  /// titre tel qu'il est écrit, sans découpage, donc chaque entrée du sommaire
  /// doit être exactement le texte du `h2` qu'elle vise. Et les rangs vont de
  /// zéro au dernier mot, dans l'ordre.
  test("les titres de section sont découpés en mots, sans changer de texte", () => {
    for (const { file } of BUILT.filter((b) => !/404|offline/.test(b.file))) {
      // Le contenu seulement : les colonnes du pied ont leurs propres `h2`,
      // qui nomment des groupes de liens et ne montent pas.
      const tout = read(file);
      const html = tout.slice(tout.indexOf('<main id="main">'), tout.indexOf("</main>"));
      const titres = [...html.matchAll(/<h2 id="([^"]+)"[^>]*>([\s\S]*?)<\/h2>|<h2>([\s\S]*?)<\/h2>/g)];
      expect(titres.length, `${file} : des titres de section`).toBeGreaterThan(2);
      for (const t of titres) {
        const corps = t[2] ?? t[3]!;
        const mots = text(corps).split(" ");
        const rangs = [...corps.matchAll(/style="--i:(\d+)" class="mot"/g)].map((m) => Number(m[1]));
        expect(rangs, `${file} : « ${text(corps)} »`).toEqual(mots.map((_, i) => i));
      }
      for (const entree of html.matchAll(/<li><a href="#([^"]+)">([^<]+)<\/a><\/li>/g)) {
        const cible = titres.find((t) => t[1] === entree[1]);
        expect(cible, `${file} : le sommaire vise #${entree[1]}`).toBeDefined();
        expect(text(cible![2]!), `${file} : #${entree[1]}`).toBe(text(entree[2]!));
      }
    }
  });

  /// Les rangs des sections de l'accueil sont décoratifs, et le disent.
  test("les rangs des sections sont décoratifs et dans l'ordre", () => {
    for (const lang of LANGS) {
      const html = read(page("home", lang).file);
      const rangs = [...html.matchAll(/<span ([^>]*)class="sec-num"[^>]*>(\d+)<\/span>|<span class="sec-num"([^>]*)>(\d+)<\/span>/g)];
      expect(rangs.length, `${lang} : un rang par section`).toBe(10);
      rangs.forEach((r, i) => {
        expect(r[0], `${lang} : rang ${i + 1}`).toContain('aria-hidden="true"');
        expect(Number(r[2] ?? r[4]), `${lang} : l'ordre`).toBe(i + 1);
      });
    }
  });

  /// **Le titre, mot par mot, et toujours le titre.** Chaque mot est un masque
  /// pour son entrée, avec son rang ; le texte du `h1`, balises retirées, est
  /// exactement l'accroche — espaces comprises —, dans les deux langues.
  test("le titre de l'accueil est l'accroche, mot par mot", () => {
    for (const lang of LANGS) {
      const html = read(page("home", lang).file);
      const h1 = html.match(/<h1 class="hero-title">([\s\S]*?)<\/h1>/)?.[1];
      expect(h1, `${lang} : le titre du héros`).toBeDefined();
      expect(text(h1!), `${lang} : le titre a changé de texte`).toBe(copy[lang]!.hero.tagline);
      const rangs = [...h1!.matchAll(/style="--i:(\d+)" class="mot"/g)].map((m) => Number(m[1]));
      expect(rangs, `${lang} : un rang par mot, dans l'ordre`).toEqual(
        copy[lang]!.hero.tagline.split(" ").map((_, i) => i),
      );
    }
  });

  /// **La bande est décorative, et elle le dit.** Elle répète en mots-clés ce
  /// que les sections expliquent en phrases ; lue par un lecteur d'écran, elle
  /// le serait deux fois, la seconde copie comprise.
  test("la bande se tait pour les lecteurs d'écran, et porte deux fois ses mots", () => {
    for (const lang of LANGS) {
      const html = read(page("home", lang).file);
      expect(html, `${lang} : la bande`).toContain('<div aria-hidden="true" class="bande">');
      const simples = html.match(/class="bande-mot">/g)?.length ?? 0;
      const doubles = html.match(/class="bande-mot bande-double">/g)?.length ?? 0;
      expect(simples, `${lang} : des mots dans la bande`).toBeGreaterThan(4);
      expect(doubles, `${lang} : la seconde copie, mot pour mot`).toBe(simples);
    }
  });

  /// The strongest guard here: resolve every relative reference against the
  /// directory of the page that makes it, and require the file to exist. A
  /// subdirectory page that says `./chunk.js` instead of `../chunk.js` builds
  /// fine, deploys fine, and 404s in the browser.
  test("every relative reference resolves to a file that exists", () => {
    let checked = 0;
    for (const { route, lang, file } of BUILT) {
      void route;
      void lang;
      const html = read(file);
      const here = dirname(join(dist, file));
      const refs = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map((match) => match[1]!);

      for (const raw of refs) {
        if (/^(https?:|data:|mailto:|#)/.test(raw)) continue;
        expect(raw.startsWith("/"), `chemin absolu dans ${file} : ${raw}`).toBe(false);

        // A fragment addresses a place inside a document, not a file:
        // `./#install` is the landing page's install section and resolves to
        // the landing page itself.
        const ref = raw.split("#")[0]!;
        if (ref === "") continue;

        // A directory reference means that directory's index.
        const target = normalize(join(here, ref.endsWith("/") ? `${ref}index.html` : ref));
        expect(existsSync(target), `${file} référence ${raw}, absent du build`).toBe(true);
        checked += 1;
      }
    }
    expect(checked).toBeGreaterThan(40);
  });

  test("every document carries the head a shared link needs", () => {
    for (const { route, lang, file } of BUILT) {
      void route;
      void lang;
      const html = read(file);
      expect(html, `${file} : viewport`).toContain("width=device-width");
      expect(html, `${file} : viewport-fit`).toContain("viewport-fit=cover");
      expect(html, `${file} : canonical`).toContain('rel="canonical"');
      expect(html, `${file} : manifeste`).toContain('rel="manifest"');
      expect(html, `${file} : icône iOS`).toContain('rel="apple-touch-icon"');
      expect(html, `${file} : image sociale`).toContain('property="og:image"');
      // Catches an empty or placeholder description. The bound is deliberately
      // below the shortest real one — the French 404's complete sentence is 39
      // characters — because the guard is against a stub, not against brevity.
      expect(html, `${file} : description`).toMatch(/<meta name="description" content="[^"]{30,}"/);
    }
  });

  /// Within a language, not across it: "Architecture" is the same word in
  /// French, so two pages sharing a title across languages is correct and
  /// telling them apart is what the hreflang links are for.
  test("each page has its own title and description", () => {
    for (const lang of LANGS) {
      const pages = BUILT.filter((page) => page.lang === lang);
      const titles = new Set<string>();
      const descriptions = new Set<string>();
      for (const { file } of pages) {
        const html = read(file);
        titles.add(html.match(/<title>([^<]+)<\/title>/)![1]!);
        descriptions.add(html.match(/<meta name="description" content="([^"]+)"/)![1]!);
      }
      expect(titles.size, `titres distincts en ${lang}`).toBe(pages.length);
      expect(descriptions.size, `descriptions distinctes en ${lang}`).toBe(pages.length);
    }
  });

  /// The whole point of the French build: a French page must not be an English
  /// page wearing a French address.
  test("each French page is actually in French", () => {
    for (const { route, file } of BUILT.filter((page) => page.lang === "fr")) {
      const html = read(file);
      const english = read(page(route.id, "en").file);
      expect(html, `${file} : langue déclarée`).toContain('<html lang="fr">');
      const title = (raw: string) => raw.match(/<title>([^<]+)<\/title>/)![1]!;
      const lede = (raw: string) => raw.match(/<meta name="description" content="([^"]+)"/)![1]!;
      // Titles may legitimately match — "Architecture" — but a page whose
      // title *and* description both match the English one was never
      // translated.
      expect(
        title(html) === title(english) && lede(html) === lede(english),
        `${file} : identique à la version anglaise`,
      ).toBe(false);
    }
  });

  test("hydration knows which page it is on and in which language", () => {
    for (const { route, lang, file } of BUILT) {
      const html = read(file);
      expect(html, `${file} : route`).toContain(`data-route="${route.id}"`);
      expect(html, `${file} : langue`).toContain(`data-lang="${lang}"`);
      expect(html, `${file} : base`).toMatch(/data-base="(\.\/|(\.\.\/)+)"/);
    }
  });

  test("structured data appears once per language, on the landing pages", () => {
    const withJsonLd = BUILT.filter(({ file }) => read(file).includes("application/ld+json"));
    expect(withJsonLd.map(({ route, lang }) => `${lang}:${route.id}`)).toEqual([
      "en:home",
      "fr:home",
    ]);
  });
});

describe("the mark", () => {
  /// Where each size of the mark belongs. The hero lockup — mark plus the name
  /// set large — is the landing page's alone, because no other page has that
  /// room. The footer carries the mark small on every page, beside the
  /// wordmark, so the pair is what a reader sees wherever they end up.
  test("the hero lockup is the landing page's, the footer mark is everywhere", () => {
    for (const { route, file } of BUILT) {
      const html = read(file);
      const hero = html.split('class="hero-logo"').length - 1;
      expect(hero, `${file} : marque du hero`).toBe(route.id === "home" ? 1 : 0);
      expect(
        html.split('class="footer-logo"').length - 1,
        `${file} : marque du pied de page`,
      ).toBe(1);
      expect(html, `${file} : mot-marque`).toContain('class="brand');
    }
  });

  /// Two copies of the same drawing on one page means two elements sharing an
  /// id, which is invalid and resolves to whichever came first. Harmless while
  /// the gradients are identical, and a silent wrong-colour bug the day they
  /// are not.
  test("two marks on a page do not share an id", () => {
    const ids = [...read("index.html").matchAll(/id="(wisq-[^"]+)"/g)].map((m) => m[1]!);
    expect(ids.length, "l'accueil porte deux marques, donc six identifiants").toBe(6);
    expect(new Set(ids).size, "identifiant dupliqué entre les deux marques").toBe(ids.length);
  });

  /// Drawn, not fetched. An <img> here would be a second request before the
  /// hero can paint, and a committed binary nobody can diff.
  test("the mark is inline and costs no request", () => {
    const home = read("index.html");
    // L'ordre des attributs n'est pas un contrat : Yew écrit `class` en dernier.
    expect(home).toMatch(/<svg [^>]*class="hero-logo"/);
    expect(home.match(/<img[^>]*hero-logo/)).toBeNull();
  });

  /// The header brand and the heading already say what this is, so announcing
  /// it a third time is noise for anyone listening rather than looking.
  test("the mark is decorative", () => {
    const svg = read("index.html").match(/<svg [^>]*class="hero-logo"[^>]*>/)?.[0];
    expect(svg).toBeDefined();
    expect(svg).toContain('aria-hidden="true"');
  });
});

describe("theme", () => {
  /// The guard that makes an explicit choice mean anything. Without
  /// `:not([data-theme="light"])` a reader whose system is dark and who asked
  /// for light keeps the media query's colours — the switch appears to work in
  /// one direction and silently fails in the other, which is the kind of
  /// half-working nobody reports.
  test("an explicit choice outranks the system setting, both ways", () => {
    // Read with the quotes optional: the minifier drops them, so asserting the
    // source spelling would test the bundler rather than the behaviour.
    const css = readFileSync(join(dist, styleFile()), "utf8");
    expect(css, "la requête média doit céder à un choix explicite").toMatch(
      /:root:not\(\[data-theme=["']?light["']?\]\)/,
    );
    expect(css, "le choix sombre doit exister hors requête média").toMatch(
      /:root\[data-theme=["']?dark["']?\]/,
    );
    // ...et les jetons sombres doivent vraiment être aux deux endroits, pas
    // seulement sélectionnés aux deux endroits.
    //
    // **Cette ligne portait `--bg:#0b0d10` en clair, et c'était la mauvaise
    // affirmation.** Elle gravait une couleur, donc elle tombait au premier
    // changement de palette — et surtout elle ne disait rien du seul défaut
    // qu'elle prétendait couvrir : si la requête média était tenue à jour et
    // le bloc explicite laissé en arrière, les deux portaient des couleurs
    // sombres et le test passait, pendant qu'un choix explicite ramenait
    // l'ancienne palette. Ce qu'il faut comparer, ce sont les deux blocs entre
    // eux, et il n'y a plus de figure à maintenir.
    const media = css.slice(css.indexOf("prefers-color-scheme:dark"));
    expect(
      tokensOf(media, ":root:not([data-theme=light]){"),
      "les deux blocs sombres ont dérivé l'un de l'autre",
    ).toEqual(tokensOf(css, ":root[data-theme=dark]{"));
  });

  /// **Les deux couleurs de barre étaient écrites à la main en cinq endroits.**
  ///
  /// Ce sont les deux `--bg`, et le navigateur les peint autour de la page : la
  /// barre d'état sur iOS, le bandeau d'onglet ailleurs. Elles vivaient dans
  /// `src/theme.ts`, dans les deux métas de `src/index.html`, dans les deux
  /// métas de chaque document construit, dans le script en ligne du thème et
  /// dans les deux clés du manifeste. Un commentaire disait « kept beside the
  /// palette in styles.css » ; rien ne le vérifiait, et le changement de
  /// palette en a trouvé quatre sur cinq encore au bleu.
  ///
  /// Il y a maintenant une source — `BAR` — et c'est la feuille de style
  /// construite qui l'arbitre, pas une sixième copie écrite dans ce test.
  test("la couleur de la barre vient de la palette, partout", () => {
    const css = readFileSync(join(dist, styleFile()), "utf8");
    const light = tokensOf(css, ":root{")["--bg"];
    const dark = tokensOf(css, ":root[data-theme=dark]{")["--bg"];
    expect(light, "la feuille de style n'a pas de fond clair").toBeDefined();
    expect(dark, "la feuille de style n'a pas de fond sombre").toBeDefined();
    expect(BAR.light, "BAR.light contre --bg clair").toBe(light!);
    expect(BAR.dark, "BAR.dark contre --bg sombre").toBe(dark!);

    for (const { file } of BUILT) {
      const html = read(file);
      const metas = [
        ...html.matchAll(
          /<meta name="theme-color" content="([^"]+)" media="\(prefers-color-scheme: (dark|light)\)"/g,
        ),
      ];
      expect(metas.length, `${file} : il faut les deux métas theme-color`).toBe(2);
      for (const meta of metas) {
        expect(meta[1], `${file} : méta ${meta[2]}`).toBe(meta[2] === "dark" ? dark! : light!);
      }
      // Le script en ligne choisit entre les deux quand le lecteur a tranché :
      // sur `auto` les métas suffisent, sur un choix explicite c'est lui.
      expect(html, `${file} : le script de thème doit porter les deux couleurs`).toContain(
        `"${dark}":"${light}"`,
      );
    }

    const manifest = JSON.parse(read("manifest.webmanifest"));
    expect(manifest.theme_color, "manifeste : theme_color").toBe(dark!);
    expect(manifest.background_color, "manifeste : background_color").toBe(dark!);

    // Et la page du serveur de développement, qui n'est pas construite et que
    // rien ne regardait : c'est la copie qui était restée le plus longtemps
    // fausse, parce qu'on ne la voit qu'en lançant `bun run dev`.
    const dev = readFileSync(join(import.meta.dir, "..", "src", "index.html"), "utf8");
    expect(dev, "src/index.html : méta sombre").toContain(
      `content="${dark}" media="(prefers-color-scheme: dark)"`,
    );
    expect(dev, "src/index.html : méta claire").toContain(
      `content="${light}" media="(prefers-color-scheme: light)"`,
    );
  });

  /// **Les contrastes se relisent, ils ne se citent pas.**
  ///
  /// La palette crème portait ses mesures en commentaire — « #bf3a0b rend 4,71
  /// sur crème » — et c'était juste pour le fond. Personne n'avait mesuré les
  /// cartes : le texte doux y rendait 4,27 et l'accent 4,26, sous le seuil de
  /// 4,5 que WCAG demande pour du texte courant, sur les surfaces qui portent
  /// l'essentiel de l'accueil. Le passage au violet l'a vu parce que ce test
  /// existait avant la palette.
  ///
  /// Chaque couple est un couple que la page **peint** — la règle qui le pose
  /// est nommée —, lu dans la feuille de style construite, pour les deux
  /// thèmes. Le dégradé des boutons est lu arrêt par arrêt : un texte posé sur
  /// un dégradé doit tenir sur toute sa longueur, pas en moyenne.
  test("chaque couple texte-fond que la page peint passe 4,5, dans les deux thèmes", () => {
    const css = readFileSync(join(dist, styleFile()), "utf8");
    const lineaire = (c: number) => {
      const v = c / 255;
      return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
    };
    const luminance = (couleur: string) => {
      let hex = couleur.replace("#", "");
      if (hex.length === 3 || hex.length === 4) hex = [...hex].map((c) => c + c).join("");
      expect(hex.length, `${couleur} : une couleur à écrire en hexadécimal opaque`).toBe(6);
      const [r, g, b] = [0, 2, 4].map((i) => lineaire(parseInt(hex.slice(i, i + 2), 16)));
      return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
    };
    const contraste = (a: string, b: string) => {
      const [haut, bas] = [luminance(a), luminance(b)].sort((x, y) => y - x);
      return (haut! + 0.05) / (bas! + 0.05);
    };
    const COUPLES: [texte: string, fond: string, ou: string][] = [
      ["--fg", "--bg", "le corps du texte"],
      ["--fg-soft", "--bg", "les paragraphes d'un document"],
      ["--fg", "--bg-soft", "le titre d'une carte"],
      ["--fg-soft", "--bg-soft", "le texte d'une carte"],
      ["--accent", "--bg", "un lien"],
      ["--accent", "--bg-soft", "l'étiquette d'une carte"],
      ["--accent-fg", "--accent", "le lien d'évitement"],
      ["--fg-code", "--bg-code", "un bloc de code"],
    ];
    for (const [theme, selecteur] of [
      ["clair", ":root{"],
      ["sombre", ":root[data-theme=dark]{"],
    ] as const) {
      const jetons = tokensOf(css, selecteur);
      for (const [texte, fond, ou] of COUPLES) {
        const rendu = contraste(jetons[texte]!, jetons[fond]!);
        expect(rendu, `${theme} : ${texte} sur ${fond} (${ou}) rend ${rendu.toFixed(2)}`)
          .toBeGreaterThanOrEqual(4.5);
      }
      const arrets = jetons["--degrade"]?.match(/#[0-9a-f]{3,8}\b/gi) ?? [];
      expect(arrets.length, `${theme} : le dégradé des boutons doit avoir deux arrêts`).toBe(2);
      for (const arret of arrets) {
        const rendu = contraste(jetons["--accent-fg"]!, arret);
        expect(rendu, `${theme} : un bouton, --accent-fg sur ${arret}, rend ${rendu.toFixed(2)}`)
          .toBeGreaterThanOrEqual(4.5);
      }
    }
  });

  /// An effect runs after the page has painted, so the theme cannot come from
  /// React: a reader who chose light on a dark system would see a flash of
  /// dark on every navigation.
  test("the theme is applied before the first paint, on every page", () => {
    for (const { file } of BUILT) {
      const html = read(file);
      const head = html.slice(0, html.indexOf("</head>"));
      expect(head, `${file} : script de thème absent de la tête`).toContain("wisq.theme");
      expect(head, `${file} : le script doit poser data-theme`).toContain("data-theme");
    }
  });

  /// Inline and dependency-free on purpose: it must not wait for the bundle,
  /// and it must not be able to fail to load.
  test("the theme script is inline and cannot fail to load", () => {
    const head = read("index.html").slice(0, read("index.html").indexOf("</head>"));
    const script = head.match(/<script>[^<]*wisq\.theme[\s\S]*?<\/script>/)?.[0];
    expect(script, "le script de thème doit être en ligne").toBeDefined();
    expect(script).not.toContain("src=");
    expect(script, "il doit échouer sans bruit plutôt que casser la page").toContain("catch");
  });
});

describe("footer", () => {
  /// A footer is where someone goes when the page did not answer them. It is
  /// on every page or it is not a footer, so this checks every page rather
  /// than the landing one.
  /// Read against the copy rather than against hard-coded English, so the
  /// French pages are held to the same standard in their own language instead
  /// of being exempt from the check.
  test("every page carries the whole footer, in its own language", () => {
    // L'échappement de Yew pour un nœud de texte : `&`, `<` et `>`, et pas
    // l'apostrophe, que React écrivait `&#x27;` sans que le HTML l'exige.
    const escape = (text: string) =>
      text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    for (const { lang, file } of BUILT) {
      const html = read(file);
      const footer = copy[lang]!.footer;
      expect(html, `${file} : vie privée`).toContain(
        `>${escape(copy[lang]!.pages.privacy!)}</a>`,
      );
      expect(html, `${file} : retour en haut`).toContain(`>${escape(footer.backToTop)}</a>`);
      expect(html, `${file} : version`).toContain(`${escape(footer.version)} `);
      // These two are here because they were once removed and nothing said
      // so. Taking the licence out of the footer took the end of the version
      // line and one of the three items in the legal row with it, and the
      // build stayed green while the footer visibly thinned. A footer is
      // checked line by line or it is not checked.
      expect(html, `${file} : droits`).toContain(escape(footer.rights));
      expect(html, `${file} : copyright`).toContain(escape(footer.copyright));
    }
  });

  /// The site used to announce a licence in the badge, in the comparison table
  /// and twice in the footer. None had been chosen — it was inherited from a
  /// template and nobody had picked it, which makes it a claim about what
  /// someone may do with this code, published without anyone deciding it.
  ///
  /// So the guard is inverted: naming a licence here has to fail until there
  /// is one to name. When there is, this test is the place that says so, and
  /// changing it is a deliberate act rather than a copy edit.
  test("no page claims a licence for wisq", () => {
    // GPL is allowed: it appears as a fact about QEMU, which is somebody
    // else's project and really is under it.
    //
    // The URL forms are in the list because of where the first one hid: the
    // visible page had been cleaned while the JSON-LD block still carried
    // `"license": "https://www.apache.org/licenses/LICENSE-2.0"` — the
    // machine-readable claim, which is the one a search engine repeats.
    const claims = [
      "Apache-2.0",
      "Apache 2.0",
      "MIT License",
      "Licence MIT",
      "BSD-",
      "apache.org/licenses",
      "opensource.org/licenses",
      "\"license\"",
    ];
    for (const { file } of BUILT) {
      const html = read(file);
      for (const claim of claims) {
        expect(html, `${file} annonce « ${claim} »`).not.toContain(claim);
      }
    }
  });

  /// On every page, in both languages, and naming the same person the
  /// repository's own copyright line names — a site that credits someone the
  /// repository does not is a site making a claim nothing backs.
  ///
  /// It used to read that line out of LICENSE. There is no LICENSE now: none
  /// had been chosen, and a file granting rights nobody decided to grant is
  /// worse than no file. NOTICE still carries the copyright holder, and so
  /// does the README, so the check moved there rather than being dropped —
  /// the claim it guards is about authorship, which did not change.
  test("every page says who made it, and agrees with the repository", () => {
    for (const { lang, file } of BUILT) {
      const html = read(file);
      expect(html, `${file} : ligne d'auteur`).toContain(copy[lang]!.footer.author);
      expect(html, `${file} : nom de l'auteur`).toContain(`>${AUTHOR}</a>`);
      expect(html, `${file} : meta author`).toContain(`<meta name="author" content="${AUTHOR}" />`);
    }
    const repoRoot = join(dist, "..", "..");
    expect(
      readFileSync(join(repoRoot, "NOTICE"), "utf8"),
      "NOTICE doit nommer le même titulaire",
    ).toContain(`Copyright 2026 ${AUTHOR}`);
    for (const file of ["README.md", "README.fr.md"]) {
      expect(
        readFileSync(join(repoRoot, file), "utf8"),
        `${file} doit nommer le même titulaire`,
      ).toContain(`Copyright 2026 ${AUTHOR}`);
    }
  });

  /// Saying what is mine must not quietly stop saying what is not. The
  /// third-party credit is the thing most easily lost when an author line is
  /// added next to it.
  test("crediting the author does not displace the credit to others", () => {
    // The credited name and work, rather than the sentence around them: the
    // sentence differs per language and its apostrophes come out escaped.
    for (const { file } of BUILT) {
      const html = read(file);
      expect(html, `${file} : auteur crédité`).toContain("Charles Lohr");
      expect(html, `${file} : travail crédité`).toContain("mini-rv32ima");
    }
    const notice = readFileSync(join(dist, "..", "..", "NOTICE"), "utf8");
    expect(notice, "NOTICE doit garder la provenance mini-rv32ima").toContain("Charles Lohr");
    expect(notice, "NOTICE doit garder la mention UTM").toContain("UTM");
  });

  /// The site does not present wisq as open source and does not send anyone to
  /// browse its sources. That is a decision about what is published, not a
  /// detail of wording, so it is checked on the built pages rather than left to
  /// whoever next edits the copy: an "open source" badge or a "Source" link
  /// would come back the moment someone added one, and nothing would object.
  ///
  /// This test is about **claiming to be open source and sending people to
  /// browse the sources**. It is not the whole policy: "no page hands out a way
  /// to install the project", just below, forbids the install commands and
  /// download paths, and the two are separate decisions about separate things.
  ///
  /// That sentence replaces one that said "the release download survives on
  /// purpose — it is how a reader installs the thing". It had stopped being
  /// true: the neighbouring test forbids `releases/latest` and `.ipa`, and no
  /// download link is on the site. A comment describing a state that no longer
  /// exists is worse than no comment, because it is what the next reader acts
  /// on — measured, on me: I read it, concluded the site was missing an install
  /// route it was supposed to have, and wrote one before the other test
  /// stopped me.
  test("the site neither claims to be open source nor links to its sources", () => {
    const forbidden = [
      "github.com/maxlestage/wisq/blob/",
      "github.com/maxlestage/wisq/tree/",
      "github.com/maxlestage/wisq/issues",
    ];
    for (const { file } of BUILT) {
      const html = read(file);
      expect(html.toLowerCase(), `${file} : revendication « open source »`).not.toContain(
        "open source",
      );
      for (const link of forbidden) {
        expect(html, `${file} : lien vers les sources`).not.toContain(link);
      }
      expect(html, `${file} : lien « Source » nu vers le dépôt`).not.toContain(
        '"https://github.com/maxlestage/wisq"',
      );
    }
  });

  /// The site explains what wisq is and how it fits together. What it does not
  /// do is tell anyone how to install it — no clone, no tap, no script to pipe
  /// into a shell, no download link. A reader deciding whether this is for
  /// them needs to know that an agent prints a link and the phone scans it;
  /// none of that hands them a build.
  ///
  /// It lived in `render.test.tsx` and read React's render; it reads the built
  /// pages now, which is what a reader gets — and the hero's two new buttons
  /// are held by it like everything else: they lead to the guide and the
  /// release notes, not to a download.
  test("no page hands out a way to install the project", () => {
    for (const { file } of BUILT) {
      const html = read(file);
      for (const trace of [
        "install-ios.sh",
        "install.sh",
        "brew tap",
        "brew install",
        "git clone",
        "cargo run",
        "cargo build",
        "xcodegen",
        "wisq-agent --",
        "githubusercontent",
        'id="install"',
        "releases/latest",
        ".ipa",
      ]) {
        expect(html, `${file} : mode d'emploi (${trace})`).not.toContain(trace);
      }
    }
  });

  /// **Rien de l'invite n'est visible avant que le module n'ait décidé.** La
  /// bannière, ses deux formulations et le bouton d'installation partent
  /// masqués, et seul le bouton de renvoi est laissé visible dans un parent
  /// masqué. Rendre la mauvaise formulation démasquée mettrait « touchez le
  /// bouton Partager » sous un lecteur Android.
  test("nothing in the install banner is visible until the module says so", () => {
    for (const { file } of BUILT) {
      const html = read(file);
      for (const marker of [
        /<aside role="complementary" data-install="" hidden="hidden" class="install-banner">/,
        /<div data-install-variant="prompt" hidden="hidden">/,
        /<div data-install-variant="ios" hidden="hidden">/,
        /<button type="button" data-install-accept="" hidden="hidden"/,
      ]) {
        expect(html, `${file} : « ${marker.source} » n'est pas masqué`).toMatch(marker);
      }
    }
  });

  test("the footer's links stay inside the site", () => {
    const html = read("index.html");
    expect(html, "le pied de page doit mener à la page vie privée").toContain('href="./privacy/"');
  });

  test("the version shown is the newest released one", () => {
    const changelog = readFileSync(join(dist, "..", "..", "CHANGELOG.md"), "utf8");
    const newest = changelog.match(/^## \[(\d+\.\d+\.\d+)\] —/m)?.[1];
    expect(newest, "aucune version datée dans le CHANGELOG").toBeDefined();
    expect(read("index.html"), "la version du pied de page a dérivé").toContain(
      `Version ${newest}`,
    );
  });
});

describe("progressive web app", () => {
  test("the manifest is valid and complete enough to install", () => {
    const manifest = JSON.parse(read("manifest.webmanifest"));
    expect(manifest.name.length).toBeGreaterThan(0);
    expect(manifest.short_name).toBe("wisq");
    expect(manifest.display).toBe("standalone");
    expect(manifest.background_color).toMatch(/^#[0-9a-f]{6}$/i);
    expect(manifest.theme_color).toMatch(/^#[0-9a-f]{6}$/i);

    // Relative, so the site keeps working when it moves off /wisq/.
    expect(manifest.start_url.startsWith("./")).toBe(true);
    expect(manifest.scope.startsWith("./")).toBe(true);
  });

  test("the manifest's icons exist and are the size they claim", () => {
    const manifest = JSON.parse(read("manifest.webmanifest"));
    expect(manifest.icons.length).toBeGreaterThanOrEqual(3);
    for (const icon of manifest.icons) {
      const relative = icon.src.replace(/^\.\//, "");
      const [width, height] = icon.sizes.split("x").map(Number);
      const actual = pngSize(relative);
      expect(actual.width, `${relative} : largeur`).toBe(width);
      expect(actual.height, `${relative} : hauteur`).toBe(height);
    }
  });

  /// An installable icon that a launcher may crop to a circle needs one
  /// declared maskable, or Android pastes the square onto a white plate.
  test("one icon is declared maskable", () => {
    const manifest = JSON.parse(read("manifest.webmanifest"));
    const maskable = manifest.icons.filter((icon: { purpose?: string }) =>
      icon.purpose?.includes("maskable"),
    );
    expect(maskable.length).toBeGreaterThanOrEqual(1);
  });

  /// iOS ignores the manifest for the Home Screen icon and reads this instead.
  /// It is also the reason these are PNG rather than SVG.
  test("the iOS home screen icon is a real PNG", () => {
    expect(pngSize("apple-touch-icon.png")).toEqual({ width: 180, height: 180 });
  });

  test("the social card is the size the scrapers crop to", () => {
    expect(pngSize("social-card.png")).toEqual({ width: 1200, height: 630 });
  });

  /// **These read `sw.js` as text.** That is deliberate and it is not enough:
  /// they check that the built worker names the right files and contains the
  /// right guards, which catches a build that stopped emitting something. What
  /// they cannot see is behaviour — measured, by breaking nine of the worker's
  /// behaviours in ways that left every string below intact, and watching all
  /// nine pass the whole suite. `tests/service-worker.test.ts` runs the worker
  /// instead, and is where a change to what it *does* gets caught.
  test("the service worker precaches only files that exist", () => {
    const sw = read("sw.js");
    const list = JSON.parse(sw.match(/const PRECACHE = (\[[\s\S]*?\]);/)![1]!) as string[];
    expect(list.length).toBeGreaterThan(5);
    for (const entry of list) {
      const relative = entry.replace(/^\.\//, "");
      const target = join(dist, relative === "" ? "index.html" : relative);
      const file = existsSync(target) && statSync(target).isDirectory()
        ? join(target, "index.html")
        : relative.endsWith("/")
          ? join(dist, relative, "index.html")
          : target;
      expect(existsSync(file), `précache ${entry} : fichier absent`).toBe(true);
    }
  });

  /// The defect this exists for: `Cache.addAll` rejects the entire list when
  /// two entries resolve to the same URL, and a rejected install leaves no
  /// worker at all. The site keeps working and quietly stops being installable
  /// — found by driving a browser, not by reading the code.
  test("the precache list has no duplicates, and the install deduplicates anyway", () => {
    const sw = read("sw.js");
    const list = JSON.parse(sw.match(/const PRECACHE = (\[[\s\S]*?\]);/)![1]!) as string[];
    expect(new Set(list).size, "doublon dans PRECACHE").toBe(list.length);
    expect(sw, "l'installation doit dédupliquer").toContain("new Set(");
  });

  /// One fallback per language, or a reader browsing in French falls out of
  /// French the moment the network goes.
  test("the service worker has an offline fallback per language, and both were built", () => {
    const sw = read("sw.js");
    for (const lang of LANGS) {
      expect(sw, `repli hors ligne ${lang}`).toContain(`${lang}: "./${page("offline", lang).path}"`);
      expect(existsSync(join(dist, page("offline", lang).file)), `${lang} : page hors ligne`).toBe(true);
    }
    expect(sw, "le repli suit la langue de l'adresse").toContain("offlineFor");
  });

  /// A 404 from a mistyped link, or a 500 from a half-finished deploy, must not
  /// be kept and served back later. Found by watching the cache grow by one
  /// entry per unknown address while driving a browser.
  test("only pages that actually loaded are cached", () => {
    const sw = read("sw.js");
    const navigation = sw.slice(sw.indexOf('request.mode === "navigate"'));
    expect(navigation.slice(0, navigation.indexOf("cache.put"))).toContain("response.ok");
  });

  test("the cache is versioned, so an old one cannot outlive a deploy", () => {
    const sw = read("sw.js");
    expect(sw).toMatch(/const VERSION = "wisq-[0-9a-f]+"/);
    expect(sw).toContain("caches.delete");
  });
});

describe("discoverability", () => {
  test("the sitemap lists every page meant to be found, in both languages", () => {
    const sitemap = read("sitemap.xml");
    const listed = ROUTES.filter((route) => route.listed);
    for (const lang of LANGS) {
      for (const route of listed) {
        expect(sitemap, `${lang}/${route.id} absent du sitemap`).toContain(
          `${siteURL()}${page(route.id, lang).path}</loc>`,
        );
      }
    }
    expect([...sitemap.matchAll(/<loc>/g)].length).toBe(listed.length * LANGS.length);
    // Each entry names its counterpart, so a search engine shows a reader the
    // one in their language rather than picking for them.
    expect([...sitemap.matchAll(/hreflang=/g)].length).toBe(
      listed.length * LANGS.length * LANGS.length,
    );
    // The offline page and the 404 are not destinations.
    expect(sitemap).not.toContain("offline/");
    expect(sitemap).not.toContain("404");
  });

  test("robots points at the sitemap", () => {
    const robots = read("robots.txt");
    expect(robots).toContain("Sitemap:");
    expect(robots).toContain("sitemap.xml");
  });

  test("an unknown address gets a page, not a bare server error", () => {
    const html = read("404.html");
    expect(html).toContain("Not found");
    // And it can still navigate. With one page left, home is the whole of it —
    // a dead end is not a 404 page.
    expect(html).toContain('class="brand"');
  });

  /// The privacy page says the site loads nothing from anyone else. That is a
  /// claim about the built artefact, so it is checked against the built
  /// artefact rather than trusted.
  test("no external stylesheet, script, font, image or frame is loaded", () => {
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });

    for (const file of walk(dist).filter((f) => f.endsWith(".html"))) {
      const html = readFileSync(file, "utf8");
      const loaders = [
        ...html.matchAll(/<script[^>]+src="([^"]+)"/g),
        ...html.matchAll(/<link[^>]+rel="(?:stylesheet|preload|preconnect|dns-prefetch)"[^>]+href="([^"]+)"/g),
        ...html.matchAll(/<img[^>]+src="([^"]+)"/g),
        ...html.matchAll(/<iframe[^>]+src="([^"]+)"/g),
      ];
      for (const match of loaders) {
        expect(
          /^https?:/.test(match[1]!),
          `${file} charge une ressource externe : ${match[1]}`,
        ).toBe(false);
      }
    }
  });

  test("the stylesheet and the script fetch nothing from another host", () => {
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });

    for (const file of walk(dist).filter((f) => /\.(css|js)$/.test(f))) {
      const text = readFileSync(file, "utf8");
      // @import and url() in CSS, and fetch/import in JS, are the ways an
      // asset pulls in a third party without the HTML showing it.
      for (const match of text.matchAll(/(?:@import\s+|url\(|fetch\(|import\()["']?(https?:\/\/[^"')\s]+)/g)) {
        expect(false, `${file} contacte ${match[1]}`).toBe(true);
      }
    }
  });

  test("nothing in the build leaks an absolute deploy path", () => {
    // Guards the move off /wisq/: a hardcoded /wisq/ in an asset reference
    // would break the day the site gets its own domain.
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((entry) => {
        const full = join(dir, entry);
        return statSync(full).isDirectory() ? walk(full) : [full];
      });
    const documents = walk(dist).filter((file) => file.endsWith(".html"));
    expect(documents.length).toBeGreaterThan(0);
    for (const file of documents) {
      const refs = [...readFileSync(file, "utf8").matchAll(/(?:src|href)="(\/[^"]*)"/g)];
      expect(refs.map((match) => match[1]), `${file} : chemin absolu`).toEqual([]);
    }
  });
});
