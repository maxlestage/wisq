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
// refus franc. Les trois branches sont jugées sous Bun, et la boucle hôte avec
// elles : `crates/wisq-page/tests/page.rs`.
//
// **Une trappe ne coûte qu'une région.** Le module est construit avec
// `panic = "abort"` : sur `wasm32-unknown-unknown`, un panic de l'émetteur — ou
// une allocation qui échoue — est une trappe `unreachable`. Rien n'est
// déroulé : le verrou de la porte reste pris, et chaque appel suivant
// trapperait à son tour (reproduit le 14 novembre sous Bun : une fenêtre
// impossible à allouer, puis plus aucune traduction, même de deux
// instructions). Plutôt que de croire qu'une instance trappée est encore
// saine, on la jette : `resoudre` en recrée une neuve depuis le même
// `WebAssembly.Module`, déjà compilé, et la région suivante repart sur un
// émetteur intact. Le mode processus de `kernel-entry` avait la même
// propriété sans la chercher : un `x86-translate` qui meurt n'emporte que sa
// région.

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
  const texte = new TextDecoder();
  // **Les exports de l'instance en service.** Remplacés en entier après une
  // trappe : garder `memory` d'une instance et `emettre` d'une autre ferait
  // lire un module dans la mémoire de quelqu'un d'autre.
  let porte = null;
  // **Combien d'instances ont été créées**, la première comprise : ce qu'un
  // pilote imprime pour dire qu'une trappe a eu lieu, et ce que le test lit.
  let instances = 0;
  function instancier() {
    // **Aucun import.** L'émetteur est du calcul pur sur ses deux tampons : il
    // ne lit ni l'heure, ni un fichier, ni la mémoire de l'invité.
    porte = new WebAssembly.Instance(module, {}).exports;
    instances += 1;
  }
  instancier();
  // **La raison du dernier refus**, gardée pour qui veut la journaliser. La
  // boucle hôte ne la demande pas : elle ne distingue que les trois réponses.
  let pourquoi = null;

  /// **Les octets du dernier résultat, copiés.** Pas une vue : la mémoire de
  /// l'émetteur grandit d'une région à l'autre, et une vue sur l'ancien
  /// `buffer` se détacherait sous le pied de qui la garde.
  const lire = () => new Uint8Array(porte.memory.buffer, porte.dernier(), porte.taille()).slice();

  /// **Traduire une fenêtre**, comme `Module::resolving_or_why(fenêtre,
  /// base, entree, emplacement, pages)`. Rend `{ module }`, `{ encore }` ou
  /// `{ refus }` — les deux derniers portant la raison, en texte, sous la
  /// forme `{:?}` de `Refused` — ou `{ trappe }` quand l'instance a trappé
  /// (elle est alors déjà remplacée, et la raison est le message du moteur).
  function resoudre(fenetre, base, emplacement, pages, entree = 0) {
    try {
      // **L'adresse est relue avant chaque copie** : `allouer` peut déplacer
      // le tampon, et la mémoire a pu grandir depuis l'appel précédent.
      const place = porte.allouer(fenetre.length);
      new Uint8Array(porte.memory.buffer, place, fenetre.length).set(fenetre);
      // Un `i64` côté module : un `BigInt` de ce côté-ci, ramené sur 64 bits
      // pour qu'une adresse du noyau (au-dessus de 2⁶³) passe telle quelle.
      const code = porte.emettre(
        fenetre.length,
        BigInt.asUintN(64, BigInt(base)),
        entree,
        emplacement,
        pages,
      );
      if (code >= 0) return { module: lire() };
      const raison = texte.decode(lire());
      if (code === CODES.encore) return { encore: raison };
      return { refus: raison };
    } catch (trappe) {
      // **Tout ce qui lève ici rend l'instance suspecte**, trappe du module
      // ou erreur du moteur au milieu d'une copie : on ne sait pas où elle
      // s'est arrêtée. La remplacer coûte une instanciation, pas une
      // compilation.
      instancier();
      return { trappe: String(trappe) };
    }
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
      if (rendu.trappe !== undefined) {
        // **Une panne, pas un refus.** Lever fait dire à `host.js`
        // « traduction en panne » (`BROKEN`) plutôt que « refusée » : la
        // cause est dans l'émetteur, pas dans les octets de l'invité, et un
        // nouvel essai de la même région part déjà sur une instance neuve.
        pourquoi = rendu.trappe;
        throw new Error("l'émetteur de la page a trappé : " + rendu.trappe);
      }
      pourquoi = rendu.refus;
      if (surRefus !== null) surRefus(adresse, rendu.refus);
      return null;
    };
  }

  return {
    resoudre,
    traducteur,
    /// La raison du dernier refus — ou de la dernière trappe — vue par un
    /// `traducteur`, ou `null` après une traduction.
    get pourquoi() {
      return pourquoi;
    },
    /// Ce que l'émetteur occupe, en octets : sa mémoire ne rétrécit jamais.
    get memoire() {
      return porte.memory.buffer.byteLength;
    },
    /// Le nombre d'instances créées : 1 tant qu'aucune trappe n'a eu lieu.
    get instances() {
      return instances;
    },
  };
}
