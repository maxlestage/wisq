//! **L'instantané de la machine PC native** : un format à elle, versionné, et
//! ce qu'il porte dit ici en entier.
//!
//! **Ce qu'il porte** (version 1) :
//! - l'en-tête : `WISQPC\r\n`, la version, la RAM, l'écran annoncé (largeur
//!   et hauteur, zéro sans écran) — une reprise refuse une autre RAM ou un
//!   autre écran, comme `X86Machine.restore` ;
//! - la machine : ses compteurs (retirées, attente, battement), l'arrêt sur
//!   `hlt`, l'ombre de `sti`, la page zéro posée, l'état du générateur de
//!   `rdrand` quand il est fixé, le temps encore à rattraper et le temps
//!   rattrapé ;
//! - le processeur : les seize registres, RIP, les drapeaux, FS et GS, les
//!   registres de contrôle, EFER, les seize XMM et MXCSR, l'état entier du
//!   x87 (contrôle, état, étiquettes, les huit registres), les sélecteurs, le
//!   code de la dernière faute ;
//! - le système : GDT, IDT, la tâche, la LDT, les MSR (ceux qui ont un nom,
//!   et les autres), les registres de débogage ;
//! - les puces de la machine : les deux 8259, le 8253 et son haut-parleur,
//!   le 16550 (et ce qu'il tient en entrée comme en sortie), l'horloge CMOS ;
//! - la RAM, page par page : une carte d'un bit par page de quatre
//!   kibioctets, puis les seules pages qui ne sont pas nulles.
//!
//! **Ce qu'il ne porte pas** : la carte des périphériques (`wisq-carte` :
//! l'i8042, l'horloge CMOS de la carte, le pont PCI, les disques virtio, la
//! carte de Bochs et sa mémoire vidéo, la tablette). Ses états sont privés à
//! ce crate-là, qui n'offre ni sauvegarde ni reprise ; une reprise laisse la
//! carte du poste telle qu'elle est. **Un invité qui s'est servi de la carte
//! ne se reprend donc pas fidèlement** — ses pilotes croiraient à des files
//! que la carte a oubliées. Ni les frappes en attente, ni ce qui a été tapé
//! au port série et pas encore donné (les commandes du poste).
//!
//! Tout est petit-boutiste. Un instantané tronqué, ou suivi d'octets de trop,
//! est refusé : rien n'est reposé tant que tout n'a pas été lu.

use super::chargeur::Placement;
use super::herites::{Controleur, Herites, HorlogeCmos, Minuterie, Serie};
use super::machine::Alea;
use super::poste::Poste;
use super::systeme::{Systeme, Table};

/// Les huit premiers octets : un nom, et `\r\n` pour qu'une conversion de
/// fins de ligne se voie.
pub const MAGIE: [u8; 8] = *b"WISQPC\r\n";
/// La version de ce format.
pub const VERSION: u32 = 1;
/// La page de la carte de la RAM.
pub const PAGE: usize = 4096;

/// Pourquoi un instantané ne se reprend pas.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RefusDInstantane {
    /// Ce n'est pas un instantané de cette machine.
    PasUnInstantane,
    /// Un format que ce code ne sait pas lire (plus récent).
    VersionInconnue(u32),
    /// Tronqué, abîmé, ou suivi d'octets de trop.
    Abime,
    /// Sauvé d'une machine d'une autre RAM.
    AutreMemoire { sauvee: u64, ici: u64 },
    /// Sauvé sous un autre écran (ou sans écran, ou avec) : le noyau a réglé
    /// son mode sur celui qu'il a trouvé.
    AutreEcran,
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
pub fn sauver(poste: &Poste) -> Vec<u8> {
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
        // La source de l'hôte ne se sauve pas : la reprise garde la sienne.
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
    e.0
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
    if version != VERSION {
        return Err(RefusDInstantane::VersionInconnue(version));
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
    super::systeme::rafraichir_le_mode_long(&mut machine.cpu);
    machine.apres_reprise(lu.ombre, lu.placement);
    poste.reposer(lu.du, lu.rattrape);
    Ok(())
}
