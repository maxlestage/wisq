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
    /// **La page est là, et l'anneau n'y a pas droit** : le bit utilisateur
    /// manque à un niveau pour un accès de l'anneau trois, ou le bit 63
    /// interdit d'exécuter (EFER.NXE allumé).
    Forbidden { address: u64 },
    /// **L'adresse n'est pas canonique** : ses bits 63 à 47 ne sont pas tous
    /// égaux. Les tables n'en traduisent que quarante-huit, et la marcher
    /// quand même la confondrait avec son alias — une lecture à
    /// 0x8000_0000_0000_6000 rendrait le contenu de 0x6000. Le silicium ne
    /// lève pas de faute de page : `#GP(0)` pour une référence par DS, ES, FS
    /// ou GS, et **`#SS(0)` pour une référence par la pile** (`push`, `pop`,
    /// `call`, `ret`, ou une adresse bâtie sur RSP ou RBP). La machine PC fait
    /// la différence au moment de livrer (`pc::machine`). Seule la traduction
    /// de la machine PC (`translate_cached`, avec son tampon) la rend ;
    /// `translate`, le juge de l'émetteur, marche les tables comme il l'a
    /// toujours fait.
    NonCanonical { address: u64 },
    /// **Une cible de saut qui n'est pas canonique** : `Cpu` refuse de charger
    /// RIP avec elle (`jmp`, `call`, `ret`, `jcc`, `loop`, `jrcxz`), et la
    /// faute tombe sur le saut, pas sur l'instruction d'après. Ce n'est pas un
    /// accès : le silicium lève toujours `#GP(0)`, même pour la cible d'un
    /// `ret`, qui vient de la pile.
    NonCanonicalTarget { address: u64 },
}

impl Unmapped {
    /// L'adresse invitée sur laquelle la machine s'est arrêtée.
    pub fn address(&self) -> u64 {
        match self {
            Self::Absent { address, .. }
            | Self::ReadOnly { address }
            | Self::TableOutside { address, .. }
            | Self::Outside { address }
            | Self::Forbidden { address }
            | Self::NonCanonical { address }
            | Self::NonCanonicalTarget { address } => *address,
        }
    }
}

/// **Une adresse canonique** est l'extension de signe de ses quarante-huit
/// bits bas : ses bits 63 à 47 sont tous égaux.
#[inline(always)]
pub fn is_canonical(address: u64) -> bool {
    ((address as i64) << 16) >> 16 == address as i64
}

/// **La mémoire d'un périphérique** : ce qui répond à une adresse physique
/// que la RAM ne couvre pas — au-delà de sa fin, ou dans le trou sous quatre
/// gibioctets. L'écran de Bochs (sa mémoire vidéo et ses registres) et la
/// tablette y vivent, derrière les BAR que le pont PCI annonce ; c'est le
/// `readSlowly` et le `writeSlowly` de `X86Memory.swift`.
///
/// `largeur` va de 1 à 8 octets. `None` (ou `false`) : personne ne répond, et
/// l'accès reste refusé comme avant (`Unmapped::Outside`).
pub trait DeviceMemory: Send {
    fn read(&mut self, place: u64, width: u8) -> Option<u64>;
    fn write(&mut self, place: u64, width: u8, value: u64) -> bool;
    /// Quelqu'un répond-il à ces `width` octets ? Sans rien lire ni écrire :
    /// ce qu'un accès à cheval demande avant de poser son premier octet.
    fn claims(&self, place: u64, width: u8) -> bool;
}

/// **Les périphériques derrière la mémoire**, partagés : la machine PC les
/// tient aussi par leurs ports. Rien par défaut — l'interpréteur de
/// référence et le juge de l'émetteur n'en ont pas, et ne voient aucune
/// différence. Seul le chemin lent les consulte : le tampon de traduction ne
/// garde jamais une page hors de la RAM, donc une adresse ordinaire ne les
/// rencontre pas.
#[derive(Clone, Default)]
pub struct Devices(pub Option<std::sync::Arc<std::sync::Mutex<dyn DeviceMemory>>>);

impl std::fmt::Debug for Devices {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(if self.0.is_some() {
            "Devices(branchés)"
        } else {
            "Devices(aucun)"
        })
    }
}

