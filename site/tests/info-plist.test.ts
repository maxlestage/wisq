import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

/**
 * Ce que l'application déclare à iOS, et pourquoi ça vit dans `project.yml`.
 *
 * `xcodegen generate` **écrit** le fichier nommé par `info.path` : il part de
 * ses clés par défaut, y fusionne `info.properties`, supprime ce qui existait
 * et écrit le résultat. Un `App/Info.plist` tenu à la main était donc effacé à
 * chaque génération — mesuré en exécutant XcodeGen, pas déduit — et
 * l'application construite n'avait plus que huit clés.
 *
 * Ce qui manquait alors n'était pas décoratif : le schéma d'URL `wisq://` (les
 * liens d'appairage), la découverte Bonjour, l'autorisation de réseau local
 * sans laquelle iOS 14+ ne laisse joindre aucune machine, la version, et les
 * deux clés sur lesquelles App Store Connect a refusé le premier envoi
 * (90475 écran de lancement, 90474 orientations).
 */
const manifest = readFileSync(new URL("../../project.yml", import.meta.url), "utf8");

/** Le bloc `properties` de la cible application, tel quel. */
function appProperties(): string {
  const start = manifest.indexOf("      properties:");
  expect(start).toBeGreaterThan(-1);
  const end = manifest.indexOf("\n    dependencies:", start);
  expect(end).toBeGreaterThan(start);
  return manifest.slice(start, end);
}

test("tout ce que l'application déclare à iOS est dans project.yml", () => {
  const properties = appProperties();
  const required = [
    // Refus 90475 : sans écran de lancement, le paquet est rejeté à l'envoi.
    "UILaunchScreen",
    // Refus 90474 : sans orientations, idem.
    "UISupportedInterfaceOrientations",
    // Sans quoi les liens wisq:// n'ouvrent pas l'application.
    "CFBundleURLSchemes",
    // Sans quoi la découverte des agents sur le réseau local est muette.
    "NSBonjourServices",
    // Sans quoi iOS refuse le réseau local, donc tout ce que fait wisq.
    "NSLocalNetworkUsageDescription",
    // Sans quoi TestFlight redemande la conformité à l'exportation.
    "ITSAppUsesNonExemptEncryption",
    // Sans quoi le numéro de build de l'exécution CI est ignoré.
    "CFBundleVersion",
  ];
  for (const key of required) {
    expect(properties).toContain(key);
  }
});

test("les quatre orientations sont déclarées, pas trois", () => {
  // Apple refuse le paquet deux fois pour la même clé, avec deux messages :
  // absente (90474), et présente mais incomplète — « you need to include all
  // of the four orientations to support iPad multitasking ». Une application
  // qui déclare l'iPad et ne demande pas le plein écran a opté pour le
  // multitâche, donc les quatre sont exigées. Trois avaient été écrites, et
  // le deuxième envoi a été refusé là-dessus.
  const properties = appProperties();
  for (const orientation of [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
  ]) {
    expect(properties).toContain(orientation);
  }
});

test("le schéma d'URL déclaré est bien celui des liens d'appairage", () => {
  // `AgentPairingLink` et le QR du démon écrivent wisq:// ; un schéma qui
  // change ici sans changer là casse l'appairage sans rien faire rougir.
  expect(appProperties()).toContain("wisq");
  const daemon = readFileSync(
    new URL("../../crates/wisq-agent/src/pairing.rs", import.meta.url), "utf8");
  expect(daemon).toContain("wisq://agent");
});

/** Ce que `git ls-files` connaît, sous la racine donnée. */
function tracked(path: string): string {
  return execFileSync("git", ["ls-files", path], {
    cwd: new URL("../..", import.meta.url).pathname,
    encoding: "utf8",
  });
}

test("les deux sorties de XcodeGen sont suivies, et rien d'autre du projet", () => {
  // Ce test disait le contraire : `App/Info.plist` ne devait PAS être suivi,
  // pour que personne ne l'édite en croyant que ça sert. La raison était
  // bonne et la conséquence ne l'était pas — sans `Wisq.xcodeproj` ni
  // `Info.plist` dans le dépôt, il faut XcodeGen pour avoir quoi que ce soit
  // à ouvrir, et XcodeGen n'est pas dans Xcode. Les deux fichiers sont donc
  // suivis, et ce qui remplace l'exclusion est le test d'à côté : ils doivent
  // dire la même chose que `project.yml`.
  expect(tracked("App/")).toContain("App/Info.plist");
  expect(tracked("Wisq.xcodeproj/")).toContain("Wisq.xcodeproj/project.pbxproj");

  // La ré-inclusion du .gitignore ne laisse entrer que le fichier de projet :
  // l'espace de travail et le schéma sont des états d'éditeur, pas la spec.
  expect(tracked("Wisq.xcodeproj/")).not.toContain("xcworkspace");
  expect(tracked("Wisq.xcodeproj/")).not.toContain("xcscheme");

  // Le catalogue d'icônes reste dehors : c'est un binaire, et
  // `scripts/build-app-icon.sh` le dessine depuis le code du site.
  expect(tracked("App/")).not.toContain("Assets.xcassets");
});

/**
 * Les cinq clés que XcodeGen écrit de lui-même, mesurées sur le fichier qu'il
 * produit plutôt que lues dans sa documentation. Tout le reste du plist doit
 * venir de `project.yml`, et c'est ce que le test ci-dessous exige dans les
 * deux sens.
 */
const xcodegenDefaults = [
  "CFBundleExecutable",
  "CFBundleIdentifier",
  "CFBundleInfoDictionaryVersion",
  "CFBundleName",
  "CFBundlePackageType",
];

test("le plist commité et project.yml déclarent exactement les mêmes clés", () => {
  // La garde qui remplace l'exclusion. Un fichier généré sous suivi diverge de
  // sa source en silence : quelqu'un modifie `project.yml` sans relancer
  // `xcodegen generate`, et le dépôt porte un manifeste qui n'est plus celui
  // que la spec décrit. C'est déjà arrivé dans l'autre sens, quand le plist
  // était tenu à la main : huit clés au lieu de dix-neuf, sans un rouge.
  //
  // Ce que ce test ne voit pas, dit franchement : les *valeurs*. Une chaîne
  // changée dans `project.yml` et non régénérée passe ici. La garde qui le
  // verrait régénère et compare octet pour octet, ce que cette suite ne peut
  // pas faire — elle tourne sous Bun, sans XcodeGen.
  const properties = appProperties();
  const declared = [...properties.matchAll(/^ {8}([A-Za-z][A-Za-z0-9]*):/gm)]
    .map((match) => match[1]!);
  expect(declared.length).toBeGreaterThan(0);

  const plist = readFileSync(new URL("../../App/Info.plist", import.meta.url), "utf8");
  const written = [...plist.matchAll(/<key>([^<]+)<\/key>/g)].map((match) => match[1]!);
  expect(written.length).toBeGreaterThan(0);

  // Sens 1 — la spec vers le fichier : ce que `project.yml` déclare est écrit.
  for (const key of declared) {
    expect(written).toContain(key);
  }

  // Sens 2 — le fichier vers la spec : rien n'y est arrivé par une autre voie
  // que `project.yml`, defaults de XcodeGen mis à part. Les clés imbriquées
  // (celles du dictionnaire de `CFBundleURLTypes`) sont couvertes ici : elles
  // sont dans le bloc `properties`, plus bas que huit espaces.
  for (const key of written) {
    if (xcodegenDefaults.includes(key)) continue;
    expect(properties).toContain(key);
  }
});
