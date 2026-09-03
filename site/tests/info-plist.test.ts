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

test("App/Info.plist n'est pas suivi par git, parce qu'il est généré", () => {
  // La garde qui compte : tant que le fichier est suivi, quelqu'un l'éditera
  // en croyant que ça sert, et XcodeGen l'effacera au prochain passage.
  const tracked = execFileSync("git", ["ls-files", "App/"], {
    cwd: new URL("../..", import.meta.url).pathname,
    encoding: "utf8",
  });
  expect(tracked).not.toContain("App/Info.plist");
});
