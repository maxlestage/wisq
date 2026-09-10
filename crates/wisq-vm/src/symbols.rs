//! **Nommer une adresse du noyau, avec sa carte des symboles.**
//!
//! `--example kernel-entry` disait « rip 0xffffffff81000642 », et personne ne
//! pouvait le lire. La feuille de route a donc porté, pendant toute une
//! tranche, un « on ne sait pas si ce `jmp .` est un chemin d'erreur ou une
//! boucle de parking » — alors que la carte du noyau exact était dans l'ISO
//! d'Alpine depuis le début. L'adresse se nomme `__startup_64 + 658` : le
//! `for (;;)` que le noyau écrit lui-même derrière une garde sur son argument
//! — un `eb fe`, saut sur lui-même. Le dépôt a d'abord lu ça comme du
//! rembourrage, et s'est trompé pendant deux tranches faute d'avoir demandé
//! **qui mène là**.
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

    /// **Nommer une adresse tenue en physique, avec une carte écrite en
    /// virtuel.**
    ///
    /// Le noyau démarre à son adresse **physique** : `X86BootLoader` le charge
    /// à `preferredAddress`, et le code de démarrage de Linux calcule l'adresse
    /// de `_text` par `%rip` parce qu'à ce moment-là la pagination n'est pas
    /// encore la sienne. `System.map`, lui, est écrit en virtuel. `map` est ce
    /// que Linux appelle `__START_KERNEL_map` et qui relie les deux.
    ///
    /// **L'addition ne doit être faite qu'une fois**, et c'est tout l'objet de
    /// cette fonction. Un même relevé porte les deux formes — le noyau bascule
    /// à l'adressage virtuel en cours de démarrage — et additionner une adresse
    /// déjà virtuelle ne rate pas franchement : ça déborde et ça rend un nom.
    /// `--example kernel-entry` a imprimé, sur une mesure,
    /// « phys_startup_64 + 18446744069414584494 » pour une adresse ordinaire.
    /// Un outil dont tout le métier est d'être lu ne peut pas se permettre ça.
    ///
    /// Le nom rendu porte l'adresse **telle qu'on la tient**, pas sa
    /// traduction : c'est celle qu'on relit dans un registre ou dans la RAM.
    /// **Au-delà de quoi un symbole ne nomme plus rien.**
    ///
    /// `nearest` rend le symbole juste en dessous, quelle que soit la distance.
    /// C'est ce qu'il faut pour une adresse de code ; c'est faux pour tout le
    /// reste. Un relevé imprime aussi des mots de pile, dont beaucoup ne sont
    /// pas des adresses — `0x10`, `0x0` — et chacun se voyait recoller un nom
    /// de symbole avec un décalage de plusieurs mébioctets. Un nom faux est
    /// pire qu'une adresse nue : personne ne relit un nombre à côté d'un nom
    /// pour vérifier qu'il est petit.
    ///
    /// Un mébioctet est très large pour une fonction — la plus grosse du noyau
    /// est cent fois plus petite — et c'est voulu : la borne est là pour écarter
    /// l'absurde, pas pour trancher au plus juste.
    const NAMES_WITHIN: u64 = 1 << 20;

    #[must_use]
    pub fn describe_loaded(&self, address: u64, map: u64) -> String {
        let virtual_address = if address >= map {
            address
        } else {
            address.wrapping_add(map)
        };
        match self.nearest(virtual_address) {
            Some((name, 0)) => format!("0x{address:x} ({name})"),
            Some((name, offset)) if offset < Self::NAMES_WITHIN => {
                format!("0x{address:x} ({name} + {offset})")
            }
            _ => format!("0x{address:x}"),
        }
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
