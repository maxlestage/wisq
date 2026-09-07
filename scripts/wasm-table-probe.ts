// **Un module peut-il en appeler un autre sans repasser par JavaScript, et à
// quel prix ?**
//
// `cargo run -p wisq-vm --release --example chain` a relevé **192 ns par retour
// de main**, et l'a décomposé : le poste principal n'est pas WebAssembly, c'est
// le site d'appel JavaScript. Un `run` appelé en boucle coûte 25 ns ;
// soixante-quatre `run` différents depuis le même endroit en coûtent 99, parce
// que JavaScriptCore y perd son cache en ligne. Une boucle hôte qui répartit
// par adresse depuis JavaScript paie ça à chaque changement de région.
//
// **La piste, et c'est elle que cette sonde juge.** Une `WebAssembly.Table`
// **importée et partagée** : chaque région y pose ses blocs, et un
// `call_indirect` sur cette table atteint un bloc compilé dans un *autre*
// module — sans jamais repasser par JavaScript. Si c'est deux nanosecondes, la
// répartition entre régions redevient interne et le bureau local tient ; si
// c'est cent, la piste ne vaut rien et il faut le dire.
//
// Cette sonde ne mesure pas wisq : elle mesure **le moteur**, avec deux modules
// écrits à la main, minuscules et sans rapport avec l'émetteur. C'est voulu —
// la question porte sur ce que JavaScriptCore sait faire, pas sur ce que le
// dépôt produit.
//
// **Et la seconde moitié de la question**, plus bas dans ce fichier : une région
// ne connaît pas l'indice, dans la table, d'une adresse qu'elle n'a pas
// compilée. Il lui faudrait une correspondance adresse → indice lue à
// l'exécution. Combien coûte-t-elle, et le module sait-il la faire seul ?
//
//     bun scripts/wasm-table-probe.ts

const LINKS = 64;

function uleb(value: number): number[] {
  const out: number[] = [];
  do {
    let byte = value & 0x7f;
    value >>>= 7;
    if (value !== 0) byte |= 0x80;
    out.push(byte);
  } while (value !== 0);
  return out;
}

const section = (id: number, body: number[]) => [id, ...uleb(body.length), ...body];
const vector = (items: number[][]) => [...uleb(items.length), ...items.flat()];
const name = (text: string) => [...uleb(text.length), ...[...text].map(c => c.charCodeAt(0))];
// **La taille se dérive, elle ne se compte pas à la main.** Mon premier essai a
// écrit huit pour un corps de sept octets, et le moteur a refusé le module en
// disant que la fonction dépassait ce qui restait.
const codeEntry = (body: number[]) => [...uleb(body.length), ...body];
const HEADER = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

/// Un module appelé : une fonction `() -> i32` qui rend une constante.
function callee(value: number): Uint8Array {
  return Uint8Array.from([
    ...HEADER,
    ...section(1, vector([[0x60, 0x00, 0x01, 0x7f]])),
    ...section(3, vector([[0x00]])),
    ...section(7, vector([[...name("f"), 0x00, 0x00]])),
    ...section(10, vector([codeEntry([0x00, 0x41, value & 0x7f, 0x0b])])),
  ]);
}

/// Le module appelant : il **importe** la table et fait `call_indirect` sur
/// l'indice qu'on lui passe. Rien d'autre.
const caller = Uint8Array.from([
  ...HEADER,
  ...section(1, vector([[0x60, 0x00, 0x01, 0x7f], [0x60, 0x01, 0x7f, 0x01, 0x7f]])),
  ...section(2, vector([[...name("env"), ...name("t"), 0x01, 0x70, 0x00, ...uleb(LINKS)]])),
  ...section(3, vector([[0x01]])),
  ...section(7, vector([[...name("run"), 0x00, 0x00]])),
  ...section(10, vector([codeEntry([0x00, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0b])])),
]);

const table = new WebAssembly.Table({ element: "anyfunc", initial: LINKS });
const direct: Array<() => number> = [];
for (let index = 0; index < LINKS; index++) {
  const instance = new WebAssembly.Instance(new WebAssembly.Module(callee(index)), {});
  const f = instance.exports.f as () => number;
  table.set(index, f);
  direct.push(f);
}
const run = new WebAssembly.Instance(new WebAssembly.Module(caller), { env: { t: table } })
  .exports.run as (index: number) => number;

const ROUNDS = 5_000_000;
function measure(label: string, body: (rounds: number) => number): number {
  body(200_000); // échauffement : JavaScriptCore compile par paliers
  const began = process.hrtime.bigint();
  body(ROUNDS);
  const ns = Number(process.hrtime.bigint() - began) / ROUNDS;
  console.log(`${label.padEnd(56)} ${ns.toFixed(1)} ns`);
  return ns;
}

