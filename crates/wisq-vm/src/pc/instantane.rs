//! **L'instantané de la machine PC native** : un format à elle, versionné, et
//! ce qu'il porte dit ici en entier.
//!
//! **Ce qu'il porte** (version 2) :
//! - l'en-tête : `WISQPC\r\n`, la version, la RAM, l'écran annoncé (largeur
//!   et hauteur, zéro sans écran) — une reprise refuse une autre RAM ou un
//!   autre écran, comme `X86Machine.restore` ;
//! - la machine : ses compteurs (retirées, attente, battement), l'arrêt sur
//!   `hlt`, l'ombre de `sti`, la page zéro posée, l'état du générateur de
//!   `rdrand` quand il est fixé, le temps encore à rattraper et le temps
//!   rattrapé. **Un générateur de l'hôte (`Alea::Hote`) ne se sauve pas** :
//!   une étiquette dit seulement qu'il était là, et la machine qui reprend
//!   garde le sien, à graine ou de l'hôte ;
//! - le processeur : les seize registres, RIP, les drapeaux, FS et GS, les
//!   registres de contrôle, EFER, les seize XMM et MXCSR, l'état entier du
//!   x87 (contrôle, état, étiquettes, les huit registres), les sélecteurs, le
//!   code de la dernière faute ;
//! - le système : GDT, IDT, la tâche, la LDT, les MSR (ceux qui ont un nom,
//!   et les autres), les registres de débogage ;
//! - les puces de la machine : les deux 8259, le 8253 et son haut-parleur,
//!   le 16550 (et ce qu'il tient en entrée comme en sortie), l'horloge CMOS ;
//! - **les entrées pas encore données à l'invité** (les commandes du poste) :
//!   les octets tapés au port série, les frappes qui attendent leur tour
//!   avant l'i8042, et les deux états du clavier qui vont avec ;
//! - **la carte des périphériques** (`wisq-carte`, `CartePc::sauver`),
//!   précédée de sa longueur : l'horloge CMOS de la carte, l'i8042 et ses
//!   frappes en attente, le pont PCI (l'adresse choisie, les BAR, les
//!   registres de commande, les lignes), chaque disque virtio (ce que le
//!   pilote a écrit, sa file et ses deux index), la carte de Bochs (ses
//!   registres, son mode, sa mémoire vidéo page par page), la tablette (ses
//!   files et ses événements en attente), la carte réseau si elle est là (ses
//!   files et leurs index ; pas les trames en file, que le cœur Swift ne
//!   sauve pas non plus), les notifications notées et pas encore
//!   servies ; pour chaque disque, **où vivent ses octets** : « ailleurs »
//!   pour un disque sur fichier (son fichier et sa couche, scellés par
//!   `wisq_pc_flush_disks` avant l'instantané, comme `flushDisk` du cœur
//!   Swift), embarqués pour une image en mémoire ;
//! - la RAM, page par page : une carte d'un bit par page de quatre
//!   kibioctets, puis les seules pages qui ne sont pas nulles.
//!
//! **Ce qu'il ne porte pas** : ce qui est autour de la machine et pas
//! dedans — les octets d'un disque sur fichier, le câble de la carte réseau
//! et ses deux files de trames (`pc::reseau`), l'horloge de l'hôte, la graine
//! de l'hôte. La carte réseau se branche avant la reprise, comme l'écran
//! (`Poste::brancher_reseau`) : reprise, elle garde ce câble-là. Une carte
//! que l'instantané porte et que la machine n'a pas branchée revient sans
//! câble — rien n'entre ni ne sort, comme le cœur Swift sans réseau ; une
//! carte branchée que l'instantané ne porte pas disparaît du bus, et ses
//! files sont fermées. La machine qui reprend branche
//! ses disques sur fichier **avant** la reprise, de la même capacité, aux
//! mêmes emplacements, et pas d'autres ; sinon la reprise est refusée
//! (`AutresDisques`).
//!
//! **La version 1** (sans la carte) est refusée (`Perime`) : un invité qui
//! s'est servi de la carte ne s'y reprend pas fidèlement — ses pilotes
//! croiraient à des files que la carte a oubliées —, et aucune session de la
//! version 1 n'a été écrite par l'application, qui ne sauvait pas encore
//! cette machine.
//!
//! Tout est petit-boutiste. Rien n'est reposé tant que tout n'a pas été lu
//! et vérifié : sont refusés un instantané tronqué ou suivi d'octets de
//! trop, un booléen qui ne vaut ni zéro ni un, un battement de zéro
//! instruction (le temps de l'invité se divise par lui), une étiquette
//! d'aléa inconnue, deux fois le même MSR, un bit de la carte des pages
//! au-delà de la dernière, une carte dite absente (le poste la branche
//! toujours), une heure des puces au-delà de l'an 9999, une frappe en
//! attente qui n'est pas une touche ou plus de frappes que l'i8042 n'en
//! admet, et tout ce que la carte refuse d'elle-même (`CartePc::relire` :
//! un index de file hors de sa taille, une fenêtre de travers, un écran qui
//! n'est pas celui de la machine…).
//!
//! **Une machine qui a déjà tourné se reprend comme une neuve** : sa RAM est
//! effacée avant que les pages de l'instantané y soient posées (une page nulle
//! de l'instantané l'est donc aussi après la reprise), et ce qu'elle gardait
//! de son état d'avant est oublié ou se recompare (`Machine::apres_reprise`).
//! **Le bit LMA d'EFER ne se lit pas** : il est recalculé de LME et de la
//! pagination, comme le silicium, qui ne le laisse pas écrire.

