// **Sous quelle forme un module doit-il traverser vers la vue ?**
//
// L'application traduit une région et doit remettre les octets au
// `WKWebView`. `web/host.js` déclare que `wisqTranslated(id, octets)` reçoit
// **un tableau de nombres**, et la question revient forcément : pourquoi pas du
// base64, trois fois plus court à écrire ?
//
//     bun scripts/wasm-crossing-probe.ts
//
// **La réponse s'inverse deux fois selon comment on la mesure**, ce qui est la
// raison d'être de cette sonde. Le tableau produit une source deux fois et
// demie plus longue, donc il devrait perdre ; il gagne, parce que
// JavaScriptCore analyse un littéral plus vite qu'une boucle de décodage ne
// tourne. Puis il reperd contre `Uint8Array.fromBase64`, qui décode en natif —
// mais cette méthode demande iOS 18.2 alors que wisq vise iOS 17, et sur le
// plancher la seule solution de repli est justement la boucle, la pire des
// trois.
//
// Et l'ordre de grandeur ferme le sujet : un démarrage traduit quelques
// milliers de régions, donc l'écart total se compte en dizaines de
// millisecondes **sur un démarrage entier**. Le tableau reste, et cette sonde
// est ce qui permet de le dire plutôt que de le croire.
//
// Bun embarque le même JavaScriptCore que le WKWebView ; c'est ce qui rend la
// mesure d'ici pertinente. Elle ne dit rien du processeur d'un iPhone, et n'en
// a pas besoin : ce qu'on compare, ce sont deux chemins dans le même moteur.

import { readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..");

// **Un vrai module, pas un tampon d'octets au hasard.** `WebKitBench` porte
// celui que l'émetteur produit pour la boucle du banc, et un test Rust le
// compare à ce que l'émetteur refait — donc il ne peut pas rancir en silence.
// Le relire ici évite d'en poser une seconde copie dans le dépôt.
function benchModule(): Uint8Array {
  const swift = readFileSync(
    join(repoRoot, "Sources/WisqCore/WebKitBench.swift"),
    "utf8",
  );
  const at = swift.indexOf("moduleBase64 =");
  if (at < 0) throw new Error("WebKitBench n'annonce plus de moduleBase64");
  const end = swift.indexOf("public static let guestPages", at);
  const pieces = swift.slice(at, end).match(/"([A-Za-z0-9+/=]+)"/g) ?? [];
  const base64 = pieces.map((piece) => piece.slice(1, -1)).join("");
  const binary = atob(base64);
  const module = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) module[i] = binary.charCodeAt(i);
  return module;
}

const module = benchModule();

// Les vraies régions vont plus haut que ce module-ci. Ce qui est mesuré est le
// coût **par octet**, donc la seconde taille est là pour montrer comment
// chaque forme monte, pas pour décrire un module en particulier.
const larger = new Uint8Array(4 * 1024);
for (let at = 0; at < larger.length; at++) larger[at] = module[at % module.length];

let received: Uint8Array | null = null;
const globals = globalThis as Record<string, unknown>;
globals.viaArray = (_id: number, bytes: number[]) => {
  received = Uint8Array.from(bytes);
};
globals.viaLoop = (_id: number, text: string) => {
  const binary = atob(text);
  const out = new Uint8Array(binary.length);
  for (let at = 0; at < binary.length; at++) out[at] = binary.charCodeAt(at);
  received = out;
};
globals.viaNative = (_id: number, text: string) => {
  const from = (Uint8Array as unknown as {
    fromBase64?: (text: string) => Uint8Array;
  }).fromBase64;
  received = from ? from(text) : null;
};

function base64Of(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function time(source: string, turns: number): number {
  const started = Bun.nanoseconds();
  for (let turn = 0; turn < turns; turn++) (0, eval)(source);
  return (Bun.nanoseconds() - started) / turns / 1000;
}

console.log(`Uint8Array.fromBase64 : ${
  (Uint8Array as unknown as { fromBase64?: unknown }).fromBase64
    ? "présente"
    : "absente"
}\n`);

for (const [what, bytes] of [
  [`module du banc (${module.length} o)`, module],
  [`quatre kibioctets`, larger],
] as const) {
  const text = base64Of(bytes);
  const forms: Record<string, string> = {
    "tableau": `viaArray(1, [${bytes.join(",")}])`,
    "base64, boucle": `viaLoop(1, "${text}")`,
    "base64, natif": `viaNative(1, "${text}")`,
  };
  console.log(what);
  for (const [name, source] of Object.entries(forms)) {
    // **Vérifier avant de chronométrer.** Une forme qui rend les mauvais
    // octets serait la plus rapide de toutes, et le classement ne voudrait
    // rien dire.
    received = null;
    (0, eval)(source);
    if (received === null) {
      console.log(`  ${name.padEnd(15)} indisponible dans ce moteur`);
      continue;
    }
    const back = received as Uint8Array;
    if (back.length !== bytes.length) throw new Error(`${name} : longueur`);
    for (let at = 0; at < bytes.length; at++) {
      if (back[at] !== bytes[at]) throw new Error(`${name} : octet ${at}`);
    }
    time(source, 200);
    const each = time(source, 3000);
    const growth = (source.length / bytes.length).toFixed(2);
    console.log(
      `  ${name.padEnd(15)} ${each.toFixed(1)} µs   source ${source.length} o (×${growth})`,
    );
  }
  console.log();
}
