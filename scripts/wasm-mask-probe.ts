// **Enfermer l'invité dans sa RAM coûte-t-il quelque chose ?**
//
// La feuille de route disait que la correspondance adresse → indice devrait
// vivre dans une **seconde mémoire WebAssembly**, hors de portée de l'invité,
// et notait la réserve : rien ne prouve qu'un vrai iPhone accepte la
// multi-mémoire, et seul un envoi TestFlight le dira.
//
// Il y a une autre porte, qui ne demande aucune extension du langage : replier
// chaque adresse invitée par un `et` sur la taille de sa RAM. L'hôte fournit
// alors une mémoire **plus grande** que ce que le module déclare, et le module
// ne peut pas atteindre ce qui vit au-dessus. Un `i32.and` par accès — la
// question est ce qu'il coûte.
//
//     bun scripts/wasm-mask-probe.ts
//
// **La sonde mesure deux formes, et c'est tout l'intérêt** : la réponse n'est
// pas la même, et la mauvaise des deux est celle qu'on mesurerait d'abord.
//
// Cette sonde ne mesure pas wisq : elle mesure le moteur, avec des modules
// écrits à la main. Elle mesure aussi **de combien elle tremble**, sans quoi un
// écart de quelques pour cent ne voudrait rien dire.

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
const codeEntry = (body: number[]) => [...uleb(body.length), ...body];
const HEADER = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

const PAGES = 16;
const MASK = PAGES * 65536 - 1;
const HIGH = 0x80000;
const COUNT = 60000;

/// Le corps commun aux deux formes. `source` empile l'adresse de lecture,
/// `sink` celle de l'écriture ; le reste — la boucle, l'accumulateur, le
/// compteur — est identique, pour que la seule différence chronométrée soit
/// d'où vient l'adresse et si elle est repliée.
function loopBody(source: number[], sink: number[], advance: number[]): number[] {
  return [
    0x02, 0x01, 0x7f, 0x01, 0x7e, // locals : i32 i, i64 acc
    0x02, 0x40, //                   block
    0x03, 0x40, //                     loop
    0x20, 0x01, 0x20, 0x00, 0x4f, 0x0d, 0x01, // i >= count ? sortir
    ...source,
    0x29, 0x03, 0x00, //               i64.load
    0x20, 0x02, 0x7c, 0x21, 0x02, //   acc += …
    ...sink,
    0x20, 0x02,
    0x37, 0x03, 0x00, //               i64.store
    ...advance,
    0x20, 0x01, 0x41, 0x01, 0x6a, 0x21, 0x01, // i += 1
    0x0c, 0x00, 0x0b, 0x0b,
    0x20, 0x02, 0x0b, //               rendre l'accumulateur
  ];
}

const AND = (masked: boolean) => (masked ? [code_i32_const(MASK), 0x71].flat() : []);
function code_i32_const(value: number): number[] {
  return [0x41, ...uleb(value)];
}

/// **Première forme : l'adresse est un compteur.** `i << 3`, ce que le moteur
/// sait réduire à un pointeur qui avance.
function counterModule(masked: boolean): Uint8Array {
  const and = AND(masked);
  const source = [0x20, 0x01, 0x41, 0x03, 0x74, ...and];
  const sink = [0x20, 0x01, 0x41, 0x03, 0x74, ...code_i32_const(HIGH), 0x6a, ...and];
  return module(loopBody(source, sink, []), false);
}

/// **Seconde forme : l'adresse vient d'une globale**, comme dans l'émetteur,
/// où chaque adresse se recalcule depuis un registre invité.
function globalModule(masked: boolean): Uint8Array {
  const and = AND(masked);
  const source = [0x23, 0x00, 0xa7, ...and];
  const sink = [0x23, 0x00, 0xa7, ...code_i32_const(HIGH), 0x6a, ...and];
  const advance = [0x23, 0x00, 0x42, 0x08, 0x7c, 0x24, 0x00]; // g0 += 8
  return module(loopBody(source, sink, advance), true);
}

function module(body: number[], global: boolean): Uint8Array {
  const imports: number[][] = [[...name("env"), ...name("m"), 0x02, 0x00, ...uleb(PAGES)]];
  if (global) imports.push([...name("env"), ...name("g0"), 0x03, 0x7e, 0x01]);
  return Uint8Array.from([
    ...HEADER,
    ...section(1, vector([[0x60, 0x01, 0x7f, 0x01, 0x7e]])),
    ...section(2, vector(imports)),
    ...section(3, vector([[0x00]])),
    ...section(7, vector([[...name("run"), 0x00, 0x00]])),
    ...section(10, vector([codeEntry(body)])),
  ]);
}

