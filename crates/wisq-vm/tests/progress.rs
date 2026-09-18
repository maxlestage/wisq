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
    // **Les vrais chiffres du noyau Alpine après #228**, relevés par ce pilote
    // à `WISQ_ROUNDS=16384 WISQ_TURNS=1000000` : `marche 1000000 860189 10775 30`.
    //
    // Ils ont démenti ce que cette tranche croyait aller montrer. La
    // conjecture était « la machine tourne en rond depuis le début » — le
    // relevé de #228 posait sa dernière région à la traduction 10 776, et ce
    // nombre a été lu comme un tour parce que le pilote imprimait le rang des
    // traductions sous le mot « tour ». La machine a en fait atteint du
    // terrain neuf jusqu'au tour **860 189 sur un million**, soit 86 % du
    // budget, avant de se refermer sur trente adresses.
    //
    // C'est exactement ce que cette tranche existe pour empêcher : une
    // conclusion tirée d'un relevé qui nomme mal ce qu'il compte.
    let seen = Progress::of(1_000_000, Some(860_189), 10_775, 30).expect("des comptes cohérents");
    let said = seen.describe();
    assert!(
        said.contains("860189"),
        "le tour de la dernière adresse neuve doit être dit : {said}"
    );
    assert!(
        said.contains("139811"),
        "le nombre de tours passés sans rien de neuf doit être dit, \
         pas laissé à soustraire : {said}"
    );
    assert!(
        said.contains(" 30 "),
        "l'étroitesse de ce qui suit est le second chiffre, et il doit \
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

/// **La cadence du battement : jamais muet sur un long relevé, jamais un
/// déluge sur un court.**
///
/// #262 a été ouverte sur un fait, pas sur une intuition : une mesure lancée à
/// `WISQ_TURNS=40000000` a tourné **deux heures à 99,8 % de processeur sans
/// imprimer une ligne**. Le pilote JavaScript engendré n'écrivait rien dans sa
/// boucle de tours — `arret`, `marche`, `retours` et le reste ne sortent
/// qu'après. Impossible, pendant ce temps, de dire si la machine avançait ou
/// tournait en rond : exactement la question que #229 a appris à poser, avec
/// des compteurs qui n'arrivaient qu'à la fin.
///
/// `beat` est la période, en tours, entre deux lignes de progrès. Deux bornes
/// la tiennent, et elles tirent en sens contraire :
///
/// - **jamais un déluge** — deux cents lignes au plus, quel que soit le
///   budget, sinon le relevé devient illisible et noie les lignes de
///   traduction ;
/// - **jamais muet** — un relevé assez long pour qu'on se demande s'il avance
///   doit en donner au moins une vingtaine.
///
/// Un plancher garde les relevés courts tranquilles : à mille tours, la
/// machine a fini avant qu'on ait le temps de se poser la question, et le
/// relevé final suffit.
///
/// **Ce que ce test ne tient pas, et il faut le dire** : que la ligne soit
/// bien émise *dans* la boucle. Ça, seul un vrai relevé le montre — le juger
/// ici demanderait de faire tourner Bun sur un noyau, ce qu'un test unitaire
/// ne fait pas. La cadence, elle, est la décision, et elle est ici.
#[test]
fn the_beat_is_never_a_flood_and_never_silent_on_a_long_run() {
    /// Le plus grand nombre de lignes qu'un relevé a le droit d'imprimer.
    const MOST: usize = 200;
    /// Au-delà de ce budget, on se demande si la machine avance — et le relevé
    /// doit répondre sans attendre sa propre fin.
    const LONG: usize = 100_000;
    /// Le moins qu'un tel relevé doive dire.
    const LEAST: usize = 20;

    for turns in [
        1,
        2,
        999,
        1_024,
        65_536,
        LONG,
        1_000_000,
        8_000_000,
        40_000_000,
        usize::MAX,
    ] {
        let beat = Progress::beat(turns);
        assert!(
            beat >= 1,
            "une période nulle ne bat jamais — et en JavaScript, `tour % 0`              vaut NaN, donc le relevé serait muet sans le dire ({turns} tours)"
        );
        let lines = turns / beat;
        assert!(
            lines <= MOST,
            "{lines} lignes de progrès pour {turns} tours : le relevé noierait              ses propres traductions"
        );
        if turns >= LONG {
            assert!(
                lines >= LEAST,
                "{lines} lignes pour {turns} tours : c'est le silence que #262                  a payé deux heures"
            );
        }
    }
}