use super::chargeur::Placement;
use super::herites::{Controleur, Herites, HorlogeCmos, Minuterie, Serie};
use super::machine::Alea;
use super::poste::{EntreesEnAttente, Poste, DERNIERE_SECONDE};
use super::systeme::{Systeme, Table};
use wisq_carte::i8042::{CodeTouche, PLUS_DE_FRAPPES, TOUCHES};
use wisq_carte::pc::{EtatDeCarte, RefusDeReprise};

pub use wisq_carte::pc::RefusDeSauvegarde;

/// Les huit premiers octets : un nom, et `\r\n` pour qu'une conversion de
/// fins de ligne se voie.
pub const MAGIE: [u8; 8] = *b"WISQPC\r\n";
/// La version de ce format : 2 porte la carte des périphériques.
pub const VERSION: u32 = 2;
/// La page de la carte de la RAM.
pub const PAGE: usize = 4096;

/// Pourquoi un instantané ne se reprend pas.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RefusDInstantane {
    /// Ce n'est pas un instantané de cette machine.
    PasUnInstantane,
    /// Un format que ce code ne sait pas lire (plus récent).
    VersionInconnue(u32),
    /// Un format plus ancien, qui ne portait pas la carte des périphériques :
    /// refusé plutôt que repris à moitié.
    Perime(u32),
    /// Tronqué, abîmé, ou suivi d'octets de trop.
    Abime,
    /// Sauvé d'une machine d'une autre RAM.
    AutreMemoire { sauvee: u64, ici: u64 },
    /// Sauvé sous un autre écran (ou sans écran, ou avec) : le noyau a réglé
    /// son mode sur celui qu'il a trouvé.
    AutreEcran,
    /// Les disques branchés ne sont pas ceux de l'instantané : un disque sur
    /// fichier manque ou n'a pas la même capacité, un emplacement vide dans
    /// l'instantané ne l'est pas ici, une image embarquée tomberait sur un
    /// disque sur fichier.
    AutresDisques,
}

struct Ecrivain(Vec<u8>);