impl Devices {
    /// Lire `width` octets d'un périphérique, à cette adresse physique.
    #[cold]
    #[inline(never)]
    pub fn read(&self, place: u64, width: usize) -> Option<u64> {
        let bus = self.0.as_ref()?;
        let mut bus = bus.lock().unwrap_or_else(|poison| poison.into_inner());
        bus.read(place, u8::try_from(width).ok()?)
    }

    /// Écrire `width` octets dans un périphérique ; `false` sans personne.
    #[cold]
    #[inline(never)]
    pub fn write(&self, place: u64, width: usize, value: u64) -> bool {
        let Some(bus) = self.0.as_ref() else {
            return false;
        };
        let Ok(width) = u8::try_from(width) else {
            return false;
        };
        let mut bus = bus.lock().unwrap_or_else(|poison| poison.into_inner());
        bus.write(place, width, value)
    }

    /// Un périphérique répond-il à ces octets ? Voir `DeviceMemory::claims`.
    #[cold]
    #[inline(never)]
    pub fn claims(&self, place: u64, width: usize) -> bool {
        let Some(bus) = self.0.as_ref() else {
            return false;
        };
        let Ok(width) = u8::try_from(width) else {
            return false;
        };
        let bus = bus.lock().unwrap_or_else(|poison| poison.into_inner());
        bus.claims(place, width)
    }
}

/// Le bit utilisateur d'une entrée : sans lui à chaque niveau, l'anneau trois
/// n'a aucun droit sur la page.
pub const USER: u64 = 1 << 2;

/// « Accédée » : le processeur le pose en traversant l'entrée.
pub const ACCESSED: u64 = 1 << 5;

/// « Salie » : le processeur le pose sur la feuille à la première écriture.
pub const DIRTY: u64 = 1 << 6;

/// Le bit 63 d'une entrée : la page ne s'exécute pas, quand EFER.NXE le permet.
pub const NO_EXECUTE: u64 = 1 << 63;

/// EFER.NXE : sans lui, le bit 63 d'une entrée n'interdit rien.
pub const NO_EXECUTE_ENABLE: u64 = 1 << 11;

/// Ce que l'accès venait faire.
///
/// `Fetch` est la lecture d'une instruction, que le bit 63 peut interdire.
/// `Machine` est une lecture que le processeur fait pour son compte — une porte
/// de l'IDT, un descripteur, une pile du TSS — : elle a les droits de l'anneau
/// zéro quel que soit l'anneau du programme interrompu.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Access {
    Read,
    Write,
    Fetch,
    Machine,
}

/// Ce qu'une marche des tables a trouvé : la page physique, ses droits, et les
/// entrées traversées (leur adresse physique et leur valeur), pour que le
/// tampon de traduction puisse y poser les bits « accédée » et « salie ».
#[derive(Clone, Copy, Debug)]
struct Walked {
    /// L'adresse physique de l'octet visé.
    place: u64,
    /// Le ET des bits d'écriture et d'utilisateur des niveaux traversés, et le
    /// OU de leurs bits « pas d'exécution ».
    writable: bool,
    user: bool,
    no_execute: bool,
    entries: [(u64, u64); 4],
    depth: usize,
}

/// **Le tampon de traduction de la machine PC** : mille vingt-quatre cases à
/// accès direct, comme celui du cœur Swift.
///
/// Une case garde la page physique et les droits **bruts** de la page ; le
/// droit de l'accès se décide à chaque passage, contre l'anneau et CR0.WP du
/// moment. Un changement d'anneau ne vide donc rien. Ce qui vide : écrire CR3,
/// CR4, le bit de pagination ou de protection de CR0 (`write_control_register`),
/// EFER et `invlpg` (la machine appelle `flush_translations`).
///
/// **Une case ne sert à l'écriture que si la feuille est déjà « salie ».** La
/// première écriture repasse par les tables et y pose le bit, comme le
/// silicium ; les suivantes ne paient rien.
#[derive(Clone, Debug)]
pub struct Tlb {
    /// Les cases, dans la boîte même : une lecture du chemin rapide va du
    /// processeur à la case sans passer par un second pointeur.
    entries: [TlbEntry; TLB_SLOTS],
    /// Le nombre de vidages. Qui garde une traduction hors du tampon — la
    /// page d'instructions de la boucle d'exécution — la compare à ce compte.
    pub generation: u64,
}

