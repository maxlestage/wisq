//! **L'état de la carte, en octets** : ce que l'instantané de la machine PC
//! native (`wisq-vm`, `pc::instantane`, version 2) porte de la carte, écrit et
//! relu ici parce que les états des périphériques sont privés à leurs modules.
//!
//! Chaque périphérique a son `sauver` et son `relire`, à côté de ses champs :
//! [`cmos`](super::cmos), [`i8042`](super::i8042), [`pci`](super::pci) et ses
//! emplacements, [`virtio_blk`](super::virtio_blk),
//! [`virtio_net`](super::virtio_net), [`ecran`](super::ecran),
//! [`tablette`](super::tablette) ; la façade ([`pc::CartePc`](super::pc::CartePc))
//! les assemble, avec ses disques et ses notifications en attente.
//!
//! **Les règles** sont celles de l'instantané de la machine : tout est
//! petit-boutiste ; un booléen vaut zéro ou un ; **rien n'est reposé tant que
//! tout n'a pas été lu et vérifié** — `relire` rend un état neuf, ou rien, et
//! c'est la façade qui le pose, d'un coup, une fois la lecture entière
//! acceptée. Chaque `relire` refuse ce que son périphérique ne peut pas tenir :
//! un index de file hors de sa taille, une taille de file qui n'est pas une
//! puissance de deux, une fenêtre de travers, une file d'attente au-delà de
//! sa borne.
//!
//! Ce module ne dépend de rien, comme le crate : les deux machines (la page en
//! wasm32 et la machine native) le compilent ; seule la seconde s'en sert.

/// Ce qu'on écrit, octet après octet.
pub(crate) struct Ecrivain(pub(crate) Vec<u8>);

impl Ecrivain {
    pub(crate) fn u8(&mut self, valeur: u8) {
        self.0.push(valeur);
    }
    pub(crate) fn u16(&mut self, valeur: u16) {
        self.0.extend_from_slice(&valeur.to_le_bytes());
    }
    pub(crate) fn u32(&mut self, valeur: u32) {
        self.0.extend_from_slice(&valeur.to_le_bytes());
    }
    pub(crate) fn u64(&mut self, valeur: u64) {
        self.0.extend_from_slice(&valeur.to_le_bytes());
    }
    pub(crate) fn i64(&mut self, valeur: i64) {
        self.0.extend_from_slice(&valeur.to_le_bytes());
    }
    pub(crate) fn oui(&mut self, valeur: bool) {
        self.u8(u8::from(valeur));
    }
    /// Un octet qui peut manquer : sa présence, puis lui (zéro sans lui).
    pub(crate) fn peut_etre_u8(&mut self, valeur: Option<u8>) {
        self.oui(valeur.is_some());
        self.u8(valeur.unwrap_or(0));
    }
    /// Un mot de 64 bits qui peut manquer.
    pub(crate) fn peut_etre_u64(&mut self, valeur: Option<u64>) {
        self.oui(valeur.is_some());
        self.u64(valeur.unwrap_or(0));
    }
    /// Un compte d'éléments, sur huit octets.
    pub(crate) fn compte(&mut self, combien: usize) {
        self.u64(combien as u64);
    }
    /// Des octets, précédés de leur longueur.
    pub(crate) fn octets(&mut self, octets: &[u8]) {
        self.compte(octets.len());
        self.0.extend_from_slice(octets);
    }
    /// **Un grand bloc page par page** (la mémoire vidéo, l'image d'un disque
    /// en mémoire) : sa longueur, une carte d'un bit par page de quatre
    /// kibioctets, puis les seules pages qui ne sont pas nulles — l'encodage
    /// de la RAM de l'instantané.
    pub(crate) fn pages(&mut self, octets: &[u8]) {
        self.compte(octets.len());
        let pages: Vec<&[u8]> = octets.chunks(PAGE).collect();
        let mut carte = vec![0u8; pages.len().div_ceil(8)];
        for (rang, page) in pages.iter().enumerate() {
            if page.iter().any(|&octet| octet != 0) {
                carte[rang / 8] |= 1 << (rang % 8);
            }
        }
        self.0.extend_from_slice(&carte);
        for (rang, page) in pages.iter().enumerate() {
            if carte[rang / 8] & (1 << (rang % 8)) != 0 {
                self.0.extend_from_slice(page);
            }
        }
    }
}

/// La page de l'encodage par pages.
pub(crate) const PAGE: usize = 4096;

/// Ce qu'on relit, sans jamais lire au-delà.
pub(crate) struct Lecteur<'a> {
    octets: &'a [u8],
    ou: usize,
}

