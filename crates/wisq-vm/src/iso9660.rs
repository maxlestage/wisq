//! **Lire ce qu'il y a dans une image de disque optique.**
//!
//! Quelqu'un arrive avec `omarchy-4.0.2.iso` et veut le faire tourner. wisq
//! refusait, en disant lui-même quoi faire : « s'il y a un noyau là-dedans, il
//! est **dedans**, sous `/boot`, avec son initramfs ». Ce module va le
//! chercher.
//!
//! **Conçu sur un vrai ISO**, `alpine-virt 3.20.3`, parcouru avant qu'une
//! ligne soit écrite. Trois choses y ont été mesurées plutôt que supposées :
//!
//! * les noms lisibles viennent de **Rock Ridge**, une extension rangée dans
//!   la zone d'usage système de chaque enregistrement. Sans elle, un chemin
//!   ressemble à `/BOOT/VMLINUZ_.VIR;1` et aucune recette de démarrage ne
//!   parle ce dialecte. Joliet, l'autre extension, n'est pas nécessaire.
//! * le noyau est un bzImage ordinaire, que le reconnaisseur de ce dépôt
//!   accepte déjà — il n'y a pas de second problème derrière la porte.
//! * l'image porte **sa propre recette** : `syslinux.cfg` et `grub.cfg`
//!   donnent le chemin du noyau, celui de l'initramfs, **et la ligne de
//!   commande**. C'est ce dernier point qui décide de la forme de ce module :
//!   une ligne de commande devinée démarre un noyau incapable de trouver sa
//!   racine, et la panne tombe très loin de sa cause.
//!
//! Rien ici ne tient l'image entière : une image d'installation pèse des
//! gibioctets, et un téléphone n'a pas ça. Le lecteur demande des tranches à
//! une source, et chaque taille qu'il lit dans le fichier passe par un
//! plafond avant de devenir une allocation.

/// **La source des octets.** Un fichier, une tranche en mémoire, un descripteur
/// — le lecteur ne veut savoir qu'une chose : rendre exactement ces octets-là,
/// ou rien.
///
/// « Ou rien » est la moitié qui compte. Une source qui rendrait une lecture
/// courte en silence ferait interpréter du bourrage comme une structure.
pub trait Bytes {
    fn read(&self, at: u64, into: &mut [u8]) -> bool;
}

impl Bytes for &[u8] {
    fn read(&self, at: u64, into: &mut [u8]) -> bool {
        let Ok(at) = usize::try_from(at) else {
            return false;
        };
        let Some(end) = at.checked_add(into.len()) else {
            return false;
        };
        if end > self.len() {
            return false;
        }
        into.copy_from_slice(&self[at..end]);
        true
    }
}

/// La taille d'un secteur, et le seul multiple que le format emploie. Le
/// descripteur la déclare tout de même, et on la lit plutôt que de la croire.
const SECTOR: usize = 2048;

/// **Le plafond d'un répertoire.** Sa taille est un entier de trente-deux bits
/// venu du fichier, donc de n'importe où. Quatre mébioctets tiennent des
/// dizaines de milliers d'entrées ; au-delà, c'est une image qui ment ou une
/// image qu'on ne saura pas servir, et les deux se refusent pareil.
const DIRECTORY_CEILING: u32 = 4 << 20;

/// La profondeur au-delà de laquelle on cesse de descendre. ISO 9660 en permet
/// huit ; Rock Ridge lève la limite, mais un chemin plus profond que ça dans
/// une image d'installation est un cycle, pas une arborescence.
const DEPTH_CEILING: usize = 16;

/// Une entrée : un fichier ou un répertoire, avec où il commence et ce qu'il
/// pèse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// Le nom lisible — celui de Rock Ridge quand il existe, sinon celui du
    /// champ ISO, débarrassé de son numéro de version.
    pub name: String,
    /// Le secteur où le contenu commence.
    pub start: u32,
    /// Sa longueur en octets.
    pub size: u32,
    pub directory: bool,
}

/// Une image ouverte : son bloc, son étiquette, et sa racine.
pub struct Iso<B: Bytes> {
    source: B,
    label: String,
    root: Entry,
}