impl Ecrivain {
    fn u8(&mut self, valeur: u8) {
        self.0.push(valeur);
    }
    fn u16(&mut self, valeur: u16) {
        self.0.extend_from_slice(&valeur.to_le_bytes());
    }
    fn u32(&mut self, valeur: u32) {
        self.0.extend_from_slice(&valeur.to_le_bytes());
    }
    fn u64(&mut self, valeur: u64) {
        self.0.extend_from_slice(&valeur.to_le_bytes());
    }
    fn oui(&mut self, valeur: bool) {
        self.u8(u8::from(valeur));
    }
    fn peut_etre(&mut self, valeur: Option<u64>) {
        self.oui(valeur.is_some());
        self.u64(valeur.unwrap_or(0));
    }
    fn octets(&mut self, octets: &[u8]) {
        self.u64(octets.len() as u64);
        self.0.extend_from_slice(octets);
    }
}

struct Lecteur<'a> {
    octets: &'a [u8],
    ou: usize,
}

impl<'a> Lecteur<'a> {
    fn prendre(&mut self, combien: usize) -> Option<&'a [u8]> {
        let fin = self.ou.checked_add(combien)?;
        let morceau = self.octets.get(self.ou..fin)?;
        self.ou = fin;
        Some(morceau)
    }
    fn u8(&mut self) -> Option<u8> {
        Some(self.prendre(1)?[0])
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.prendre(2)?.try_into().ok()?))
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_le_bytes(self.prendre(4)?.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.prendre(8)?.try_into().ok()?))
    }
    /// Un booléen : zéro ou un, rien d'autre.
    fn oui(&mut self) -> Option<bool> {
        match self.u8()? {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }
    fn peut_etre(&mut self) -> Option<Option<u64>> {
        let present = self.oui()?;
        let valeur = self.u64()?;
        Some(present.then_some(valeur))
    }
    fn octets(&mut self) -> Option<&'a [u8]> {
        let longueur = usize::try_from(self.u64()?).ok()?;
        self.prendre(longueur)
    }
}

fn ecrire_table(e: &mut Ecrivain, table: &Table) {
    e.u64(table.base);
    e.u64(table.limite);
}

fn lire_table(l: &mut Lecteur) -> Option<Table> {
    Some(Table {
        base: l.u64()?,
        limite: l.u64()?,
    })
}

fn ecrire_controleur(e: &mut Ecrivain, c: &Controleur) {
    e.u8(c.masque);
    e.u8(c.demande);
    e.u8(c.service);
    e.u8(c.base_des_vecteurs);
    e.u8(c.etape);
    e.oui(c.lit_le_service);
}

fn lire_controleur(l: &mut Lecteur) -> Option<Controleur> {
    Some(Controleur {
        masque: l.u8()?,
        demande: l.u8()?,
        service: l.u8()?,
        base_des_vecteurs: l.u8()?,
        etape: l.u8()?,
        lit_le_service: l.oui()?,
    })
}

fn ecrire_minuterie(e: &mut Ecrivain, m: &Minuterie) {
    e.u16(m.rechargement);
    e.oui(m.ecrit_le_haut);
    e.oui(m.lit_le_haut);
    e.oui(m.verrou.is_some());
    e.u16(m.verrou.unwrap_or(0));
    e.u64(m.recharge_a);
    e.oui(m.coup_unique);
    e.u64(m.levees);
    e.u16(m.haut_parleur);
    e.oui(m.haut_parleur_ecrit_le_haut);
    e.oui(m.haut_parleur_lit_le_haut);
    e.u64(m.haut_parleur_parti_a);
    e.oui(m.porte);
}

fn lire_minuterie(l: &mut Lecteur) -> Option<Minuterie> {
    let rechargement = l.u16()?;
    let ecrit_le_haut = l.oui()?;
    let lit_le_haut = l.oui()?;
    let verrouille = l.oui()?;
    let verrou = l.u16()?;
    Some(Minuterie {
        rechargement,
        ecrit_le_haut,
        lit_le_haut,
        verrou: verrouille.then_some(verrou),
        recharge_a: l.u64()?,
        coup_unique: l.oui()?,
        levees: l.u64()?,
        haut_parleur: l.u16()?,
        haut_parleur_ecrit_le_haut: l.oui()?,
        haut_parleur_lit_le_haut: l.oui()?,
        haut_parleur_parti_a: l.u64()?,
        porte: l.oui()?,
    })
}

