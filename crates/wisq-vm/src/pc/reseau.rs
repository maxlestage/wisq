//! **Le câble de la carte réseau, tendu à l'hôte** : deux files de trames
//! entre la carte (`wisq_carte::pc::CartePc`, sur le fil de la course) et
//! l'application (n'importe quel fil, par l'ABI C `wisq_pc_net_*`).
//!
//! **Pourquoi des files, et pas un rappel.** Le cœur Swift appelle
//! `backend.send` pendant l'`out` qui notifie la file d'émission, et
//! `backend.receive` à chaque passage de son contrôleur d'interruptions. Ici,
//! l'autre bout est du Swift (`UserNetwork`) derrière une frontière C. Un
//! rappel viendrait du fil de la course, au milieu d'une instruction, le
//! verrou de la carte tenu : un rappel qui toucherait la machine (une frappe,
//! l'écran) s'y bloquerait pour toujours, et le Swift appelé là devrait
//! savoir tout cela. Avec deux files, rien du Swift ne s'exécute sous un
//! verrou de la machine : l'application vide ce qui sort et remet ce qui
//! entre quand elle veut, de n'importe quel fil, entre deux tranches
//! (`RustPCMachine.run`), et la carte, elle, interroge la file entrante à son
//! propre rythme ([`wisq_carte::virtio_net::VirtioNet::sonder`]).
//!
//! **Les deux files sont bornées** ([`TRAMES_EN_FILE`], la borne de l'attente
//! de la carte elle-même). Pleine, la file entrante **refuse** la trame
//! remise ([`Remise::Pleine`]) : l'appelant le sait, la trame n'est pas prise,
//! et le refus est compté — un port de commutateur dont la mémoire est pleine.
//! Pleine, la file sortante **perd** la trame que l'invité émet, et le compte :
//! l'invité ne peut pas attendre, son pilote a déjà rendu le tampon.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use wisq_carte::pc::Cable;
use wisq_carte::virtio_net::{PLUS_EN_ATTENTE, PLUS_GRANDE_TRAME};

/// **Combien de trames chaque file tient au plus** : la borne de l'attente de
/// la carte (`PLUS_EN_ATTENTE`, `waitingLimit` du cœur Swift).
pub const TRAMES_EN_FILE: usize = PLUS_EN_ATTENTE;

/// **La plus grande trame** qui passe, dans un sens comme dans l'autre : une
/// trame Ethernet sans les jumbos, sans l'en-tête virtio (1 514 octets).
pub const PLUS_GRANDE: usize = PLUS_GRANDE_TRAME;

/// Ce que devient une trame remise par l'hôte.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Remise {
    /// Prise : la carte la donnera à l'invité dès qu'il aura posé un tampon.
    Prise,
    /// La file entrante est pleine : la trame n'est pas prise, et le refus
    /// est compté.
    Pleine,
    /// Vide, ou plus grande qu'une trame Ethernet : ce n'est pas une trame.
    PasUneTrame,
}

/// Les compteurs du câble.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Compteurs {
    /// Les trames refusées à l'entrée, file pleine.
    pub refusees: u64,
    /// Les trames de l'invité perdues à la sortie, file pleine.
    pub perdues: u64,
    /// Ce qui attend dans chaque file.
    pub entrantes: usize,
    pub sortantes: usize,
}

#[derive(Default)]
struct Files {
    entrantes: VecDeque<Vec<u8>>,
    sortantes: VecDeque<Vec<u8>>,
    refusees: u64,
    perdues: u64,
}

/// **Les deux files**, partagées entre la carte et l'hôte.
#[derive(Default)]
pub struct Reseau {
    files: Mutex<Files>,
    /// Des trames entrantes attendent : la carte l'interroge toutes les mille
    /// instructions au travail, et ne prend le verrou que s'il y a à prendre.
    arrivees: AtomicBool,
    /// Combien de fois la carte a interrogé le câble : le rythme se juge.
    questions: AtomicU64,
}

impl Reseau {
    fn tenir(&self) -> MutexGuard<'_, Files> {
        self.files
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// **Remettre une trame à l'invité**, de n'importe quel fil.
    pub fn remettre(&self, trame: &[u8]) -> Remise {
        if trame.is_empty() || trame.len() > PLUS_GRANDE {
            return Remise::PasUneTrame;
        }
        let mut files = self.tenir();
        if files.entrantes.len() >= TRAMES_EN_FILE {
            files.refusees = files.refusees.wrapping_add(1);
            return Remise::Pleine;
        }
        files.entrantes.push_back(trame.to_vec());
        self.arrivees.store(true, Ordering::Release);
        Remise::Prise
    }

    /// **La longueur de la prochaine trame que l'invité a émise**, sans la
    /// retirer ; rien quand aucune n'attend.
    pub fn longueur_de_la_prochaine(&self) -> Option<usize> {
        self.tenir().sortantes.front().map(Vec::len)
    }

    /// **Prendre la prochaine trame émise**, dans l'ordre de l'invité.
    pub fn prendre(&self) -> Option<Vec<u8>> {
        self.tenir().sortantes.pop_front()
    }

    /// **Prendre la prochaine trame émise si elle tient dans `vers`** : sa
    /// longueur, et elle est copiée et retirée ; trop longue, sa longueur
    /// seule, et elle reste ; rien quand aucune n'attend.
    pub fn prendre_dans(&self, vers: &mut [u8]) -> Option<usize> {
        let mut files = self.tenir();
        let longueur = files.sortantes.front()?.len();
        if longueur <= vers.len() {
            if let Some(trame) = files.sortantes.pop_front() {
                vers[..longueur].copy_from_slice(&trame);
            }
        }
        Some(longueur)
    }

