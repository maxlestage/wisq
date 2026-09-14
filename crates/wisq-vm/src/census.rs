//! **Combien de pointeurs hauts une image de noyau porte, et pourquoi ça se
//! recompte plutôt que se cite.**
//!
//! `docs/DEMARRAGE.md` argumente que le repli d'adresses par masque ne mènera
//! jamais un noyau Linux là où il s'attend à vivre, et il l'appuie sur un
//! comptage : dans l'image de référence, dix fois plus de mots valent une
//! adresse noyau haute (`0xffffffff8…`) qu'une adresse de chargement physique.
//!
//! **L'argument tenait ; les deux nombres publiés, non.** Le texte annonçait
//! 122 994 et 11 933 sous la phrase « Ce n'est pas une supposition, c'est une
//! mesure », sans dire par quelle commande. Aucune définition plausible ne les
//! reproduit : le préfixe exact donne 122 970, la borne `>= 0xffffffff80000000`
//! en donne 134 984, et les bandes basses essayées vont de 515 à 36 081.
//!
//! Ce module est la commande qui manquait. Il ne rend pas les nombres publiés
//! plus vrais : il rend la mesure **refaisable**, ce qui est la seule chose
//! qu'un chiffre de ce genre puisse offrir.
//!
//! **Les deux bandes, et pourquoi elles sont étroites.**
//!
//! - *Haute* : les mots dont les trente-six bits de tête valent `0xffffffff8`.
//!   C'est l'espace du texte et des données du noyau x86-64, de
//!   `0xffffffff80000000` à `0xffffffff8fffffff`. Le quartet suivant, `9`, sort
//!   de la fenêtre où l'image de référence range quoi que ce soit.
//! - *Basse* : les mots de `[0x1000000, 0x4000000)`. L'image de référence entre
//!   à `0x1000090`, et la borne haute laisse la place aux soixante-quatre
//!   mébioctets par défaut sans mordre sur ce qui n'est plus un chargement.
//!
//! **Les deux bandes sont disjointes par construction**, et un test le tient :
//! un même mot ne peut pas gonfler les deux colonnes et fausser le rapport que
//! le document en tire.

/// Ce qu'une image porte comme mots, et ce que ces mots valent.
///
/// `of` est la porte : une image trop courte pour un seul mot aligné n'est pas
/// une mesure à zéro, c'est une absence de mesure. Rendre `Census { high: 0 }`
/// laisserait un relevé imprimer « aucun pointeur haut » sur un fichier vide et
/// faire croire au lecteur que le noyau ne vit pas en haut.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Census {
    words: usize,
    tail: usize,
    high: usize,
    low: usize,
}

impl Census {
    /// **Les quatre bornes sont publiques pour qu'un test puisse les lire.**
    ///
    /// Une première version les gardait privées et le test affirmait leur
    /// disjonction sur des littéraux recopiés à côté. Un sabotage qui déplaçait
    /// le plafond bas par-dessus la bande haute passait au travers : le test
    /// comparait deux nombres écrits dans le test, pas les bornes du module.
    /// Une assertion sur une copie n'est pas une assertion sur l'original.
    pub const HIGH_FLOOR: u64 = 0xffff_ffff_8000_0000;
    pub const HIGH_CEILING: u64 = 0xffff_ffff_8fff_ffff;
    /// Là où l'image de référence entre (`0x1000090`), et jusqu'où un
    /// chargement physique reste plausible.
    pub const LOW_FLOOR: u64 = 0x0100_0000;
    pub const LOW_CEILING: u64 = 0x0400_0000;

    /// Compte les deux bandes sur les mots de huit octets alignés depuis le
    /// début de l'image. Rend `None` si l'image n'en porte aucun.
    pub fn of(bytes: &[u8]) -> Option<Self> {
        let words = bytes.len() / 8;
        if words == 0 {
            return None;
        }
        let mut high = 0;
        let mut low = 0;
        for chunk in bytes.chunks_exact(8) {
            let word = u64::from_le_bytes(chunk.try_into().expect("huit octets exactement"));
            if (Self::HIGH_FLOOR..=Self::HIGH_CEILING).contains(&word) {
                high += 1;
            } else if (Self::LOW_FLOOR..Self::LOW_CEILING).contains(&word) {
                low += 1;
            }
        }
        Some(Self {
            words,
            tail: bytes.len() - words * 8,
            high,
            low,
        })
    }

    /// Les mots entiers examinés.
    pub fn words(&self) -> usize {
        self.words
    }

    /// Les octets de queue qui ne font pas un mot, nommés plutôt que tus : un
    /// relevé qui les passe sous silence laisse croire qu'il a tout lu.
    pub fn tail(&self) -> usize {
        self.tail
    }

    /// Les mots valant une adresse noyau haute.
    pub fn high(&self) -> usize {
        self.high
    }

    /// Les mots valant une adresse de chargement physique plausible.
    pub fn low(&self) -> usize {
        self.low
    }
}