fn ecrire_serie(e: &mut Ecrivain, s: &Serie) {
    e.u8(s.autorisation);
    e.u8(s.fifo);
    e.u8(s.ligne);
    e.u8(s.modem);
    e.u8(s.brouillon);
    e.u16(s.diviseur);
    e.oui(s.emission_en_attente);
    let entree: Vec<u8> = s.entree.iter().copied().collect();
    e.octets(&entree);
    e.octets(&s.sortie);
}

fn lire_serie(l: &mut Lecteur) -> Option<Serie> {
    Some(Serie {
        autorisation: l.u8()?,
        fifo: l.u8()?,
        ligne: l.u8()?,
        modem: l.u8()?,
        brouillon: l.u8()?,
        diviseur: l.u16()?,
        emission_en_attente: l.oui()?,
        entree: l.octets()?.iter().copied().collect(),
        sortie: l.octets()?.to_vec(),
    })
}

fn ecrire_placement(e: &mut Ecrivain, p: Option<Placement>) {
    e.oui(p.is_some());
    let p = p.unwrap_or(Placement {
        adresse_du_noyau: 0,
        octets_reserves: 0,
        page_zero: 0,
        ligne_de_commande: 0,
        adresse_de_l_initramfs: 0,
        octets_de_l_initramfs: 0,
        entree: 0,
    });
    e.u64(p.adresse_du_noyau);
    e.u64(p.octets_reserves as u64);
    e.u64(p.page_zero);
    e.u64(p.ligne_de_commande);
    e.u64(p.adresse_de_l_initramfs);
    e.u64(p.octets_de_l_initramfs as u64);
    e.u64(p.entree);
}

fn lire_placement(l: &mut Lecteur) -> Option<Option<Placement>> {
    let present = l.oui()?;
    let placement = Placement {
        adresse_du_noyau: l.u64()?,
        octets_reserves: usize::try_from(l.u64()?).ok()?,
        page_zero: l.u64()?,
        ligne_de_commande: l.u64()?,
        adresse_de_l_initramfs: l.u64()?,
        octets_de_l_initramfs: usize::try_from(l.u64()?).ok()?,
        entree: l.u64()?,
    };
    Some(present.then_some(placement))
}