#[derive(Clone, Copy, Debug, Default)]
struct TlbEntry {
    /// L'adresse de la page virtuelle, plus un : zéro veut dire « vide ».
    tag: u64,
    frame: u64,
    flags: u8,
}

const TLB_SLOTS: usize = 1024;
const TLB_WRITABLE: u8 = 1;
const TLB_USER: u8 = 2;
const TLB_NO_EXECUTE: u8 = 4;
const TLB_DIRTY: u8 = 8;

impl Default for Tlb {
    fn default() -> Self {
        Self {
            entries: [TlbEntry::default(); TLB_SLOTS],
            generation: 0,
        }
    }
}

impl Cpu {
    /// La pagination est-elle allumée ?
    pub fn paging(&self) -> bool {
        self.control[0] & PAGING != 0
    }

    /// L'anneau courant : les deux bits bas de CS.
    pub fn privilege(&self) -> u8 {
        (self.segments[1] & 3) as u8
    }

    /// **Donner un tampon de traduction à ce processeur.** C'est ce qui fait
    /// de lui celui d'une machine : les accès passent par le tampon, et les
    /// bits « accédée » et « salie » sont posés dans les tables.
    pub fn with_translation_cache(mut self) -> Self {
        self.tlb = Some(Box::default());
        self
    }

    /// Oublier toutes les traductions gardées. Sans tampon, rien à faire.
    pub fn flush_translations(&mut self) {
        if let Some(tlb) = self.tlb.as_mut() {
            for entry in tlb.entries.iter_mut() {
                entry.tag = 0;
            }
            tlb.generation = tlb.generation.wrapping_add(1);
        }
    }

    /// **L'adresse physique correspondant à une adresse virtuelle.**
    ///
    /// Sans pagination les deux sont la même chose — et c'est le cas au
    /// démarrage, avant que le noyau n'ait posé ses tables. Avec, il faut
    /// parcourir quatre niveaux de neuf bits, pris du haut vers le bas.
    ///
    /// **Aucun cache ici** : cette fonction marche les tables à chaque appel
    /// et ne les modifie pas. C'est le juge du test différentiel, et un cache
    /// lui ajouterait un état invisible à vider au bon moment. La machine PC,
    /// elle, passe par `translate_cached`, qui garde les traductions dans
    /// `Tlb` et pose les bits « accédée » et « salie ».
    ///
    /// **Les droits sont ceux du cœur Swift** : en anneau trois il faut le bit
    /// utilisateur à chaque niveau, et le bit d'écriture pour écrire ; en
    /// anneau zéro, seule l'écriture sur une page en lecture seule est
    /// refusée, et seulement si CR0.WP est allumé. L'anneau est zéro tant que
    /// personne n'a chargé CS — ce que cet interpréteur a toujours été.
    pub fn translate(&self, virtual_address: u64, access: Access) -> Result<u64, Unmapped> {
        if !self.paging() {
            return Ok(virtual_address);
        }
        let walked = self.walk(virtual_address)?;
        self.permits(&walked, access, virtual_address)?;
        Ok(walked.place)
    }

