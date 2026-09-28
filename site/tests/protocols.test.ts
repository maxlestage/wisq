/// **Le guide disait deux protocoles, la page d'accueil en disait trois.**
///
/// `RemoteProtocol` déclare `vnc`, `spice` et `rdp` ; `MachineEditorView` fait
/// un `ForEach` sur `allCases`, donc l'application propose les trois ;
/// `RemoteSession` construit une `RDPSession` pour le troisième ; et
/// `Sources/WisqRemote/RDP/` porte treize fichiers — négociation, MCS, échange
/// de clés, licence, capacités, bitmaps RLE, entrées. Le tableau des deux
/// README dit « fait » pour cette liste et « à faire » pour NLA/CredSSP, les
/// canaux virtuels, le curseur et la retaille.
///
/// Pendant ce temps `src/pages/docs.ts` annonçait « wisq parle **deux**
/// protocoles de console » et n'en nommait que deux, dans les deux langues,
/// tandis que `content.ts` annonçait « **trois** clients écrits à la main ». Le
/// site se contredisait d'une page à l'autre, et `roadmap.ts` disait de RDP
/// qu'il était « le seul protocole de console que wisq ne parle pas ».
///
/// **La liste qui décide est celle du code**, parce que c'est elle que
/// l'application montre. Ce fichier la lit et exige que la page la nomme
/// entière, et que le nombre écrit en mots s'accorde.
///
/// **Ce qu'il ne tient pas** : ce que chaque protocole *fait*. Que RDP ne parle
/// que la sécurité historique, qu'un serveur exigeant NLA soit refusé par son
/// nom — aucune comparaison de listes ne voit ça. C'est le tableau des README
/// qui le porte, et il n'est pas tenu non plus.

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

/// Les noms tels que l'application les affiche : le `displayName` de l'énum,
/// pas les cases, parce que c'est cette chaîne-là que l'utilisateur lit dans le
/// sélecteur et que la page doit employer.
/// **Le premier lecteur écrit ici lisait trop.** Il découpait à partir de
/// `var displayName` jusqu'à la fin du fichier, ramassait les `return` des
/// propriétés suivantes et annonçait quatre protocoles dont « TLS ». Un lecteur
/// trop gourmand ne se distingue pas d'un lecteur juste tant que personne ne
/// compte ce qu'il a lu : les cases de l'énum sont donc relues séparément, et
/// les deux comptes doivent s'accorder.
function protocolNames(): string[] {
  const source = readFileSync(
    join(repoRoot, "Sources", "WisqCore", "RemoteProtocol.swift"),
    "utf8",
  );
  const start = source.indexOf("var displayName");
  expect(start, "RemoteProtocol n'a plus de displayName").toBeGreaterThan(0);
  const block = source.slice(start, source.indexOf("\n    }", start));
  const names = [
    ...new Set([...block.matchAll(/case \.\w+: return "([A-Z0-9]+)"/g)].map((m) => m[1])),
  ];

  // Le second lecteur : les cases déclarées avant la première propriété.
  const head = source.slice(source.indexOf("enum RemoteProtocol"), start);
  const cases = [...new Set([...head.matchAll(/^ {4}case (\w+)$/gm)].map((m) => m[1]))];
  expect(
    names.length,
    `displayName rend ${names.length} noms (${names.join(", ")}) et l'énum déclare ` +
      `${cases.length} cases (${cases.join(", ")}) : l'un des deux lecteurs lit à côté.`,
  ).toBe(cases.length);
  return names;
}

/// **Le paragraphe qui annonce le compte, et lui seul.**
///
/// La première version de ce test demandait que le nom apparaisse « quelque part
/// dans la moitié », et un sabordage a SURVÉCU : retirer « RDP » de la phrase qui
/// liste les protocoles laissait intacte l'occurrence de la phrase suivante, et
/// la garde passait. C'est l'assertion qui a l'air d'une garde — elle mesurait
/// une empreinte, pas l'acte. Le paragraphe est donc découpé autour de l'endroit
/// où le compte est annoncé, et c'est lui qui doit nommer les trois.
function announcingParagraph(text: string, pattern: RegExp): string {
  const found = text.match(pattern);
  expect(found, `aucun paragraphe n'annonce combien de protocoles : ${pattern}`).not.toBeNull();
  const at = text.indexOf(found![0]);
  const opens = text.lastIndexOf('"', at);
  const closes = text.indexOf('"', at);
  expect(opens, "le paragraphe n'est pas une chaîne entre guillemets").toBeGreaterThan(-1);
  expect(closes).toBeGreaterThan(at);
  return text.slice(opens, closes);
}

/// Les deux moitiés du guide. Le fichier porte `docsEn` puis `docsFr`, et une
/// correction faite dans une seule langue est le défaut le plus courant de ce
/// dépôt.
function halves(): { language: string; text: string }[] {
  const page = readFileSync(join(repoRoot, "site", "src", "pages", "docs.ts"), "utf8");
  const split = page.indexOf("export const docsFr");
  expect(split, "docs.ts ne porte plus deux moitiés nommées").toBeGreaterThan(0);
  return [
    { language: "en", text: page.slice(0, split) },
    { language: "fr", text: page.slice(split) },
  ];
}

/// Le nombre écrit en mots, par langue. Un guide qui dit « deux » là où l'énum
/// en déclare trois est faux même s'il nomme les trois.
const spelled: Record<number, { en: string; fr: string }> = {
  1: { en: "one", fr: "un" },
  2: { en: "two", fr: "deux" },
  3: { en: "three", fr: "trois" },
  4: { en: "four", fr: "quatre" },
};

const counted = {
  en: /(\w+) console protocols/,
  fr: /(\w+) protocoles de console/,
};

test("le paragraphe qui annonce le compte nomme chaque protocole", () => {
  const names = protocolNames();
  for (const { language, text } of halves()) {
    const paragraph = announcingParagraph(text, counted[language as "en" | "fr"]);
    for (const name of names) {
      expect(
        paragraph.includes(name),
        `« ${name} » est dans RemoteProtocol.allCases, donc dans le sélecteur ` +
          `de l'application, et le paragraphe ${language} qui annonce les ` +
          `protocoles ne le nomme pas.`,
      ).toBe(true);
    }
  }
});

test("le compte écrit en mots est celui de l'énum", () => {
  const names = protocolNames();
  const word = spelled[names.length];
  expect(word, `aucun mot connu pour ${names.length} protocoles`).toBeDefined();
  for (const { language, text } of halves()) {
    const pattern = counted[language as "en" | "fr"];
    const found = text.match(pattern);
    expect(found, `la moitié ${language} ne dit plus combien de protocoles`).not.toBeNull();
    expect(
      found?.[1],
      `la moitié ${language} annonce « ${found?.[1]} » protocoles de console, ` +
        `et l'énum en déclare ${names.length} (${names.join(", ")}).`,
    ).toBe(word[language as "en" | "fr"]);
  }
});

/// **Un lecteur qui ne lit rien ressemble à un lecteur qui lit la bonne
/// chose.** Si le motif du `displayName` cessait de correspondre, les deux tests
/// ci-dessus passeraient sur une liste vide.
test("la liste vient vraiment du code, et elle n'est pas vide", () => {
  const names = protocolNames();
  expect(names.length).toBeGreaterThanOrEqual(2);
  expect(names).toContain("RDP");
});