/// **Sauver le poste.** Machine arrêtée : rien ne tourne pendant qu'on lit.
///
/// Refusé seulement pour une carte dont un disque a des requêtes en vol,
/// ce que la machine native ne laisse jamais entre deux instructions (elle
/// sert chaque requête pendant l'`out` qui la notifie).
pub fn sauver(poste: &Poste) -> Result<Vec<u8>, RefusDeSauvegarde> {
    let carte = poste.commandes().carte().tenir().sauver()?;
    let machine = &poste.machine;
    let cpu = &machine.cpu;
    let ram = &cpu.memory.bytes;
    let mut e = Ecrivain(Vec::with_capacity(ram.len() / 4 + 4096));
    e.0.extend_from_slice(&MAGIE);
    e.u32(VERSION);
    e.u64(machine.ram);
    let (largeur, hauteur) = poste
        .ecran()
        .map_or((0, 0), |ecran| (ecran.largeur as u32, ecran.hauteur as u32));
    e.u32(largeur);
    e.u32(hauteur);

    // La machine.
    e.u64(machine.instructions_par_battement);
    e.u64(machine.retirees);
    e.u64(machine.attente);
    e.oui(machine.arretee);
    e.peut_etre(machine.ombre());
    ecrire_placement(&mut e, machine.placement());
    match machine.alea {
        Alea::Fixe(etat) => {
            e.u8(0);
            e.u64(etat);
        }
        // La source de l'hôte ne se sauve pas : la machine qui reprend garde
        // son générateur.
        Alea::Hote(_) => {
            e.u8(1);
            e.u64(0);
        }
    }
    let (du, rattrape) = poste.rattrapage();
    e.u64(du);
    e.u64(rattrape);

    // Le processeur.
    for registre in cpu.regs {
        e.u64(registre);
    }
    e.u64(cpu.rip);
    e.u64(cpu.flags.read());
    e.u64(cpu.gs_base);
    e.u64(cpu.fs_base);
    for controle in cpu.control {
        e.u64(controle);
    }
    for [bas, haut] in cpu.xmm {
        e.u64(bas);
        e.u64(haut);
    }
    e.u32(cpu.mxcsr);
    e.u16(cpu.fpu_control);
    e.u16(cpu.fpu_status);
    for (mantisse, exposant) in cpu.x87 {
        e.u64(mantisse);
        e.u16(exposant);
    }
    e.u8(cpu.fpu_tags);
    for segment in cpu.segments {
        e.u16(segment);
    }
    e.u64(cpu.efer);
    e.u64(cpu.fault_code);

    // Le système.
    let s = &machine.systeme;
    ecrire_table(&mut e, &s.gdt);
    ecrire_table(&mut e, &s.idt);
    e.u16(s.tache);
    e.u64(s.base_de_tache);
    e.u64(s.limite_de_tache);
    e.u16(s.ldt);
    e.u64(s.gs_du_noyau);
    e.u64(s.star);
    e.u64(s.lstar);
    e.u64(s.cstar);
    e.u64(s.masque_d_appel);
    e.u64(s.tsc_aux);
    e.u64(s.autres.len() as u64);
    for (&numero, &valeur) in &s.autres {
        e.u32(numero);
        e.u64(valeur);
    }
    for debug in s.debug {
        e.u64(debug);
    }

    // Les puces.
    let h = &machine.herites;
    ecrire_controleur(&mut e, &h.maitre);
    ecrire_controleur(&mut e, &h.second);
    ecrire_minuterie(&mut e, &h.minuterie);
    ecrire_serie(&mut e, &h.serie);
    e.u8(h.cmos.index);
    e.u8(h.cmos.etat_b);
    e.u64(h.cmos.secondes_depuis_1970);
    e.0.extend_from_slice(&h.cmos.memoire);
    e.oui(h.cmos_ailleurs);

    // Les entrées pas encore données à l'invité.
    let entrees = poste.entrees();
    e.octets(&entrees.serie);
    e.u64(entrees.frappes.len() as u64);
    for (code, enfoncee) in &entrees.frappes {
        e.u8(code.jeu1);
        e.oui(code.etendue);
        e.oui(*enfoncee);
    }
    for mot in entrees.tenues_au_bout.iter().chain(&entrees.tenues_remises) {
        e.u64(*mot);
    }

    // La carte des périphériques, d'un bloc.
    e.octets(&carte);

    // La RAM : la carte des pages non nulles, puis elles.
    e.u64(ram.len() as u64);
    let pages: Vec<&[u8]> = ram.chunks(PAGE).collect();
    let mut carte = vec![0u8; pages.len().div_ceil(8)];
    for (rang, page) in pages.iter().enumerate() {
        if page.iter().any(|&octet| octet != 0) {
            carte[rang / 8] |= 1 << (rang % 8);
        }
    }
    e.0.extend_from_slice(&carte);
    for (rang, page) in pages.iter().enumerate() {
        if carte[rang / 8] & (1 << (rang % 8)) != 0 {
            e.0.extend_from_slice(page);
        }
    }
    Ok(e.0)
}

