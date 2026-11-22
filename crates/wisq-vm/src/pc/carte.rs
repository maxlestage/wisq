//! **La carte des périphériques, branchée derrière les ports de la machine**
//! — le raccord que le contrat entre les deux flux confie à celui-ci.
//!
//! `wisq_carte::pc::CartePc` (le crate `crates/wisq-page/src/carte`, une
//! feuille sans dépendance) tient l'i8042, l'horloge CMOS, le pont PCI 440FX,
//! les disques virtio, l'écran, la tablette et la carte réseau, aux mêmes
//! ports, lignes et emplacements que le cœur Swift. La machine la prend comme
//! n'importe quels [`Peripheriques`] : **après** ses propres puces (deux 8259,
//! le 8253, le 16550 et son horloge CMOS, qui passent donc devant celles de la
//! carte sur les ports qu'elles partagent), ses lignes recopiées à niveau dans
//! les 8259 à chaque service du matériel.
//!
//! **Le disque est servi sur-le-champ.** Une notification (`out` sur le
//! registre de la file) est notée par la carte ; la machine lui donne la RAM
//! juste après l'`out` qu'elle a pris : la requête est
//! lue, le fichier lu, la réponse rendue et la ligne levée avant que
//! l'instruction suivante ne s'exécute — comme `VirtioBlock.serve` du cœur
//! Swift. Un octet que le disque écrit dans du code se voit : il passe par
//! `Ram::ecrire`, qui avance la génération de sa page, et les blocs décodés
//! de cette page se recomparent à leur prochaine entrée.
//!
//! **La mémoire des périphériques** (la mémoire vidéo et les registres de
//! l'écran de Bochs, la BAR0 de la tablette) répond hors de la RAM : la carte
//! est aussi un [`DeviceMemory`], que la traduction d'adresses consulte quand
//! la RAM ne couvre pas une adresse physique (`Cpu::devices`). Pour la tenir
//! des deux côtés, elle est partagée ([`CartePartagee`], [`brancher`]) : la
//! machine par ses ports, le processeur par sa mémoire.
//!
//! **Le service à chaque tour** : une sonnette de la tablette (une écriture
//! dans sa BAR0) est notée, et la file relue au tour suivant du matériel, avec
//! ce que le doigt a fait ([`Peripheriques::servir_tour`]), au plus deux cent
//! cinquante-six instructions plus tard.
//!
//! **La carte réseau**, quand le poste la branche (`Poste::brancher_reseau`,
//! `pc::reseau`) : une émission est servie sur-le-champ, comme le disque ; ce
//! que le câble remet est interrogé au tour du matériel
//! (`CartePc::sonder_reseau`) — un tour sur quatre quand le processeur
//! travaille, à chaque tour quand il dort —, et rangé dans les tampons de
//! l'invité par `Ram::ecrire`, chaque écriture notée : une trame reçue
//! par-dessus du code décodé le fait relire. `wisq-pc` ne la branche pas.

use std::sync::{Arc, Mutex, MutexGuard};

use wisq_carte::pc::CartePc;
use wisq_carte::Ram;

use super::machine::{Machine, Peripheriques, Suivi};
use crate::x86_paging::{DeviceMemory, Devices};

/// La RAM de la machine, vue par la carte : par adresse physique, une plage
/// entière ou rien. **Chaque écriture est notée** (`Suivi`) : le disque qui
/// lit un fichier dans une page de code, une file de la tablette, tout
/// passe par `ecrire`, et les blocs décodés de cette page le verront.
struct Tranche<'a, 'b> {
    ram: &'a mut [u8],
    suivi: &'a mut Suivi<'b>,
}

impl Tranche<'_, '_> {
    fn plage(&self, adresse: u64, longueur: usize) -> Option<std::ops::Range<usize>> {
        let debut = usize::try_from(adresse).ok()?;
        let fin = debut.checked_add(longueur)?;
        (fin <= self.ram.len()).then_some(debut..fin)
    }
}

impl Ram for Tranche<'_, '_> {
    fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool {
        let Some(plage) = self.plage(adresse, vers.len()) else {
            return false;
        };
        vers.copy_from_slice(&self.ram[plage]);
        true
    }

    fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool {
        let Some(plage) = self.plage(adresse, depuis.len()) else {
            return false;
        };
        self.ram[plage].copy_from_slice(depuis);
        self.suivi.noter(adresse, depuis.len());
        true
    }
}

impl Peripheriques for CartePc {
    fn port_lire(&mut self, port: u16, largeur: u8, ram: &mut [u8]) -> Option<u32> {
        self.port_lire_suivi(port, largeur, ram, &mut Suivi(None))
    }

    fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32, ram: &mut [u8]) -> bool {
        self.port_ecrire_suivi(port, largeur, valeur, ram, &mut Suivi(None))
    }

    /// Lire un port de la carte ne touche pas à la RAM : rien à dire.
    fn port_lire_suivi(
        &mut self,
        port: u16,
        largeur: u8,
        _ram: &mut [u8],
        _suivi: &mut Suivi<'_>,
    ) -> Option<u32> {
        CartePc::port_lire(self, port, largeur)
    }

    /// Un `out` que la carte prend : s'il a noté une notification, elle est
    /// servie tout de suite, la RAM en main — chaque écriture notée.
    fn port_ecrire_suivi(
        &mut self,
        port: u16,
        largeur: u8,
        valeur: u32,
        ram: &mut [u8],
        suivi: &mut Suivi<'_>,
    ) -> bool {
        let pris = CartePc::port_ecrire(self, port, largeur, valeur);
        if pris && self.a_servir() {
            CartePc::servir(self, &mut Tranche { ram, suivi });
        }
        pris
    }

    /// Le tour : le temps, la tablette, la carte réseau — ce que le câble a
    /// remis, rangé dans les tampons de l'invité —, chaque écriture notée ;
    /// puis les lignes.
    fn tour_suivi(
        &mut self,
        tics: u64,
        ram: &mut [u8],
        suivi: &mut Suivi<'_>,
        occupe: bool,
    ) -> u16 {
        CartePc::battre(self, tics);
        if self.a_servir() || self.tablette().is_some() {
            CartePc::servir(self, &mut Tranche { ram, suivi });
        }
        if self.reseau().is_some() {
            self.sonder_reseau(&mut Tranche { ram, suivi }, occupe);
        }
        CartePc::lignes(self)
    }

    fn lignes(&self) -> u16 {
        CartePc::lignes(self)
    }

    fn reveil(&self) -> bool {
        CartePc::reveil(self)
    }

    fn battre(&mut self, tics: u64) {
        CartePc::battre(self, tics);
    }

    /// Une sonnette de la tablette, et ce que le doigt a fait : relus à
    /// chaque tour.
    fn servir_tour(&mut self, ram: &mut [u8]) {
        if self.a_servir() || self.tablette().is_some() {
            CartePc::servir(
                self,
                &mut Tranche {
                    ram,
                    suivi: &mut Suivi(None),
                },
            );
        }
    }

    fn remise_demandee(&self) -> bool {
        CartePc::remise_demandee(self)
    }
}

/// **La carte, vue par la mémoire** : ce que [`wisq_carte::Carte::region`]
/// dit à elle. Une sonnette de la tablette est notée (`CartePc::mem_ecrire`),
/// et servie au tour suivant.
impl DeviceMemory for CartePc {
    fn read(&mut self, place: u64, width: u8) -> Option<u64> {
        self.mem_lire(place, width)
    }

    fn write(&mut self, place: u64, width: u8, value: u64) -> bool {
        self.mem_ecrire(place, width, value)
    }

    fn claims(&self, place: u64, width: u8) -> bool {
        self.carte().region(place, usize::from(width)).is_some()
    }
}

/// **La carte, tenue des deux côtés** : par la machine (ses ports, ses
/// lignes, son service) et par le processeur (sa mémoire). Un verrou que
/// personne ne dispute : un seul fil fait tourner la machine, et l'hôte ne
/// le prend qu'entre deux tranches (une image, une frappe).
#[derive(Clone)]
pub struct CartePartagee(pub Arc<Mutex<CartePc>>);

impl CartePartagee {
    /// La carte, pour lire son écran ou lui donner une frappe.
    pub fn tenir(&self) -> MutexGuard<'_, CartePc> {
        self.0.lock().unwrap_or_else(|poison| poison.into_inner())
    }
}

/// **Brancher une carte** derrière les ports et la mémoire d'une machine, et
/// rendre de quoi la tenir. Son horloge CMOS, complète, prend les ports 0x70
/// et 0x71 à celle des puces de la machine.
pub fn brancher(machine: &mut Machine, carte: CartePc) -> CartePartagee {
    let partagee = CartePartagee(Arc::new(Mutex::new(carte)));
    machine.cpu.devices = Devices(Some(partagee.0.clone()));
    machine.herites.cmos_ailleurs = true;
    machine.peripheriques = Some(Box::new(partagee.clone()));
    partagee
}

impl Peripheriques for CartePartagee {
    fn port_lire(&mut self, port: u16, largeur: u8, ram: &mut [u8]) -> Option<u32> {
        Peripheriques::port_lire(&mut *self.tenir(), port, largeur, ram)
    }

    fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32, ram: &mut [u8]) -> bool {
        Peripheriques::port_ecrire(&mut *self.tenir(), port, largeur, valeur, ram)
    }

    fn lignes(&self) -> u16 {
        self.tenir().lignes()
    }

    fn reveil(&self) -> bool {
        self.tenir().reveil()
    }

    fn battre(&mut self, tics: u64) {
        self.tenir().battre(tics);
    }

    fn servir_tour(&mut self, ram: &mut [u8]) {
        Peripheriques::servir_tour(&mut *self.tenir(), ram);
    }

    /// Les trois temps du tour sous un seul verrou.
    fn tour(&mut self, tics: u64, ram: &mut [u8]) -> u16 {
        Peripheriques::tour(&mut *self.tenir(), tics, ram)
    }

    fn port_lire_suivi(
        &mut self,
        port: u16,
        largeur: u8,
        ram: &mut [u8],
        suivi: &mut Suivi<'_>,
    ) -> Option<u32> {
        Peripheriques::port_lire_suivi(&mut *self.tenir(), port, largeur, ram, suivi)
    }

    fn port_ecrire_suivi(
        &mut self,
        port: u16,
        largeur: u8,
        valeur: u32,
        ram: &mut [u8],
        suivi: &mut Suivi<'_>,
    ) -> bool {
        Peripheriques::port_ecrire_suivi(&mut *self.tenir(), port, largeur, valeur, ram, suivi)
    }

    fn tour_suivi(
        &mut self,
        tics: u64,
        ram: &mut [u8],
        suivi: &mut Suivi<'_>,
        occupe: bool,
    ) -> u16 {
        Peripheriques::tour_suivi(&mut *self.tenir(), tics, ram, suivi, occupe)
    }

    fn remise_demandee(&self) -> bool {
        self.tenir().remise_demandee()
    }
}
