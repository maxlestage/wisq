//! Une machine de bureau, décrite pour libvirt.
//!
//! **Pourquoi ce fichier existe.** wisq sait afficher un bureau distant : SPICE
//! complet, le son, le presse-papiers, l'envoi de fichier, la tablette. Ce qu'il
//! ne savait pas faire, c'est **construire la machine qui montre ce bureau** à
//! partir d'une image. Quelqu'un qui apporte `omarchy-4.0.2.iso` devait écrire
//! lui-même un XML libvirt, connaître `virt-install`, choisir un modèle de
//! carte graphique et penser au mot de passe SPICE. C'est ce qui séparait « j'ai
//! une image » de « j'ai un bureau », et c'est tout ce que ce module fait.
//!
//! **Ce n'est pas l'émulateur local, et c'est délibéré.** L'interpréteur du
//! téléphone n'a pas de JIT — iOS ne le permet pas — et il rend une console
//! texte. Un bureau réel demande une accélération que seule la machine hôte a.
//! Ici, l'image tourne sur l'hôte avec son accélérateur (KVM sous Linux, HVF sur
//! un Mac), à vitesse réelle, et le téléphone en reçoit les pixels.
//!
//! **Le mot de passe n'est pas optionnel.** Un bureau SPICE ouvert sur le réseau
//! local sans mot de passe est un écran et un clavier offerts à qui passe. Le
//! domaine engendré en porte toujours un, tiré de la source aléatoire du système,
//! et il ne sort qu'une fois, sur le canal déjà authentifié.

use std::fmt::Write as _;
use std::path::Path;

/// Ce que la machine hôte sait accélérer.
///
/// Le type de domaine décide de tout le reste : `kvm` et `hvf` exécutent le code
/// invité sur le vrai processeur, `qemu` l'interprète — cent fois plus lentement,
/// ce qui rend un bureau injouable. On le lit dans les capacités plutôt que de le
/// deviner, et on n'échoue pas quand il n'y en a pas : un bureau lent reste un
/// bureau, et la personne mérite de le voir plutôt que de recevoir un refus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Accelerator {
    Kvm,
    Hvf,
    None,
}

impl Accelerator {
    pub fn domain_type(self) -> &'static str {
        match self {
            Accelerator::Kvm => "kvm",
            Accelerator::Hvf => "hvf",
            Accelerator::None => "qemu",
        }
    }

    /// Ce que `virsh capabilities` annonce.
    ///
    /// libvirt y liste un `<domain type='...'/>` par accélérateur disponible.
    /// L'ordre de préférence est celui de la vitesse ; `qemu` est toujours là et
    /// n'apprend donc rien.
    pub fn from_capabilities(text: &str) -> Accelerator {
        if text.contains("domain type='kvm'") || text.contains("domain type=\"kvm\"") {
            Accelerator::Kvm
        } else if text.contains("domain type='hvf'") || text.contains("domain type=\"hvf\"") {
            Accelerator::Hvf
        } else {
            Accelerator::None
        }
    }

    /// Ce qu'on dit à la personne quand il n'y a rien à accélérer.
    pub fn warning(self) -> Option<&'static str> {
        match self {
            Accelerator::None => Some(
                "aucune accélération sur cet hôte (ni KVM ni HVF) : le bureau tournera, \
                 mais lentement. Sous Linux, vérifiez /dev/kvm et votre appartenance au \
                 groupe kvm ; sur un Mac, libvirt 8.1 ou plus récent.",
            ),
            _ => None,
        }
    }
}

/// La carte graphique de l'invité.
///
/// **Deux modèles, deux mondes.** `virtio` est celui des compositeurs Wayland —
/// Hyprland, GNOME, KDE modernes — parce qu'il expose un vrai périphérique DRM.
/// `qxl` est le plus vieux et le plus doux pour SPICE en 2D, ce que veut un
/// bureau X11 léger. Se tromper ne casse pas la machine : elle démarre et
/// l'écran reste noir, ce qui est le symptôme le plus difficile à relier à sa
/// cause. D'où le choix, explicite, plutôt qu'un modèle unique.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Video {
    Virtio,
    Qxl,
}