/// Tout ce qu'un instantané repose, lu avant d'être reposé.
struct Lu {
    instructions_par_battement: u64,
    retirees: u64,
    attente: u64,
    arretee: bool,
    ombre: Option<u64>,
    placement: Option<Placement>,
    graine: Option<u64>,
    du: u64,
    rattrape: u64,
    regs: [u64; 16],
    rip: u64,
    drapeaux: u64,
    gs_base: u64,
    fs_base: u64,
    control: [u64; 9],
    xmm: [[u64; 2]; 16],
    mxcsr: u32,
    fpu_control: u16,
    fpu_status: u16,
    x87: [(u64, u16); 8],
    fpu_tags: u8,
    segments: [u16; 6],
    efer: u64,
    fault_code: u64,
    systeme: Systeme,
    herites: Herites,
}

/// L'en-tête : la version, la RAM, l'écran.
fn lire_l_en_tete(l: &mut Lecteur, poste: &Poste) -> Result<(), RefusDInstantane> {
    if l.prendre(MAGIE.len()) != Some(&MAGIE[..]) {
        return Err(RefusDInstantane::PasUnInstantane);
    }
    let version = l.u32().ok_or(RefusDInstantane::Abime)?;
    if version > VERSION {
        return Err(RefusDInstantane::VersionInconnue(version));
    }
    if version < VERSION {
        return Err(RefusDInstantane::Perime(version));
    }
    let sauvee = l.u64().ok_or(RefusDInstantane::Abime)?;
    if sauvee != poste.machine.ram {
        return Err(RefusDInstantane::AutreMemoire {
            sauvee,
            ici: poste.machine.ram,
        });
    }
    let largeur = l.u32().ok_or(RefusDInstantane::Abime)?;
    let hauteur = l.u32().ok_or(RefusDInstantane::Abime)?;
    let ici = poste
        .ecran()
        .map_or((0, 0), |ecran| (ecran.largeur as u32, ecran.hauteur as u32));
    if (largeur, hauteur) != ici {
        return Err(RefusDInstantane::AutreEcran);
    }
    Ok(())
}

