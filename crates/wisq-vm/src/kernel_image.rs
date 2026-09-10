//! **Ce qu'on vient de nous tendre : du code, ou une archive ?**
//!
//! Un `vmlinuz` de distribution est un **bzImage** : un talon d'amorçage en
//! mode réel, puis le vrai noyau **compressé**. Les octets qui suivent le talon
//! ne sont pas des instructions, ce sont des données.
//!
//! **Le piège, payé une fois.** L'outil de couverture de l'émetteur a été lancé
//! sur le `vmlinuz-lts` d'Alpine tel qu'il se télécharge. Il a rendu 106 entrées
//! de fonction et 6,6 % de régions compilées, là où la feuille de route en cite
//! 10 116 et 98,2 %. Rien n'avait régressé : l'outil décodait du gzip comme si
//! c'était du x86, et rendait un nombre qui *ressemblait* à une mesure. Sur la
//! charge utile décompressée, les deux chiffres se sont retrouvés à l'octet
//! près.
//!
//! Un nombre faux qui a l'air d'un nombre est pire qu'un refus, et c'est la
//! faute que ce dépôt documente partout ailleurs. D'où ce module : la question
//! est posée **avant** de mesurer, et la réponse dit où est la charge utile.

/// Ce qu'un fichier de noyau est réellement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KernelImage {
    /// Un ELF : le code est là, tel quel, prêt à être décodé.
    Elf,
    /// Un bzImage : le vrai noyau est plus loin, et compressé.
    Compressed {
        how: Compression,
        /// Où commence la charge utile, en octets depuis le début du fichier.
        at: usize,
    },
    /// Un bzImage dont on ne reconnaît pas la compression. Il faut le dire
    /// plutôt que de laisser croire que c'est du code : le talon en mode réel
    /// se décode en x86 parfaitement valide, et parfaitement dénué de sens.
    CompressedUnknown,
    /// Autre chose : ni ELF, ni bzImage.
    Unknown,
}

/// Les compressions que le noyau sait produire, avec le nombre magique qui les
/// ouvre. `Lzma` est le canard boiteux — ses trois octets sont trop communs
/// pour être cherchés en aveugle, et il n'est donc reconnu qu'à l'endroit où le
/// talon s'arrête.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Compression {
    Gzip,
    Xz,
    Zstd,
    Bzip2,
    Lz4,
    Lzo,
}

impl Compression {
    const fn magic(self) -> &'static [u8] {
        match self {
            Compression::Gzip => &[0x1f, 0x8b, 0x08],
            Compression::Xz => &[0xfd, b'7', b'z', b'X', b'Z', 0x00],
            Compression::Zstd => &[0x28, 0xb5, 0x2f, 0xfd],
            Compression::Bzip2 => b"BZh",
            Compression::Lz4 => &[0x02, 0x21, 0x4c, 0x18],
            Compression::Lzo => &[0x89, b'L', b'Z', b'O'],
        }
    }

    /// Le nom que l'utilisateur reconnaîtra dans un message.
    pub const fn name(self) -> &'static str {
        match self {
            Compression::Gzip => "gzip",
            Compression::Xz => "xz",
            Compression::Zstd => "zstd",
            Compression::Bzip2 => "bzip2",
            Compression::Lz4 => "lz4",
            Compression::Lzo => "lzo",
        }
    }
}

/// **L'ancre du bzImage**, et pourquoi elle est indispensable.
///
/// `HdrS` à l'offset `0x202` est le champ `header` de la structure d'amorçage
/// Linux. Sans cette ancre, chercher un nombre magique de compression dans un
/// fichier quelconque trouverait n'importe quoi : trois octets `1f 8b 08`
/// apparaissent par hasard tous les seize mégaoctets environ. Ancré, le même
/// nombre magique désigne la charge utile.
const SETUP_MAGIC: &[u8; 4] = b"HdrS";
const SETUP_MAGIC_AT: usize = 0x202;

/// Le nombre magique d'un ELF, quelle que soit sa classe.
const ELF_MAGIC: &[u8; 4] = b"\x7fELF";