impl Video {
    pub fn model(self) -> &'static str {
        match self {
            Video::Virtio => "virtio",
            Video::Qxl => "qxl",
        }
    }

    pub fn parse(name: &str) -> Option<Video> {
        match name {
            "virtio" => Some(Video::Virtio),
            "qxl" => Some(Video::Qxl),
            _ => None,
        }
    }
}

/// Tout ce qu'il faut pour écrire le domaine.
#[derive(Debug, Clone)]
pub struct Desktop {
    pub name: String,
    /// L'image d'installation, montée en lecteur optique et amorcée en premier.
    pub image: String,
    /// Le disque qcow2 où l'installation ira.
    pub disk: String,
    pub memory_mib: u32,
    pub cpus: u32,
    pub video: Video,
    /// L'adresse sur laquelle SPICE écoute. `0.0.0.0` pour que le téléphone
    /// l'atteigne — d'où le mot de passe, qui n'est pas négociable.
    pub listen: String,
    pub password: String,
    pub accelerator: Accelerator,
}

impl Desktop {
    /// Le domaine, tel que `virsh define` l'attend.
    ///
    /// **L'ordre d'amorçage est le cœur de l'affaire.** L'image d'abord, le
    /// disque ensuite : c'est ce qui fait apparaître l'installateur au premier
    /// démarrage, puis le système installé aux suivants — le disque devient
    /// amorçable et le BIOS le préfère dès qu'il porte un chargeur, sans qu'on
    /// ait à retoucher le domaine.
    pub fn xml(&self) -> String {
        let mut out = String::with_capacity(2048);
        let _ = writeln!(out, "<domain type='{}'>", self.accelerator.domain_type());
        let _ = writeln!(out, "  <name>{}</name>", escape(&self.name));
        let _ = writeln!(out, "  <title>{} — bureau wisq</title>", escape(&self.name));
        let _ = writeln!(
            out,
            "  <memory unit='MiB'>{}</memory>\n  <currentMemory unit='MiB'>{}</currentMemory>",
            self.memory_mib, self.memory_mib
        );
        let _ = writeln!(out, "  <vcpu placement='static'>{}</vcpu>", self.cpus);
        out.push_str("  <os>\n    <type arch='x86_64' machine='q35'>hvm</type>\n");
        out.push_str("    <boot dev='cdrom'/>\n    <boot dev='hd'/>\n  </os>\n");
        out.push_str("  <features>\n    <acpi/>\n    <apic/>\n  </features>\n");
        // Le processeur de l'hôte tel quel : un modèle générique retire les
        // instructions modernes, et un bureau qui s'en sert tombe sur une
        // instruction illégale au lieu de démarrer.
        out.push_str("  <cpu mode='host-passthrough' check='none'/>\n");
        out.push_str("  <clock offset='utc'/>\n");
        out.push_str("  <on_poweroff>destroy</on_poweroff>\n");
        out.push_str("  <on_reboot>restart</on_reboot>\n");
        out.push_str("  <devices>\n");
        let _ = writeln!(
            out,
            "    <disk type='file' device='disk'>\n      \
             <driver name='qemu' type='qcow2' discard='unmap'/>\n      \
             <source file='{}'/>\n      \
             <target dev='vda' bus='virtio'/>\n    </disk>",
            escape(&self.disk)
        );
        let _ = writeln!(
            out,
            "    <disk type='file' device='cdrom'>\n      \
             <driver name='qemu' type='raw'/>\n      \
             <source file='{}'/>\n      \
             <target dev='sda' bus='sata'/>\n      \
             <readonly/>\n    </disk>",
            escape(&self.image)
        );
        // Réseau en mode utilisateur : il sort vers Internet sans droits
        // particuliers et sans réseau libvirt à déclarer d'abord. Un pont
        // demanderait une configuration de l'hôte que personne n'a envie de
        // faire depuis un téléphone.
        out.push_str("    <interface type='user'>\n      <model type='virtio'/>\n    </interface>");
        // La tablette, et non la souris : SPICE envoie des coordonnées absolues,
        // ce qu'un doigt sur un écran produit. Avec une souris relative, le
        // pointeur dérive et devient impossible à poser.
        out.push_str("    <input type='tablet' bus='usb'/>\n");
        out.push_str("    <input type='keyboard' bus='usb'/>\n");
        let _ = writeln!(
            out,
            "    <graphics type='spice' autoport='yes' listen='{}' passwd='{}'>\n      \
             <listen type='address' address='{}'/>\n      \
             <image compression='auto_glz'/>\n    </graphics>",
            escape(&self.listen),
            escape(&self.password),
            escape(&self.listen)
        );
        let _ = writeln!(
            out,
            "    <video>\n      <model type='{}' heads='1' primary='yes'/>\n    </video>",
            self.video.model()
        );
        // Le canal de l'agent invité : presse-papiers dans les deux sens et
        // envoi de fichier, que wisq sait déjà parler.
        out.push_str(
            "    <channel type='spicevmc'>\n      \
             <target type='virtio' name='com.redhat.spice.0'/>\n    </channel>",
        );
        // Le son, parce que wisq a un canal audio et qu'un bureau muet se
        // remarque tout de suite.
        out.push_str("    <sound model='ich9'/>\n");
        out.push_str("    <audio id='1' type='spice'/>\n");
        out.push_str("    <console type='pty'/>\n");
        out.push_str("    <memballoon model='virtio'/>\n");
        out.push_str("  </devices>\n</domain>\n");
        out
    }
}