impl<B: Bytes> Iso<B> {
    /// Ouvre une image, ou rend `None` si ce n'en est pas une.
    ///
    /// Les descripteurs de volume commencent au secteur seize et se suivent
    /// jusqu'à un terminateur. On cherche le descripteur **principal**, celui
    /// de type un : c'est lui qui porte la racine.
    pub fn open(source: B) -> Option<Self> {
        let mut sector = [0u8; SECTOR];
        for index in 16..32u64 {
            if !source.read(index * SECTOR as u64, &mut sector) {
                return None;
            }
            if &sector[1..6] != b"CD001" {
                return None;
            }
            match sector[0] {
                // Le descripteur principal.
                1 => {
                    // **La taille de bloc est lue, pas supposée.** Le format
                    // en autorise d'autres ; ce lecteur n'en sert qu'une, et
                    // il vaut mieux refuser franchement une image exotique que
                    // lire ses structures de travers.
                    let block = u16::from_le_bytes([sector[128], sector[129]]);
                    if block as usize != SECTOR {
                        return None;
                    }
                    let label = String::from_utf8_lossy(&sector[40..72])
                        .trim_end()
                        .to_string();
                    let root = Self::entry(&sector[156..190])?.1;
                    return Some(Iso {
                        source,
                        label,
                        root,
                    });
                }
                // Le terminateur : il n'y a plus rien à lire.
                255 => return None,
                _ => {}
            }
        }
        None
    }

    /// L'étiquette de volume, telle que le graveur l'a écrite.
    pub fn volume_label(&self) -> &str {
        &self.label
    }

    pub fn root(&self) -> &Entry {
        &self.root
    }

    /// La source, telle qu'elle a été donnée.
    ///
    /// **Rendue pour qu'un test puisse la regarder.** Un plafond qui empêche
    /// une allocation ne se voit pas dans le verdict — la lecture échouerait
    /// de toute façon sur une image courte — mais il se voit dans ce que le
    /// lecteur *demande*. Sans cet accès, la garde n'était tenue par rien.
    pub fn source(&self) -> &B {
        &self.source
    }

