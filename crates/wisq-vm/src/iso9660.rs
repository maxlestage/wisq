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

/// **L'image, lue sur le disque, jamais tenue en mémoire.**
///
/// C'est la seule forme que le téléphone puisse employer : une image
/// d'installation pèse des gibioctets. Elle vit ici plutôt que chez ses
/// appelants — l'exemple et l'ABI C en avaient chacun une copie, et deux
/// copies d'un lecteur de fichier finissent par ne plus ouvrir de la même
/// façon.
pub struct OnDisk(std::cell::RefCell<std::fs::File>);

impl OnDisk {
    pub fn open(path: &std::path::Path) -> Option<Self> {
        std::fs::File::open(path)
            .ok()
            .map(|file| OnDisk(std::cell::RefCell::new(file)))
    }
}

impl Bytes for OnDisk {
    fn read(&self, at: u64, into: &mut [u8]) -> bool {
        use std::io::{Read, Seek, SeekFrom};
        let mut file = self.0.borrow_mut();
        file.seek(SeekFrom::Start(at)).is_ok() && file.read_exact(into).is_ok()
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

    /// **Le même contenu, écrit au fil de l'eau.**
    ///
    /// `read` rend un `Vec` : commode pour un fichier de configuration de deux
    /// cents octets, ruineux pour un initramfs de cent mébioctets sur un
    /// téléphone. Celle-ci ne tient jamais plus d'une tranche à la fois.
    ///
    /// Rend faux **sans avoir fini d'écrire** quand la lecture échoue en
    /// chemin : l'appelant doit alors jeter ce qu'il a reçu. Un fichier à
    /// moitié écrit qu'on croirait entier est exactement le défaut que le
    /// plafond de `read` évite ailleurs.
    pub fn copy(&self, entry: &Entry, sink: &mut impl std::io::Write, ceiling: u64) -> bool {
        if entry.directory || u64::from(entry.size) > ceiling {
            return false;
        }
        let mut chunk = vec![0u8; 1 << 16];
        let mut done = 0u64;
        while done < u64::from(entry.size) {
            let want = chunk.len().min((u64::from(entry.size) - done) as usize);
            let at = u64::from(entry.start) * SECTOR as u64 + done;
            if !self.source.read(at, &mut chunk[..want]) {
                return false;
            }
            if sink.write_all(&chunk[..want]).is_err() {
                return false;
            }
            done += want as u64;
        }
        true
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
    /// Le ou les initramfs, **séparés par une espace** et dans l'ordre où le
    /// chargeur les poserait (voir `join_initrds`).
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
///
/// **`/boot/isolinux/` manquait**, et c'est là que Void Linux et Tiny Core
/// rangent la leur : leurs deux images étaient refusées faute de recette,
/// alors qu'elles en portent une de trois lignes.
///
/// **`/boot/grub2/` aussi**, le dossier de grub chez Fedora et ses parents :
/// Fedora Workstation 44 y range sa recette, et son `/EFI/BOOT/grub.cfg`
/// ne fait que la relire par `configfile`.
const WHERE: [&str; 10] = [
    "/loader/entries",
    "/boot/syslinux/syslinux.cfg",
    "/boot/syslinux/isolinux.cfg",
    "/boot/isolinux/isolinux.cfg",
    "/isolinux/isolinux.cfg",
    "/syslinux/syslinux.cfg",
    "/boot/grub/grub.cfg",
    "/boot/grub2/grub.cfg",
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
        parse_entries(text, from, &|_| None).map(|(recipe, _)| recipe)
    }

    /// Lit une recette **comme dans une image**, sans en bâtir une : `file`
    /// rend le texte d'un fichier de l'image, `names` les noms d'un dossier,
    /// et `label` est l'étiquette du volume. C'est ce que fait [`Recipe::of`],
    /// les trois venant de l'image ; publique pour la même raison que
    /// [`Recipe::read`].
    pub fn read_in(
        text: &str,
        from: &str,
        label: &str,
        file: &dyn Fn(&str) -> Option<String>,
        names: &dyn Fn(&str) -> Vec<String>,
    ) -> Option<Recipe> {
        let mut seen = vec![from.to_string()];
        let text = sourced(text, base_of(from), file, &mut seen, 0);
        let resolve = |kernel: &str| resolved(kernel, names);
        let (mut recipe, guessed) = parse_entries(&text, from, &resolve)?;
        if guessed {
            recipe.command_line = with_label(&recipe.command_line, &text, label);
        }
        recipe.command_line = with_antix_device(&recipe.command_line, &recipe.kernel, label);
        Some(recipe)
    }

    /// Cherche une recette dans l'image, et rend la première qui nomme un
    /// noyau.
    pub fn of<B: Bytes>(iso: &Iso<B>) -> Option<Recipe> {
        let file = |path: &str| {
            let entry = iso.find(path).filter(|entry| !entry.directory)?;
            let bytes = iso.read(&entry, RECIPE_CEILING)?;
            Some(String::from_utf8_lossy(&bytes).into_owned())
        };
        let names = |path: &str| {
            iso.find(path)
                .filter(|entry| entry.directory)
                .map(|entry| {
                    iso.list(&entry)
                        .into_iter()
                        .filter(|child| !child.directory)
                        .map(|child| child.name)
                        .collect()
                })
                .unwrap_or_default()
        };
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
                if let Some(recipe) =
                    Recipe::read_in(&text, &path, iso.volume_label(), &file, &names)
                {
                    return Some(recipe);
                }
            }
        }
        None
    }
}

