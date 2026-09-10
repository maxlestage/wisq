//! **Nommer une adresse, avec la carte des symboles du noyau.**
//!
//! `--example kernel-entry` rendait « rip 0xffffffff81000642 », et la feuille
//! de route a porté pendant toute une tranche un « on ne sait pas si c'est un
//! chemin d'erreur ou une boucle de parking ». La carte était pourtant à portée
//! — dans l'ISO d'Alpine — et l'adresse se nomme : `__startup_64 + 658`, le
//! `for (;;)` que le noyau écrit derrière une garde sur son argument. Le dépôt
//! a d'abord lu ça comme du rembourrage : nommer l'adresse ne suffisait pas, il
//! fallait aussi demander qui y mène.
//!
//! Ce qui se joue ici est donc la lisibilité d'un relevé, pas une optimisation.
//! Un diagnostic qu'on ne sait pas lire n'est pas un diagnostic.
use wisq_vm::symbols::Symbols;

/// Un extrait de vrai `System.map-6.6.134-0-lts`, dans l'ordre où il vient —
/// et **une ligne dans le désordre**, parce qu'un `System.map` n'est trié que
/// par convention et qu'un résolveur qui suppose l'ordre se trompe en silence.
const CARTE: &str = "\
ffffffff81000390 T sev_verify_cbit
ffffffff810003b0 T __startup_64
ffffffff81000660 T startup_64_setup_env
ffffffff81000090 T startup_64
ffffffff81bcca30 T __x86_return_thunk
0000000000000000 D __per_cpu_start
";

#[test]
fn an_address_inside_a_function_is_named_with_its_offset() {
    let carte = Symbols::parse(CARTE);
    assert_eq!(
        carte.nearest(0xffff_ffff_8100_0642),
        Some(("__startup_64", 658)),
        "c'est l'adresse où le noyau d'Alpine s'arrête, et elle est dans __startup_64"
    );
}

/// Une adresse qui **est** un symbole se nomme sans décalage. Sans ce cas, un
/// résolveur qui rendrait toujours « + 0 » passerait le test d'au-dessus.
#[test]
fn an_address_that_is_a_symbol_carries_no_offset() {
    let carte = Symbols::parse(CARTE);
    assert_eq!(
        carte.nearest(0xffff_ffff_81bc_ca30),
        Some(("__x86_return_thunk", 0))
    );
}

/// **La carte n'est triée que par convention.** `startup_64` est écrit après
/// deux symboles plus hauts dans l'extrait ci-dessus, exprès : un résolveur qui
/// se fie à l'ordre du fichier nommerait d'après le mauvais voisin.
///
/// **Et ce test a d'abord menti sur ce qu'il tenait.** Écrit avec la seule
/// adresse `startup_64 + 42`, il **survivait** au retrait du tri : chercher
/// dans une suite non triée est un comportement non spécifié, et ce cas-là
/// tombait juste par chance. Trois autres tests l'attrapaient, mais pas celui
/// qui porte son nom — exactement la forme d'assertion qui ressemble à une
/// garde sans en être une. Les deux adresses sont donc vérifiées ensemble, et
/// la seconde est celle qui casse.
#[test]
fn a_map_written_out_of_order_still_resolves() {
    let carte = Symbols::parse(CARTE);
    assert_eq!(
        carte.nearest(0xffff_ffff_8100_00ba),
        Some(("startup_64", 42))
    );
    assert_eq!(
        carte.nearest(0xffff_ffff_8100_0642),
        Some(("__startup_64", 658)),
        "sans le tri, celle-ci se nomme d'après le mauvais voisin"
    );
}

/// Sous le premier symbole, il n'y a rien à nommer. Rendre le premier symbole
/// avec un décalage négatif — ou pire, un décalage énorme — serait une réponse
/// fausse là où « je ne sais pas » est la bonne.
#[test]
fn an_address_below_every_symbol_is_not_named() {
    let carte = Symbols::parse("ffffffff81000090 T startup_64\n");
    assert_eq!(carte.nearest(0xffff_ffff_8100_008f), None);
}

/// Une carte vide ne nomme rien, et ne panique pas : c'est ce qu'on obtient
/// d'un fichier absent ou tronqué, et l'outil doit continuer à imprimer ses
/// adresses nues plutôt que s'arrêter.
#[test]
fn an_empty_map_names_nothing() {
    assert_eq!(Symbols::parse("").nearest(0xffff_ffff_8100_0642), None);
    assert_eq!(Symbols::parse("des ordures\n\n").nearest(1), None);
}

/// **Les lignes illisibles sont sautées, pas fatales.** Un `System.map` est du
/// texte produit par une chaîne de compilation, et l'outil qui le lit n'a
/// aucune raison de refuser tout le fichier pour une ligne.
#[test]
fn unreadable_lines_are_skipped_and_the_rest_still_resolves() {
    let carte = Symbols::parse("pas une adresse\nffffffff81000090 T startup_64\nzz\n");
    assert_eq!(
        carte.nearest(0xffff_ffff_8100_0091),
        Some(("startup_64", 1))
    );
}

