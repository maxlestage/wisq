//! La traduction d'adresses de l'interpréteur Rust : quatre niveaux de tables.
//!
//! **Pourquoi ici et pas dans `x86.rs`.** L'interpréteur est la référence du
//! test différentiel, et il ne paginait pas : `GuestMemory` est une fenêtre
//! plate, et les registres de contrôle étaient refusés. Tant qu'il ne pagine
//! pas, rien ne peut juger la pagination de l'émetteur — c'est la tranche
//! suivante, et celle-ci lui pose son juge.
//!
//! **La référence est le cœur Swift**, `Sources/WisqVM/X86Paging.swift`, qui
//! démarre Alpine jusqu'à son shell de secours. Les deux marches sont écrites
//! pour rendre la même chose ; les endroits où elles ne peuvent pas sont dits
//! nommément plus bas.

use crate::x86::{Cpu, Width};

/// Le bit de présence d'une entrée. Sans lui, tout le reste de l'entrée
/// appartient au système d'exploitation et ne veut rien dire pour la machine.
pub const PRESENT: u64 = 1 << 0;

/// Le bit d'écriture d'une entrée.
///
/// **C'est la copie sur écriture.** Quand un programme se dédouble, le noyau
/// ne recopie pas sa mémoire : il donne les mêmes pages aux deux et retire ce
/// bit des deux côtés. Un cœur qui ne le regarde pas laisse l'écriture passer,
/// la copie n'a jamais lieu, et tous les programmes partagent la même page.
pub const WRITABLE: u64 = 1 << 1;

/// « Cette entrée est une grande page et le parcours s'arrête ici. »
pub const HUGE: u64 = 1 << 7;

/// Les bits d'adresse d'une entrée : de 12 à 51.
pub const FRAME: u64 = 0x000F_FFFF_FFFF_F000;

/// CR0.PG — la pagination elle-même.
pub const PAGING: u64 = 1 << 31;

/// CR0.WP. Sans lui, le noyau écrit à travers une page en lecture seule ; avec,
/// il faute comme un programme. Linux l'allume, et c'est ce qui rend la copie
/// sur écriture sûre même quand c'est le noyau qui écrit dans la mémoire d'un
/// programme.
pub const WRITE_PROTECT: u64 = 1 << 16;

/// **Pourquoi une adresse invitée n'a pas de traduction.**
///
/// Un vrai processeur délivrerait `#PF` et le noyau invité déciderait. Ici la
/// machine s'arrête, et ce qui remplace la faute c'est de **nommer l'adresse**
/// — les interruptions sont le mur suivant, et rendre `None` sans rien dire
/// ferait de chaque table mal montée une panne muette.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Unmapped {
    /// Une entrée du parcours n'a pas son bit de présence.
    Absent { address: u64, level: u32 },
    /// Une écriture sur une page en lecture seule, CR0.WP allumé.
    ReadOnly { address: u64 },
    /// **Le parcours lui-même est sorti de la fenêtre attachée.** La table de
    /// pages n'est pas dans la RAM que le harnais a fournie ; c'est une faute
    /// du montage, pas de l'invité, et la confondre avec une page absente
    /// enverrait chercher un défaut là où il n'y en a pas.
    TableOutside { address: u64, table: u64 },
    /// L'adresse traduit, mais l'accès sort de la fenêtre attachée.
    Outside { address: u64 },
}

impl Unmapped {
    /// L'adresse invitée sur laquelle la machine s'est arrêtée.
    pub fn address(&self) -> u64 {
        match self {
            Self::Absent { address, .. }
            | Self::ReadOnly { address }
            | Self::TableOutside { address, .. }
            | Self::Outside { address } => *address,
        }
    }
}

/// Ce que l'accès venait faire. Seul l'écriture change quelque chose ici : il
/// n'y a pas d'anneau trois dans cet interpréteur, donc pas de bit
/// utilisateur à consulter.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Access {
    Read,
    Write,
}

impl Cpu {
    /// La pagination est-elle allumée ?
    pub fn paging(&self) -> bool {
        self.control[0] & PAGING != 0
    }

