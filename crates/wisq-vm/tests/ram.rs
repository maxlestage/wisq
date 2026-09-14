//! **Quelle taille de RAM une machine confinée peut réellement déclarer.**
//!
//! Le pilote du noyau portait `const PAGES: u32 = 1024` — 64 Mio — en dur,
//! pendant que le nombre de tours et le plafond de traductions se réglaient
//! depuis #209. À ce chiffre, le noyau Alpine franchit tous ses initcalls puis
//! **meurt de faim** : `kworker invoked oom-killer`, puis
//! « Kernel panic - not syncing: System is deadlocked on memory ». Le mur
//! n'était plus une instruction, c'était la taille déclarée.
//!
//! **La contrainte qui empêche d'écrire n'importe quoi est réelle, et elle
//! était écrite en commentaire sans être exécutable** : c'est le repli par le
//! masque de la RAM qui fait tomber `0xffffffff81000090` sur `0x1000090`.
//! `Module::fold` est `address & (pages * 65536 - 1)` ; le masque doit donc
//! effacer le demi-haut *et* le `0x8` du `0x81000090`, ce qui tient jusqu'à
//! deux gibioctets et casse à quatre.
//!
//! Le refus est un **refus**, pas un avertissement. Une machine qui démarre sur
//! une adresse repliée de travers ne le dit pas : elle s'égare, et le relevé
//! parle d'une région introuvable trois écrans plus loin.
use wisq_vm::x86_wasm::{usable_ram, RamRefusal};

/// **L'adresse que la machine réclame pour de vrai, et sa place physique.**
///
/// Pas celle de l'en-tête ELF : pour `vmlinux.bin` d'Alpine, le point d'entrée
/// y est **déjà physique** — `0x1000090` des deux côtés. La première version de
/// cette garde interrogeait cette adresse-là et acceptait donc quatre
/// gibioctets sans broncher : le repli d'une adresse déjà physique est un
/// non-événement, quelle que soit la taille.
///
/// Ce que la machine replie vraiment, c'est l'adresse **virtuelle** qu'elle
/// réclame une fois `secondary_startup_64` passé et CR3 chargé :
/// `0x1000090 + __START_KERNEL_map`. Une garde qui approuve pour une raison qui
/// n'est pas la bonne est pire qu'aucune garde — elle rassure.
const ENTRY_VIRTUAL: u64 = 0xffff_ffff_8100_0090;
const ENTRY_PHYSICAL: u64 = 0x0100_0090;
/// Ce que ce noyau occupe, BSS compris — une vingtaine de mébioctets.
const TOP: u64 = 24 * 1024 * 1024;

#[test]
fn the_sizes_where_the_fold_still_lands_on_the_physical_address_are_accepted() {
    // 64 Mio — ce que le pilote déclarait — jusqu'à deux gibioctets.
    for pages in [1024u32, 2048, 4096, 8192, 16384, 32768] {
        assert_eq!(
            usable_ram(pages, ENTRY_VIRTUAL, ENTRY_PHYSICAL, TOP),
            Ok(()),
            "{} Mio devrait être utilisable",
            u64::from(pages) * 65536 / (1024 * 1024)
        );
    }
}

/// **Quatre gibioctets est la première taille qui casse**, et c'est la borne
/// que le commentaire du pilote annonçait sans que rien ne la tienne : à
/// `0xFFFFFFFF` le masque ne mord plus sur le `0x8`, et `0x81000090` reste
/// `0x81000090` au lieu de tomber sur `0x1000090`.
#[test]
fn four_gibibytes_is_refused_because_the_fold_stops_landing_right() {
    let refusal = usable_ram(65536, ENTRY_VIRTUAL, ENTRY_PHYSICAL, TOP);
    assert_eq!(
        refusal,
        Err(RamRefusal::FoldMisses {
            folded: 0x8100_0090
        }),
        "à quatre gibioctets le repli doit être refusé, et dire où il tombe"
    );
}

/// Le confinement de l'émetteur travaille par masque : une taille qui n'est pas
/// une puissance de deux n'a pas de masque, et `ram - 1` y découperait une
/// adresse au hasard. **Ce n'est pas une préférence de style.**
#[test]
fn a_size_that_is_not_a_power_of_two_has_no_mask_and_is_refused() {
    for pages in [3u32, 1000, 1025, 5000] {
        assert_eq!(
            usable_ram(pages, ENTRY_VIRTUAL, ENTRY_PHYSICAL, TOP),
            Err(RamRefusal::NotAPowerOfTwo),
            "{pages} pages n'est pas une puissance de deux"
        );
    }
}

#[test]
fn a_machine_with_no_ram_at_all_is_refused_before_anything_else() {
    assert_eq!(
        usable_ram(0, ENTRY_VIRTUAL, ENTRY_PHYSICAL, TOP),
        Err(RamRefusal::Empty)
    );
}

/// **Une RAM où le noyau ne tient pas est refusée, et dit ce qu'il faudrait.**
/// Le pilote imprimait déjà « le noyau déborde la RAM déclarée » et
/// **continuait quand même** — le montage posait alors des segments qui se
/// recouvraient par le repli, en silence.
#[test]
fn a_ram_too_small_for_the_kernel_says_how_much_it_would_take() {
    // 16 Mio pour un noyau qui en occupe 24.
    let refusal = usable_ram(256, ENTRY_VIRTUAL, ENTRY_PHYSICAL, TOP);
    assert_eq!(refusal, Err(RamRefusal::TooSmall { needed: TOP }));
}

/// **L'ordre des refus compte.** Une taille qui n'est pas une puissance de deux
/// n'a pas de masque du tout : lui demander où son repli tombe n'a pas de sens,
/// et rendre `FoldMisses` ferait chercher un défaut de repli là où le défaut
/// est la taille elle-même.
#[test]
fn a_size_that_is_neither_a_power_of_two_nor_big_enough_is_refused_for_the_first_reason() {
    assert_eq!(
        usable_ram(3, ENTRY_VIRTUAL, ENTRY_PHYSICAL, TOP),
        Err(RamRefusal::NotAPowerOfTwo),
        "trois pages sont trop petites *et* pas une puissance de deux ; \
         c'est la taille qui est fautive, pas le repli"
    );
}
