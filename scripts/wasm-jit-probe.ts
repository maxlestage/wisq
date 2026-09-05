// Le plafond de vitesse d'un cœur qui se recompile, sans JIT à nous.
//
// **Le fait de départ.** iOS n'autorise aucune page à la fois inscriptible et
// exécutable pour une application de l'App Store : pas de JIT, donc un
// interpréteur, donc 10,6 MIPS mesurés pour le cœur x86 de wisq. Un bureau
// complet, à ce rythme, demande plus d'une heure de démarrage.
//
// **Le contournement.** WebKit, lui, a le droit de compiler : c'est la seule
// exception d'iOS, et une application peut héberger un WKWebView. Du
// WebAssembly engendré à l'exécution y est compilé en code natif par
// JavaScriptCore. L'émulateur ne génère alors pas de code machine — ce qui lui
// est interdit — il génère du WebAssembly, qui est une donnée, et c'est WebKit
// qui le compile.
//
// **Ce que ce programme mesure.** Le plafond de cette idée, et rien d'autre :
// la boucle du banc x86 de wisq, recompilée à la main en WebAssembly, exécutée
// par le même moteur que WKWebView — Bun embarque JavaScriptCore. Un vrai
// recompilateur paierait en plus la répartition entre blocs, la traduction
// d'adresses et les drapeaux complets ; ce chiffre-ci est donc une borne
// supérieure, à comparer aux 10,6 MIPS de l'interpréteur.
//
//     bun scripts/wasm-jit-probe.ts

const SECTION = { type: 1, func: 3, memory: 5, export: 7, code: 10 } as const;

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