    /// **L'adresse physique correspondant à une adresse virtuelle.**
    ///
    /// Sans pagination les deux sont la même chose — et c'est le cas au
    /// démarrage, avant que le noyau n'ait posé ses tables. Avec, il faut
    /// parcourir quatre niveaux de neuf bits, pris du haut vers le bas.
    ///
    /// **Aucun cache ici, à la différence du cœur Swift**, qui en tient un de
    /// mille vingt-quatre entrées. L'interpréteur Rust est le juge du test
    /// différentiel, pas le chemin chaud : un cache lui ajouterait un état
    /// invisible à vider au bon moment — trois vidages, dont le troisième a
    /// déjà coûté une chasse entière côté Swift — pour une vitesse dont
    /// personne ne dépend ici. C'est aussi pourquoi `write_control_register`
    /// n'a rien à faire de spécial sur CR3 ou CR4.
    ///
    /// **Ce que la marche ne modélise pas**, et il faut le dire : il n'y a pas
    /// d'anneau trois dans cet interpréteur, donc le bit utilisateur d'une
    /// entrée n'est jamais consulté, et les bits « accédée » et « salie » ne
    /// sont jamais posés. Un noyau qui s'en sert pour choisir sa page à
    /// évincer verrait toutes les pages également froides.
    pub fn translate(&self, virtual_address: u64, access: Access) -> Result<u64, Unmapped> {
        if !self.paging() {
            return Ok(virtual_address);
        }
        let mut table = self.control[3] & FRAME;
        // **Les permissions sont le ET des quatre niveaux.** Une table qui
        // n'est pas inscriptible interdit d'écrire dans tout ce qu'elle
        // couvre, même si la feuille au bout dit le contraire ; c'est ainsi
        // qu'un noyau ferme un espace entier d'un seul bit.
        let mut writable = true;
        for level in [39u32, 30, 21, 12] {
            let index = (virtual_address >> level) & 0x1FF;
            // **Lue physiquement.** Une entrée de table porte une adresse
            // physique ; la faire passer par `translate` serait une récursion
            // sans fond, et un test le tient.
            let entry = self.memory.read(table + index * 8, Width::Qword).ok_or(
                Unmapped::TableOutside {
                    address: virtual_address,
                    table,
                },
            )?;
            if entry & PRESENT == 0 {
                return Err(Unmapped::Absent {
                    address: virtual_address,
                    level,
                });
            }
            writable &= entry & WRITABLE != 0;
            if level > 12 && entry & HUGE != 0 {
                // Une grande page : le reste de l'adresse sert de décalage
                // dedans, et le parcours s'arrête.
                let size = 1u64 << level;
                self.permits(writable, access, virtual_address)?;
                return Ok((entry & FRAME & !(size - 1)) | (virtual_address & (size - 1)));
            }
            table = entry & FRAME;
        }
        self.permits(writable, access, virtual_address)?;
        Ok(table | (virtual_address & 0xFFF))
    }

    /// Cet accès a-t-il le droit ?
    ///
    /// **Une seule question, faute d'anneau trois** : CR0.WP est-il allumé sur
    /// une page en lecture seule. Le cœur Swift en pose deux de plus, qui
    /// n'ont pas d'objet ici.
    fn permits(&self, writable: bool, access: Access, address: u64) -> Result<(), Unmapped> {
        if access == Access::Write && !writable && self.control[0] & WRITE_PROTECT != 0 {
            return Err(Unmapped::ReadOnly { address });
        }
        Ok(())
    }

    /// **Écrire un registre de contrôle.** Rien de plus que poser la valeur :
    /// sans cache de traduction, il n'y a rien à vider — voir `translate`.
    pub fn write_control_register(&mut self, which: u8, value: u64) {
        self.control[which as usize] = value;
    }

    /// Vrai quand l'accès dépasse la fin de sa page.
    fn crosses(at: u64, width: Width) -> bool {
        (at & 0xFFF) + width as u64 > 0x1000
    }

    /// **Lire `width` octets à une adresse virtuelle**, frontière de page
    /// comprise.
    ///
    /// Deux pages virtuelles voisines ne sont voisines en physique que par
    /// accident : dans la carte d'identité du démarrage elles le sont, dans
    /// l'espace des modules elles ne le sont pas. Le cœur Swift a porté ce
    /// défaut — voir `Sources/WisqVM/X86PageStraddle.swift` — et le poser
    /// d'emblée ici évite de le refaire.
    pub fn read_memory(&mut self, at: u64, width: Width) -> Result<u64, Unmapped> {
        let outcome = self.load(at, width);
        self.note(outcome)
    }