impl<'a> Lecteur<'a> {
    pub(crate) fn nouveau(octets: &'a [u8]) -> Self {
        Self { octets, ou: 0 }
    }
    /// Tout a été lu, et rien ne reste derrière.
    pub(crate) fn au_bout(&self) -> bool {
        self.ou == self.octets.len()
    }
    pub(crate) fn prendre(&mut self, combien: usize) -> Option<&'a [u8]> {
        let fin = self.ou.checked_add(combien)?;
        let morceau = self.octets.get(self.ou..fin)?;
        self.ou = fin;
        Some(morceau)
    }
    pub(crate) fn u8(&mut self) -> Option<u8> {
        Some(self.prendre(1)?[0])
    }
    pub(crate) fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.prendre(2)?.try_into().ok()?))
    }
    pub(crate) fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.prendre(4)?.try_into().ok()?))
    }
    pub(crate) fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.prendre(8)?.try_into().ok()?))
    }
    pub(crate) fn i64(&mut self) -> Option<i64> {
        Some(i64::from_le_bytes(self.prendre(8)?.try_into().ok()?))
    }
    /// Un booléen : zéro ou un, rien d'autre.
    pub(crate) fn oui(&mut self) -> Option<bool> {
        match self.u8()? {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }
    /// Un octet qui peut manquer ; absent, l'octet écrit doit être nul.
    pub(crate) fn peut_etre_u8(&mut self) -> Option<Option<u8>> {
        let present = self.oui()?;
        let valeur = self.u8()?;
        match (present, valeur) {
            (true, valeur) => Some(Some(valeur)),
            (false, 0) => Some(None),
            (false, _) => None,
        }
    }
    /// Un mot qui peut manquer ; absent, le mot écrit doit être nul.
    pub(crate) fn peut_etre_u64(&mut self) -> Option<Option<u64>> {
        let present = self.oui()?;
        let valeur = self.u64()?;
        match (present, valeur) {
            (true, valeur) => Some(Some(valeur)),
            (false, 0) => Some(None),
            (false, _) => None,
        }
    }
    /// **Un compte d'éléments, borné** : au-delà de `plus`, l'état est
    /// refusé avant qu'on lise ou qu'on alloue quoi que ce soit.
    pub(crate) fn compte(&mut self, plus: usize) -> Option<usize> {
        let combien = usize::try_from(self.u64()?).ok()?;
        (combien <= plus).then_some(combien)
    }
    /// Des octets précédés de leur longueur, au plus `plus`.
    pub(crate) fn octets(&mut self, plus: usize) -> Option<&'a [u8]> {
        let longueur = self.compte(plus)?;
        self.prendre(longueur)
    }
    /// **Un bloc écrit par [`Ecrivain::pages`]**, de `longueur` octets tout
    /// juste : rend, pour chaque page non nulle, son rang et ses octets. Un
    /// bit de la carte au-delà de la dernière page est refusé.
    pub(crate) fn pages(&mut self, longueur: usize) -> Option<Vec<(usize, &'a [u8])>> {
        let octets = usize::try_from(self.u64()?).ok()?;
        if octets != longueur {
            return None;
        }
        let pages = octets.div_ceil(PAGE);
        let carte = self.prendre(pages.div_ceil(8))?;
        if pages % 8 != 0 && carte[pages / 8] >> (pages % 8) != 0 {
            return None;
        }
        let mut pleines = Vec::new();
        for rang in 0..pages {
            if carte[rang / 8] & (1 << (rang % 8)) != 0 {
                let taille = PAGE.min(octets - rang * PAGE);
                pleines.push((rang, self.prendre(taille)?));
            }
        }
        Some(pleines)
    }
    /// La longueur d'un bloc écrit par [`Ecrivain::pages`], sans le lire :
    /// une image de disque en mémoire, dont la taille n'est pas connue
    /// d'avance. Au plus `plus` octets.
    pub(crate) fn longueur_des_pages(&self, plus: usize) -> Option<usize> {
        let huit = self.octets.get(self.ou..self.ou.checked_add(8)?)?;
        let longueur = usize::try_from(u64::from_le_bytes(huit.try_into().ok()?)).ok()?;
        (longueur <= plus).then_some(longueur)
    }
}

/// **Poser un bloc relu page par page** dans `vers`, effacé d'abord : une
/// page nulle de l'état l'est aussi après.
pub(crate) fn poser_les_pages(vers: &mut [u8], pages: &[(usize, &[u8])]) {
    vers.fill(0);
    for &(rang, page) in pages {
        vers[rang * PAGE..rang * PAGE + page.len()].copy_from_slice(page);
    }
}

/// **Ce que les tests de chaque périphérique partagent** : écrire un état,
/// le relire en entier, et vérifier qu'aucune coupure ne se relit.
#[cfg(test)]
pub(crate) mod essais {
    use super::{Ecrivain, Lecteur};