/// Le mot de passe du bureau : vingt caractères de la source aléatoire du
/// système.
///
/// **Jamais un PRNG semé.** C'est ce qui garde l'écran et le clavier d'une
/// machine sur un réseau que le démon ne contrôle pas ; le déduire de l'heure de
/// création serait le donner. Si `/dev/urandom` ne se lit pas, on refuse d'en
/// inventer un — un bureau sans mot de passe est pire que pas de bureau.
pub fn generate_password() -> Result<String, String> {
    const ALPHABET: &[u8] = b"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    use std::io::Read;
    let mut buffer = [0u8; 20];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut buffer))
        .map_err(|e| format!("impossible de lire /dev/urandom ({e}) : refus d'ouvrir un bureau sans mot de passe"))?;
    Ok(buffer
        .iter()
        .map(|b| ALPHABET[*b as usize % ALPHABET.len()] as char)
        .collect())
}

/// Ce qu'un chemin d'image doit être pour qu'on le mette dans un domaine.
///
/// **Absolu, existant, et un fichier.** libvirt résout les chemins relatifs
/// depuis son propre répertoire de travail, pas celui de la personne : un chemin
/// relatif accepté ici donnerait une machine qui ne trouve pas son image, et le
/// symptôme serait « pas de média amorçable » plusieurs minutes plus tard.
pub fn check_image(path: &str) -> Result<(), String> {
    let candidate = Path::new(path);
    if !candidate.is_absolute() {
        return Err(format!("le chemin de l'image doit être absolu : {path}"));
    }
    match std::fs::metadata(candidate) {
        Ok(info) if info.is_file() => Ok(()),
        Ok(_) => Err(format!("ce n'est pas un fichier : {path}")),
        Err(error) => Err(format!("image illisible ({error}) : {path}")),
    }
}