    fn load(&self, at: u64, width: Width) -> Result<u64, Unmapped> {
        let outside = || Unmapped::Outside { address: at };
        if !Self::crosses(at, width) {
            let place = self.translate(at, Access::Read)?;
            return self.memory.read(place, width).ok_or_else(outside);
        }
        let head = (0x1000 - (at & 0xFFF)) as usize;
        let low = self.translate(at, Access::Read)?;
        let high = self.translate(at + head as u64, Access::Read)?;
        let low = self.memory.read_bytes(low, head).ok_or_else(outside)?;
        let high = self
            .memory
            .read_bytes(high, width as usize - head)
            .ok_or_else(outside)?;
        Ok(low | (high << (8 * head)))
    }

    /// **Écrire `width` octets à une adresse virtuelle**, frontière comprise.
    pub fn write_memory(&mut self, at: u64, width: Width, value: u64) -> Result<(), Unmapped> {
        let outcome = self.store(at, width, value);
        self.note(outcome)
    }

    fn store(&mut self, at: u64, width: Width, value: u64) -> Result<(), Unmapped> {
        let outside = || Unmapped::Outside { address: at };
        if !Self::crosses(at, width) {
            let place = self.translate(at, Access::Write)?;
            return self.memory.write(place, width, value).ok_or_else(outside);
        }
        // **Tout vérifié avant qu'un seul octet ne soit posé.** Une
        // instruction qui faute ne laisse aucune trace, sans quoi le noyau
        // invité reprendrait sur une moitié de valeur — et les deux
        // traductions ne suffisent pas : la fenêtre attachée peut refuser
        // l'une des deux places.
        let head = (0x1000 - (at & 0xFFF)) as usize;
        let tail = width as usize - head;
        let low = self.translate(at, Access::Write)?;
        let high = self.translate(at + head as u64, Access::Write)?;
        if !self.memory.holds(low, head) || !self.memory.holds(high, tail) {
            return Err(outside());
        }
        self.memory
            .write_bytes(low, head, value)
            .ok_or_else(outside)?;
        self.memory
            .write_bytes(high, tail, value >> (8 * head))
            .ok_or_else(outside)
    }

