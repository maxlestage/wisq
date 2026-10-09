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

/// Le dossier des pages du site, depuis que le front est en Rust.
const pages = join(repoRoot, "crates", "wisq-site", "src", "pages");

/// Les deux moitiés du guide. Le fichier porte `DOCS_EN` puis `DOCS_FR`, et une
/// correction faite dans une seule langue est le défaut le plus courant de ce
/// dépôt.
function halves(): { language: string; text: string }[] {
  const page = readFileSync(join(pages, "docs.rs"), "utf8");
  const split = page.indexOf("pub static DOCS_FR");
  expect(split, "docs.rs ne porte plus deux moitiés nommées").toBeGreaterThan(0);
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

/// **La page qui prévient du clair doit dire que le chiffrement existe.**
///
/// `privacy.ts` portait « la version 1 parle à vos machines en clair », à plat.
/// `MachineEditorView` a pourtant un sélecteur « Chiffrement » qui parcourt
/// `TransportSecurity.allCases` — aucun, TLS, TLS épinglé par empreinte —, et
/// `NetworkByteStream` porte les trois. Le clair est le **défaut**, pas la
/// seule possibilité, et c'est sur la page de confidentialité que la nuance
/// compte le plus : quelqu'un pouvait lire ça et monter un tunnel là où deux
/// touches suffisaient.
///
/// Ce test tient la moitié qu'une liste peut tenir : tant que
/// `TransportSecurity` offre autre chose que `none`, la réserve doit nommer
/// TLS. Ce qu'il ne tient pas, c'est la justesse du reste de la phrase.
function securityModes(): string[] {
  const source = readFileSync(
    join(repoRoot, "Sources", "WisqCore", "RemoteProtocol.swift"),
    "utf8",
  );
  const head = source.slice(source.indexOf("enum TransportSecurity"));
  const block = head.slice(0, head.indexOf("\n    public var"));
  return [...new Set([...block.matchAll(/^ {4}case (\w+)$/gm)].map((m) => m[1]))];
}

test("la réserve sur le clair nomme le chiffrement que l'application propose", () => {
  const modes = securityModes();
  expect(modes, "TransportSecurity ne déclare plus de cases").toContain("none");
  const encrypted = modes.filter((mode) => mode !== "none");
  if (encrypted.length === 0) return;

  const page = readFileSync(join(pages, "privacy.rs"), "utf8");
  const split = page.indexOf("pub static PRIVACY_FR");
  expect(split, "privacy.rs ne porte plus deux moitiés nommées").toBeGreaterThan(0);

  // **Ce qui est mesuré est la phrase sur la machine, pas le paragraphe.** Un
  // premier sabordage a SURVÉCU : en retirant TLS de la partie « transport
  // d'une machine », la phrase d'après — celle sur le démon hôte, qui parle
  // TLS aussi — satisfaisait l'assertion. La tranche voisine a payé le même
  // défaut la veille : une assertion sur un paragraphe se laisse contenter par
  // un autre chemin. La lecture s'arrête donc là où le sujet change.
  for (const [language, half, agent] of [
    ["en", page.slice(0, split), "The host agent"],
    ["fr", page.slice(split), "Le démon hôte"],
  ] as const) {
    const warning = half.match(/[^"]*(in the clear|en clair)[^"]*/);
    expect(warning, `la moitié ${language} ne parle plus du trafic en clair`).not.toBeNull();
    const cut = warning![0].indexOf(agent);
    expect(
      cut,
      `la réserve ${language} ne passe plus au démon hôte (« ${agent} ») : ` +
        `la découpe ne sait plus où le sujet change.`,
    ).toBeGreaterThan(0);
    const aboutMachines = warning![0].slice(0, cut);
    expect(
      aboutMachines.includes("TLS"),
      `la moitié ${language} prévient du trafic en clair vers vos machines sans ` +
        `dire que l'application propose ${encrypted.join(" et ")} : le clair est ` +
        `le défaut, pas la seule possibilité. (Le démon hôte, lui, est nommé ` +
        `après et ne compte pas pour cette phrase.)`,
    ).toBe(true);
  }
});

/// **« Quatre routes derrière un jeton porteur », et personne ne comptait.**
///
/// #317 a relevé les quantités écrites **en lettres** dans les pages du site —
/// un nombre en mots échappe au compteur de `claims.test.ts`, qui compte les
/// chiffres — et il en restait une sans garde et sans liste : celle-ci. Elle a
/// été nommée dans le journal plutôt que vérifiée, deux tranches de suite.
///
/// **Elle est juste.** Mesuré : `service.rs` porte quatre bras de route,
/// `AgentClient.swift` quatre appels, et la page énumère les quatre dans les
/// deux langues. Ce test existe pour que ça reste vrai sans que personne n'ait
/// à le recompter — et pour que la phrase cesse d'être une affirmation que le
/// dépôt porte sans la tenir.
///
/// **Ce qu'il tient, et c'est la phrase entière :**
/// - le **compte** des routes du démon, lu dans son `match` ;
/// - le **compte** des appels du client Swift, qui doit être le même — c'est ce
///   que « implémenté deux fois pour ne pas pouvoir diverger » veut dire ;
/// - les **énumérations** de la page, une par langue ;
/// - le **mot** de chaque chapeau, dans les deux langues ;
/// - et **« derrière un jeton »** : que le contrôle du jeton précède la
///   répartition, de sorte qu'aucune route ne puisse être ajoutée devant lui.
///
/// **Ce qu'il ne tient pas** : ce que chaque route *fait*. Qu'un identifiant
/// invalide soit refusé avant d'atteindre un sous-processus, que `stop` lise
/// `force` dans le corps — aucun comptage ne voit ça. Ce sont les tests du
/// démon qui le portent.
const ROUTE_WORDS_FR = ["zéro", "une", "deux", "trois", "quatre", "cinq", "six", "sept", "huit"];
const ROUTE_WORDS_EN = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight"];

test("les quatre routes du protocole sont comptées là où elles sont écrites", () => {
  const daemon = readFileSync(
    join(repoRoot, "crates/wisq-agent/src/service.rs"),
    "utf8",
  );
  // Les bras de route portent une **longueur de chemin chiffrée** —
  // `("GET", 2)`, `("POST", 4)` — là où les deux bras de secours portent `_`.
  // C'est ce qui les distingue sans avoir à lire la suite de chaque bras.
  //
  // **Et la méthode n'est pas énumérée, elle est quelconque.** Le premier
  // lecteur écrit ici ne comptait que `GET` et `POST` : un sabotage qui ajoutait
  // un bras `("DELETE", 3)` au démon a **survécu**, servi et annoncé nulle part.
  // Un compte qui ne voit qu'une partie de ce qu'il compte ne garde pas le
  // reste — c'est la sixième fois qu'un survivant nomme une garde absente
  // plutôt qu'une garde fausse.
  const served = [...daemon.matchAll(/\("[A-Z]+", \d+\)/g)];
  expect(served.length, "aucun bras de route trouvé dans service.rs").toBeGreaterThan(1);

  // **Le jeton d'abord.** La phrase dit « derrière un jeton porteur » : le
  // contrôle doit précéder la répartition, sinon une route ajoutée devant lui
  // serait ouverte à tous et la page mentirait sans qu'un compte bouge.
  const guardAt = daemon.indexOf("if !self.authorized(");
  expect(guardAt, "service.rs ne contrôle plus le jeton par `authorized`").toBeGreaterThan(-1);
  expect(
    guardAt,
    "le contrôle du jeton doit venir avant le premier bras de route",
  ).toBeLessThan(daemon.search(/\("[A-Z]+", \d+\)/));

  const client = readFileSync(
    join(repoRoot, "Sources/WisqRemote/Agent/AgentClient.swift"),
    "utf8",
  );
  const called = [...client.matchAll(/send\(path: "vms/g)];
  expect(
    called.length,
    `le démon sert ${served.length} routes et le client en appelle ${called.length} : ` +
      "« implémenté deux fois pour ne pas pouvoir diverger » ne tient plus",
  ).toBe(served.length);

  const page = readFileSync(join(pages, "protocol.rs"), "utf8");
  // Une énumération par langue : la page est écrite deux fois, et c'est
  // justement la moitié qui dérive quand personne ne compte.
  const listed = [...page.matchAll(/Block::H3\("[A-Z]+ \/v1\/vms/g)];
  expect(
    listed.length,
    `la page énumère ${listed.length} routes pour ${served.length} servies, ` +
      "dans deux langues",
  ).toBe(served.length * 2);

  for (const [words, pattern, language] of [
    [ROUTE_WORDS_FR, /([\p{L}]+) routes derrière un jeton porteur/u, "fr"],
    [ROUTE_WORDS_EN, /([\p{L}]+) routes behind a bearer token/iu, "en"],
  ] as const) {
    const found = page.match(pattern);
    expect(found, `la moitié ${language} n'annonce plus le nombre de routes`).not.toBeNull();
    expect(
      found![1].toLowerCase(),
      `la moitié ${language} annonce « ${found![1]} » et le démon sert ${served.length} routes`,
    ).toBe(words[served.length]);
  }
});