fn lire_le_reste(l: &mut Lecteur) -> Option<Lu> {
    let instructions_par_battement = l.u64()?;
    if instructions_par_battement == 0 {
        return None;
    }
    let retirees = l.u64()?;
    let attente = l.u64()?;
    let arretee = l.oui()?;
    let ombre = l.peut_etre()?;
    let placement = lire_placement(l)?;
    let graine = match (l.u8()?, l.u64()?) {
        (0, etat) => Some(etat),
        (1, _) => None,
        _ => return None,
    };
    let du = l.u64()?;
    let rattrape = l.u64()?;

    let mut regs = [0u64; 16];
    for registre in &mut regs {
        *registre = l.u64()?;
    }
    let rip = l.u64()?;
    let drapeaux = l.u64()?;
    let gs_base = l.u64()?;
    let fs_base = l.u64()?;
    let mut control = [0u64; 9];
    for controle in &mut control {
        *controle = l.u64()?;
    }
    let mut xmm = [[0u64; 2]; 16];
    for registre in &mut xmm {
        *registre = [l.u64()?, l.u64()?];
    }
    let mxcsr = l.u32()?;
    let fpu_control = l.u16()?;
    let fpu_status = l.u16()?;
    let mut x87 = [(0u64, 0u16); 8];
    for registre in &mut x87 {
        *registre = (l.u64()?, l.u16()?);
    }
    let fpu_tags = l.u8()?;
    let mut segments = [0u16; 6];
    for segment in &mut segments {
        *segment = l.u16()?;
    }
    let efer = l.u64()?;
    let fault_code = l.u64()?;

    let mut systeme = Systeme {
        gdt: lire_table(l)?,
        idt: lire_table(l)?,
        tache: l.u16()?,
        base_de_tache: l.u64()?,
        limite_de_tache: l.u64()?,
        ldt: l.u16()?,
        gs_du_noyau: l.u64()?,
        star: l.u64()?,
        lstar: l.u64()?,
        cstar: l.u64()?,
        masque_d_appel: l.u64()?,
        tsc_aux: l.u64()?,
        ..Systeme::default()
    };
    let autres = usize::try_from(l.u64()?).ok()?;
    for _ in 0..autres {
        let numero = l.u32()?;
        let valeur = l.u64()?;
        systeme.autres.insert(numero, valeur);
    }
    if systeme.autres.len() != autres {
        // Deux fois le même MSR : écrit par quelqu'un d'autre que `sauver`.
        return None;
    }
    for debug in &mut systeme.debug {
        *debug = l.u64()?;
    }

    let maitre = lire_controleur(l)?;
    let second = lire_controleur(l)?;
    let minuterie = lire_minuterie(l)?;
    let serie = lire_serie(l)?;
    let index = l.u8()?;
    let etat_b = l.u8()?;
    let secondes_depuis_1970 = l.u64()?;
    let memoire: [u8; 128] = l.prendre(128)?.try_into().ok()?;
    let cmos_ailleurs = l.oui()?;
    // Le poste branche toujours sa carte (`Poste::essayer`), et `sauver` ne
    // porte que l'heure bornée de `Poste::regler_l_heure` : un instantané qui
    // dit la carte absente, ou une heure au-delà de l'an 9999, n'a pas été
    // écrit par `sauver`. Repris, il rendrait les ports 0x70 et 0x71 aux puces
    // de la machine, devant la carte encore branchée, avec une date hors de
    // toute borne.
    if !cmos_ailleurs || secondes_depuis_1970 > DERNIERE_SECONDE as u64 {
        return None;
    }
    Some(Lu {
        instructions_par_battement,
        retirees,
        attente,
        arretee,
        ombre,
        placement,
        graine,
        du,
        rattrape,
        regs,
        rip,
        drapeaux,
        gs_base,
        fs_base,
        control,
        xmm,
        mxcsr,
        fpu_control,
        fpu_status,
        x87,
        fpu_tags,
        segments,
        efer,
        fault_code,
        systeme,
        herites: Herites {
            maitre,
            second,
            minuterie,
            serie,
            cmos: HorlogeCmos {
                index,
                etat_b,
                secondes_depuis_1970,
                memoire,
            },
            cmos_ailleurs,
        },
    })
}

/// **Les entrées pas encore données à l'invité**, ou rien : une frappe dont
/// le code n'est pas une touche du jeu 1 (de 1 à 0x7F, ce que
/// `frappes_du_jeu_1` admet), ou plus de frappes que l'i8042 n'en admet.
fn lire_les_entrees(l: &mut Lecteur) -> Option<EntreesEnAttente> {
    let serie = l.octets()?.to_vec();
    let combien = usize::try_from(l.u64()?).ok()?;
    if combien > PLUS_DE_FRAPPES {
        return None;
    }
    let mut frappes = Vec::with_capacity(combien);
    for _ in 0..combien {
        let jeu1 = l.u8()?;
        let etendue = l.oui()?;
        let enfoncee = l.oui()?;
        if !(1..=0x7F).contains(&jeu1) {
            return None;
        }
        frappes.push((CodeTouche { jeu1, etendue }, enfoncee));
    }
    let mut tenues = [[0u64; TOUCHES / 64]; 2];
    for mot in tenues.iter_mut().flatten() {
        *mot = l.u64()?;
    }
    let [tenues_au_bout, tenues_remises] = tenues;
    Some(EntreesEnAttente {
        serie,
        frappes,
        tenues_au_bout,
        tenues_remises,
    })
}

/// La carte relue contre celle du poste, sans rien y changer.
fn lire_la_carte<'a>(
    l: &mut Lecteur<'a>,
    poste: &Poste,
) -> Result<EtatDeCarte<'a>, RefusDInstantane> {
    let octets = l.octets().ok_or(RefusDInstantane::Abime)?;
    poste
        .commandes()
        .carte()
        .tenir()
        .relire(octets)
        .map_err(|refus| match refus {
            RefusDeReprise::Abime => RefusDInstantane::Abime,
            RefusDeReprise::AutresDisques => RefusDInstantane::AutresDisques,
        })
}

