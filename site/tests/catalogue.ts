/// **Ce que le site déclare de lui-même, lu à la source.**
///
/// Les tests lisaient `src/routes.ts`, `src/content.ts`, `src/pages/*.ts` et
/// `src/theme.ts` : la liste des routes, la copie, les documents, les couleurs
/// de barre. Ces fichiers sont partis avec React — le front entier est dans
/// `crates/wisq-site` —, et une seconde déclaration écrite ici serait
/// exactement la copie que ce dépôt passe son temps à retirer.
///
/// Le binaire de pré-rendu sait tout ça, puisqu'il rend les pages : il l'écrit
/// en JSON sur sa sortie, la construction le lit pour écrire `dist`, et les
/// tests le lisent ici. **Une seule source pour la page, la construction et la
/// garde.** Il est construit par `bun run build`, qui doit tourner avant
/// `bun test` — la CI fait exactement ça.

import { existsSync } from "node:fs";
import { join } from "node:path";

export interface Route {
  id: string;
  path: string;
  listed: boolean;
  output: string | null;
}

export interface Rendered {
  route: string;
  lang: string;
  /// Le fichier écrit, relatif à `dist` : `index.html`, `fr/docs/index.html`.
  file: string;
  /// L'adresse, relative à la racine du site : `""`, `"fr/docs/"`.
  path: string;
  base: string;
  title: string;
  description: string;
  /// Une phrase de prose de la page, assez longue pour qu'aucune autre ne la
  /// contienne : `null` pour l'accueil, qui n'est pas un document.
  sentence: string | null;
  markup: string;
}

export interface Copy {
  pages: Record<string, string>;
  footer: { author: string; rights: string; copyright: string; backToTop: string; version: string };
  hero: { tagline: string; lede: string };
  facts: { value: string; label: string }[];
}

export interface Catalogue {
  langs: string[];
  bar: { light: string; dark: string };
  author: string;
  authorUrl: string;
  version: string;
  releasedVersions: string[];
  routes: Route[];
  copy: Record<string, Copy>;
  pages: Rendered[];
}

export const PRERENDER = join(
  import.meta.dir, "..", "..", "target", "release", "wisq-site-prerender",
);

let cached: Catalogue | undefined;

export function catalogue(): Catalogue {
  if (cached) return cached;
  if (!existsSync(PRERENDER)) {
    throw new Error(`${PRERENDER} manquant : lancez \`bun run build\` avant \`bun test\``);
  }
  const run = Bun.spawnSync([PRERENDER], { stdout: "pipe", stderr: "pipe" });
  if (!run.success) {
    throw new Error(`le pré-rendu a échoué : ${new TextDecoder().decode(run.stderr)}`);
  }
  cached = JSON.parse(new TextDecoder().decode(run.stdout)) as Catalogue;
  return cached;
}

export function route(id: string): Route {
  const found = catalogue().routes.find((r) => r.id === id);
  if (!found) throw new Error(`route inconnue : ${id}`);
  return found;
}

export function page(id: string, lang: string): Rendered {
  const found = catalogue().pages.find((p) => p.route === id && p.lang === lang);
  if (!found) throw new Error(`page inconnue : ${lang}/${id}`);
  return found;
}