    /// Les octets d'un état.
    pub(crate) fn octets_de<T>(valeur: &T, sauver: impl Fn(&T, &mut Ecrivain)) -> Vec<u8> {
        let mut e = Ecrivain(Vec::new());
        sauver(valeur, &mut e);
        e.0
    }

    /// Relu jusqu'au dernier octet, ou rien.
    pub(crate) fn relu<T>(octets: &[u8], relire: impl Fn(&mut Lecteur) -> Option<T>) -> Option<T> {
        let mut l = Lecteur::nouveau(octets);
        let valeur = relire(&mut l)?;
        l.au_bout().then_some(valeur)
    }

    /// **Aucune coupure ne se relit** : chaque préfixe strict est refusé.
    pub(crate) fn chaque_coupure_refusee<T>(
        octets: &[u8],
        relire: impl Fn(&mut Lecteur) -> Option<T>,
    ) {
        for longueur in 0..octets.len() {
            let mut l = Lecteur::nouveau(&octets[..longueur]);
            assert!(
                relire(&mut l).is_none(),
                "coupé à {longueur} octets sur {}",
                octets.len()
            );
        }
    }

    /// Un état abîmé par `abimer`, puis sauvé : se relit-il ?
    pub(crate) fn se_relit<T: Clone>(
        valeur: &T,
        abimer: impl FnOnce(&mut T),
        sauver: impl Fn(&T, &mut Ecrivain),
        relire: impl Fn(&mut Lecteur) -> Option<T>,
    ) -> bool {
        let mut abime = valeur.clone();
        abimer(&mut abime);
        relu(&octets_de(&abime, sauver), relire).is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **Les pages** : un bloc qui ne tombe pas sur une page entière, des
    /// pages nulles sautées, et chaque refus.
    #[test]
    fn a_block_by_pages_reads_back_and_refuses_what_is_wrong() {
        let mut bloc = vec![0u8; 3 * PAGE + 100];
        bloc[5] = 1;
        bloc[3 * PAGE + 99] = 7;
        let mut e = Ecrivain(Vec::new());
        e.pages(&bloc);
        assert_eq!(e.0.len(), 8 + 1 + PAGE + 100, "deux pages nulles sautées");
        let mut l = Lecteur::nouveau(&e.0);
        assert_eq!(l.longueur_des_pages(usize::MAX), Some(bloc.len()));
        assert_eq!(
            l.longueur_des_pages(bloc.len() - 1),
            None,
            "au-delà de la borne"
        );
        let pages = l.pages(bloc.len()).expect("relu");
        assert!(l.au_bout());
        let mut relu = vec![0xEE; bloc.len()];
        poser_les_pages(&mut relu, &pages);
        assert_eq!(relu, bloc);

        assert!(
            Lecteur::nouveau(&e.0).pages(bloc.len() + 1).is_none(),
            "une autre longueur"
        );
        assert!(
            Lecteur::nouveau(&e.0[..e.0.len() - 1])
                .pages(bloc.len())
                .is_none(),
            "tronqué"
        );
        let mut au_dela = e.0.clone();
        au_dela[8] |= 1 << 5; // la page 5 n'existe pas
        assert!(
            Lecteur::nouveau(&au_dela).pages(bloc.len()).is_none(),
            "un bit de trop"
        );
    }

    /// **Les petits champs** : un booléen qui n'est ni zéro ni un, une valeur
    /// absente qui n'est pas nulle, un compte au-delà de sa borne.
    #[test]
    fn small_fields_refuse_what_was_not_written_by_the_writer() {
        let mut e = Ecrivain(Vec::new());
        e.peut_etre_u8(Some(3));
        e.peut_etre_u8(None);
        e.peut_etre_u64(Some(9));
        e.peut_etre_u64(None);
        e.compte(4);
        e.octets(b"abc");
        let mut l = Lecteur::nouveau(&e.0);
        assert_eq!(l.peut_etre_u8(), Some(Some(3)));
        assert_eq!(l.peut_etre_u8(), Some(None));
        assert_eq!(l.peut_etre_u64(), Some(Some(9)));
        assert_eq!(l.peut_etre_u64(), Some(None));
        assert_eq!(l.compte(4), Some(4));
        assert_eq!(l.octets(3), Some(&b"abc"[..]));
        assert!(l.au_bout());

        assert_eq!(Lecteur::nouveau(&[2]).oui(), None, "ni zéro ni un");
        assert_eq!(
            Lecteur::nouveau(&[0, 5]).peut_etre_u8(),
            None,
            "absent mais pas nul"
        );
        let mut quatre = Ecrivain(Vec::new());
        quatre.compte(5);
        assert_eq!(
            Lecteur::nouveau(&quatre.0).compte(4),
            None,
            "au-delà de la borne"
        );
    }
}
