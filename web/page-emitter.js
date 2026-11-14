// L'émetteur dans la page.
//
// **Ce que ce fichier remplace.** Une région inconnue se traduisait par un
// aller-retour : la page lisait la fenêtre, l'envoyait à Swift, Swift appelait
// l'émetteur Rust par le C ABI, puis renvoyait le module sous forme de source
// JavaScript. 5,35 à 8,68 ms par région relevés en CI, presque tout en
// transport. Sous Bun, `examples/kernel-entry.rs` payait l'équivalent : un
// processus `x86-translate` lancé par région.
//
// **Ce qu'il fait à la place.** Le même émetteur, compilé lui-même en
// WebAssembly (`crates/wisq-page`, construit par
// `scripts/build-page-emitter.sh`), est instancié une fois dans la page. Une
// traduction devient un appel dans le même fil : copier la fenêtre, appeler
// `emettre`, relire le module. Aucune ligne de l'émetteur n'est recopiée ici ;
// ce fichier ne fait que passer des octets.
//
// **Ce qu'il rend est jugé, octet pour octet**, contre
// `Module::resolving_or_why` en natif : `crates/wisq-page/tests/page.rs`.
//
// **Et il se branche sans toucher la boucle hôte.** `traducteur(pages)` rend
// exactement la fonction que `machine({ translate })` de `web/host.js` attend :
// `(adresse, emplacement, fenêtre)` → les octets d'un module, `"encore"` quand
// la première instruction a pu être coupée par le bord, ou `null` pour un
// refus franc.

/// Les codes que rend `emettre` quand il ne rend pas de module. Les mêmes
/// nombres que `ENCORE`, `REFUS` et `MAL_FORME` de `crates/wisq-page` ; un test
/// natif les compare (`page.rs`).
export const CODES = Object.freeze({ encore: -1, refus: -2, malForme: -3 });

/// **Instancier l'émetteur.** `source` est le module de `wisq_page.wasm`, déjà
/// compilé (`WebAssembly.Module`) ou en octets. Synchrone, comme la boucle :
/// l'appelant qui veut compiler hors du fil le fait avant, avec
/// `WebAssembly.compile`, et passe le module.
export function emetteur(source) {
  const module = source instanceof WebAssembly.Module ? source : new WebAssembly.Module(source);
  // **Aucun import.** L'émetteur est du calcul pur sur ses deux tampons : il
  // ne lit ni l'heure, ni un fichier, ni la mémoire de l'invité.
  const { exports } = new WebAssembly.Instance(module, {});
  const { memory, allouer, emettre, dernier, taille } = exports;
  const texte = new TextDecoder();
  // **La raison du dernier refus**, gardée pour qui veut la journaliser. La
  // boucle hôte ne la demande pas : elle ne distingue que les trois réponses.
  let pourquoi = null;

  /// **Les octets du dernier résultat, copiés.** Pas une vue : la mémoire de
  /// l'émetteur grandit d'une région à l'autre, et une vue sur l'ancien
  /// `buffer` se détacherait sous le pied de qui la garde.
  const lire = () => new Uint8Array(memory.buffer, dernier(), taille()).slice();

  /// **Traduire une fenêtre**, comme `Module::resolving_or_why(fenêtre,
  /// base, entree, emplacement, pages)`. Rend `{ module }`, `{ encore }` ou
  /// `{ refus }` — les deux derniers portant la raison, en texte, sous la
  /// forme `{:?}` de `Refused`.
  function resoudre(fenetre, base, emplacement, pages, entree = 0) {
    // **L'adresse est relue avant chaque copie** : `allouer` peut déplacer
    // le tampon, et la mémoire a pu grandir depuis l'appel précédent.
    const place = allouer(fenetre.length);
    new Uint8Array(memory.buffer, place, fenetre.length).set(fenetre);
    // Un `i64` côté module : un `BigInt` de ce côté-ci, ramené sur 64 bits
    // pour qu'une adresse du noyau (au-dessus de 2⁶³) passe telle quelle.
    const code = emettre(fenetre.length, BigInt.asUintN(64, BigInt(base)), entree, emplacement, pages);
    if (code >= 0) return { module: lire() };
    const raison = texte.decode(lire());
    if (code === CODES.encore) return { encore: raison };
    return { refus: raison };
  }

  /// **La fonction `translate` de `machine()`**, pour une RAM de `pages`
  /// pages de 64 Kio. `surRefus`, s'il est donné, reçoit l'adresse et la
  /// raison de chaque refus franc : c'est ce qu'un pilote imprime.
  function traducteur(pages, surRefus = null) {
    return (adresse, emplacement, fenetre) => {
      const rendu = resoudre(fenetre, adresse, emplacement, pages);
      if (rendu.module !== undefined) {
        pourquoi = null;
        return rendu.module;
      }
      if (rendu.encore !== undefined) {
        pourquoi = rendu.encore;
        return "encore";
      }
      pourquoi = rendu.refus;
      if (surRefus !== null) surRefus(adresse, rendu.refus);
      return null;
    };
  }

  return {
    resoudre,
    traducteur,
    /// La raison du dernier refus vu par un `traducteur`, ou `null`.
    get pourquoi() {
      return pourquoi;
    },
    /// Ce que l'émetteur occupe, en octets : sa mémoire ne rétrécit jamais.
    get memoire() {
      return memory.buffer.byteLength;
    },
  };
}
