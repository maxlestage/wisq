//! **Nommer une adresse du noyau, avec sa carte des symboles.**
//!
//! `--example kernel-entry` disait « rip 0xffffffff81000642 », et personne ne
//! pouvait le lire. La feuille de route a donc porté, pendant toute une
//! tranche, un « on ne sait pas si ce `jmp .` est un chemin d'erreur ou une
//! boucle de parking » — alors que la carte du noyau exact était dans l'ISO
//! d'Alpine depuis le début. L'adresse se nomme `__startup_64 + 658` : le
//! rembourrage que le compilateur pose **après** le retour de la fonction.
//!
//! Ce module ne fait donc pas gagner de vitesse ; il rend un relevé lisible.
//! Un diagnostic qu'on ne sait pas lire n'est pas un diagnostic — le dépôt
//! l'avait déjà payé une fois, avec un chiffre imprimé avant des dizaines de
//! milliers de lignes de journal.
//!
//! **Le format lu est celui de `System.map`** : une adresse en hexadécimal, un
//! type d'une lettre, un nom. Les lignes illisibles sont sautées plutôt que
//! fatales — c'est du texte produit par une chaîne de compilation, et refuser
//! tout le fichier pour une ligne ne servirait personne.

/// Les symboles d'un noyau, rangés pour qu'on puisse chercher dedans.
#[derive(Debug, Default, Clone)]
pub struct Symbols {
    /// Triés par adresse. **Le tri est fait ici et non supposé** : un
    /// `System.map` n'est ordonné que par convention, et un résolveur qui
    /// parcourt les lignes dans l'ordre du fichier nommerait d'après le mauvais
    /// voisin — en silence, ce qui est la pire façon de se tromper.
    entries: Vec<(u64, String)>,
}

impl Symbols {
    /// Lit une carte. Ce qui ne ressemble pas à « adresse type nom » est sauté.
    #[must_use]
    pub fn parse(text: &str) -> Self {
        let mut entries: Vec<(u64, String)> = text
            .lines()
            .filter_map(|line| {
                let mut fields = line.split_whitespace();
                let address = u64::from_str_radix(fields.next()?, 16).ok()?;
                let _kind = fields.next()?;
                Some((address, fields.next()?.to_string()))
            })
            .collect();
        entries.sort_by_key(|(address, _)| *address);
        Self { entries }
    }

    /// Le symbole qui couvre cette adresse, et de combien elle le dépasse.
    ///
    /// `None` sous le premier symbole : il n'y a rien à nommer, et rendre le
    /// premier avec un décalage énorme serait une réponse fausse là où « je ne
    /// sais pas » est la bonne.
    #[must_use]
    pub fn nearest(&self, address: u64) -> Option<(&str, u64)> {
        let at = self.entries.partition_point(|(a, _)| *a <= address);
        let (start, name) = self.entries.get(at.checked_sub(1)?)?;
        Some((name.as_str(), address - start))
    }

    /// L'adresse, et son nom s'il y en a un — la forme qu'un relevé imprime.
    #[must_use]
    pub fn describe(&self, address: u64) -> String {
        match self.nearest(address) {
            Some((name, 0)) => format!("0x{address:x} ({name})"),
            Some((name, offset)) => format!("0x{address:x} ({name} + {offset})"),
            None => format!("0x{address:x}"),
        }
    }

    /// Vrai quand la carte ne porte rien — un fichier absent, vide ou illisible.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}