    /// La marche elle-même, sans jugement des droits.
    fn walk(&self, virtual_address: u64) -> Result<Walked, Unmapped> {
        let mut table = self.control[3] & FRAME;
        // **Les permissions sont le ET des quatre niveaux.** Une table qui
        // n'est pas inscriptible interdit d'écrire dans tout ce qu'elle
        // couvre, même si la feuille au bout dit le contraire ; c'est ainsi
        // qu'un noyau ferme un espace entier d'un seul bit.
        let mut walked = Walked {
            place: 0,
            writable: true,
            user: true,
            no_execute: false,
            entries: [(0, 0); 4],
            depth: 0,
        };
        for level in [39u32, 30, 21, 12] {
            let index = (virtual_address >> level) & 0x1FF;
            // **Lue physiquement.** Une entrée de table porte une adresse
            // physique ; la faire passer par `translate` serait une récursion
            // sans fond, et un test le tient.
            let at = table + index * 8;
            let entry = self
                .memory
                .read(at, Width::Qword)
                .ok_or(Unmapped::TableOutside {
                    address: virtual_address,
                    table,
                })?;
            if entry & PRESENT == 0 {
                return Err(Unmapped::Absent {
                    address: virtual_address,
                    level,
                });
            }
            walked.entries[walked.depth] = (at, entry);
            walked.depth += 1;
            walked.writable &= entry & WRITABLE != 0;
            walked.user &= entry & USER != 0;
            walked.no_execute |= entry & NO_EXECUTE != 0;
            if level > 12 && entry & HUGE != 0 {
                // Une grande page : le reste de l'adresse sert de décalage
                // dedans, et le parcours s'arrête.
                let size = 1u64 << level;
                walked.place = (entry & FRAME & !(size - 1)) | (virtual_address & (size - 1));
                return Ok(walked);
            }
            table = entry & FRAME;
        }
        walked.place = table | (virtual_address & 0xFFF);
        Ok(walked)
    }

    /// Cet accès a-t-il le droit ?
    fn permits(&self, walked: &Walked, access: Access, address: u64) -> Result<(), Unmapped> {
        let flags = (if walked.writable { TLB_WRITABLE } else { 0 })
            | (if walked.user { TLB_USER } else { 0 })
            | (if walked.no_execute && self.efer & NO_EXECUTE_ENABLE != 0 {
                TLB_NO_EXECUTE
            } else {
                0
            })
            | TLB_DIRTY;
        if self.allowed(flags, access) {
            return Ok(());
        }
        Err(self.refusal(flags, access, address))
    }

    /// Le refus qui correspond à des droits insuffisants : lecture seule quand
    /// c'est l'écriture qui manque, interdite sinon (le bit utilisateur, ou le
    /// bit 63 devant une lecture d'instruction).
    fn refusal(&self, flags: u8, access: Access, address: u64) -> Unmapped {
        let user_ok = self.privilege() < 3 || flags & TLB_USER != 0;
        if access == Access::Write && user_ok {
            Unmapped::ReadOnly { address }
        } else {
            Unmapped::Forbidden { address }
        }
    }

    /// Les droits bruts d'une page suffisent-ils à cet accès, maintenant ?
    #[inline(always)]
    fn allowed(&self, flags: u8, access: Access) -> bool {
        let user = self.segments[1] & 3 == 3;
        match access {
            Access::Machine => true,
            Access::Read => !user || flags & TLB_USER != 0,
            Access::Fetch => (!user || flags & TLB_USER != 0) && flags & TLB_NO_EXECUTE == 0,
            Access::Write => {
                if flags & TLB_DIRTY == 0 {
                    return false;
                }
                if user {
                    flags & (TLB_USER | TLB_WRITABLE) == TLB_USER | TLB_WRITABLE
                } else {
                    flags & TLB_WRITABLE != 0 || self.control[0] & WRITE_PROTECT == 0
                }
            }
        }
    }

    /// Le code d'erreur qu'une faute de page empile pour cet accès.
    fn page_fault_code(&self, present: bool, access: Access) -> u64 {
        u64::from(present)
            | (u64::from(access == Access::Write) << 1)
            | (u64::from(self.privilege() == 3 && access != Access::Machine) << 2)
            | (u64::from(access == Access::Fetch) << 4)
    }

    /// **La traduction de la machine PC** : par le tampon, et sinon par les
    /// tables — en y posant « accédée » sur chaque entrée traversée et
    /// « salie » sur la feuille quand l'accès écrit, comme le silicium.
    ///
    /// Sans tampon posé (`tlb` à `None`), c'est `translate`.
    #[inline(always)]
    pub fn translate_cached(
        &mut self,
        virtual_address: u64,
        access: Access,
    ) -> Result<u64, Unmapped> {
        if self.control[0] & PAGING == 0 {
            return Ok(virtual_address);
        }
        let Some(tlb) = self.tlb.as_ref() else {
            return self.translate(virtual_address, access);
        };
        let page = virtual_address & !0xFFF;
        let slot = (page >> 12) as usize & (TLB_SLOTS - 1);
        let entry = tlb.entries[slot];
        if entry.tag == page.wrapping_add(1) && self.allowed(entry.flags, access) {
            return Ok(entry.frame | (virtual_address & 0xFFF));
        }
        self.fill(virtual_address, access)
    }