console.log(`${LINKS} modules appelés, un module appelant, une table partagée`);
const inside = measure("call_indirect vers 64 autres modules, en rotation", rounds => {
  let sum = 0, at = 0;
  for (let round = 0; round < rounds; round++) { sum += run(at); at = (at + 1) & (LINKS - 1); }
  return sum;
});
const outside = measure("les mêmes 64, appelés depuis JavaScript", rounds => {
  let sum = 0, at = 0;
  for (let round = 0; round < rounds; round++) { sum += direct[at](); at = (at + 1) & (LINKS - 1); }
  return sum;
});
measure("depuis JavaScript, un seul, en boucle (le cas facile)", rounds => {
  let sum = 0;
  for (let round = 0; round < rounds; round++) sum += direct[0]();
  return sum;
});

console.log();
console.log(`Rester dans WebAssembly coûte ×${(outside / inside).toFixed(0)} moins cher.`);
console.log(
  "Ce que ça dit du bureau : la répartition entre régions peut redevenir interne,",
);
console.log(
  "et les 192 ns du retour de main ne seraient plus payés qu'aux cibles jamais traduites.",
);
console.log(
  "Reste la question de l'indice : une région ne connaît pas celui d'une adresse qu'elle",
);
console.log("n'a pas compilée. C'est la seconde moitié, mesurée juste en dessous.");

// ---------------------------------------------------------------------------
// **La seconde moitié : retrouver l'indice d'une adresse.**
//
// `call_indirect` demande un indice, et une région ne connaît pas celui d'une
// adresse qu'elle n'a pas compilée. Il faut donc une correspondance
// adresse → indice que le module lit lui-même, dans la mémoire invitée, sans
// repasser par l'hôte — sinon on retombe sur les 192 ns qu'on cherche à éviter.
//
// Le module de sonde fait le cas le plus simple : une table à correspondance
// directe, sans sondage.
//
//     place = tronqué(((adresse × K) & (EMPLACEMENTS-1)) × 16)
//     mem[place] == adresse ? mem[place+8] : -1
//
// **Vérifiée avant d'être chronométrée**, et ce n'est pas une formalité : la
// première version de cette sonde rendait zéro pour tout, et son chiffre — 5,6
// ns — ne mesurait qu'une recherche qui ne cherchait rien.

const SLOTS = 8192n;
const KNUTH = 0x9e3779b1n;
const PAGES = 32;

function signed(value: bigint): number[] {
  const out: number[] = [];
  let more = true;
  while (more) {
    let byte = Number(value & 0x7fn);
    value >>= 7n;
    if ((value === 0n && (byte & 0x40) === 0) || (value === -1n && (byte & 0x40) !== 0)) {
      more = false;
    } else {
      byte |= 0x80;
    }
    out.push(byte);
  }
  return out;
}

const lookup = Uint8Array.from([
  ...HEADER,
  ...section(1, vector([[0x60, 0x01, 0x7e, 0x01, 0x7f]])),
  ...section(2, vector([[...name("env"), ...name("mem"), 0x02, 0x00, ...uleb(PAGES)]])),
  ...section(3, vector([[0x00]])),
  ...section(7, vector([[...name("run"), 0x00, 0x00]])),
  ...section(10, vector([codeEntry([
    0x01, 0x01, 0x7f,                          // une locale i32 : l'emplacement
    0x20, 0x00, 0x42, ...signed(KNUTH), 0x7e,  // adresse × K
    0x42, ...signed(SLOTS - 1n), 0x83,         // & (EMPLACEMENTS-1)
    0x42, 0x10, 0x7e,                          // × 16
    0xa7, 0x21, 0x01,                          // tronqué → place
    0x20, 0x01, 0x29, 0x03, 0x08,              // la valeur, mem[place+8]
    0x42, 0x7f,                                // -1
    0x20, 0x01, 0x29, 0x03, 0x00,              // la clé, mem[place]
    0x20, 0x00, 0x51,                          // clé == adresse ?
    0x1b,                                      // select
    0xa7, 0x0b,
  ])])),
]);

const memory = new WebAssembly.Memory({ initial: PAGES });
const find = new WebAssembly.Instance(new WebAssembly.Module(lookup), { env: { mem: memory } })
  .exports.run as (address: bigint) => number;

const cells = new BigUint64Array(memory.buffer);
const GUEST = 0x30000000n;
const placed: bigint[] = [];
const taken = new Set<number>();
for (let step = 0; placed.length < 4096 && step < 4096 * 4; step++) {
  const address = GUEST + BigInt(step) * 16n;
  const at = Number(((address * KNUTH) & (SLOTS - 1n)) * 16n);
  if (taken.has(at)) continue; // pas de sondage : on ne garde que les libres
  taken.add(at);
  cells[at / 8] = address;
  cells[at / 8 + 1] = BigInt(placed.length);
  placed.push(address);
}
let missed = 0;
for (let index = 0; index < placed.length; index++) {
  if (find(placed[index]) !== index) missed++;
}
const absent = find(GUEST + 7n);
console.log();
console.log(`${placed.length} adresses posées, ${missed} mal retrouvées, une absente rend ${absent}`);
if (missed !== 0 || absent !== -1) {
  console.log("La sonde est fausse : rien à chronométrer, et surtout rien à conclure.");
  process.exit(1);
}
const found = measure("adresse → indice, lue par le module", rounds => {
  let sum = 0, at = 0;
  for (let round = 0; round < rounds; round++) {
    sum += find(placed[at]);
    at = at + 1 < placed.length ? at + 1 : 0;
  }
  return sum;
});