/// Les pages de la RAM : la carte, puis les pages non nulles, jusqu'au bout
/// exact de l'instantané. Rend, pour chaque page non nulle, son rang et ses
/// octets.
fn lire_la_ram<'a>(l: &mut Lecteur<'a>, longueur: usize) -> Option<Vec<(usize, &'a [u8])>> {
    let octets = usize::try_from(l.u64()?).ok()?;
    if octets != longueur {
        return None;
    }
    let pages = octets.div_ceil(PAGE);
    let carte = l.prendre(pages.div_ceil(8))?;
    // Les bits au-delà de la dernière page doivent être nuls.
    if pages % 8 != 0 && carte[pages / 8] >> (pages % 8) != 0 {
        return None;
    }
    let mut pleines = Vec::new();
    for rang in 0..pages {
        if carte[rang / 8] & (1 << (rang % 8)) != 0 {
            let taille = PAGE.min(octets - rang * PAGE);
            pleines.push((rang, l.prendre(taille)?));
        }
    }
    Some(pleines)
}

/// **Reprendre un instantané** dans ce poste : tout est lu et vérifié avant
/// que rien ne soit reposé. Machine arrêtée.
pub fn reprendre(poste: &mut Poste, octets: &[u8]) -> Result<(), RefusDInstantane> {
    let mut l = Lecteur { octets, ou: 0 };
    lire_l_en_tete(&mut l, poste)?;
    let lu = lire_le_reste(&mut l).ok_or(RefusDInstantane::Abime)?;
    let entrees = lire_les_entrees(&mut l).ok_or(RefusDInstantane::Abime)?;
    let carte = lire_la_carte(&mut l, poste)?;
    let longueur = poste.machine.cpu.memory.bytes.len();
    let pages = lire_la_ram(&mut l, longueur).ok_or(RefusDInstantane::Abime)?;
    if l.ou != octets.len() {
        return Err(RefusDInstantane::Abime);
    }

    let machine = &mut poste.machine;
    machine.instructions_par_battement = lu.instructions_par_battement;
    machine.retirees = lu.retirees;
    machine.attente = lu.attente;
    machine.arretee = lu.arretee;
    if let Some(graine) = lu.graine {
        machine.alea = Alea::Fixe(graine);
    }
    let cpu = &mut machine.cpu;
    cpu.regs = lu.regs;
    cpu.rip = lu.rip;
    cpu.flags.write(lu.drapeaux);
    cpu.gs_base = lu.gs_base;
    cpu.fs_base = lu.fs_base;
    cpu.control = lu.control;
    cpu.xmm = lu.xmm;
    cpu.mxcsr = lu.mxcsr;
    cpu.fpu_control = lu.fpu_control;
    cpu.fpu_status = lu.fpu_status;
    cpu.x87 = lu.x87;
    cpu.fpu_tags = lu.fpu_tags;
    cpu.segments = lu.segments;
    cpu.efer = lu.efer;
    cpu.fault_code = lu.fault_code;
    cpu.memory.bytes.fill(0);
    for (rang, page) in pages {
        cpu.memory.bytes[rang * PAGE..rang * PAGE + page.len()].copy_from_slice(page);
    }
    machine.systeme = lu.systeme;
    machine.herites = lu.herites;
    // LMA est en lecture seule sur le silicium : le processeur le tire de
    // LME et de la pagination. Un instantané où il est faux reprend donc
    // comme le processeur l'aurait (`the_long_mode_bit_is_recomputed_on_resume`).
    super::systeme::rafraichir_le_mode_long(&mut machine.cpu);
    machine.apres_reprise(lu.ombre, lu.placement);
    poste.commandes().carte().tenir().reposer(carte);
    poste.reseau_apres_reprise();
    poste.reposer_les_entrees(entrees);
    poste.reposer(lu.du, lu.rattrape);
    Ok(())
}