/// Ce que ce fichier est.
pub fn recognise(bytes: &[u8]) -> KernelImage {
    if bytes.starts_with(ELF_MAGIC) {
        return KernelImage::Elf;
    }
    if bytes.len() <= SETUP_MAGIC_AT + SETUP_MAGIC.len()
        || &bytes[SETUP_MAGIC_AT..SETUP_MAGIC_AT + 4] != SETUP_MAGIC
    {
        return KernelImage::Unknown;
    }
    // Un bzImage. La charge utile est **le premier** nombre magique trouvé après
    // l'en-tête : chercher le plus petit décalage plutôt que le premier de la
    // liste, sans quoi l'ordre de l'énumération déciderait du résultat sur un
    // fichier qui contient plusieurs motifs.
    let mut best: Option<(Compression, usize)> = None;
    for how in [
        Compression::Gzip,
        Compression::Xz,
        Compression::Zstd,
        Compression::Bzip2,
        Compression::Lz4,
        Compression::Lzo,
    ] {
        if let Some(at) = find(bytes, how.magic(), SETUP_MAGIC_AT) {
            if best.is_none_or(|(_, seen)| at < seen) {
                best = Some((how, at));
            }
        }
    }
    match best {
        Some((how, at)) => KernelImage::Compressed { how, at },
        None => KernelImage::CompressedUnknown,
    }
}

fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if from >= haystack.len() {
        return None;
    }
    haystack[from..]
        .windows(needle.len())
        .position(|window| window == needle)
        .map(|at| at + from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bz_image(payload_at: usize, magic: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0x90u8; payload_at.max(SETUP_MAGIC_AT + 4)];
        bytes[SETUP_MAGIC_AT..SETUP_MAGIC_AT + 4].copy_from_slice(SETUP_MAGIC);
        bytes.resize(payload_at, 0x90);
        bytes.extend_from_slice(magic);
        bytes.extend_from_slice(&[0u8; 64]);
        bytes
    }

    /// Un ELF est du code, et se lit tel quel.
    #[test]
    fn an_elf_is_read_as_it_is() {
        let mut bytes = ELF_MAGIC.to_vec();
        bytes.extend_from_slice(&[0u8; 64]);
        assert_eq!(recognise(&bytes), KernelImage::Elf);
    }

    /// **La garde qui compte.** Un bzImage ne doit jamais passer pour du code :
    /// c'est exactement ce qui a rendu 6,6 % là où la vérité est 98,2 %.
    #[test]
    fn a_bz_image_is_never_mistaken_for_code() {
        let bytes = bz_image(0x5000, Compression::Gzip.magic());
        assert_eq!(
            recognise(&bytes),
            KernelImage::Compressed {
                how: Compression::Gzip,
                at: 0x5000
            }
        );
    }

    /// Les six compressions, chacune à sa place.
    #[test]
    fn each_compression_is_named_by_its_own_magic() {
        for how in [
            Compression::Gzip,
            Compression::Xz,
            Compression::Zstd,
            Compression::Bzip2,
            Compression::Lz4,
            Compression::Lzo,
        ] {
            let bytes = bz_image(0x4000, how.magic());
            assert_eq!(
                recognise(&bytes),
                KernelImage::Compressed { how, at: 0x4000 },
                "{} n'est pas reconnu",
                how.name()
            );
        }
    }

    /// **L'ancre, et ce qu'elle empêche.** Trois octets `1f 8b 08` dans un
    /// fichier qui n'est pas un bzImage n'en font pas une archive. Sans
    /// l'ancre `HdrS`, ce test-ci rendrait `Compressed` sur du bruit.
    #[test]
    fn a_compression_magic_without_the_setup_header_proves_nothing() {
        let mut bytes = vec![0x90u8; 0x4000];
        bytes.extend_from_slice(Compression::Gzip.magic());
        assert_eq!(recognise(&bytes), KernelImage::Unknown);
    }

    /// Un bzImage dont la compression n'est pas reconnue le dit, plutôt que de
    /// se faire passer pour du code.
    #[test]
    fn a_bz_image_with_no_known_payload_still_refuses_to_look_like_code() {
        let mut bytes = vec![0x90u8; SETUP_MAGIC_AT + 4];
        bytes[SETUP_MAGIC_AT..SETUP_MAGIC_AT + 4].copy_from_slice(SETUP_MAGIC);
        bytes.extend_from_slice(&[0x90u8; 4096]);
        assert_eq!(recognise(&bytes), KernelImage::CompressedUnknown);
    }

    /// **La charge utile est la première, pas celle que l'énumération nomme en
    /// premier.** Un noyau xz contient souvent des octets `BZh` plus loin ;
    /// prendre le premier de la liste au lieu du plus proche donnerait une
    /// compression fausse et un décalage encore plus faux.
    #[test]
    fn the_payload_is_the_nearest_magic_not_the_first_one_listed() {
        let mut bytes = bz_image(0x1000, Compression::Xz.magic());
        bytes.extend_from_slice(&[0x90u8; 4096]);
        bytes.extend_from_slice(Compression::Bzip2.magic());
        assert_eq!(
            recognise(&bytes),
            KernelImage::Compressed {
                how: Compression::Xz,
                at: 0x1000
            }
        );
    }

    /// Un fichier trop court pour porter l'ancre n'est pas un bzImage.
    #[test]
    fn a_file_too_short_for_the_anchor_is_not_a_bz_image() {
        assert_eq!(recognise(&[0x90u8; 16]), KernelImage::Unknown);
        assert_eq!(recognise(&[]), KernelImage::Unknown);
    }
}