    /// Ranger le refus là où le reste du cœur peut le lire, et lever
    /// `faulted`. Un vrai processeur délivrerait `#PF` ; ici la machine
    /// s'arrête en nommant l'adresse, et les interruptions sont le mur suivant.
    fn note<T>(&mut self, outcome: Result<T, Unmapped>) -> Result<T, Unmapped> {
        if let Err(why) = outcome {
            self.unmapped = Some(why);
            self.faulted = true;
        }
        outcome
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::x86::{decode, GuestMemory};

    /// Les quatre tables du montage, à des adresses physiques fixes. La RAM
    /// commence à zéro pour qu'une adresse physique soit un décalage : une base
    /// non nulle rendrait chaque entrée illisible à la lecture du test.
    const PML4: u64 = 0x1000;
    const PDPT: u64 = 0x2000;
    const PD: u64 = 0x3000;
    const PT: u64 = 0x4000;
    /// La première trame de données. Loin des tables, pour qu'un parcours qui
    /// se trompe de niveau tombe sur des zéros plutôt que sur du plausible.
    const DATA: u64 = 0x1_0000;

    fn machine() -> Cpu {
        let mut cpu = Cpu {
            memory: GuestMemory {
                base: 0,
                bytes: vec![0; 0x8_0000],
            },
            ..Cpu::default()
        };
        cpu.write_control_register(3, PML4);
        cpu.write_control_register(0, PAGING);
        cpu
    }

    fn put(cpu: &mut Cpu, table: u64, index: u64, entry: u64) {
        cpu.memory
            .write(table + index * 8, Width::Qword, entry)
            .expect("la table tient dans la fenêtre");
    }

    /// Poser une page de quatre kibioctets : les quatre entrées du chemin.
    ///
    /// Un seul jeu de tables, donc toutes les adresses d'un test partagent
    /// leurs trois premiers niveaux — c'est assez tant qu'elles vivent dans le
    /// même bloc de deux mébioctets, et les tests qui en sortent le disent.
    fn map(cpu: &mut Cpu, virtual_address: u64, frame: u64, flags: u64) {
        put(
            cpu,
            PML4,
            (virtual_address >> 39) & 0x1ff,
            PDPT | PRESENT | WRITABLE,
        );
        put(
            cpu,
            PDPT,
            (virtual_address >> 30) & 0x1ff,
            PD | PRESENT | WRITABLE,
        );
        put(
            cpu,
            PD,
            (virtual_address >> 21) & 0x1ff,
            PT | PRESENT | WRITABLE,
        );
        put(
            cpu,
            PT,
            (virtual_address >> 12) & 0x1ff,
            frame | PRESENT | flags,
        );
    }

    /// **Sans pagination, l'adresse virtuelle est l'adresse physique.**
    ///
    /// C'est l'état d'un processeur au démarrage, et c'est celui de tous les
    /// tests écrits avant cette tranche : si ce chemin bougeait, ils
    /// tomberaient tous. Le tenir ici le dit à qui touchera la marche.
    #[test]
    fn without_paging_an_address_is_its_own_translation() {
        let mut cpu = machine();
        cpu.write_control_register(0, 0);
        assert!(!cpu.paging());
        for address in [0u64, 8, 0x1234, DATA, 0x7_FFFF] {
            assert_eq!(cpu.translate(address, Access::Read), Ok(address));
        }
    }

    /// **La marche à quatre niveaux trouve la trame.**
    #[test]
    fn four_levels_lead_to_the_frame() {
        let mut cpu = machine();
        map(&mut cpu, 0xFFFF_8000_0020_1000, DATA, WRITABLE);
        assert_eq!(
            cpu.translate(0xFFFF_8000_0020_1000, Access::Read),
            Ok(DATA),
            "la page traduit"
        );
        assert_eq!(
            cpu.translate(0xFFFF_8000_0020_1ABC, Access::Read),
            Ok(DATA + 0xABC),
            "les douze bits du bas passent tels quels"
        );
    }

    /// **Les tables sont lues physiquement.**
    ///
    /// Le parcours ne peut pas se traduire lui-même : une entrée de table
    /// porte une adresse physique, et la faire passer par `translate` serait
    /// une récursion sans fond. Ce test le montre en posant une correspondance
    /// qui *déplacerait* les tables si elle s'appliquait à elles.
    #[test]
    fn the_tables_are_read_by_their_physical_address() {
        let mut cpu = machine();
        // L'adresse éprouvée est **0x202000** et non 0x201000 : ce montage n'a
        // qu'une table de feuilles, et 0x201000 y occuperait la case 1, la
        // même que le leurre posé juste après. Le test se serait alors mesuré
        // à lui-même.
        map(&mut cpu, 0x20_2000, DATA, WRITABLE);
        // PML4 vu comme une adresse virtuelle mènerait ailleurs — et la marche
        // n'en tient aucun compte.
        map(&mut cpu, PML4, DATA + 0x2000, WRITABLE);
        cpu.memory
            .write(DATA + 0x2000, Width::Qword, 0)
            .expect("la trame leurre tient dans la fenêtre");
        assert_eq!(cpu.translate(0x20_2000, Access::Read), Ok(DATA));
    }

    /// **Une grande page arrête le parcours au troisième niveau.**
    ///
    /// Le bit PS posé sur l'entrée du répertoire : deux mébioctets, et les
    /// vingt et un bits du bas de l'adresse servent de décalage dedans.
    #[test]
    fn a_two_megabyte_page_stops_the_walk_at_the_directory() {
        let mut cpu = machine();
        let big = 0x40_0000u64;
        put(&mut cpu, PML4, 0, PDPT | PRESENT | WRITABLE);
        put(&mut cpu, PDPT, 0, PD | PRESENT | WRITABLE);
        put(
            &mut cpu,
            PD,
            big >> 21,
            0x20_0000 | PRESENT | WRITABLE | HUGE,
        );
        assert_eq!(cpu.translate(big, Access::Read), Ok(0x20_0000));
        assert_eq!(
            cpu.translate(big + 0x1F_FFFF, Access::Read),
            Ok(0x20_0000 + 0x1F_FFFF),
            "les vingt et un bits du bas sont le décalage dans la grande page"
        );
    }

    /// **Une entrée absente arrête la machine en nommant l'adresse**, et en
    /// disant à quel niveau. Les quatre niveaux sont éprouvés un par un :
    /// n'en tenir qu'un laisserait trois `guard` sans juge.
    #[test]
    fn an_absent_entry_names_the_address_and_its_level() {
        for (level, table, index_shift) in [
            (39u32, PML4, 39u32),
            (30, PDPT, 30),
            (21, PD, 21),
            (12, PT, 12),
        ] {
            let mut cpu = machine();
            let at = 0xFFFF_8000_0020_1000u64;
            map(&mut cpu, at, DATA, WRITABLE);
            put(&mut cpu, table, (at >> index_shift) & 0x1ff, 0);
            assert_eq!(
                cpu.translate(at, Access::Read),
                Err(Unmapped::Absent { address: at, level }),
                "le niveau {level} vidé doit être celui qui est nommé"
            );
        }
    }

    /// **Une table hors de la fenêtre attachée ne se confond pas avec une page
    /// absente.** C'est une faute du montage, et le dire autrement enverrait
    /// chercher un défaut d'invité.
    #[test]
    fn a_table_outside_the_window_says_so() {
        let mut cpu = machine();
        let far = 0x9_0000_0000u64;
        cpu.write_control_register(3, far);
        assert_eq!(
            cpu.translate(0x1000, Access::Read),
            Err(Unmapped::TableOutside {
                address: 0x1000,
                table: far
            })
        );
    }

    /// **CR0.WP allumé, une page en lecture seule refuse l'écriture** — et la
    /// laisse passer quand il est éteint. Les deux moitiés sont ici : ne tenir
    /// que la première ferait passer un cœur qui refuse toujours.
    #[test]
    fn a_read_only_page_refuses_a_write_only_when_write_protect_is_on() {
        let mut cpu = machine();
        let at = 0x20_1000u64;
        map(&mut cpu, at, DATA, 0); // sans WRITABLE
        assert_eq!(
            cpu.translate(at, Access::Read),
            Ok(DATA),
            "la lecture passe"
        );
        assert_eq!(
            cpu.translate(at, Access::Write),
            Ok(DATA),
            "sans CR0.WP, le noyau écrit à travers"
        );
        cpu.write_control_register(0, PAGING | WRITE_PROTECT);
        assert_eq!(
            cpu.translate(at, Access::Write),
            Err(Unmapped::ReadOnly { address: at })
        );
        assert_eq!(
            cpu.translate(at, Access::Read),
            Ok(DATA),
            "la lecture passe toujours"
        );
    }

    /// **Les permissions sont le ET des quatre niveaux.** Une table qui n'est
    /// pas inscriptible interdit d'écrire dans tout ce qu'elle couvre, même si
    /// la feuille au bout dit le contraire ; c'est ainsi qu'un noyau ferme un
    /// espace entier d'un seul bit.
    #[test]
    fn a_read_only_table_closes_everything_below_it() {
        let mut cpu = machine();
        let at = 0x20_1000u64;
        map(&mut cpu, at, DATA, WRITABLE);
        cpu.write_control_register(0, PAGING | WRITE_PROTECT);
        assert_eq!(cpu.translate(at, Access::Write), Ok(DATA));
        // Le répertoire perd son bit d'écriture ; la feuille garde le sien.
        put(&mut cpu, PD, (at >> 21) & 0x1ff, PT | PRESENT);
        assert_eq!(
            cpu.translate(at, Access::Write),
            Err(Unmapped::ReadOnly { address: at }),
            "un niveau en lecture seule suffit"
        );
    }

    /// **Écrire CR3 change la carte entière.** La même adresse virtuelle mène
    /// à deux trames selon la racine en place.
    #[test]
    fn writing_cr3_changes_the_whole_map() {
        let mut cpu = machine();
        let at = 0x20_1000u64;
        map(&mut cpu, at, DATA, WRITABLE);
        assert_eq!(cpu.translate(at, Access::Read), Ok(DATA));

        // Une seconde racine, ses propres tables, la même adresse virtuelle.
        let (pml4, pdpt, pd, pt) = (0x5000u64, 0x6000, 0x7000, 0x8000);
        put(
            &mut cpu,
            pml4,
            (at >> 39) & 0x1ff,
            pdpt | PRESENT | WRITABLE,
        );
        put(&mut cpu, pdpt, (at >> 30) & 0x1ff, pd | PRESENT | WRITABLE);
        put(&mut cpu, pd, (at >> 21) & 0x1ff, pt | PRESENT | WRITABLE);
        put(
            &mut cpu,
            pt,
            (at >> 12) & 0x1ff,
            (DATA + 0x1000) | PRESENT | WRITABLE,
        );
        cpu.write_control_register(3, pml4);
        assert_eq!(
            cpu.translate(at, Access::Read),
            Ok(DATA + 0x1000),
            "la nouvelle racine mène ailleurs"
        );
    }

    /// **Un accès à cheval sur deux pages emprunte les deux traductions.**
    ///
    /// C'est le défaut que le cœur Swift a porté et que
    /// `Sources/WisqVM/X86PageStraddle.swift` ferme : deux pages virtuelles
    /// voisines ne sont voisines en physique que par accident. Le poser ici
    /// d'emblée évite de le refaire.
    #[test]
    fn an_access_across_a_page_boundary_uses_both_translations() {
        let mut cpu = machine();
        let at = 0x20_1FFCu64; // quatre octets avant la fin de sa page
        map(&mut cpu, 0x20_1000, DATA, WRITABLE);
        // La page virtuelle suivante mène **en arrière** en physique : si
        // l'accès prenait huit octets contigus, il lirait la trame d'à côté.
        map(&mut cpu, 0x20_2000, DATA - 0x1000, WRITABLE);

        cpu.write_memory(at, Width::Qword, 0x1122_3344_5566_7788)
            .expect("l'écriture passe");
        assert_eq!(
            cpu.memory.read(DATA + 0xFFC, Width::Dword),
            Some(0x5566_7788),
            "la moitié basse est au bout de la première trame"
        );
        assert_eq!(
            cpu.memory.read(DATA - 0x1000, Width::Dword),
            Some(0x1122_3344),
            "la moitié haute est au début de la seconde"
        );
        assert_eq!(
            cpu.read_memory(at, Width::Qword),
            Ok(0x1122_3344_5566_7788),
            "et la relecture recolle les deux moitiés"
        );
    }

    /// **Une écriture à cheval dont la seconde page manque ne pose rien.**
    ///
    /// Les deux traductions d'abord, les deux écritures ensuite : une
    /// instruction qui faute ne doit laisser aucune trace, sans quoi le noyau
    /// invité reprendrait sur une moitié de valeur.
    #[test]
    fn a_straddling_write_whose_far_page_is_missing_leaves_nothing_behind() {
        let mut cpu = machine();
        let at = 0x20_1FFCu64;
        map(&mut cpu, 0x20_1000, DATA, WRITABLE);
        put(&mut cpu, PT, (0x20_2000u64 >> 12) & 0x1ff, 0);
        cpu.memory
            .write(DATA + 0xFFC, Width::Dword, 0xDEAD_BEEF)
            .expect("le témoin tient");

        let refusal = cpu
            .write_memory(at, Width::Qword, 0x1122_3344_5566_7788)
            .expect_err("la seconde page manque");
        assert_eq!(
            refusal.address(),
            0x20_2000,
            "c'est la page haute qui manque"
        );
        assert_eq!(
            cpu.memory.read(DATA + 0xFFC, Width::Dword),
            Some(0xDEAD_BEEF),
            "la moitié basse n'a pas été posée"
        );
    }

    /// **L'autre mur de la même écriture : la trame haute existe pour les
    /// tables, mais pas dans la RAM attachée.**
    ///
    /// Le test voisin coupe l'écriture par une *traduction* qui échoue ; ici
    /// les deux traductions réussissent et c'est la fenêtre qui refuse. Deux
    /// gardes différentes, et vérifier les traductions ne suffit pas : sans
    /// l'examen des deux places avant la première écriture, la moitié basse
    /// serait posée.
    #[test]
    fn a_straddling_write_whose_far_frame_is_outside_the_window_leaves_nothing_behind() {
        let mut cpu = machine();
        let at = 0x20_1FFCu64;
        map(&mut cpu, 0x20_1000, DATA, WRITABLE);
        // Une trame que la table nomme et que la RAM attachée n'a pas.
        map(&mut cpu, 0x20_2000, 0x9_0000, WRITABLE);
        cpu.memory
            .write(DATA + 0xFFC, Width::Dword, 0xDEAD_BEEF)
            .expect("le témoin tient");

        let refusal = cpu
            .write_memory(at, Width::Qword, 0x1122_3344_5566_7788)
            .expect_err("la trame haute sort de la fenêtre");
        assert_eq!(refusal, Unmapped::Outside { address: at });
        assert_eq!(
            cpu.memory.read(DATA + 0xFFC, Width::Dword),
            Some(0xDEAD_BEEF),
            "la moitié basse n'a pas été posée"
        );
    }

    /// **`mov %cr3,%rax` et `mov %rax,%cr3` s'exécutent** au lieu d'être
    /// refusés, et le nombre fait l'aller-retour.
    #[test]
    fn the_control_registers_are_executed_rather_than_refused() {
        let mut cpu = machine();
        cpu.regs[0] = 0x9_A000;
        // `0f 22 d8` — mov %rax,%cr3
        let write = decode(&[0x0f, 0x22, 0xd8]).expect("mov %rax,%cr3");
        cpu.execute(&write);
        assert!(!cpu.faulted, "l'écriture n'est plus un refus");
        assert_eq!(cpu.control[3], 0x9_A000);

        // `0f 20 d9` — mov %cr3,%rcx
        let read = decode(&[0x0f, 0x20, 0xd9]).expect("mov %cr3,%rcx");
        cpu.execute(&read);
        assert!(!cpu.faulted, "la lecture n'est plus un refus");
        assert_eq!(cpu.regs[1], 0x9_A000, "le nombre fait l'aller-retour");
    }

    /// **Les instructions ordinaires passent par la traduction.**
    ///
    /// C'est la moitié qui décide de tout : une marche que personne n'emprunte
    /// serait du code juste et mort. Trois chemins distincts sont éprouvés,
    /// parce qu'ils sont écrits à trois endroits — l'opérande source, la
    /// destination écrite, et la pile.
    #[test]
    fn ordinary_instructions_reach_memory_through_the_translation() {
        let load = |paging: bool| {
            let mut cpu = machine();
            if !paging {
                cpu.write_control_register(0, 0);
            }
            map(&mut cpu, 0x20_1000, DATA, WRITABLE);
            cpu.memory
                .write(DATA, Width::Qword, 0xCAFE_F00D)
                .expect("la trame tient");
            cpu.regs[6] = 0x20_1000; // RSI
                                     // `48 8b 06` — mov (%rsi),%rax
            cpu.execute(&decode(&[0x48, 0x8b, 0x06]).expect("mov (%rsi),%rax"));
            cpu
        };
        let cpu = load(true);
        assert!(!cpu.faulted, "la page est là");
        assert_eq!(cpu.regs[0], 0xCAFE_F00D, "la lecture a suivi la traduction");
        // **Le contraste, sans quoi le test passerait sur une identité.** Sans
        // pagination la même adresse mène ailleurs, et l'invité lit des zéros.
        let flat = load(false);
        assert_eq!(flat.regs[0], 0, "sans pagination, 0x201000 est vide");

        // L'écriture, l'autre chemin.
        let mut cpu = machine();
        map(&mut cpu, 0x20_1000, DATA, WRITABLE);
        cpu.regs[6] = 0x20_1000;
        cpu.regs[0] = 0x1234_5678;
        // `48 89 06` — mov %rax,(%rsi)
        cpu.execute(&decode(&[0x48, 0x89, 0x06]).expect("mov %rax,(%rsi)"));
        assert!(!cpu.faulted);
        assert_eq!(
            cpu.memory.read(DATA, Width::Qword),
            Some(0x1234_5678),
            "l'écriture est allée dans la trame, pas à l'adresse virtuelle"
        );

        // La pile, écrite par `push` sans passer par les opérandes.
        let mut cpu = machine();
        map(&mut cpu, 0x20_1000, DATA, WRITABLE);
        cpu.regs[4] = 0x20_1800; // RSP, au milieu de la page
        cpu.regs[0] = 0xABCD;
        cpu.execute(&decode(&[0x50]).expect("push %rax"));
        assert!(!cpu.faulted);
        assert_eq!(cpu.regs[4], 0x20_17F8);
        assert_eq!(
            cpu.memory.read(DATA + 0x7F8, Width::Qword),
            Some(0xABCD),
            "la pile aussi passe par la traduction"
        );
    }

    /// **Une page absente sous une instruction ordinaire arrête la machine, et
    /// nomme l'adresse.** `faulted` seul dirait qu'il y a eu faute ; il ne
    /// dirait pas laquelle, et c'est la seule chose utile quand un noyau part
    /// dans le décor.
    #[test]
    fn a_missing_page_under_an_instruction_names_the_address() {
        let mut cpu = machine();
        cpu.regs[6] = 0x20_1000;
        cpu.execute(&decode(&[0x48, 0x8b, 0x06]).expect("mov (%rsi),%rax"));
        assert!(cpu.faulted, "aucune table ne porte cette adresse");
        assert_eq!(
            cpu.unmapped.map(|why| why.address()),
            Some(0x20_1000),
            "et l'adresse est nommée"
        );
    }

    /// **Allumer la pagination par l'instruction, pas par le champ.** Un test
    /// qui poserait `control[0]` à la main tiendrait la marche sans tenir le
    /// chemin par lequel un vrai noyau l'allume.
    #[test]
    fn a_guest_turns_paging_on_by_writing_cr0() {
        let mut cpu = machine();
        cpu.write_control_register(0, 0);
        map(&mut cpu, 0x20_1000, DATA, WRITABLE);
        assert_eq!(
            cpu.translate(0x20_1000, Access::Read),
            Ok(0x20_1000),
            "avant, l'identité"
        );

        cpu.regs[0] = PAGING;
        cpu.execute(&decode(&[0x0f, 0x22, 0xc0]).expect("mov %rax,%cr0"));
        assert!(!cpu.faulted);
        assert!(cpu.paging());
        assert_eq!(
            cpu.translate(0x20_1000, Access::Read),
            Ok(DATA),
            "après, la marche"
        );
    }

    /// **Un `cmpxchg16b` dont la seconde moitié est en lecture seule ne
    /// laisse aucune trace de la première.**
    ///
    /// Seize octets à cheval sur deux pages, la première inscriptible, la
    /// seconde non, CR0.WP allumé. Les deux lectures passent — lire une page
    /// en lecture seule est permis —, la comparaison tient, la première
    /// écriture passe, la seconde faute. Un cœur qui s'arrêterait là
    /// laisserait une moitié de paire neuve en mémoire, et le noyau invité
    /// reprendrait sur une liste libre à moitié écrite. Le cœur défait la
    /// première écriture, rapporte la faute, ne touche ni RDX:RAX ni ZF, et
    /// laisse RIP dessus.
    #[test]
    fn a_cmpxchg16b_whose_second_half_is_read_only_leaves_the_first_half_as_it_was() {
        const A_LOW: u64 = 0x1111_2222_3333_4444;
        const A_HIGH: u64 = 0x5555_6666_7777_8888;
        let mut cpu = machine();
        map(&mut cpu, 0x20_1000, DATA, WRITABLE);
        map(&mut cpu, 0x20_2000, DATA + 0x1000, 0); // sans WRITABLE
        cpu.write_control_register(0, PAGING | WRITE_PROTECT);
        // La paire : huit octets au bout de la première page, huit au début
        // de la seconde.
        cpu.memory.write(DATA + 0xff8, Width::Qword, A_LOW).unwrap();
        cpu.memory
            .write(DATA + 0x1000, Width::Qword, A_HIGH)
            .unwrap();
        cpu.rip = 0x1000;
        cpu.regs[0] = A_LOW;
        cpu.regs[2] = A_HIGH;
        cpu.regs[3] = 0x9999_aaaa_bbbb_cccc;
        cpu.regs[1] = 0xdddd_eeee_ffff_0000;
        cpu.regs[6] = 0x20_1ff8 - 0x20;
        cpu.flags.write(crate::x86::CF);

        cpu.step(&[0xf0, 0x48, 0x0f, 0xc7, 0x4e, 0x20]); // lock cmpxchg16b 0x20(%rsi)

        assert!(cpu.faulted, "la seconde moitié refuse l'écriture");
        assert_eq!(
            cpu.unmapped,
            Some(Unmapped::ReadOnly { address: 0x20_2000 }),
            "et la faute nomme la page en lecture seule"
        );
        assert_eq!(
            cpu.memory.read(DATA + 0xff8, Width::Qword),
            Some(A_LOW),
            "la première moitié est défaite"
        );
        assert_eq!(
            cpu.memory.read(DATA + 0x1000, Width::Qword),
            Some(A_HIGH),
            "la seconde n'a jamais été écrite"
        );
        assert_eq!(
            (cpu.regs[0], cpu.regs[2]),
            (A_LOW, A_HIGH),
            "RDX:RAX intacts"
        );
        let flags = cpu.flags.read();
        assert_eq!(flags & crate::x86::ZF, 0, "ZF n'est pas posé");
        assert_ne!(flags & crate::x86::CF, 0, "et le reste survit");
        assert_eq!(cpu.rip, 0x1000, "RIP reste dessus");
    }
}