/// **Grub lit d'autres fichiers**, et la recette peut être dans l'un d'eux.
///
/// Le `grub.cfg` d'Artix ne porte aucune ligne `linux` : il définit des
/// fonctions, puis écrit `source /boot/grub/kernels.cfg`, et c'est là que
/// sont les entrées. Chaque `source` ou `configfile` dont le chemin est écrit
/// en clair est remplacé par le texte du fichier, à sa place — l'ordre des
/// entrées reste celui que grub verrait.
///
/// Un chemin qui passe par une variable (`source /boot/grub/locales/${1}`)
/// reste tel quel : sa valeur n'existe qu'au moment où grub l'exécute. Un
/// fichier déjà lu ne l'est pas deux fois — `menu_reload` relit `grub.cfg`
/// lui-même —, et quatre niveaux suffisent à toute image vue.
///
/// **Syslinux aussi.** Tails écrit `kernel vesamenu.c32` puis `append
/// live64.cfg` dans `isolinux.cfg` : le « noyau » est le module de menu, et
/// le menu est dans `live64.cfg`, qui lit `menu.cfg` par `include`. Les
/// `include` et `config` de syslinux, et un `append` qui ne nomme qu'un
/// fichier `.cfg`, sont suivis de même, depuis le dossier de la recette.
fn sourced(
    text: &str,
    base: &str,
    file: &dyn Fn(&str) -> Option<String>,
    seen: &mut Vec<String>,
    depth: usize,
) -> String {
    let mut out = String::with_capacity(text.len());
    for line in text.lines() {
        let mut words = line.split_whitespace();
        let command = words.next().unwrap_or("").to_ascii_lowercase();
        let word = words.next().unwrap_or("").trim_matches('"');
        // Le périphérique devant le chemin, `($root)/boot/grub2/grub.cfg`
        // chez Fedora, est l'image elle-même : il tombe avant qu'on juge si
        // le chemin passe par une variable.
        let path = absolute(word, base);
        let literal = words.next().is_none() && path.len() > 1 && !path.contains('$');
        let follows = match command.as_str() {
            "source" | "configfile" | "include" | "config" => true,
            "append" => word.to_ascii_lowercase().ends_with(".cfg"),
            _ => false,
        };
        if follows && literal && depth < 4 && !seen.contains(&path) {
            seen.push(path.clone());
            if let Some(inner) = file(&path) {
                out.push_str(&sourced(&inner, base, file, seen, depth + 1));
                out.push('\n');
                continue;
            }
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// **Un noyau dont le nom passe par une variable**, trouvé sur le disque.
///
/// Artix écrit `linux /boot/vmlinuz-$2`, et `$2` vaut ce qu'une boucle `for`
/// a assemblé — `x86_64` suivi des arguments. Lire la boucle reviendrait à
/// écrire un interprète de grub. Mais le fichier, lui, est là : le dossier
/// `/boot` porte un seul nom qui commence par `vmlinuz-`. **Un seul**, sinon
/// rien : entre deux noyaux, choisir serait deviner, et une entrée de plus
/// loin dans le fichier aura peut-être un nom en clair.
fn resolved(kernel: &str, names: &dyn Fn(&str) -> Vec<String>) -> Option<String> {
    let (folder, name) = kernel.rsplit_once('/')?;
    if folder.contains('$') {
        return None;
    }
    let prefix = &name[..name.find('$')?];
    if prefix.is_empty() {
        return None;
    }
    let mut matching = names(folder)
        .into_iter()
        .filter(|candidate| candidate.starts_with(prefix));
    let found = matching.next()?;
    matching
        .next()
        .is_none()
        .then(|| format!("{folder}/{found}"))
}

/// **L'argument qui nomme le support**, gardé quand le reste n'a pu être lu.
///
/// Un système « live » cherche au démarrage le disque d'où il vient, et le
/// reconnaît à son étiquette : `label=ARTIX_202608`, `archisolabel=…`,
/// `CDLABEL=…`. Quand grub assemble la ligne par ses variables, wisq ne peut
/// pas la recalculer ; mais cet argument-là y est écrit en toutes lettres,
/// parce qu'il ne dépend de rien, et sans lui l'initramfs ne trouve jamais
/// sa racine. Il est repris du texte, s'il y figure, une seule fois.
fn with_label(command_line: &str, text: &str, label: &str) -> String {
    let mut words: Vec<String> = command_line
        .split_whitespace()
        .map(str::to_string)
        .collect();
    if label.trim().is_empty() {
        return words.join(" ");
    }
    for word in text.split(|c: char| c.is_whitespace() || c == '"' || c == ';') {
        let Some((key, value)) = word.split_once('=') else {
            continue;
        };
        let key_ok = !key.is_empty()
            && key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'));
        if key_ok && value == label && !words.iter().any(|known| known == word) {
            words.push(word.to_string());
        }
    }
    words.join(" ")
}

/// **antiX reconnaît son support à son étiquette**, puisqu'il ne le trouve
/// pas tout seul sur un disque virtio.
///
/// L'`init` d'antiX — celui de MX Linux et d'antiX, reconnus à leur noyau
/// rangé dans `/antiX/` — trie les périphériques par numéro majeur et ne
/// garde que ceux des CD, des clés et des disques qu'il connaît. Le disque
/// virtio reçoit un majeur dynamique qui n'est pas dans la liste, même avec
/// `from=all` : MX s'arrêtait sur « No all devices found », son disque
/// pourtant présent. `blab=<étiquette>` lui fait chercher le volume par son
/// nom, sans passer par ce tri. Rien n'est ajouté quand l'image désigne déjà
/// son support, ni pour une étiquette qui contient une espace.
fn with_antix_device(command_line: &str, kernel: &str, label: &str) -> String {
    let named = command_line.split_whitespace().any(|word| {
        ["blab=", "blabel=", "bootlabel=", "buuid=", "bootuuid=", "bdev=", "bootdev="]
            .iter()
            .any(|key| word.starts_with(key))
    });
    let label = label.trim();
    if !kernel.starts_with("/antiX/") || named || label.is_empty() || label.contains(char::is_whitespace) {
        return command_line.to_string();
    }
    let line = command_line.trim();
    if line.is_empty() {
        format!("blab={label}")
    } else {
        format!("{line} blab={label}")
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
/// Les entrées d'un fichier de chargeur, dans l'ordre.
///
/// **Un fichier en porte plusieurs, et c'est tout le sujet.** Le `grub.cfg`
/// d'Omarchy en a quatre : Arch, Arch avec lecteur d'écran, un mode de secours,
/// et memtest. Un mot d'ouverture — `menuentry` chez grub, `LABEL` chez
/// syslinux — commence la suivante.
///
/// Ce qui précède la première est une entrée aussi : c'est ce qui fait qu'une
/// entrée `systemd-boot`, qui n'a **aucun** mot d'ouverture et occupe son
/// fichier entier, se lit sans cas particulier.
fn entries(text: &str) -> Vec<&str> {
    let mut cuts = vec![0usize];
    for line in text.lines() {
        let word = line.split_whitespace().next().unwrap_or("");
        if matches!(word.to_ascii_uppercase().as_str(), "MENUENTRY" | "LABEL") {
            let at = line.as_ptr() as usize - text.as_ptr() as usize;
            if at != 0 {
                cuts.push(at);
            }
        }
    }
    cuts.push(text.len());
    cuts.windows(2)
        .map(|pair| &text[pair[0]..pair[1]])
        .filter(|block| !block.trim().is_empty())
        .collect()
}

/// Lire une recette, quel que soit le chargeur qui l'a écrite.
///
/// **La première entrée qui nomme un noyau gagne.** Les distributions mettent
/// leur défaut en tête — Arch le dit même deux fois, par `default=archlinux` et
/// par la place de l'entrée —, et prendre la première est la règle la plus
/// simple qui rende ce que la personne aurait obtenu en démarrant l'image.
///
/// **Honorer `default=` explicitement n'est pas fait**, et c'est un choix : ça
/// ajouterait un dialecte de plus (l'identifiant vit dans `--id` chez grub,
/// dans le nom du `LABEL` chez syslinux) pour départager des cas où les deux
/// règles s'accordent déjà. Le jour où une image les fera diverger, ce sera un
/// défaut nommé, avec son image pour le montrer.
///
/// Rendu avec la recette : **le nom du noyau a-t-il été trouvé sur le
/// disque** plutôt que lu (voir `resolved`). Une entrée dont le noyau ne se
/// lit ni ne se trouve est passée, et la suivante a sa chance.
fn parse_entries(
    text: &str,
    from: &str,
    resolve: &dyn Fn(&str) -> Option<String>,
) -> Option<(Recipe, bool)> {
    entries(text).into_iter().find_map(|block| {
        let recipe = one(block, from)?;
        if !recipe.kernel.contains('$') {
            return Some((recipe, false));
        }
        let kernel = resolve(&recipe.kernel)?;
        Some((Recipe { kernel, ..recipe }, true))
    })
}

/// Une entrée, et elle seule.
///
/// **Rien ne traverse d'une entrée à l'autre.** C'est la garde : le premier jet
/// lisait le fichier entier d'un trait, gardait le dernier `linux` et le
/// dernier `initrd`, et rendait le noyau de memtest avec l'initramfs d'Arch et
/// les arguments d'une troisième entrée. Une machine construite là-dessus part
/// sur le mauvais cœur, et le refus qu'elle affiche ne parle de rien de tout ça.
///
/// Les trois dialectes disent la même chose avec des mots différents, et un
/// seul lecteur les couvre : on cherche le mot-clé en tête de ligne, sans égard
/// à la casse, et on prend le reste.
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
fn one(text: &str, from: &str) -> Option<Recipe> {
    let base = base_of(from);
    let mut kernel = None;
    let mut initrd = None;
    let mut command_line = String::new();
    let parameters = positional(text);
    for line in logical_lines(text) {
        let line = with_parameters(line.trim(), &parameters);
        let line = line.trim();
        let Some((word, rest)) = line.split_once(char::is_whitespace) else {
            continue;
        };
        let rest = rest.trim();
        match word.to_ascii_uppercase().as_str() {
            "KERNEL" | "LINUX" | "LINUXEFI" => {
                // Grub écrit le noyau et ses arguments sur la même ligne.
                let (path, arguments) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
                // **Un module de syslinux n'est pas un noyau.** `kernel
                // vesamenu.c32` ouvre un menu (Tails) ; le prendre pour le
                // noyau démarrait le menu de syslinux sur le cœur x86.
                if path.to_ascii_lowercase().ends_with(".c32") {
                    continue;
                }
                kernel = Some(absolute(path, base));
                if !arguments.trim().is_empty() {
                    command_line = arguments.trim().to_string();
                }
            }
            "INITRD" | "INITRDEFI" => {
                // **Plusieurs initramfs, et plusieurs lignes.** Grub en cite
                // plusieurs sur une ligne — les microcodes puis l'initramfs,
                // chez Artix —, syslinux les sépare par des virgules, et une
                // entrée systemd-boot écrit une ligne par fichier. Tous sont
                // gardés, dans l'ordre : le chargeur les pose bout à bout, et
                // c'est ainsi que le noyau les lit.
                initrd = join_initrds(initrd, rest, base);
            }
            "APPEND" | "OPTIONS" => command_line = rest.to_string(),
            _ => {}
        }
    }
    // **L'initramfs dans les arguments**, la forme d'origine de syslinux :
    // `APPEND initrd=/boot/initrd root=…`. C'est celle de Void Linux. Sans
    // ligne `INITRD`, le mot est pris pour ce qu'il dit, et retiré de la
    // ligne : un noyau démarré directement n'en fait rien, et le laisser
    // ferait croire qu'il a servi.
    if initrd.is_none() {
        let (named, others): (Vec<&str>, Vec<&str>) = command_line
            .split_whitespace()
            .partition(|word| word.starts_with("initrd="));
        if !named.is_empty() {
            for word in &named {
                initrd = join_initrds(initrd, &word["initrd=".len()..], base);
            }
            command_line = others.join(" ");
        }
    }
    kernel.map(|kernel| Recipe {
        kernel,
        initrd,
        command_line: without_unset(&command_line),
        from: from.to_string(),
    })
}

/// **Ce qu'une entrée de grub reçoit en `$1`, `$2`…** : son titre, puis les
/// mots écrits après lui sur la ligne `menuentry`, options `--…` exceptées.
///
/// Artix s'en sert pour nommer son noyau — `menuentry "…" "$title " {
/// linux /boot/vmlinuz-$2 }` —, et l'aide de grub le fait pour ses propres
/// menus. Les guillemets sont ceux du shell ; une entrée sans mot
/// d'ouverture (syslinux, systemd-boot) n'a pas de paramètres.
fn positional(text: &str) -> Vec<String> {
    let header = text.lines().next().unwrap_or("").trim_start();
    let Some(rest) = header.strip_prefix("menuentry") else {
        return Vec::new();
    };
    let rest = rest.split('{').next().unwrap_or("");
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote = None;
    let mut started = false;
    for c in rest.chars() {
        match (quote, c) {
            (None, '"' | '\'') => {
                quote = Some(c);
                started = true;
            }
            (Some(open), _) if c == open => quote = None,
            (None, c) if c.is_whitespace() => {
                if started {
                    words.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            _ => {
                current.push(c);
                started = true;
            }
        }
    }
    if started {
        words.push(current);
    }
    words.retain(|word| !word.starts_with("--"));
    words
}

/// Remplace `$1`, `${2}`… par les paramètres de l'entrée. Un numéro sans
/// paramètre reste écrit : c'est `without_unset` qui le fait tomber, comme
/// le reste de ce que grub ne trouverait pas.
fn with_parameters(line: &str, parameters: &[String]) -> String {
    if parameters.is_empty() || !line.contains('$') {
        return line.to_string();
    }
    let mut out = line.to_string();
    for (index, value) in parameters.iter().enumerate().rev() {
        let number = index + 1;
        out = out.replace(&format!("${{{number}}}"), value);
        out = out.replace(&format!("${number}"), value);
    }
    out
}

/// **Une variable que wisq n'a pas lue vaut rien**, comme chez grub pour une
/// variable qui n'est pas posée. `$kopts` et `${auto}` disparaissent de la
/// ligne au lieu d'arriver au noyau en toutes lettres, où ils ne veulent
/// rien dire ; un mot qui n'était qu'une variable disparaît avec elle.
fn without_unset(command_line: &str) -> String {
    command_line
        .split_whitespace()
        .map(|word| {
            let mut kept = String::with_capacity(word.len());
            let mut chars = word.chars().peekable();
            while let Some(c) = chars.next() {
                if c != '$' {
                    kept.push(c);
                    continue;
                }
                if chars.peek() == Some(&'{') {
                    for inner in chars.by_ref() {
                        if inner == '}' {
                            break;
                        }
                    }
                } else {
                    while chars
                        .peek()
                        .is_some_and(|next| next.is_ascii_alphanumeric() || *next == '_')
                    {
                        chars.next();
                    }
                }
            }
            kept
        })
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Ajoute à la liste les initramfs qu'une ligne cite.
///
/// **La liste est une chaîne, ses chemins séparés par une espace** : un
/// chemin de recette n'en porte jamais — grub et syslinux s'en servent
/// eux-mêmes comme séparateur —, et la frontière avec Swift reste une chaîne.
/// Une variable de grub (`$tuned_initrd`) n'est pas un fichier : elle tombe,
/// comme grub la remplace par rien quand elle n'est pas posée.
fn join_initrds(list: Option<String>, line: &str, base: &str) -> Option<String> {
    let mut paths: Vec<String> = list
        .map(|known| known.split(' ').map(str::to_string).collect())
        .unwrap_or_default();
    paths.extend(
        line.split(|c: char| c.is_whitespace() || c == ',')
            .filter(|word| !word.is_empty() && !word.starts_with('$'))
            .map(|word| absolute(word, base)),
    );
    (!paths.is_empty()).then(|| paths.join(" "))
}

/// Les lignes d'une entrée, **celles que grub coupe par `\` recollées**.
///
/// Le `grub.cfg` de Void écrit son noyau sur une ligne et ses arguments sur
/// les quatre suivantes. Lues une à une, la ligne du noyau finissait par une
/// barre oblique, prise pour un argument, et les vrais arguments étaient
/// perdus.
fn logical_lines(text: &str) -> Vec<String> {
    let mut lines = Vec::new();
    let mut pending = String::new();
    for line in text.lines() {
        // La suite d'une ligne coupée perd son retrait : il n'est que de la
        // mise en page, et il restait au milieu des arguments.
        let line = if pending.is_empty() {
            line
        } else {
            line.trim_start()
        };
        match line.trim_end().strip_suffix('\\') {
            Some(head) => {
                pending.push_str(head.trim_end());
                pending.push(' ');
            }
            None => {
                pending.push_str(line);
                lines.push(std::mem::take(&mut pending));
            }
        }
    }
    if !pending.is_empty() {
        lines.push(pending);
    }
    lines
}

/// Le chemin absolu, dans l'image, d'un chemin écrit par une recette.
///
/// **Le périphérique que grub écrit devant**, `(${voidlive})/boot/vmlinuz`
/// ou `($root)/vmlinuz`, nomme l'image elle-même : c'est celle qu'on lit. Il
/// est retiré ; sans ça, le chemin cherché commençait par une parenthèse.
///
/// **Un chemin relatif part du dossier de la recette chez syslinux**, pas de
/// la racine : c'est son répertoire courant. Mageia écrit `kernel
/// x86_64/vmlinuz` dans `/isolinux/isolinux.cfg`, et le noyau est en
/// `/isolinux/x86_64/vmlinuz` ; lu depuis la racine, il était introuvable et
/// l'image refusée. Grub et systemd-boot, eux, partent de la racine
/// (`base` vide).
fn absolute(path: &str, base: &str) -> String {
    let path = path.trim();
    let path = match path.strip_prefix('(').and_then(|rest| rest.split_once(')')) {
        Some((_, inside)) => inside,
        None => path,
    };
    if path.starts_with('/') {
        path.to_string()
    } else {
        format!("{base}/{path}")
    }
}

/// Le dossier d'où partent les chemins relatifs d'une recette : celui du
/// fichier pour syslinux et isolinux, la racine (`""`) pour les autres.
fn base_of(from: &str) -> &str {
    let syslinux = from.contains("/syslinux/")
        || from.contains("/isolinux/")
        || from.ends_with("syslinux.cfg")
        || from.ends_with("isolinux.cfg");
    match from.rsplit_once('/') {
        Some((parent, _)) if syslinux => parent,
        _ => "",
    }
}