/// **Un segment `PT_LOAD` d'un noyau ELF : où il vit, et ce qu'il porte.**
///
/// Les deux tailles ne sont pas la même chose, et les confondre coûte cher.
/// `file_size` est ce que le fichier porte ; `memory_size` est ce que le
/// segment occupe une fois chargé. L'écart est le BSS — des zéros que le
/// noyau attend et qu'aucun octet du fichier ne décrit. Le vmlinux d'Alpine
/// en traîne cinq mébioctets.
///
/// `physical_address` est celle à laquelle un chargeur pose le segment ;
/// `virtual_address` est celle à laquelle il a été lié. Pour le texte d'un
/// noyau x86-64 les deux diffèrent de `__START_KERNEL_map`, et le code de
/// démarrage passe de l'une à l'autre en cours de route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Load {
    /// Où le segment commence dans le fichier.
    pub offset: u64,
    /// L'adresse à laquelle il a été lié.
    pub virtual_address: u64,
    /// L'adresse à laquelle un chargeur le pose.
    pub physical_address: u64,
    /// Ce que le fichier en porte.
    pub file_size: u64,
    /// Ce qu'il occupe en mémoire — jamais moins que `file_size`.
    pub memory_size: u64,
}

/// **Le point d'entrée et tous les segments chargeables d'un ELF64.**
///
/// `None` quand ce n'est pas un ELF64 petit-boutiste, quand les en-têtes de
/// programme ne tiennent pas dans le fichier, ou quand un segment prétend
/// porter plus d'octets que le fichier n'en a. Ce dernier cas mérite d'être
/// refusé plutôt que tronqué : servir les octets d'à côté donnerait un noyau
/// qui démarre et se perd plus loin, ce qui est la panne la plus chère à
/// diagnostiquer.
///
/// **Tous les segments, pas seulement celui qui porte l'entrée.** Le montage
/// de `--example kernel-entry` n'en posait qu'un, et `secondary_startup_64`
/// chargeait son pointeur de pile depuis un `initial_stack` qui n'était nulle
/// part : RSP valait zéro et les empilements descendaient en négatif.
#[must_use]
pub fn loads(bytes: &[u8]) -> Option<(u64, Vec<Load>)> {
    if !bytes.starts_with(ELF_MAGIC) || bytes.len() < 64 {
        return None;
    }
    // Classe 64 bits, et petit-boutiste : tout le reste de cette lecture en
    // dépend, et le supposer donnerait des décalages qui ont l'air de nombres.
    if bytes[4] != 2 || bytes[5] != 1 {
        return None;
    }
    let word = |at: usize| -> Option<u64> {
        Some(u64::from_le_bytes(bytes.get(at..at + 8)?.try_into().ok()?))
    };
    let half = |at: usize| -> Option<u16> {
        Some(u16::from_le_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
    };
    let entry = word(24)?;
    let table = usize::try_from(word(32)?).ok()?;
    let size = usize::from(half(54)?);
    let count = usize::from(half(56)?);
    if size < 56 {
        return None;
    }
    let mut segments = Vec::new();
    for index in 0..count {
        let at = table.checked_add(index.checked_mul(size)?)?;
        bytes.get(at..at + 56)?;
        let kind = u32::from_le_bytes(bytes.get(at..at + 4)?.try_into().ok()?);
        if kind != 1 {
            continue; // ce n'est pas un PT_LOAD
        }
        let load = Load {
            offset: word(at + 8)?,
            virtual_address: word(at + 16)?,
            physical_address: word(at + 24)?,
            file_size: word(at + 32)?,
            memory_size: word(at + 40)?,
        };
        // Ce que le fichier prétend porter doit y être. Sinon on servirait les
        // octets d'à côté, ou rien.
        let end = load.offset.checked_add(load.file_size)?;
        if end > bytes.len() as u64 || load.memory_size < load.file_size {
            return None;
        }
        segments.push(load);
    }
    Some((entry, segments))
}