    /// Le chemin lent de `translate_cached` : marcher, juger, marquer, garder.
    #[inline(never)]
    fn fill(&mut self, virtual_address: u64, access: Access) -> Result<u64, Unmapped> {
        // Le contrôle est ici, sur le chemin lent : une adresse qui n'est pas
        // canonique n'entre jamais au tampon, donc n'y est jamais trouvée.
        if !is_canonical(virtual_address) {
            return Err(Unmapped::NonCanonical {
                address: virtual_address,
            });
        }
        let walked = match self.walk(virtual_address) {
            Ok(walked) => walked,
            Err(why) => {
                self.fault_code = self.page_fault_code(false, access);
                return Err(why);
            }
        };
        let nx = walked.no_execute && self.efer & NO_EXECUTE_ENABLE != 0;
        let rights = (if walked.writable { TLB_WRITABLE } else { 0 })
            | (if walked.user { TLB_USER } else { 0 })
            | (if nx { TLB_NO_EXECUTE } else { 0 });
        // Le droit se juge comme si la page était déjà salie : c'est la
        // marche qui la salit, juste après.
        if !self.allowed(rights | TLB_DIRTY, access) {
            self.fault_code = self.page_fault_code(true, access);
            return Err(self.refusal(rights | TLB_DIRTY, access, virtual_address));
        }
        // **Les bits que le processeur pose lui-même.** « Accédée » à chaque
        // niveau, « salie » sur la feuille d'une écriture. Un noyau lit le
        // second pour savoir quelles pages réécrire sur le disque.
        let writes = access == Access::Write;
        let last = walked.depth - 1;
        let mut dirty = false;
        for (rank, &(at, entry)) in walked.entries[..walked.depth].iter().enumerate() {
            let mut marked = entry | ACCESSED;
            if rank == last {
                if writes {
                    marked |= DIRTY;
                }
                dirty = marked & DIRTY != 0;
            }
            if marked != entry {
                let _ = self.memory.write(at, Width::Qword, marked);
            }
        }
        let page = virtual_address & !0xFFF;
        let frame = walked.place & !0xFFF;
        // **Seule la RAM se garde.** Une page hors de la mémoire attachée, ou
        // dans le trou sous quatre gibioctets, n'entre pas au tampon : l'accès
        // la refusera à chaque fois, par le chemin lent.
        if self.memory.holds(frame, 0x1000) && !self.in_hole(frame) {
            if let Some(tlb) = self.tlb.as_mut() {
                let slot = (page >> 12) as usize & (TLB_SLOTS - 1);
                tlb.entries[slot] = TlbEntry {
                    tag: page.wrapping_add(1),
                    frame,
                    flags: rights | if dirty { TLB_DIRTY } else { 0 },
                };
            }
        }
        Ok(walked.place)
    }

    /// L'adresse physique est-elle dans le trou de la carte mémoire d'un PC ?
    /// Voir `Cpu::memory_hole`.
    #[inline(always)]
    fn in_hole(&self, place: u64) -> bool {
        place.wrapping_sub(self.memory_hole.0) < self.memory_hole.1
    }

    /// **Écrire un registre de contrôle.** Poser la valeur, et vider le tampon
    /// de traduction quand elle change ce qu'il garde : CR3 (une autre table),
    /// CR4, et les bits de pagination et de protection en écriture de CR0. Les
    /// trois vidages sont ceux du cœur Swift, dont le troisième a coûté une
    /// chasse entière.
    pub fn write_control_register(&mut self, which: u8, value: u64) {
        let previous = self.control[which as usize];
        self.control[which as usize] = value;
        if which == 3
            || which == 4
            || (which == 0 && (previous ^ value) & (PAGING | WRITE_PROTECT) != 0)
        {
            self.flush_translations();
        }
    }

    /// Vrai quand l'accès dépasse la fin de sa page.
    #[inline(always)]
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
    #[inline]
    pub fn read_memory(&mut self, at: u64, width: Width) -> Result<u64, Unmapped> {
        let outcome = self.load(at, width, Access::Read);
        self.note(outcome)
    }

