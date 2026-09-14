//! **Une proportion qui ne touche ses bornes que quand elle les a atteintes.**
//!
//! Le relevé de couverture imprimait « 100.0 % de succès » sous une ligne
//! annonçant 641 octets refusés, et douze opcodes nommés juste en dessous. Le
//! calcul était juste : 2 932 212 sur 2 932 853 vaut 99,978 %, qui s'arrondit
//! à 100,0 au dixième. La **phrase**, elle, était fausse — elle disait que le
//! décodeur lit tout.
//!
//! Ce n'est pas un défaut d'arrondi, c'est un défaut de sens. Trois décimales
//! de plus ne le corrigeraient pas : elles repousseraient le seuil sans le
//! supprimer, et un relevé à 99,9999 % finirait par arrondir à cent le jour où
//! il ne reste qu'un octet refusé — le jour précisément où ce dernier octet
//! est ce qu'on cherche.
//!
//! **Ce qui manquait est une réserve, pas une précision.** `100 %` dit quelque
//! chose qu'aucun arrondi ne doit pouvoir dire : *il n'en reste aucun*. Et la
//! même chose vaut en bas : `0 %` dit *aucun n'est passé*.
//!
//! Le relevé rendait ces deux affirmations indiscernables de leurs voisines,
//! et il le faisait dans le même fichier :
//!
//! ```text
//! décodage linéaire : …                     soit 100.0 % de succès   ← arrondi
//! régions depuis les cibles de `call` : …   0 refusées (100.0 %)     ← exact
//! ```
//!
//! C'est la parenté de #229 : là, un pilote concluait « la machine avançait
//! encore » à partir d'un fait qui ne le portait pas ; ici, une mise en forme
//! conclut « tout est lu » à partir d'un quotient qui ne le porte pas non
//! plus. Dans les deux cas le nombre est exact et la lecture est fausse.

/// Ce qu'une mesure a réussi et ce qu'elle a refusé, avec de quoi le dire sans
/// prétendre à une borne qu'elle n'a pas atteinte.
///
/// Les deux comptes viennent d'une boucle de sonde. `of` est la porte : elle
/// refuse une mesure vide plutôt que de rendre `NaN`, qu'un `{:.1}` imprime
/// « NaN » et qu'un lecteur pressé prend pour un défaut du décodeur.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rate {
    hit: u64,
    missed: u64,
}

impl Rate {
    /// Refuse une mesure qui n'a rien compté.
    ///
    /// Zéro sur zéro n'est pas « zéro pour cent » : c'est une sonde qui n'a
    /// pas tourné, et les deux ne se corrigent pas pareil.
    #[must_use]
    pub fn of(hit: u64, missed: u64) -> Option<Self> {
        if hit == 0 && missed == 0 {
            return None;
        }
        Some(Self { hit, missed })
    }

    /// La part de réussite, en clair, à `decimals` décimales.
    ///
    /// **Les deux bornes sont réservées.** `100 %` n'est rendu que si rien
    /// n'est refusé, `0 %` que si rien n'est réussi — sans décimale ni dans un
    /// cas ni dans l'autre, pour qu'un lecteur voie du premier coup d'œil
    /// qu'il ne lit pas un arrondi. Entre les deux, la proportion est
    /// **rabattue** vers l'intérieur si l'arrondi l'emmenait sur une borne :
    /// `99,978 %` s'écrit « 99,9 % », pas « 100,0 % ».
    ///
    /// Rabattre plutôt qu'ajouter des décimales est un choix. Une décimale de
    /// plus ne supprime pas le seuil, elle le déplace : un relevé à 99,9999 %
    /// finirait par arrondir à cent le jour où il ne reste qu'un octet
    /// refusé — le jour précisément où ce dernier octet est ce qu'on cherche.
    /// La précision demandée règle donc la finesse de lecture, pas la règle,
    /// et le rabat suit la précision : au centième, la borne haute est 99,99.
    #[must_use]
    pub fn describe(&self, decimals: usize) -> String {
        if self.missed == 0 {
            return "100 %".to_string();
        }
        if self.hit == 0 {
            return "0 %".to_string();
        }
        let total = self.hit as f64 + self.missed as f64;
        let share = 100.0 * self.hit as f64 / total;
        // Le plus petit pas visible à cette précision. C'est lui qui sépare
        // « presque rien » de « rien », et « presque tout » de « tout ».
        let step = 10f64.powi(-(decimals as i32));
        // `{:.n}` arrondit au plus proche : au dixième, 99,978 donnerait 100,0
        // et 0,03 donnerait 0,0. Les deux sont exactement ce que ce module
        // refuse, donc la valeur est rabattue **avant** la mise en forme, pas
        // corrigée après.
        let clamped = share.clamp(step, 100.0 - step);
        format!("{clamped:.decimals$} %").replace('.', ",")
    }
}