function build(bytes: Uint8Array, global: boolean): (n: number) => bigint {
  const memory = new WebAssembly.Memory({ initial: PAGES });
  const words = new BigUint64Array(memory.buffer);
  for (let index = 0; index < words.length; index++) words[index] = BigInt(index);
  const env: Record<string, unknown> = { m: memory };
  const g0 = new WebAssembly.Global({ value: "i64", mutable: true }, 0n);
  if (global) env.g0 = g0;
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { env });
  const run = instance.exports.run as (n: number) => bigint;
  return (n: number) => {
    g0.value = 0n;
    return run(n);
  };
}

function measure(run: (n: number) => bigint): number {
  for (let warm = 0; warm < 20; warm++) run(COUNT);
  let best = Infinity;
  for (let round = 0; round < 12; round++) {
    const started = Bun.nanoseconds();
    let turns = 0;
    while (Bun.nanoseconds() - started < 50e6) {
      run(COUNT);
      turns++;
    }
    const ns = (Bun.nanoseconds() - started) / (turns * COUNT);
    if (ns < best) best = ns;
  }
  return best;
}

/// **Vérifier avant de chronométrer.** Le premier jet écrivait juste au-dessus
/// de ce qu'il venait de lire : chaque tour effaçait la valeur du tour suivant,
/// l'accumulateur restait à zéro, et les deux formes « s'accordaient » sans
/// avoir rien lu. Un chiffre tiré de là n'aurait mesuré aucune lecture.
const expected = (BigInt(COUNT) * BigInt(COUNT - 1)) / 2n;
function judge(label: string, make: (masked: boolean) => Uint8Array, global: boolean) {
  const plain = build(make(false), global);
  const guarded = build(make(true), global);
  const a = plain(COUNT);
  const b = guarded(COUNT);
  if (a !== expected || b !== expected) {
    console.log(`${label} : la sonde est fausse (${a} et ${b} au lieu de ${expected}).`);
    process.exit(1);
  }
  // **Trois constructions de chaque, et l'étendue des deux groupes.** Un seul
  // couple ne suffisait pas : le premier jet a rendu +0,6 % puis −2,7 % pour la
  // même question, alors qu'il annonçait trembler de 0,1 %. Ce qu'il mesurait
  // vraiment, c'est le bruit *à l'intérieur* d'une construction ; le bruit
  // *entre* deux constructions est plus grand, et c'est celui-là qui compte.
  // Quand les deux étendues se chevauchent, il n'y a pas d'écart à annoncer.
  const spread = (masked: boolean) => {
    const runs = [0, 1, 2].map(() => measure(build(make(masked), global)));
    return { low: Math.min(...runs), high: Math.max(...runs) };
  };
  const free = spread(false);
  const held = spread(true);
  const overlap = free.low <= held.high && held.low <= free.high;
  console.log();
  console.log(`**${label}**`);
  console.log(`  sans masque : ${free.low.toFixed(3)} à ${free.high.toFixed(3)} ns par accès`);
  console.log(`  avec masque : ${held.low.toFixed(3)} à ${held.high.toFixed(3)} ns par accès`);
  if (overlap) {
    console.log("  les deux étendues se chevauchent : **aucun écart mesurable**.");
  } else {
    const gap = ((held.low - free.high) / free.high) * 100;
    console.log(`  écart net : **${gap > 0 ? "+" : ""}${gap.toFixed(0)} %**, sans chevauchement.`);
  }
}

console.log("Le masque d'adresse, mesuré sous JavaScriptCore.");
judge("l'adresse est un compteur", counterModule, false);
judge("l'adresse vient d'une globale", globalModule, true);
console.log();
console.log("**Les deux formes ne répondent pas la même chose, et c'est la conclusion.**");
console.log("Quand l'adresse est un compteur, le moteur la réduit à un pointeur qui avance ;");
console.log("le masque l'en empêche, et ça se paie. Quand elle vient d'une globale, il n'y a");
console.log("rien à réduire, et le masque devient **légèrement plus rapide** que son absence.");
console.log();
console.log("Cette inversion a une explication, offerte et non prouvée — je n'ai pas lu le code");
console.log("machine engendré. Un `et` sur 0xFFFFF prouve au moteur que l'adresse tient dans le");
console.log("minimum déclaré de la mémoire ; il peut alors retirer *sa* vérification de borne.");
console.log("Le masque ne s'ajoute pas au contrôle, il le remplace.");
console.log();
console.log("**L'émetteur ne produit jamais la première forme.** Une adresse invitée se");
console.log("recalcule depuis un registre — une globale — à chaque instruction, y compris");
console.log("dans la boucle du `rep`. C'est la seconde ligne qui le concerne.");
console.log();
console.log("Réserve, la même que pour tout le lot 8 : ceci mesure le JavaScriptCore qu'embarque");
console.log("Bun, sur Linux. Ce qui change par rapport à la multi-mémoire, c'est qu'un `i32.and`");
console.log("n'est pas une extension : aucun moteur ne peut le refuser.");
