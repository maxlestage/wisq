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
  "Ce que ça ne dit pas : comment une région retrouve l'indice d'une adresse qu'elle",
);
console.log(
  "n'a pas compilée. C'est le vrai travail, et il n'est pas fait.",
);