/// Les cinq caractères que XML ne laisse pas passer tels quels.
///
/// Un chemin peut porter une esperluette, et un nom un guillemet. Sans ça, le
/// domaine engendré n'est pas du XML et `virsh define` le refuse — au mieux ;
/// au pire, un nom choisi avec soin fermerait une balise et en ouvrirait une
/// autre.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            other => out.push(other),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn desktop() -> Desktop {
        Desktop {
            name: "omarchy".to_string(),
            image: "/home/max/images/omarchy-4.0.2.iso".to_string(),
            disk: "/home/max/wisq-disques/omarchy.qcow2".to_string(),
            memory_mib: 8192,
            cpus: 4,
            video: Video::Virtio,
            listen: "0.0.0.0".to_string(),
            password: "motdepasse".to_string(),
            accelerator: Accelerator::Kvm,
        }
    }

    /// **L'image s'amorce avant le disque**, et c'est ce qui fait apparaître
    /// l'installateur au premier démarrage. L'inverse donnerait un disque vide
    /// et l'écran « no bootable device » — le symptôme exact que quelqu'un
    /// mettrait une heure à relier à un ordre de deux lignes.
    #[test]
    fn the_image_boots_before_the_disk() {
        let xml = desktop().xml();
        let cdrom = xml.find("<boot dev='cdrom'/>").expect("l'ordre du cédérom");
        let disk = xml.find("<boot dev='hd'/>").expect("l'ordre du disque");
        assert!(cdrom < disk, "l'image doit passer avant le disque");
    }

    /// L'image est montée en lecture seule, en lecteur optique, et le disque en
    /// qcow2 sur virtio. Trois faits qu'un installateur vérifie tout de suite.
    #[test]
    fn the_image_is_a_read_only_cdrom_and_the_disk_is_qcow2() {
        let xml = desktop().xml();
        assert!(xml.contains("device='cdrom'"));
        assert!(xml.contains("<readonly/>"));
        assert!(xml.contains("/home/max/images/omarchy-4.0.2.iso"));
        assert!(xml.contains("type='qcow2'"));
        assert!(xml.contains("dev='vda' bus='virtio'"));
    }

    /// **Le bureau porte toujours un mot de passe.** Il écoute sur une adresse
    /// que le téléphone atteint ; sans mot de passe, c'est un écran et un
    /// clavier offerts à tout le réseau.
    #[test]
    fn the_desktop_always_carries_a_password() {
        let xml = desktop().xml();
        assert!(xml.contains("type='spice'"));
        assert!(xml.contains("passwd='motdepasse'"), "{xml}");
        assert!(xml.contains("listen='0.0.0.0'"));
    }

    /// La tablette, le son et le canal de l'agent : les trois choses que wisq
    /// sait afficher et qu'un domaine engendré sans elles rend inutilisables —
    /// un pointeur qui dérive, un bureau muet, pas de presse-papiers.
    #[test]
    fn the_devices_wisq_can_actually_use_are_declared() {
        let xml = desktop().xml();
        assert!(
            xml.contains("<input type='tablet' bus='usb'/>"),
            "la tablette"
        );
        assert!(xml.contains("<sound model='ich9'/>"), "le son");
        assert!(
            xml.contains("name='com.redhat.spice.0'"),
            "le canal de l'agent invité"
        );
    }

    /// Le modèle de carte suit le monde du bureau : virtio pour Wayland, qxl
    /// pour un X11 léger.
    #[test]
    fn the_video_model_is_the_one_asked_for() {
        assert!(desktop().xml().contains("type='virtio' heads='1'"));
        let mut qxl = desktop();
        qxl.video = Video::Qxl;
        assert!(qxl.xml().contains("type='qxl' heads='1'"));
        assert_eq!(Video::parse("qxl"), Some(Video::Qxl));
        assert_eq!(Video::parse("cirrus"), None);
    }

    /// La mémoire et les cœurs arrivent là où libvirt les lit.
    #[test]
    fn the_size_of_the_machine_lands_where_libvirt_reads_it() {
        let xml = desktop().xml();
        assert!(xml.contains("<memory unit='MiB'>8192</memory>"));
        assert!(xml.contains("<currentMemory unit='MiB'>8192</currentMemory>"));
        assert!(xml.contains("<vcpu placement='static'>4</vcpu>"));
    }

    /// **Un nom ou un chemin qui porte de l'XML ne casse pas le domaine.** Une
    /// esperluette dans un chemin est ordinaire ; une apostrophe dans un
    /// attribut fermerait la valeur et laisserait le reste au parseur.
    #[test]
    fn a_name_or_a_path_carrying_markup_is_escaped() {
        let mut hostile = desktop();
        hostile.name = "a<b&c".to_string();
        hostile.image = "/home/max/Films & séries/x'y.iso".to_string();
        let xml = hostile.xml();
        assert!(xml.contains("<name>a&lt;b&amp;c</name>"), "{xml}");
        assert!(xml.contains("Films &amp; s"), "{xml}");
        assert!(xml.contains("x&apos;y.iso"), "{xml}");
        assert!(
            !xml.contains("<b&c"),
            "le nom brut ne doit apparaître nulle part"
        );
    }

    /// L'accélérateur se lit dans les capacités, et son absence n'est pas une
    /// panne : un bureau lent reste un bureau.
    #[test]
    fn the_accelerator_comes_from_the_capabilities_and_falls_back() {
        assert_eq!(
            Accelerator::from_capabilities("<domain type='qemu'/><domain type='kvm'/>"),
            Accelerator::Kvm
        );
        assert_eq!(
            Accelerator::from_capabilities("<domain type=\"hvf\"/>"),
            Accelerator::Hvf
        );
        assert_eq!(
            Accelerator::from_capabilities("<domain type='qemu'/>"),
            Accelerator::None
        );
        assert_eq!(Accelerator::Kvm.domain_type(), "kvm");
        assert_eq!(Accelerator::None.domain_type(), "qemu");
        assert!(Accelerator::None.warning().is_some(), "et on le dit");
        assert!(Accelerator::Hvf.warning().is_none());
    }

    /// Un chemin relatif est refusé ici plutôt que par libvirt une minute plus
    /// tard, quand la machine ne trouve pas son image.
    #[test]
    fn a_relative_or_missing_image_is_refused_by_name() {
        assert!(check_image("images/omarchy.iso").is_err());
        assert!(check_image("/n/existe/pas.iso").is_err());
        let path = std::env::temp_dir().join(format!("wisq-image-{}.iso", std::process::id()));
        std::fs::write(&path, b"x").unwrap();
        assert!(check_image(path.to_str().unwrap()).is_ok());
        assert!(check_image(std::env::temp_dir().to_str().unwrap()).is_err());
        let _ = std::fs::remove_file(&path);
    }

    /// **libvirt lui-même dit si ce domaine en est un.**
    ///
    /// Toutes les assertions au-dessus vérifient que le texte contient ce qu'on
    /// y a mis — elles ne peuvent pas voir un attribut mal placé, une balise
    /// que ce schéma n'attend pas à cet endroit, ou un modèle de carte que
    /// libvirt ne connaît pas. `virt-xml-validate` compare au RelaxNG que
    /// libvirt installe avec lui : c'est la définition, pas une opinion.
    ///
    /// Mesuré ici contre libvirt 10.0.0 : les deux modèles de carte passent.
    /// L'outil n'est pas partout — le test le dit et s'arrête plutôt que de
    /// prétendre avoir vérifié.
    #[test]
    fn libvirt_itself_accepts_the_domain() {
        let Ok(tool) = which("virt-xml-validate") else {
            eprintln!(
                "virt-xml-validate absent : le domaine n'a pas été confronté au schéma de libvirt"
            );
            return;
        };
        for video in [Video::Virtio, Video::Qxl] {
            let mut spec = desktop();
            spec.video = video;
            let path = std::env::temp_dir().join(format!(
                "wisq-domaine-{}-{}.xml",
                std::process::id(),
                spec.video.model()
            ));
            std::fs::write(&path, spec.xml()).unwrap();
            let output = std::process::Command::new(&tool)
                .arg(&path)
                .arg("domain")
                .output()
                .expect("virt-xml-validate");
            let _ = std::fs::remove_file(&path);
            assert!(
                output.status.success(),
                "libvirt refuse le domaine ({}) :\n{}\n{}",
                spec.video.model(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    fn which(program: &str) -> Result<String, ()> {
        let path = std::env::var("PATH").map_err(|_| ())?;
        for folder in path.split(':') {
            let candidate = std::path::Path::new(folder).join(program);
            if candidate.is_file() {
                return Ok(candidate.to_string_lossy().to_string());
            }
        }
        Err(())
    }

    /// Le mot de passe fait vingt caractères, et deux tirages diffèrent.
    #[test]
    fn the_password_is_twenty_characters_and_not_the_same_twice() {
        let first = generate_password().expect("urandom");
        let second = generate_password().expect("urandom");
        assert_eq!(first.chars().count(), 20);
        assert_ne!(first, second);
        assert!(first.chars().all(|c| c.is_ascii_alphanumeric()));
    }
}