    /// La même lecture, avec les droits que le processeur prend pour lui-même
    /// (`Access::Machine`) : une porte de l'IDT, un descripteur, une pile du
    /// TSS se lisent en anneau zéro même quand un programme est interrompu.
    pub fn read_memory_as_machine(&mut self, at: u64, width: Width) -> Result<u64, Unmapped> {
        let outcome = self.load(at, width, Access::Machine);
        self.note(outcome)
    }

    /// Lire un octet d'instruction : les droits sont ceux d'une exécution.
    pub fn fetch_memory(&mut self, at: u64, width: Width) -> Result<u64, Unmapped> {
        let outcome = self.load(at, width, Access::Fetch);
        self.note(outcome)
    }

    #[inline(always)]
    fn load(&mut self, at: u64, width: Width, access: Access) -> Result<u64, Unmapped> {
        let outside = || Unmapped::Outside { address: at };
        if !Self::crosses(at, width) {
            let place = self.translate_cached(at, access)?;
            if !self.in_hole(place) {
                if let Some(value) = self.memory.read(place, width) {
                    return Ok(value);
                }
            }
            // Hors de la RAM : un périphérique, ou rien.
            return self.devices.read(place, width as usize).ok_or_else(outside);
        }
        let head = (0x1000 - (at & 0xFFF)) as usize;
        let low = self.translate_cached(at, access)?;
        let high = self.translate_cached(at.wrapping_add(head as u64), access)?;
        let low = self.read_place(low, head).ok_or_else(outside)?;
        let high = self
            .read_place(high, width as usize - head)
            .ok_or_else(outside)?;
        Ok(low | (high << (8 * head)))
    }

    /// `size` octets à une adresse physique (une moitié d'accès à cheval) :
    /// de la RAM, ou d'un périphérique quand la RAM ne les couvre pas.
    fn read_place(&mut self, place: u64, size: usize) -> Option<u64> {
        if !self.in_hole(place) {
            if let Some(value) = self.memory.read_bytes(place, size) {
                return Some(value);
            }
        }
        self.devices.read(place, size)
    }

    /// Ces `size` octets à une adresse physique acceptent-ils une écriture ?
    fn holds_place(&self, place: u64, size: usize) -> bool {
        (!self.in_hole(place) && self.memory.holds(place, size)) || self.devices.claims(place, size)
    }

    /// `size` octets écrits à une adresse physique, en RAM ou dans un
    /// périphérique.
    fn write_place(&mut self, place: u64, size: usize, value: u64) -> Option<()> {
        if !self.in_hole(place) && self.memory.holds(place, size) {
            return self.memory.write_bytes(place, size, value);
        }
        self.devices.write(place, size, value).then_some(())
    }

    /// **Cet octet est-il accessible ?** — sans le lire ni l'écrire. Ce qu'une
    /// instruction demande avant de poser le premier octet d'une aire qui
    /// peut fauter plus loin : `fxsave` exige ses 512 octets, un rangement de
    /// seize octets ses deux moitiés. Un refus lève `faulted`, comme un accès.
    pub fn probe_memory(&mut self, at: u64, access: Access) -> Result<(), Unmapped> {
        let outcome = self.translate_cached(at, access).and_then(|place| {
            if !self.holds_place(place, 1) {
                return Err(Unmapped::Outside { address: at });
            }
            Ok(())
        });
        self.note(outcome)
    }

    /// **Écrire `width` octets à une adresse virtuelle**, frontière comprise.
    #[inline]
    pub fn write_memory(&mut self, at: u64, width: Width, value: u64) -> Result<(), Unmapped> {
        let outcome = self.store(at, width, value);
        self.note(outcome)
    }