console.log();
console.log(
  `La recherche coûte ${found.toFixed(1)} ns **vue depuis JavaScript**, dont environ trois pour`,
);
console.log(
  "l'appel lui-même (la ligne « un seul, en boucle » ci-dessus). Dans la vraie forme elle",
);
console.log("vivrait dans le module, sans appel du tout : deux chargements et un produit.");
console.log();
console.log(
  `**Et la sonde a trouvé autre chose** : sur 16384 adresses espacées de seize octets, seules`,
);
console.log(
  `${placed.length} ont trouvé un emplacement libre. Un produit de Knuth garde les bits bas, et les`,
);
console.log(
  "bits bas d'une adresse alignée ne portent rien. La fonction de hachage devra les mélanger",
);
console.log("— un décalage avant le produit — sinon la table se remplit d'un côté.");

// ---------------------------------------------------------------------------
// **Où la correspondance peut vivre — et la prémisse qu'il a fallu jeter.**
//
// La feuille de route disait : « une petite table de hachage dans la mémoire
// invitée, tenue par l'hôte ». C'est faux, et pour une raison que ce dépôt a
// déjà apprise une fois. L'en-tête de l'émetteur la garde écrite :
//
//     la mémoire linéaire **est** la RAM de l'invité, adresse pour adresse, et
//     un noyau qui écrit à l'adresse 8 écrasait alors RCX. Les registres sont
//     donc sortis de là.
//
// Une table de correspondance posée dans cette mémoire est exactement le même
// défaut : un noyau qui écrit à la mauvaise adresse la détruit, et le module
// saute alors n'importe où. Il lui faut un endroit que l'invité ne peut pas
// adresser.
//
// D'où cette troisième sonde : **JavaScriptCore accepte-t-il deux mémoires
// importées ?** Si oui, la correspondance vit dans la seconde, hors de portée.

const guest = new WebAssembly.Memory({ initial: 1 });
const side = new WebAssembly.Memory({ initial: 1 });
new Uint32Array(side.buffer)[0] = 0xc0ffee;
new Uint32Array(guest.buffer)[0] = 0xdead;

// run() -> i32 : charge l'entier de la **seconde** mémoire.
//
// L'ordre du champ mémoire compte, et une erreur y est silencieuse : après
// l'octet d'alignement marqué du bit 6 vient **l'indice de mémoire**, puis le
// décalage. Ma première version les avait intervertis, et la sonde a rendu
// 0xde — la première mémoire lue au décalage un, une valeur assez plausible
// pour être crue.
const twoMemories = Uint8Array.from([
  ...HEADER,
  ...section(1, vector([[0x60, 0x00, 0x01, 0x7f]])),
  ...section(2, vector([
    [...name("env"), ...name("guest"), 0x02, 0x00, ...uleb(1)],
    [...name("env"), ...name("side"), 0x02, 0x00, ...uleb(1)],
  ])),
  ...section(3, vector([[0x00]])),
  ...section(7, vector([[...name("run"), 0x00, 0x00]])),
  ...section(10, vector([codeEntry([
    0x00, 0x41, 0x00, 0x28, 0x42, 0x01, 0x00, 0x0b,
  ])])),
]);

console.log();
try {
  const instance = new WebAssembly.Instance(new WebAssembly.Module(twoMemories), {
    env: { guest, side },
  });
  const got = (instance.exports.run as () => number)() >>> 0;
  if (got === 0xc0ffee) {
    console.log("Deux mémoires importées : acceptées, et la seconde est bien lue.");
    console.log(
      "La correspondance adresse → indice peut donc vivre hors de portée de l'invité.",
    );
  } else {
    console.log(`Deux mémoires acceptées, mais la lecture rend 0x${got.toString(16)} :`);
    console.log("l'encodage est faux, et le chiffre ne veut rien dire.");
  }
} catch (why) {
  console.log("Deux mémoires importées : refusées —", (why as Error).message.slice(0, 160));
  console.log("Il faudra un autre endroit pour la correspondance.");
}
console.log();
console.log(
  "**Réserve, et elle est la même que pour tout le lot 8** : ceci mesure le JavaScriptCore",
);
console.log(
  "qu'embarque Bun, sur Linux. Que le WKWebView d'un vrai iPhone accepte la multi-mémoire",
);
console.log("n'est pas établi ici — la sonde de l'application est le seul endroit qui le dira.");
