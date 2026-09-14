//! **Ce qu'un relevé a le droit de dire quand la machine ne s'arrête sur rien.**
//!
//! Depuis #228 le noyau Alpine n'a plus d'instruction manquante sur le chemin
//! parcouru : le budget de tours s'épuise et le pilote concluait « la machine
//! avançait encore ». Cette phrase était **déduite du seul fait que rien n'a
//! manqué** — ce qu'une boucle qui tourne sans progresser produit à
//! l'identique. Le relevé se terminait dans `jent_entropy_init`, qui mesure la
//! gigue d'horloge et boucle jusqu'à ce que ses tests statistiques passent : si
//! le TSC ne bouge pas assez, elle ne finit jamais.
//!
//! Ce module ne tranche pas entre progrès et ronde. Il **dit ce qui est
//! mesuré** — depuis quel tour plus aucune adresse n'est neuve, et combien
//! d'adresses distinctes le dernier dixième a visitées — et laisse la
//! conclusion au lecteur, parce qu'une boucle chaude légitime n'ouvre pas de
//! terrain neuf non plus.
use wisq_vm::progress::Progress;

#[test]
fn a_run_that_keeps_reaching_new_ground_says_so_with_its_last_new_turn() {
    // Dernière adresse neuve au tour 950 000 sur un million : la machine
    // ouvrait encore du terrain quand le budget s'est épuisé.
    let seen =
        Progress::of(1_000_000, Some(950_000), 12_000, 4_300).expect("des comptes cohérents");
    let said = seen.describe();
    assert!(
        said.contains("950000"),
        "le tour de la dernière adresse neuve doit être dit : {said}"
    );
    assert!(
        said.contains("ouvrait encore"),
        "un relevé qui ouvre du terrain jusqu'au bout doit le dire : {said}"
    );
}

#[test]
fn a_run_that_stopped_reaching_new_ground_names_the_turn_and_the_silence_after_it() {
    // Le relevé de #228 : dernière région neuve très tôt, un million de tours.
    let seen = Progress::of(1_000_000, Some(10_776), 10_800, 6).expect("des comptes cohérents");
    let said = seen.describe();
    assert!(
        said.contains("10776"),
        "le tour de la dernière adresse neuve doit être dit : {said}"
    );
    assert!(
        said.contains("989224"),
        "le nombre de tours passés sans rien de neuf doit être dit, \
         pas laissé à soustraire : {said}"
    );
    assert!(
        said.contains(" 6 "),
        "l'étroitesse du dernier dixième est le second chiffre, et il doit \
         être là : {said}"
    );
    // **Et surtout : le relevé ne conclut pas.** Une boucle chaude légitime
    // n'ouvre pas de terrain neuf non plus ; affirmer la ronde serait la même
    // faute que l'affirmation qu'on retire.
    assert!(
        !said.contains("ronde") && !said.contains("boucle"),
        "le relevé énonce ce qu'il mesure et ne tranche pas : {said}"
    );
}

#[test]
fn a_run_that_never_reached_anything_new_is_not_given_a_turn_it_does_not_have() {
    let seen = Progress::of(4096, None, 0, 0).expect("des comptes cohérents");
    let said = seen.describe();
    assert!(
        said.contains("aucune adresse"),
        "sans terrain neuf du tout, le relevé le dit plutôt que d'inventer \
         un tour : {said}"
    );
    assert!(
        !said.contains("depuis le tour"),
        "il n'y a pas de tour depuis lequel plus rien n'est neuf quand rien ne \
         l'a jamais été : {said}"
    );
}

/// **Des comptes qui ne peuvent pas venir d'une même exécution sont refusés.**
///
/// C'est la même discipline qu'un bouchon qui refuse ce que la vraie chose ne
/// pourrait pas faire : ces quatre nombres arrivent d'un pilote JavaScript qui
/// n'est jugé par rien, et un relevé qui met en forme n'importe quoi rendrait
/// une phrase d'aplomb sur un comptage cassé.
#[test]
fn counts_that_no_single_run_could_have_produced_are_refused() {
    assert!(
        Progress::of(1000, Some(1001), 5, 5).is_none(),
        "une adresse neuve après le dernier tour n'existe pas"
    );
    assert!(
        Progress::of(1000, Some(500), 5, 9).is_none(),
        "le dernier dixième ne peut pas visiter plus d'adresses distinctes \
         que le relevé entier"
    );
    assert!(
        Progress::of(1000, Some(500), 0, 0).is_none(),
        "un tour porte une adresse neuve, donc le total ne peut pas être nul"
    );
    assert!(
        Progress::of(0, None, 0, 0).is_none(),
        "un relevé de zéro tour ne mesure rien"
    );
}
