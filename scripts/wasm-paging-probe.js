// **Ce que coûterait une vraie pagination, mesuré plutôt que supposé.**
//
// `docs/DEMARRAGE.md` pose la question avant la décision : l'émetteur replie
// aujourd'hui les adresses par un `et`, et une vraie pagination consulterait un
// tampon de traduction puis marcherait quatre niveaux. Ce fichier chronomètre
// les trois formes dans le même module, sous le moteur qui les exécutera.
//
//     cargo run -p wisq-vm --release --example paging-probe -- /tmp/paging.wasm
//     bun scripts/wasm-paging-probe.js /tmp/paging.wasm [accès]
//
// **Le juge : JavaScriptCore, le moteur exact de WKWebView.**
//
// Les tables sont construites pour que la marche rende EXACTEMENT l'adresse que
// le repli rend. Les trois sommes de contrôle doivent donc être égales — sans
// cette égalité, une forme qui ne ferait rien rendrait un débit magnifique et
// faux, et c'est le piège que ce dépôt s'est déjà fait prendre une fois.
const fs = require("fs");
const PAGES = 4096;
const FOLD_MASK = 0x07ffffff;         // 128 Mio
const VPN_MASK = FOLD_MASK >>> 12;    // 32767 pages
const PML4 = 0x09000000;
const PDPT = PML4 + 4096;
const PD = PML4 + 8192;
const PT0 = PML4 + 12288;
const TLB = 0x0a000000;

const bytes = fs.readFileSync(process.argv[2]);
const memory = new WebAssembly.Memory({ initial: PAGES, maximum: PAGES });
const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), {});
const mem = new DataView(memory.buffer);
// La mémoire est celle du module, pas la mienne : on la reprend par l'export.
const guest = instance.exports.mem;
const view = new DataView(guest.buffer);
const u64 = new BigUint64Array(guest.buffer);

// ---- les tables ----
// vpn < 2^15, donc vpn>>27 et vpn>>18 valent zéro : un seul PML4, un seul PDPT.
view.setBigUint64(PML4 + 0, BigInt(PDPT), true);
view.setBigUint64(PDPT + 0, BigInt(PD), true);
const PT_COUNT = 64;                  // couvre 64*512 = 32768 pages
for (let k = 0; k < PT_COUNT; k++) {
  const table = PT0 + k * 4096;
  view.setBigUint64(PD + k * 8, BigInt(table), true);
  for (let j = 0; j < 512; j++) {
    const vpn = k * 512 + j;
    view.setBigUint64(table + j * 8, BigInt(((vpn & VPN_MASK) * 4096) >>> 0), true);
  }
}
// Le tampon commence vide, et son étiquette zéro désignerait la page zéro :
// on l'empoisonne pour qu'aucune entrée ne passe pour valide au premier tour.
for (let s = 0; s < 64; s++) view.setBigUint64(TLB + s * 16, 0xffffffffn, true);

// ---- des données à lire ----
// Sans motif, tout vaudrait zéro et l'égalité des sommes ne prouverait rien.
const fillWords = (FOLD_MASK + 1) / 8;
let x = 0x9e3779b97f4a7c15n;
for (let w = 0; w < fillWords; w++) {
  x = (x * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn;
  u64[w] = x;
}

function time(name, count, stride, wsMask) {
  const f = instance.exports[name];
  // **L'échauffement parcourt tout l'ensemble de travail**, pas quelques
  // milliers d'accès : sinon la première forme mesurée paie seule le
  // refroidissement des caches du vrai processeur, et le classement dit
  // l'ordre d'exécution plutôt que le code.
  f(count, stride, wsMask);
  let best = Infinity;
  let sum = null;
  for (let round = 0; round < 5; round++) {
    const started = process.hrtime.bigint();
    const got = f(count, stride, wsMask);
    const seconds = Number(process.hrtime.bigint() - started) / 1e9;
    if (seconds < best) best = seconds;
    sum = got.toString();
  }
  // **Le minimum, pas la moyenne.** On cherche ce que le code coûte, et le
  // bruit d'un ordonnanceur ne fait qu'ajouter — jamais retrancher.
  return { seconds: best, sum, ns: (best * 1e9) / count };
}

const cases = [
  { titre: "balayage court — 512 pages, pas de 64 octets", stride: 64, wsMask: 2 * 1024 * 1024 - 1 },
  { titre: "balayage long — 16 384 pages, pas de 64 octets", stride: 64, wsMask: 64 * 1024 * 1024 - 1 },
  { titre: "une page neuve à chaque accès — 16 384 pages", stride: 4096 + 64, wsMask: 64 * 1024 * 1024 - 1 },
];
const count = Number(process.argv[3] || 20000000);

console.log(`${count} accès par mesure, tampon de 64 entrées, mémoire de ${PAGES / 16} Mio\n`);
for (const c of cases) {
  const repli = time("repli", count, c.stride, c.wsMask);
  const tampon = time("tampon", count, c.stride, c.wsMask);
  const marche = time("marche", count, c.stride, c.wsMask);
  const accord = repli.sum === tampon.sum && repli.sum === marche.sum;
  console.log(c.titre);
  if (!accord) {
    console.log(`  LES SOMMES DIFFÈRENT — la mesure ne veut rien dire.`);
    console.log(`  repli=${repli.sum} tampon=${tampon.sum} marche=${marche.sum}\n`);
    continue;
  }
  console.log(`  repli (aujourd'hui) : ${repli.ns.toFixed(2)} ns/accès`);
  console.log(`  tampon + marche     : ${tampon.ns.toFixed(2)} ns/accès  (×${(tampon.seconds / repli.seconds).toFixed(2)})`);
  console.log(`  marche seule        : ${marche.ns.toFixed(2)} ns/accès  (×${(marche.seconds / repli.seconds).toFixed(2)})`);
  console.log(`  surcoût du tampon   : +${(tampon.ns - repli.ns).toFixed(2)} ns par accès\n`);
}