    /// Le contenu d'un répertoire. Vide si l'entrée n'en est pas un, ou si sa
    /// taille est celle d'une image qui ment.
    pub fn list(&self, directory: &Entry) -> Vec<Entry> {
        if !directory.directory || directory.size > DIRECTORY_CEILING {
            return Vec::new();
        }
        let mut data = vec![0u8; directory.size as usize];
        if !self
            .source
            .read(u64::from(directory.start) * SECTOR as u64, &mut data)
        {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut at = 0usize;
        while at < data.len() {
            let length = data[at] as usize;
            if length == 0 {
                // Un zéro dit « le reste de ce secteur est du bourrage » : un
                // enregistrement ne chevauche jamais deux secteurs, donc le
                // suivant commence au secteur d'après. Avancer d'un octet
                // ici lirait le bourrage comme une structure.
                at = (at / SECTOR + 1) * SECTOR;
                continue;
            }
            let Some(end) = at.checked_add(length) else {
                break;
            };
            if end > data.len() {
                break;
            }
            if let Some((special, entry)) = Self::entry(&data[at..end]) {
                // Les deux premières entrées de tout répertoire sont lui-même
                // et son parent, nommées par un octet nul et un octet un. Les
                // rendre ferait tourner en rond n'importe quel parcours.
                if !special {
                    out.push(entry);
                }
            }
            at = end;
        }
        out
    }

    /// L'entrée à ce chemin, ou rien.
    ///
    /// Le chemin est absolu et se compare **sans égard à la casse** : une
    /// image écrit ses noms comme elle veut, et une recette de démarrage les
    /// cite comme elle veut aussi.
    pub fn find(&self, path: &str) -> Option<Entry> {
        let mut at = self.root.clone();
        for (depth, part) in path.split('/').filter(|part| !part.is_empty()).enumerate() {
            if depth >= DEPTH_CEILING {
                return None;
            }
            at = self
                .list(&at)
                .into_iter()
                .find(|entry| entry.name.eq_ignore_ascii_case(part))?;
        }
        Some(at)
    }

    /// Les octets d'un fichier, ou rien si le plafond ne les laisse pas passer.
    ///
    /// **Refuser plutôt que tronquer.** Un noyau amputé se compile, se charge,
    /// et meurt dans une instruction qui n'a rien à voir ; un refus se lit.
    pub fn read(&self, entry: &Entry, ceiling: usize) -> Option<Vec<u8>> {
        if entry.directory || entry.size as usize > ceiling {
            return None;
        }
        let mut out = vec![0u8; entry.size as usize];
        self.source
            .read(u64::from(entry.start) * SECTOR as u64, &mut out)
            .then_some(out)
    }

    /// Un enregistrement de répertoire. Rend aussi s'il désigne le répertoire
    /// lui-même ou son parent.
    fn entry(record: &[u8]) -> Option<(bool, Entry)> {
        if record.len() < 33 {
            return None;
        }
        let start = u32::from_le_bytes(record[2..6].try_into().ok()?);
        let size = u32::from_le_bytes(record[10..14].try_into().ok()?);
        let directory = record[25] & 2 != 0;
        let name_length = record[32] as usize;
        let name_at = 33usize;
        let name_end = name_at.checked_add(name_length)?;
        if name_end > record.len() {
            return None;
        }
        let raw = &record[name_at..name_end];
        let special = raw == [0] || raw == [1];
        // La zone d'usage système suit le nom, après un octet de bourrage
        // quand la longueur du nom est paire.
        let system_at = name_end + (name_length + 1) % 2;
        let name = match rock_ridge_name(record.get(system_at..).unwrap_or(&[])) {
            Some(name) => name,
            // Le champ ISO porte un numéro de version après un point-virgule.
            // Le garder ferait chercher `vmlinuz;1` à une recette qui écrit
            // `vmlinuz`.
            None => {
                let text = String::from_utf8_lossy(raw);
                text.split(';').next().unwrap_or("").to_string()
            }
        };
        Some((
            special,
            Entry {
                name,
                start,
                size,
                directory,
            },
        ))
    }
}

/// **Le nom que Rock Ridge donne**, s'il en donne un.
///
/// La zone d'usage système est une suite d'entrées à deux lettres. Celle qui
/// nous intéresse est `NM` ; son cinquième octet porte des drapeaux, dont un
/// qui dit « le nom continue dans l'entrée suivante ».
fn rock_ridge_name(system: &[u8]) -> Option<String> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at + 4 <= system.len() {
        let length = system[at + 2] as usize;
        // Une longueur nulle ferait tourner cette boucle sans fin ; une
        // longueur qui déborde ferait lire à côté.
        if length < 4 || at + length > system.len() {
            break;
        }
        if &system[at..at + 2] == b"NM" && length > 5 {
            // Le bit 1 des drapeaux marque « courant » et « parent » — deux
            // noms qui ne sont pas des noms. Les prendre ferait apparaître des
            // entrées nommées vides.
            if system[at + 4] & 0b110 != 0 {
                return None;
            }
            out.extend_from_slice(&system[at + 5..at + length]);
        }
        at += length;
    }
    (!out.is_empty()).then(|| String::from_utf8_lossy(&out).into_owned())
}

/// **La recette de démarrage que l'image porte.**
///
/// Le chargeur d'amorçage de la distribution est un fichier texte, et il dit
/// exactement ce qu'il faut : quel noyau, quel initramfs, et avec quels
/// arguments. On le lit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Recipe {
    pub kernel: String,
    pub initrd: Option<String>,
    pub command_line: String,
    /// Le fichier d'où tout ça vient. **Il est rendu pour que l'écran puisse
    /// le nommer** : quand un démarrage tourne mal, savoir quelle recette a
    /// servi vaut mieux que la deviner.
    pub from: String,
}

/// Les endroits où une recette se trouve, dans l'ordre où on les essaie.
///
/// **Les entrées `systemd-boot` d'abord.** Un `archiso.cfg` de la famille Arch
/// se compose d'`INCLUDE` qui pointent d'autres fichiers ; une entrée de
/// chargeur, elle, tient en cinq lignes sans indirection. Quand les deux
/// existent, la seconde répond mieux à la même question.
const WHERE: [&str; 8] = [
    "/loader/entries",
    "/boot/syslinux/syslinux.cfg",
    "/boot/syslinux/isolinux.cfg",
    "/isolinux/isolinux.cfg",
    "/syslinux/syslinux.cfg",
    "/boot/grub/grub.cfg",
    "/EFI/BOOT/grub.cfg",
    "/arch/boot/syslinux/archiso_sys.cfg",
];

