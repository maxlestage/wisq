//! **`100 %` est une affirmation, pas un arrondi.**
//!
//! Le relevé de couverture imprimait, deux lignes de suite :
//!
//! ```text
//! décodage linéaire : 2932212 instructions lues, 641 octets refusés
//!   soit 100.0 % de succès
//!   opcodes refusés les plus fréquents : 0f×148 c4×127 66×65 c5×27 …
//! ```
//!
//! Le chiffre est juste au dixième près — 99,978 % s'arrondit à 100,0. Il est
//! **faux comme phrase** : il dit que le décodeur lit tout, au-dessus d'une
//! ligne qui nomme douze opcodes qu'il ne lit pas.
//!
//! Et ce n'est pas une maladresse isolée, parce que la **même** mise en forme
//! sert ailleurs dans le même relevé :
//!
//! ```text
//! régions depuis les cibles de `call` : 10116 compilées, 0 refusées (100.0 %)
//! ```
//!
//! Celui-là est vrai : zéro refus. Rien, dans le texte imprimé, ne distingue
//! le 100,0 qui compte de celui qui arrondit. C'est la forme la plus coûteuse
//! d'un relevé qui ment : il ne se trompe pas, il rend deux faits différents
//! indiscernables.
//!
//! La règle que ce module tient : **`100 %` est réservé à zéro refus**, et
//! `0 %` à zéro succès. Entre les deux, l'arrondi ne touche jamais les bornes.
use wisq_vm::rate::Rate;

/// Les nombres **réellement mesurés** sur `vmlinux.bin` (Alpine 6.6.134), le
/// 14 septembre, avec le décodeur d'après #232. Ils sont ici plutôt qu'un
/// couple choisi à la main pour que le test tombe si la borne cesse de mordre
/// sur le cas qui l'a motivée.
const MESURE_LUES: u64 = 2_932_212;
const MESURE_REFUSEES: u64 = 641;

#[test]
fn the_measured_linear_decode_never_reads_as_a_perfect_score() {
    let rate = Rate::of(MESURE_LUES, MESURE_REFUSEES).expect("des comptes non vides");
    let said = rate.describe(1);
    assert!(
        !said.contains("100"),
        "641 octets sont refusés : le relevé n'a pas le droit d'écrire cent — {said}"
    );
    // Et il ne doit pas verser dans l'excès inverse : le chiffre reste utile.
    assert!(
        said.contains("99,9"),
        "la proportion reste dite, et au dixième : {said}"
    );
}

#[test]
fn a_survey_that_refused_nothing_says_a_hundred_exactly() {
    // Les cibles de `call` du même noyau : 10 116 compilées, aucune refusée.
    let rate = Rate::of(10_116, 0).expect("des comptes non vides");
    assert_eq!(
        rate.describe(1),
        "100 %",
        "zéro refus est la seule chose qui s'écrive cent, et elle s'écrit sans décimale"
    );
}

/// **Le miroir, et il n'est pas décoratif.** Une borne posée d'un seul côté se
/// contente de déplacer le mensonge : un relevé où presque tout est refusé
/// afficherait « 0,0 % », qu'on lirait comme « rien ne passe » alors que
/// quelque chose passe. Les deux bornes sont la même règle.
#[test]
fn a_single_success_among_millions_never_reads_as_nothing() {
    let rate = Rate::of(1, MESURE_LUES).expect("des comptes non vides");
    let said = rate.describe(1);
    assert_ne!(
        said, "0 %",
        "une réussite sur trois millions n'est pas zéro : {said}"
    );
    assert_eq!(
        said, "0,1 %",
        "la borne basse rabat vers le premier dixième, et se lit comme un arrondi"
    );
}

#[test]
fn nothing_at_all_says_zero_exactly() {
    let rate = Rate::of(0, 7).expect("des comptes non vides");
    assert_eq!(
        rate.describe(1),
        "0 %",
        "aucune réussite est la seule chose qui s'écrive zéro"
    );
}

/// **Rien de mesuré n'est pas zéro pour cent.** Une division par zéro rendrait
/// `NaN`, que `{:.1}` imprime « NaN » — ou, pire, le relevé afficherait
/// « 0,0 % » et on chercherait un défaut de décodage là où il n'y a eu aucune
/// lecture. La porte refuse, comme celle de `Progress`.
#[test]
fn a_survey_that_measured_nothing_is_refused_rather_than_shown() {
    assert!(
        Rate::of(0, 0).is_none(),
        "zéro sur zéro n'est pas une proportion, c'est une mesure qui n'a pas eu lieu"
    );
}

/// **La règle suit la précision demandée, elle ne s'y dissout pas.**
///
/// Le relevé imprime certaines parts au centième — « 0,30 % des instructions
/// rendent la main à coup sûr ». Une borne figée au dixième y rabattrait
/// 0,30 sur 0,1 et mentirait dans l'autre sens : elle grossirait ce qu'elle
/// prétend rendre lisible. Le rabat doit donc valoir le plus petit pas visible
/// à la précision choisie, et pas un pas choisi une fois pour toutes.
#[test]
fn the_reserved_bounds_follow_the_precision_asked_for() {
    let rate = Rate::of(MESURE_LUES, MESURE_REFUSEES).expect("des comptes non vides");
    assert_eq!(
        rate.describe(2),
        "99,98 %",
        "au centième, 99,978 s'arrondit sans toucher la borne — c'est le \
         dixième qui la touchait"
    );
    // Et la borne mord toujours, un cran plus loin : une mesure dont la part
    // dépasse 99,99 % est rabattue au centième, pas arrondie à cent.
    let presque = Rate::of(1_000_000, 1).expect("des comptes non vides");
    assert_eq!(
        presque.describe(2),
        "99,99 %",
        "un seul refus sur un million reste un refus"
    );
    assert_eq!(presque.describe(1), "99,9 %", "et au dixième aussi");
}