    #[inline(always)]
    fn store(&mut self, at: u64, width: Width, value: u64) -> Result<(), Unmapped> {
        let outside = || Unmapped::Outside { address: at };
        if !Self::crosses(at, width) {
            let place = self.translate_cached(at, Access::Write)?;
            if !self.in_hole(place) && self.memory.write(place, width, value).is_some() {
                return Ok(());
            }
            // Hors de la RAM : un périphérique, ou rien.
            return self
                .devices
                .write(place, width as usize, value)
                .then_some(())
                .ok_or_else(outside);
        }
        // **Tout vérifié avant qu'un seul octet ne soit posé.** Une
        // instruction qui faute ne laisse aucune trace, sans quoi le noyau
        // invité reprendrait sur une moitié de valeur — et les deux
        // traductions ne suffisent pas : la fenêtre attachée peut refuser
        // l'une des deux places.
        let head = (0x1000 - (at & 0xFFF)) as usize;
        let tail = width as usize - head;
        let low = self.translate_cached(at, Access::Write)?;
        let high = self.translate_cached(at.wrapping_add(head as u64), Access::Write)?;
        if !self.holds_place(low, head) || !self.holds_place(high, tail) {
            return Err(outside());
        }
        self.write_place(low, head, value).ok_or_else(outside)?;
        self.write_place(high, tail, value >> (8 * head))
            .ok_or_else(outside)
    }

    /// **La lecture du chemin rapide** (`x86::rapide`) : ce que `read_memory`
    /// rend, par le plus court quand la page est au tampon avec le droit de
    /// lire pour l'anneau courant et que l'accès ne sort pas de sa page. Une
    /// case du tampon ne tient jamais une page hors de la RAM ni dans le trou
    /// (`fill`), donc la place se lit sans autre question. Tout le reste —
    /// pas de pagination, pas de tampon, une page à cheval, une case absente
    /// ou sans le droit — passe par `read_memory`, hors de la ligne.
    #[inline(always)]
    pub fn read_memory_fast(&mut self, at: u64, width: Width) -> Result<u64, Unmapped> {
        if let Some(place) = self.fast_place(at, width, 0, TLB_USER) {
            if let Some(value) = self.memory.read(place, width) {
                return Ok(value);
            }
        }
        self.read_memory_slow(at, width)
    }

    /// **L'écriture du chemin rapide** : ce que `write_memory` fait, par le
    /// plus court quand la page est au tampon déjà salie et inscriptible (et
    /// à l'utilisateur pour l'anneau trois). Une page en lecture seule que
    /// le noyau écrit sans CR0.WP, ou pas encore salie, passe par
    /// `write_memory`, qui en décide comme toujours.
    #[inline(always)]
    pub fn write_memory_fast(&mut self, at: u64, width: Width, value: u64) -> Result<(), Unmapped> {
        if let Some(place) = self.fast_place(
            at,
            width,
            TLB_WRITABLE | TLB_DIRTY,
            TLB_USER | TLB_WRITABLE | TLB_DIRTY,
        ) {
            if self.memory.write(place, width, value).is_some() {
                return Ok(());
            }
        }
        self.write_memory_slow(at, width, value)
    }

    /// La place physique d'un accès qui tient dans sa page et dont la case
    /// du tampon porte les droits demandés : `kernel` en anneau zéro à deux,
    /// `user` en anneau trois.
    #[inline(always)]
    fn fast_place(&self, at: u64, width: Width, kernel: u8, user: u8) -> Option<u64> {
        let tlb = self.tlb.as_deref()?;
        if self.control[0] & PAGING == 0 || (at & 0xFFF) > 0x1000 - width as u64 {
            return None;
        }
        let page = at & !0xFFF;
        let entry = &tlb.entries[(page >> 12) as usize & (TLB_SLOTS - 1)];
        let needed = if self.segments[1] & 3 == 3 {
            user
        } else {
            kernel
        };
        if entry.tag == page.wrapping_add(1) && entry.flags & needed == needed {
            return Some(entry.frame | (at & 0xFFF));
        }
        None
    }

    #[cold]
    #[inline(never)]
    fn read_memory_slow(&mut self, at: u64, width: Width) -> Result<u64, Unmapped> {
        self.read_memory(at, width)
    }

    #[cold]
    #[inline(never)]
    fn write_memory_slow(&mut self, at: u64, width: Width, value: u64) -> Result<(), Unmapped> {
        self.write_memory(at, width, value)
    }

    /// Ranger le refus là où le reste du cœur peut le lire, et lever
    /// `faulted`. La machine PC en fait une `#PF` délivrée ; l'interpréteur nu
    /// s'arrête en nommant l'adresse.
    #[inline(always)]
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