function sleb(value: bigint): number[] {
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

function section(id: number, body: number[]): number[] {
  return [id, ...uleb(body.length), ...body];
}

function vector(items: number[][]): number[] {
  return [...uleb(items.length), ...items.flat()];
}

// Les registres invités deviennent des variables locales : c'est exactement ce
// qu'un recompilateur fait, et c'est là que tout le gain se trouve — le
// registre invité vit dans un registre hôte au lieu d'un tableau.
const RAX = 1, RCX = 2, RDX = 3, RSI = 4, COUNT = 5;
const get = (n: number) => [0x20, ...uleb(n)];
const set = (n: number) => [0x21, ...uleb(n)];
const i64 = (v: bigint) => [0x42, ...sleb(v)];

const body: number[] = [
  // rcx = n (le nombre de tours), rsi = 256 (là où la boucle lit et écrit)
  ...get(0), ...set(RCX),
  ...i64(256n), ...set(RSI),
  0x03, 0x40,                                   // loop
    ...get(RAX), ...get(RCX), 0x7c, ...set(RAX),        // addq %rcx, %rax
    ...get(RAX), ...get(RSI), 0xa7, 0x29, 0x03, 0x00,   // xorq (%rsi), %rax
      0x85, ...set(RAX),
    ...get(RSI), 0xa7, ...get(RAX), 0x37, 0x03, 0x08,   // movq %rax, 8(%rsi)
    ...get(RAX), ...get(RDX), 0x52,                     // cmpq %rdx,%rax ; jne
    0x04, 0x40,                                          // if (rax != rdx)
      ...get(RDX), ...i64(1n), 0x7c, ...set(RDX),        //   incq %rdx
    0x0b,
    ...get(RCX), ...i64(1n), 0x7d, ...set(RCX),          // decq %rcx
    ...get(COUNT), ...i64(8n), 0x7c, ...set(COUNT),      // huit instructions de plus
    ...get(RCX), ...i64(0n), 0x52, 0x0d, 0x00,           // jnz boucle
  0x0b,                                          // end loop
  ...get(COUNT),
  0x0b,                                          // end function
];

const locals = [0x01, 0x05, 0x7e]; // cinq locales i64
const code = [...uleb(locals.length + body.length), ...locals, ...body];

const module = Uint8Array.from([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  ...section(SECTION.type, vector([[0x60, 0x01, 0x7e, 0x01, 0x7e]])),
  ...section(SECTION.func, vector([[0x00]])),
  ...section(SECTION.memory, vector([[0x00, 0x01]])),
  ...section(SECTION.export, vector([
    [0x03, 0x72, 0x75, 0x6e, 0x00, 0x00],
    [0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00],
  ])),
  ...section(SECTION.code, vector([code])),
]);

const compileStart = performance.now();
const instance = new WebAssembly.Instance(new WebAssembly.Module(module));
const compileMs = performance.now() - compileStart;
const run = instance.exports.run as (n: bigint) => bigint;

// Un tour à blanc : JavaScriptCore compile par paliers, et le premier appel
// paie l'interpréteur puis les compilateurs. Un émulateur qui tourne des
// minutes vit dans le palier final ; c'est celui-là qu'on mesure.
run(1_000_000n);

const rounds = 40_000_000n;
const start = performance.now();
const executed = run(rounds);
const seconds = (performance.now() - start) / 1000;
const mips = Number(executed) / seconds / 1_000_000;

console.log("");
console.log("Le plafond d'un cœur recompilé en WebAssembly, sous JavaScriptCore");
console.log(`  moteur        : ${typeof Bun !== "undefined" ? Bun.version + " (JavaScriptCore)" : "inconnu"}`);
console.log(`  compilation   : ${compileMs.toFixed(2)} ms pour ${module.length} octets de module`);
console.log(`  instructions  : ${(Number(executed) / 1_000_000).toFixed(1)} M`);
console.log(`  durée         : ${seconds.toFixed(3)} s`);
console.log(`  débit         : ${mips.toFixed(1)} MIPS`);
console.log(`  interpréteur  : 10,6 MIPS mesurés (cœur x86 en Swift)`);
console.log(`  rapport       : ×${(mips / 10.6).toFixed(0)}`);

// ---------------------------------------------------------------------------
// La même chose, mais en payant ce qu'un vrai recompilateur paie
//
// Le chiffre ci-dessus est un plafond, et il ment par optimisme : les registres
// invités y vivent dans des locales que JavaScriptCore garde en registres, les
// drapeaux se réduisent à ce dont les deux sauts ont besoin, et il n'y a
// aucune répartition entre blocs. Un vrai cœur recompilé paie les trois :
//
//   - les registres sont **en mémoire**, parce qu'un bloc peut être quitté par
//     n'importe quel bord et que le suivant doit les retrouver ;
//   - les drapeaux sont **calculés** — report, débordement, zéro, signe — à
//     chaque opération arithmétique, parce qu'on ne sait pas qui les lira ;
//   - chaque bloc revient à une boucle de répartition qui appelle le suivant
//     **indirectement**, par une table, parce que la cible n'est connue qu'à
//     l'exécution.
//
// Cette seconde mesure les inclut. C'est la borne honnête.

const REG = { rax: 0, rcx: 8, rdx: 16, rsi: 24 } as const;
const FLAG = { zf: 128, cf: 136, of: 144, sf: 152 } as const;
const GUEST = 4096;

const load = (offset: number) => [...i64c(offset), 0xa7, 0x29, 0x03, 0x00];
const store = (offset: number, value: number[]) => [...i64c(offset), 0xa7, ...value, 0x37, 0x03, 0x00];
function i64c(v: number | bigint): number[] { return [0x42, ...sleb(BigInt(v))]; }
const tee = (n: number) => [0x22, ...uleb(n)];

// Locales du bloc : rax, rcx, rdx, rsi, tmp, valeur lue
const L = { rax: 0, rcx: 1, rdx: 2, rsi: 3, tmp: 4, mem: 5 } as const;
const g = (n: number) => [0x20, ...uleb(n)];
const s = (n: number) => [0x21, ...uleb(n)];

/// Les quatre drapeaux d'une addition, écrits en mémoire comme le ferait un
/// cœur qui ne sait pas encore qui les lira.
function addFlags(a: number, b: number, result: number): number[] {
  return [
    ...store(FLAG.zf, [...g(result), 0x50, 0xad]),                    // ZF = result == 0
    ...store(FLAG.sf, [...g(result), ...i64c(63), 0x88]),             // SF = result >> 63
    ...store(FLAG.cf, [...g(result), ...g(a), 0x54, 0xad]),           // CF = result <u a
    ...store(FLAG.of, [...g(a), ...g(result), 0x85,                   // OF = ((a^r)&(b^r))>>63
                       ...g(b), ...g(result), 0x85, 0x83,
                       ...i64c(63), 0x88]),
  ];
}

function logicFlags(result: number): number[] {
  return [
    ...store(FLAG.zf, [...g(result), 0x50, 0xad]),
    ...store(FLAG.sf, [...g(result), ...i64c(63), 0x88]),
    ...store(FLAG.cf, i64c(0)),
    ...store(FLAG.of, i64c(0)),
  ];
}

const blockBody: number[] = [
  // Les registres reviennent de la mémoire : c'est l'entrée du bloc.
  ...load(REG.rax), ...s(L.rax),
  ...load(REG.rcx), ...s(L.rcx),
  ...load(REG.rdx), ...s(L.rdx),
  ...load(REG.rsi), ...s(L.rsi),

  // addq %rcx, %rax
  ...g(L.rax), ...g(L.rcx), 0x7c, ...s(L.tmp),
  ...addFlags(L.rax, L.rcx, L.tmp),
  ...g(L.tmp), ...s(L.rax),

  // xorq (%rsi), %rax — l'adresse passe par un masque, ce que fait la
  // traduction d'adresse la moins chère qu'un cœur puisse avoir.
  ...g(L.rsi), ...i64c(0xffff), 0x83, ...i64c(GUEST), 0x7c, 0xa7,
  0x29, 0x03, 0x00, ...s(L.mem),
  ...g(L.rax), ...g(L.mem), 0x85, ...s(L.tmp),
  ...logicFlags(L.tmp),
  ...g(L.tmp), ...s(L.rax),

  // movq %rax, 8(%rsi)
  ...g(L.rsi), ...i64c(0xffff), 0x83, ...i64c(GUEST + 8), 0x7c, 0xa7,
  ...g(L.rax), 0x37, 0x03, 0x00,

  // cmpq %rdx, %rax
  ...g(L.rax), ...g(L.rdx), 0x7d, ...s(L.tmp),
  ...addFlags(L.rax, L.rdx, L.tmp),

  // jne suite — le saut lit le drapeau en mémoire, comme le ferait le bloc
  // suivant s'il était ailleurs.
  ...load(FLAG.zf), 0x50, 0x45,
  0x04, 0x40,
    ...g(L.rdx), ...i64c(1), 0x7c, ...s(L.tmp),
    ...addFlags(L.rdx, L.rdx, L.tmp),
    ...g(L.tmp), ...s(L.rdx),
  0x0b,

  // decq %rcx
  ...g(L.rcx), ...i64c(1), 0x7d, ...s(L.tmp),
  ...addFlags(L.rcx, L.rcx, L.tmp),
  ...g(L.tmp), ...s(L.rcx),

  // Les registres repartent en mémoire : c'est la sortie du bloc.
  ...store(REG.rax, g(L.rax)),
  ...store(REG.rcx, g(L.rcx)),
  ...store(REG.rdx, g(L.rdx)),
  ...store(REG.rsi, g(L.rsi)),

  // jnz boucle : le bloc rend l'indice du suivant — zéro, lui-même, ou un,
  // la sortie. C'est la répartition, et elle est indirecte. `jnz` reboucle
  // tant que le drapeau zéro est **éteint**, donc la condition est `zf == 0`.
  ...load(FLAG.zf), 0x50,
  0x04, 0x7f,
    0x41, 0x00,
  0x05,
    0x41, 0x01,
  0x0b,
  0x0b,
];

const exitBody: number[] = [0x41, 0x01, 0x0b];

// La boucle de répartition : tant qu'il reste du budget, appeler le bloc
// courant par la table et prendre ce qu'il rend.
const driveBody: number[] = [
  0x41, 0x00, 0x21, 0x01,                          // next = 0
  0x03, 0x40,                                       // loop
    ...g(1), 0x11, 0x01, 0x00,                      // next = call_indirect(next)
    0x21, 0x01,
    ...g(0), ...i64c(8), 0x7d, ...s(0),             // budget -= 8
    ...g(1), 0x45,                                  // next == 0 ?
    ...g(0), ...i64c(0), 0x56, 0x71,                // et budget > 0 ?
    0x0d, 0x00,
  0x0b,
  ...g(0), 0x0b,
];

function codeEntry(localDecls: number[], body: number[]): number[] {
  const inner = [...localDecls, ...body];
  return [...uleb(inner.length), ...inner];
}

const realistic = Uint8Array.from([
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
  ...section(SECTION.type, vector([
    [0x60, 0x01, 0x7e, 0x01, 0x7e],   // 0 : (i64) -> i64, la boucle
    [0x60, 0x00, 0x01, 0x7f],         // 1 : () -> i32, un bloc
  ])),
  ...section(SECTION.func, vector([[0x01], [0x01], [0x00]])),
  ...section(4, vector([[0x70, 0x00, 0x02]])),   // table de deux entrées
  ...section(SECTION.memory, vector([[0x00, 0x02]])),
  ...section(SECTION.export, vector([
    [0x05, 0x64, 0x72, 0x69, 0x76, 0x65, 0x00, 0x02],
    [0x03, 0x6d, 0x65, 0x6d, 0x02, 0x00],
  ])),
  ...section(9, vector([[0x00, 0x41, 0x00, 0x0b, 0x02, 0x00, 0x01]])),
  ...section(SECTION.code, vector([
    codeEntry([0x01, 0x06, 0x7e], blockBody),
    codeEntry([0x00], exitBody),
    codeEntry([0x01, 0x01, 0x7f], driveBody),
  ])),
]);

const realisticStart = performance.now();
const real = new WebAssembly.Instance(new WebAssembly.Module(realistic));
const realCompileMs = performance.now() - realisticStart;
const drive = real.exports.drive as (budget: bigint) => bigint;
const memory = new BigUint64Array((real.exports.mem as WebAssembly.Memory).buffer);
memory[REG.rcx / 8] = 40_000_000n;
memory[REG.rsi / 8] = 0n;

// **Un chiffre de vitesse sur un bloc faux ne vaut rien.** Le même calcul,
// écrit en clair ici, sert d'oracle : mille tours des deux côtés, puis on
// compare les trois registres qui bougent. Sans ça, une erreur de drapeau
// ferait sortir la boucle plus tôt et rendrait un débit magnifique.
function reference(rounds: bigint): { rax: bigint; rcx: bigint; rdx: bigint } {
  const wrap = (v: bigint) => BigInt.asUintN(64, v);
  let rax = 0n, rdx = 0n, rcx = rounds;
  for (;;) {
    rax = wrap(rax + rcx);
    rax = wrap(rax ^ 0n);          // (%rsi) reste nul : rien n'écrit à 4096
    if (wrap(rax - rdx) === 0n) rdx = wrap(rdx + 1n);
    rcx = wrap(rcx - 1n);
    if (rcx === 0n) break;
  }
  return { rax, rcx, rdx };
}

memory[REG.rax / 8] = 0n;
memory[REG.rdx / 8] = 0n;
memory[REG.rcx / 8] = 1000n;
drive(1_000_000n);
const expected = reference(1000n);
const got = {
  rax: memory[REG.rax / 8],
  rcx: memory[REG.rcx / 8],
  rdx: memory[REG.rdx / 8],
};
if (got.rax !== expected.rax || got.rcx !== expected.rcx || got.rdx !== expected.rdx) {
  console.error("le bloc recompilé ne calcule pas la même chose que le modèle :");
  console.error("  attendu", expected, "obtenu", got);
  process.exit(1);
}
console.log(`  oracle        : mille tours, rax/rcx/rdx identiques au modèle`);

memory[REG.rax / 8] = 0n;
memory[REG.rdx / 8] = 0n;
memory[REG.rcx / 8] = 8_000_000n;
drive(80_000_000n);
memory[REG.rax / 8] = 0n;
memory[REG.rdx / 8] = 0n;
memory[REG.rcx / 8] = 40_000_000n;

const realRun = performance.now();
const left = drive(320_000_000n);
const realSeconds = (performance.now() - realRun) / 1000;
const done = 320_000_000n - left;
const realMips = Number(done) / realSeconds / 1_000_000;

console.log("");
console.log("La même boucle, en payant ce qu'un vrai recompilateur paie");
console.log("  registres en mémoire, quatre drapeaux calculés, répartition indirecte");
console.log(`  compilation   : ${realCompileMs.toFixed(2)} ms pour ${realistic.length} octets`);
console.log(`  instructions  : ${(Number(done) / 1_000_000).toFixed(1)} M`);
console.log(`  durée         : ${realSeconds.toFixed(3)} s`);
console.log(`  débit         : ${realMips.toFixed(1)} MIPS`);
console.log(`  rapport à l'interpréteur : ×${(realMips / 10.6).toFixed(0)}`);

// `--module` écrit le module réaliste en base64 et s'arrête là. C'est ce que
// la sonde `WebKitJITProbeTests` embarque : elle mesure le même module, mais
// dans un `WKWebView`, sur la pile d'Apple, chez le coureur Apple.
if (process.argv.includes("--module")) {
  console.log(Buffer.from(realistic).toString("base64"));
}
