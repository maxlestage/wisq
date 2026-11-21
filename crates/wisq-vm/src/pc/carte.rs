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
//! Swift. Un octet que le disque écrit dans du code se voit : les blocs et le
//! cache de décodage comparent leurs octets à l'entrée.
//!
//! **Ce qui n'est pas branché** : la mémoire des périphériques hors de la RAM
//! (l'écran Bochs et la tablette, `CartePc::mem_lire`), que la traduction
//! d'adresses de ce cœur rend en faute « hors de la mémoire », et le service
//! à chaque tour que la tablette et la carte réseau demandent
//! (`CartePc::servir` hors d'un `out`, `CartePc::sonder_reseau`) : `wisq-pc`
//! ne branche ni l'une ni l'autre. Les disques et le clavier n'en ont pas
//! besoin.

use wisq_carte::pc::CartePc;
use wisq_carte::Ram;

use super::machine::Peripheriques;

/// La RAM de la machine, vue par la carte : par adresse physique, une plage
/// entière ou rien.
struct Tranche<'a>(&'a mut [u8]);

impl Tranche<'_> {
    fn plage(&self, adresse: u64, longueur: usize) -> Option<std::ops::Range<usize>> {
        let debut = usize::try_from(adresse).ok()?;
        let fin = debut.checked_add(longueur)?;
        (fin <= self.0.len()).then_some(debut..fin)
    }
}

impl Ram for Tranche<'_> {
    fn lire(&self, adresse: u64, vers: &mut [u8]) -> bool {
        let Some(plage) = self.plage(adresse, vers.len()) else {
            return false;
        };
        vers.copy_from_slice(&self.0[plage]);
        true
    }

    fn ecrire(&mut self, adresse: u64, depuis: &[u8]) -> bool {
        let Some(plage) = self.plage(adresse, depuis.len()) else {
            return false;
        };
        self.0[plage].copy_from_slice(depuis);
        true
    }
}

impl Peripheriques for CartePc {
    fn port_lire(&mut self, port: u16, largeur: u8, _ram: &mut [u8]) -> Option<u32> {
        CartePc::port_lire(self, port, largeur)
    }

    /// Un `out` que la carte prend : s'il a noté une notification, elle est
    /// servie tout de suite, la RAM en main.
    fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32, ram: &mut [u8]) -> bool {
        let pris = CartePc::port_ecrire(self, port, largeur, valeur);
        if pris && self.a_servir() {
            CartePc::servir(self, &mut Tranche(ram));
        }
        pris
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

    fn remise_demandee(&self) -> bool {
        CartePc::remise_demandee(self)
    }
}