/// **Ce que le relevé imprime vraiment.** L'adresse reste, toujours : le nom
/// s'ajoute, il ne remplace pas. Une adresse remplacée par un nom serait
/// illisible pour la moitié du travail — comparer deux relevés, chercher dans
/// un désassemblage — et c'est l'adresse qui est le fait.
#[test]
fn what_a_reading_prints_keeps_the_address_and_adds_the_name() {
    let carte = Symbols::parse(CARTE);
    assert_eq!(
        carte.describe(0xffff_ffff_8100_0642),
        "0xffffffff81000642 (__startup_64 + 658)"
    );
    assert_eq!(
        carte.describe(0xffff_ffff_81bc_ca30),
        "0xffffffff81bcca30 (__x86_return_thunk)"
    );
    // **Rien à nommer, rien d'ajouté.** Sur une carte qui commence plus haut :
    // l'extrait ci-dessus porte `__per_cpu_start` à zéro, donc toute adresse y
    // a un nom — l'assertion écrite dessus a échoué, et elle avait raison.
    assert_eq!(
        Symbols::parse("ffffffff81000090 T startup_64\n").describe(1),
        "0x1"
    );
}

/// **Nommer une adresse qu'on tient en physique, avec une carte écrite en
/// virtuel.**
///
/// Le noyau démarre à son adresse physique — c'est ce que fait `X86BootLoader`
/// avec `preferredAddress`, et c'est ce que suppose le code de démarrage de
/// Linux, qui calcule l'adresse de `_text` par `%rip` alors que la pagination
/// n'est pas encore la sienne. `System.map`, lui, est écrit en virtuel. Les
/// deux se rejoignent par `__START_KERNEL_map`, et c'est **une addition qu'il
/// ne faut faire qu'une fois**.
///
/// La faire deux fois n'échoue pas : elle déborde et rend un nom. `--example
/// kernel-entry` a imprimé, sur une mesure, « phys_startup_64 +
/// 18446744069414584494 » pour une adresse parfaitement ordinaire — un nombre
/// que personne ne lit comme une erreur, dans un outil dont c'est tout le
/// métier d'être lu.
const MAP: u64 = 0xffff_ffff_8000_0000;

#[test]
fn a_physical_address_is_named_through_the_kernel_map() {
    let carte = Symbols::parse(CARTE);
    // 0x1000642 est l'adresse **physique** de `__startup_64 + 658` quand le
    // noyau est chargé à 16 Mio, où le charge Alpine.
    assert_eq!(
        carte.describe_loaded(0x0100_0642, MAP),
        "0x1000642 (__startup_64 + 658)",
        "une adresse physique se nomme par la carte, sans qu'on l'ait convertie avant"
    );
    // Et le nom rendu porte l'adresse **telle qu'on la tient** : c'est celle
    // qu'on relit dans un registre ou dans la RAM, pas sa traduction.
}

#[test]
fn an_address_already_virtual_is_not_offset_a_second_time() {
    let carte = Symbols::parse(CARTE);
    // La même adresse, mais virtuelle. C'est le cas qui a produit le nom
    // absurde : le noyau bascule à l'adressage virtuel en cours de démarrage,
    // donc les deux formes se croisent dans un même relevé.
    assert_eq!(
        carte.describe_loaded(0xffff_ffff_8100_0642, MAP),
        "0xffffffff81000642 (__startup_64 + 658)",
        "elle est déjà au-dessus de la carte : rien à ajouter"
    );
}

#[test]
fn a_physical_address_with_no_symbol_below_it_says_so() {
    // Une carte sans le symbole zéro : en dessous du premier symbole, il n'y a
    // rien à nommer, et l'outil doit le dire au lieu d'inventer un décalage
    // depuis le symbole d'après.
    let carte = Symbols::parse("ffffffff810003b0 T __startup_64\n");
    assert_eq!(
        carte.describe_loaded(0x0000_0100, MAP),
        "0x100",
        "aucun symbole ne précède cette adresse"
    );
}

/// **Un symbole ne nomme pas une adresse arbitrairement loin de lui.**
///
/// Le relevé imprime aussi des mots de pile, et beaucoup ne sont pas des
/// adresses. Sans borne, `0x10` se voyait nommer « fixed_percpu_data + 16 » et
/// un pointeur de pile « phys_startup_64 + 20987576 ». Un nom faux est pire
/// qu'une adresse nue : personne ne relit le nombre à côté du nom.
#[test]
fn a_value_too_far_from_any_symbol_stays_a_bare_number() {
    let carte = Symbols::parse(CARTE);
    // Deux mébioctets après le dernier symbole de la carte : plus rien ne le
    // couvre, et l'outil doit le dire en n'inventant rien.
    assert_eq!(
        carte.describe_loaded(0xffff_ffff_81dc_ca30, MAP),
        "0xffffffff81dcca30",
        "au-delà d'un mébioctet, le symbole d'en dessous ne nomme plus"
    );
    // Et juste en dessous de la borne, il nomme encore : sans ce cas, une
    // borne mise à zéro passerait le test d'au-dessus.
    assert_eq!(
        carte.describe_loaded(0xffff_ffff_81bc_ca31, MAP),
        "0xffffffff81bcca31 (__x86_return_thunk + 1)"
    );
}
