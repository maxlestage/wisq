//! **Ce que le recensement de pointeurs doit refuser, et ce qu'il doit compter.**
//!
//! `docs/DEMARRAGE.md` portait deux nombres — 122 994 adresses noyau hautes
//! contre 11 933 basses — sous la phrase « Ce n'est pas une supposition, c'est
//! une mesure ». Aucune commande n'accompagnait la mesure, et aucune des
//! définitions plausibles ne reproduisait ces deux nombres. Le raisonnement
//! qu'ils portaient tenait ; les nombres, eux, n'étaient plus vérifiables.
//!
//! Ce module existe pour que la mesure se refasse. Les tests ci-dessous
//! fixent ce qu'elle compte **avant** qu'elle compte quoi que ce soit de réel.

use wisq_vm::census::Census;

/// Huit octets, petit-boutiste, valant exactement la valeur demandée.
fn mot(valeur: u64) -> [u8; 8] {
    valeur.to_le_bytes()
}

fn image(mots: &[u64]) -> Vec<u8> {
    mots.iter().flat_map(|&m| mot(m)).collect()
}

#[test]
fn une_image_plus_courte_quun_mot_est_refusee_plutot_que_comptee_a_zero() {
    for taille in 0..8usize {
        let octets = vec![0u8; taille];
        assert!(
            Census::of(&octets).is_none(),
            "{taille} octets ne portent aucun mot aligné : refuser, pas rendre zéro"
        );
    }
    assert!(
        Census::of(&[0u8; 8]).is_some(),
        "huit octets portent exactement un mot, et c'est une mesure"
    );
}

#[test]
fn les_octets_de_queue_qui_ne_font_pas_un_mot_entier_sont_nommes() {
    let mut octets = image(&[0, 0, 0]);
    octets.extend_from_slice(&[0xff, 0xff, 0xff]);
    let recensement = Census::of(&octets).expect("trois mots entiers suffisent");
    assert_eq!(recensement.words(), 3, "trois mots entiers, pas quatre");
    assert_eq!(
        recensement.tail(),
        3,
        "les trois derniers octets ne font pas un mot et le relevé le dit"
    );
}

#[test]
fn seules_les_adresses_hautes_du_noyau_comptent_comme_hautes() {
    let octets = image(&[
        0xffff_ffff_8000_0000, // la base du noyau : haute
        0xffff_ffff_82a4_6207, // une adresse de texte : haute
        0xffff_ffff_8fff_ffff, // le dernier mot du quartet 8 : haute
        0xffff_ffff_9000_0000, // le quartet 9 : ce n'est plus 0xffffffff8…
        0xffff_8880_0000_9000, // la correspondance directe : ni l'un ni l'autre
        0x0000_0000_0100_0090, // le noyau chargé physiquement : basse
    ]);
    let recensement = Census::of(&octets).expect("six mots");
    assert_eq!(
        recensement.high(),
        3,
        "trois mots seulement portent le préfixe 0xffffffff8"
    );
}

#[test]
fn la_bande_basse_sarrete_ou_le_noyau_ne_peut_plus_etre_charge() {
    let octets = image(&[
        0x0000_0000_0100_0090, // le point d'entrée physique de l'image : basse
        0x0000_0000_01ff_ffff, // encore dans les trente-deux premiers mébioctets
        0x0000_0000_0400_0000, // la borne haute exclue
        0x0000_0000_0000_00ff, // trop bas pour être un chargement de noyau
        0xffff_ffff_8000_0000, // haute, donc pas basse
    ]);
    let recensement = Census::of(&octets).expect("cinq mots");
    assert_eq!(
        recensement.low(),
        2,
        "seuls les deux mots de [0x1000000, 0x4000000) sont des chargements plausibles"
    );
}

/// **Ce test-ci a d'abord été une assertion qui avait l'air d'une garde.**
///
/// Il comptait un mot haut, un mot bas, et vérifiait que leur somme ne
/// dépassait pas le total. Un sabotage rendant la bande basse non exclusive —
/// `if` au lieu de `else if` — l'a traversé sans le faire tomber : les deux
/// bandes sont disjointes **par leurs valeurs**, pas par le `else`, et la
/// somme restait juste dans les deux cas.
///
/// Ce que la disjonction vaut vraiment se lit sur les bornes, pas sur un
/// échantillon : le plancher de la bande haute est au-dessus du plafond de la
/// bande basse. C'est ça qui se tient ici, et un `else` retiré ne peut plus
/// s'en cacher — puisque plus rien ne prétend que le `else` y soit pour
/// quelque chose.
#[test]
fn les_deux_bandes_ne_peuvent_pas_se_recouvrir_par_construction() {
    // Lues sur le module, pas recopiées : une assertion sur une copie ne dit
    // rien de l'original, et un sabotage déplaçant une borne passerait au
    // travers sans être vu.
    let plancher_haut = Census::HIGH_FLOOR;
    let plafond_haut = Census::HIGH_CEILING;
    let plancher_bas = Census::LOW_FLOOR;
    let plafond_bas = Census::LOW_CEILING - 1;

    assert!(
        plancher_haut > plafond_bas,
        "la bande haute commence au-dessus de la bande basse : aucun mot ne tombe dans les deux"
    );
    assert!(
        plafond_haut >= plancher_haut,
        "la bande haute n'est pas vide"
    );
    assert!(plafond_bas >= plancher_bas, "la bande basse n'est pas vide");

    // Et les quatre bornes tombent du côté que le recensement leur donne.
    for (valeur, haute) in [
        (plancher_haut, true),
        (plafond_haut, true),
        (plancher_bas, false),
        (plafond_bas, false),
    ] {
        let recensement = Census::of(&mot(valeur)).expect("un mot");
        assert_eq!(
            (recensement.high(), recensement.low()),
            if haute { (1, 0) } else { (0, 1) },
            "{valeur:#x} appartient à une bande et à une seule"
        );
    }
}

#[test]
fn le_relevé_lit_les_mots_en_petit_boutiste_et_pas_autrement() {
    // Les mêmes huit octets lus à l'envers donneraient 0x0000_0080_ffff_ffff,
    // qui n'est ni haut ni bas. Si le relevé comptait gros-boutiste, ce test
    // rendrait zéro.
    let octets = mot(0xffff_ffff_8000_0000).to_vec();
    let recensement = Census::of(&octets).expect("un mot");
    assert_eq!(recensement.high(), 1, "petit-boutiste, comme le x86-64");
}
