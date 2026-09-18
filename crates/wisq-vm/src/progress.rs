//! **Dire ce qu'on a mesuré quand la machine ne s'arrête sur rien.**
//!
//! Pendant dix-huit tranches, chaque relevé du noyau se terminait sur une
//! instruction manquante, et le mur avait un nom. Depuis #228 il n'y en a plus
//! sur le chemin parcouru : le budget de tours s'épuise, et le pilote
//! concluait « la machine avançait encore ».
//!
//! **Cette phrase n'était tenue par rien.** Elle se déduisait du seul fait que
//! le budget s'était épuisé sans qu'une adresse manque — exactement ce qu'une
//! boucle qui tourne sans progresser produit aussi. Le relevé de #228 se
//! termine dans `jent_entropy_init`, qui mesure la gigue d'horloge et boucle
//! jusqu'à ce que ses tests statistiques passent : si le TSC ne bouge pas
//! assez, elle ne finit jamais. Avancer et tourner en rond se ressemblent
//! beaucoup, vus depuis un compteur de tours.
//!
//! Ce module **ne tranche pas**. Il énonce deux faits que le pilote sait déjà
//! compter et n'imprimait pas :
//!
//! - le tour où la machine a atteint pour la dernière fois une adresse qu'elle
//!   n'avait jamais atteinte, et donc combien de tours ont suivi sans rien de
//!   neuf ;
//! - combien d'adresses distinctes le dernier dixième du budget a visitées.
//!
//! **Pourquoi il ne conclut pas** : une boucle chaude légitime — un `memcpy`
//! long, un tri — n'ouvre pas de terrain neuf non plus, et son dernier dixième
//! est étroit. Conclure « ronde » sur ces deux chiffres serait remplacer une
//! affirmation non tenue par une autre. Les chiffres, eux, sont décisifs pour
//! qui lit : six adresses distinctes sur neuf cent mille tours ne se lisent pas
//! comme un `memcpy`.

/// Ce qu'une exécution a ouvert comme terrain, et ce qu'elle a fait après.
///
/// Les quatre nombres viennent du pilote JavaScript, qui n'est jugé par rien.
/// `of` est donc la porte : elle refuse ce qu'aucune exécution n'aurait pu
/// produire plutôt que de mettre en forme un comptage cassé — un relevé qui
/// parle d'aplomb à partir de nombres incohérents est pire que pas de relevé.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    turns: usize,
    last_new: Option<usize>,
    distinct: usize,
    distinct_at_the_end: usize,
}

impl Progress {
    /// Le dernier dixième du budget, en tours. C'est la fenêtre sur laquelle
    /// `distinct_at_the_end` est compté ; le nom vit ici pour que le pilote et
    /// le relevé ne puissent pas en prendre deux différentes.
    #[must_use]
    pub fn tail(turns: usize) -> usize {
        turns / 10
    }

    /// **Tous les combien le pilote doit dire où il en est**, en tours.
    ///
    /// Les quatre nombres de `Progress` ne sortent qu'à la fin. #262 a mesuré
    /// ce que ça coûte : un relevé lancé à quarante millions de tours a tourné
    /// **deux heures à 99,8 % de processeur sans imprimer une ligne**, et il
    /// n'y avait aucun moyen de dire s'il avançait ou s'il tournait en rond —
    /// la question même que #229 a appris à poser.
    ///
    /// La période tire entre deux bornes contraires. **Jamais un déluge** :
    /// deux cents lignes au plus, sinon le relevé noie ses propres lignes de
    /// traduction. **Jamais muet** : un relevé assez long pour qu'on se pose la
    /// question doit répondre sans attendre sa fin. Le plancher garde les
    /// relevés courts tranquilles — à mille tours la machine a fini avant
    /// qu'on ait eu le temps de se demander quoi que ce soit.
    ///
    /// Le nombre vit ici, et pas dans le pilote, pour que le JavaScript
    /// engendré et le test qui le tient ne puissent pas en prendre deux
    /// différents — la même raison que `tail`.
    #[must_use]
    pub fn beat(turns: usize) -> usize {
        /// Sous ce budget, le relevé final suffit : la machine a déjà fini.
        const QUIET: usize = 1 << 10;
        /// Le plus grand nombre de lignes qu'un relevé a le droit d'imprimer.
        const MOST: usize = 200;
        QUIET.max(turns / MOST)
    }

    /// Refuse tout ce qu'une seule exécution n'aurait pas pu produire.
    #[must_use]
    pub fn of(
        turns: usize,
        last_new: Option<usize>,
        distinct: usize,
        distinct_at_the_end: usize,
    ) -> Option<Self> {
        if turns == 0 {
            return None;
        }
        if distinct_at_the_end > distinct {
            return None;
        }
        match last_new {
            // Un tour qui porte une adresse neuve est un tour du relevé, et
            // cette adresse compte dans le total.
            Some(turn) if turn > turns || distinct == 0 => return None,
            None if distinct != 0 => return None,
            _ => {}
        }
        Some(Self {
            turns,
            last_new,
            distinct,
            distinct_at_the_end,
        })
    }

    /// La phrase du relevé — des faits, et pas de verdict.
    #[must_use]
    pub fn describe(&self) -> String {
        let Some(last) = self.last_new else {
            return format!(
                "aucune adresse n'a jamais été neuve sur les {} tours : la machine \
                 n'est sortie de rien",
                self.turns
            );
        };
        let after = self.turns - last;
        // **La dernière adresse neuve tombe dans le dernier dixième.** Le
        // budget est ce qui a arrêté la machine, pas la machine qui s'est
        // arrêtée : elle ouvrait encore du terrain quand on l'a coupée.
        if after <= Self::tail(self.turns) {
            return format!(
                "la machine ouvrait encore du terrain quand le budget l'a coupée : \
                 sa dernière adresse neuve est au tour {last} sur {}, et le dernier \
                 dixième a visité {} adresses distinctes sur {} en tout",
                self.turns, self.distinct_at_the_end, self.distinct
            );
        }
        format!(
            "plus aucune adresse neuve depuis le tour {last} sur {} — les {after} tours \
             suivants n'ont visité que {} adresses distinctes, sur {} vues en tout",
            self.turns, self.distinct_at_the_end, self.distinct
        )
    }
}