/// Le plafond d'un fichier de configuration. Une recette fait quelques
/// centaines d'octets ; un mébioctet laisse toute la marge du monde et arrête
/// une image qui pointerait un fichier énorme sous ce nom.
const RECIPE_CEILING: usize = 1 << 20;

impl Recipe {
    /// Lit une recette dans le texte d'un fichier de chargeur.
    ///
    /// **Publique parce qu'un dialecte se juge sans image.** Bâtir un ISO
    /// entier pour vérifier qu'une ligne `linux` est comprise ferait payer
    /// deux cents lignes de gréement à chaque dialecte ajouté.
    pub fn read(text: &str, from: &str) -> Option<Recipe> {
        parse(text, from)
    }

    /// Cherche une recette dans l'image, et rend la première qui nomme un
    /// noyau.
    pub fn of<B: Bytes>(iso: &Iso<B>) -> Option<Recipe> {
        for place in WHERE {
            let Some(entry) = iso.find(place) else {
                continue;
            };
            let candidates: Vec<(String, Entry)> = if entry.directory {
                iso.list(&entry)
                    .into_iter()
                    .filter(|child| !child.directory && child.name.ends_with(".conf"))
                    .map(|child| (format!("{place}/{}", child.name), child))
                    .collect()
            } else {
                vec![(place.to_string(), entry)]
            };
            for (path, entry) in candidates {
                let Some(bytes) = iso.read(&entry, RECIPE_CEILING) else {
                    continue;
                };
                let text = String::from_utf8_lossy(&bytes);
                if let Some(recipe) = parse(&text, &path) {
                    return Some(recipe);
                }
            }
        }
        None
    }
}

/// Lire une recette, quel que soit le chargeur qui l'a écrite.
///
/// Les trois dialectes disent la même chose avec des mots différents, et un
/// seul lecteur les couvre : on cherche le mot-clé en tête de ligne, sans
/// égard à la casse, et on prend le reste.
///
/// | | noyau | initramfs | arguments |
/// | --- | --- | --- | --- |
/// | syslinux, isolinux | `KERNEL`, `LINUX` | `INITRD` | `APPEND` |
/// | grub | `linux` | `initrd` | à la suite du noyau |
/// | systemd-boot | `linux` | `initrd` | `options` |
///
/// Grub et systemd-boot emploient tous deux `linux`, et ne rangent pas les
/// arguments au même endroit : grub les met sur la ligne du noyau, l'autre sur
/// une ligne à part. Prendre les deux couvre les deux.
fn parse(text: &str, from: &str) -> Option<Recipe> {
    let mut kernel = None;
    let mut initrd = None;
    let mut command_line = String::new();
    for line in text.lines() {
        let line = line.trim();
        let Some((word, rest)) = line.split_once(char::is_whitespace) else {
            continue;
        };
        let rest = rest.trim();
        match word.to_ascii_uppercase().as_str() {
            "KERNEL" | "LINUX" | "LINUXEFI" => {
                // Grub écrit le noyau et ses arguments sur la même ligne.
                let (path, arguments) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
                kernel = Some(absolute(path));
                if !arguments.trim().is_empty() {
                    command_line = arguments.trim().to_string();
                }
            }
            "INITRD" | "INITRDEFI" => {
                // Une ligne `initrd` peut en citer plusieurs, séparés par des
                // virgules ; wisq n'en charge qu'un, et prendre le premier en
                // silence serait un mensonge par omission — on prend la ligne
                // telle quelle et l'appelant verra qu'elle n'est pas un chemin.
                initrd = Some(absolute(rest));
            }
            "APPEND" | "OPTIONS" => command_line = rest.to_string(),
            _ => {}
        }
    }
    kernel.map(|kernel| Recipe {
        kernel,
        initrd,
        command_line,
        from: from.to_string(),
    })
}

/// Un chemin de recette est parfois relatif à la racine de l'image et parfois
/// écrit avec sa barre. Les deux désignent la même chose.
fn absolute(path: &str) -> String {
    let path = path.trim();
    if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    }
}