    /// Les compteurs, et ce qui attend.
    pub fn compteurs(&self) -> Compteurs {
        let files = self.tenir();
        Compteurs {
            refusees: files.refusees,
            perdues: files.perdues,
            entrantes: files.entrantes.len(),
            sortantes: files.sortantes.len(),
        }
    }

    /// Combien de fois la carte a interrogé le câble.
    pub fn questions(&self) -> u64 {
        self.questions.load(Ordering::Relaxed)
    }
}

/// **Le câble que la carte tient** : l'autre bout des deux files.
pub struct CableDuPoste(pub Arc<Reseau>);

impl Cable for CableDuPoste {
    /// Une trame que l'invité vient d'émettre : rangée pour l'hôte, ou
    /// perdue, file pleine.
    fn envoyer(&mut self, trame: &[u8]) {
        let mut files = self.0.tenir();
        if files.sortantes.len() >= TRAMES_EN_FILE {
            files.perdues = files.perdues.wrapping_add(1);
            return;
        }
        files.sortantes.push_back(trame.to_vec());
    }

    /// Ce que l'hôte a remis. Sans rien d'arrivé, ni verrou ni allocation.
    fn recevoir(&mut self) -> Vec<Vec<u8>> {
        self.0.questions.fetch_add(1, Ordering::Relaxed);
        if !self.0.arrivees.swap(false, Ordering::Acquire) {
            return Vec::new();
        }
        self.0.tenir().entrantes.drain(..).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **La file entrante pleine refuse**, compte le refus, et reprend dès
    /// que la carte a pris ce qui attendait.
    #[test]
    fn a_full_incoming_queue_refuses_and_counts() {
        let reseau = Arc::new(Reseau::default());
        let mut cable = CableDuPoste(reseau.clone());
        for rang in 0..TRAMES_EN_FILE {
            assert_eq!(reseau.remettre(&[rang as u8; 60]), Remise::Prise);
        }
        assert_eq!(reseau.remettre(&[0xEE; 60]), Remise::Pleine);
        assert_eq!(reseau.remettre(&[0xEF; 60]), Remise::Pleine);
        let compteurs = reseau.compteurs();
        assert_eq!(
            (compteurs.refusees, compteurs.entrantes),
            (2, TRAMES_EN_FILE)
        );
        let prises = cable.recevoir();
        assert_eq!(prises.len(), TRAMES_EN_FILE);
        assert_eq!(prises[0], vec![0; 60], "dans l'ordre");
        assert_eq!(
            prises[TRAMES_EN_FILE - 1],
            vec![(TRAMES_EN_FILE - 1) as u8; 60]
        );
        assert_eq!(
            reseau.remettre(&[0xEE; 60]),
            Remise::Prise,
            "vidée, elle reprend"
        );
        assert_eq!(cable.recevoir(), vec![vec![0xEE; 60]]);
        assert!(cable.recevoir().is_empty(), "rien de plus");
        assert_eq!(reseau.questions(), 3);
    }

    /// **Ce qui n'est pas une trame** n'entre pas, et n'est pas un refus.
    #[test]
    fn an_empty_or_oversized_frame_is_not_a_frame() {
        let reseau = Reseau::default();
        assert_eq!(reseau.remettre(&[]), Remise::PasUneTrame);
        assert_eq!(reseau.remettre(&[0; PLUS_GRANDE + 1]), Remise::PasUneTrame);
        assert_eq!(reseau.remettre(&[0; PLUS_GRANDE]), Remise::Prise);
        assert_eq!(reseau.compteurs().refusees, 0);
    }

    /// **La file sortante pleine perd** la trame de l'invité et la compte ;
    /// l'hôte prend dans l'ordre, et une trame trop longue pour son tampon
    /// reste là.
    #[test]
    fn a_full_outgoing_queue_loses_and_the_host_takes_in_order() {
        let reseau = Arc::new(Reseau::default());
        let mut cable = CableDuPoste(reseau.clone());
        for rang in 0..=TRAMES_EN_FILE {
            cable.envoyer(&vec![rang as u8; 1 + rang % 100]);
        }
        let compteurs = reseau.compteurs();
        assert_eq!(
            (compteurs.perdues, compteurs.sortantes),
            (1, TRAMES_EN_FILE)
        );
        let mut court = [0u8; 0];
        assert_eq!(
            reseau.prendre_dans(&mut court),
            Some(1),
            "la longueur seule"
        );
        assert_eq!(reseau.longueur_de_la_prochaine(), Some(1), "elle reste");
        let mut tampon = [0u8; PLUS_GRANDE];
        for rang in 0..TRAMES_EN_FILE {
            let longueur = reseau.prendre_dans(&mut tampon).expect("une trame");
            assert_eq!(&tampon[..longueur], &vec![rang as u8; 1 + rang % 100][..]);
        }
        assert_eq!(reseau.prendre_dans(&mut tampon), None);
        cable.envoyer(&[7, 7]);
        let mut juste = [0u8; 2];
        assert_eq!(
            reseau.prendre_dans(&mut juste),
            Some(2),
            "un tampon tout juste assez grand"
        );
        assert_eq!((juste, reseau.prendre()), ([7, 7], None), "la prend");
        cable.envoyer(&[8]);
        assert_eq!(reseau.prendre(), Some(vec![8]));
    }
}
