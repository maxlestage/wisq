//! **La machine PC native** : un cœur x86-64 interprété, sa mémoire, son
//! chargeur de noyau et les périphériques hérités qu'il faut pour démarrer un
//! vrai Linux — deux 8259, un 8253, un 16550 et une horloge CMOS.
//!
//! **La référence est le cœur Swift** (`Sources/WisqVM/X86*.swift`), qui
//! démarre Void Linux Xfce : même carte de machine, mêmes ports, mêmes lignes
//! d'interruption, mêmes règles. Chaque fichier d'ici dit lequel il porte.
//!
//! Le processeur est `crate::x86::Cpu`, jugé par les corpus matériels ; ce
//! module lui ajoute ce qu'un interpréteur nu refuse — les instructions de
//! système, la livraison des interruptions et des fautes, les ports — et la
//! boucle qui sert le matériel. Rien ici ne demande de fichier ni de système :
//! la cible `wasm32` le compile aussi. La carte des autres périphériques
//! (clavier, PCI, disques) est celle du crate `wisq-carte`, branchée par
//! `carte.rs`.

pub mod blocs;
pub mod carte;
pub mod chargeur;
pub mod herites;
pub mod instantane;
pub mod machine;
pub mod memoire;
pub mod poste;
pub mod systeme;

pub use chargeur::{Ecran, Placement, Refus};
pub use herites::Herites;
pub use machine::{Issue, Machine, Peripheriques};
pub use poste::{Commandes, Fin, Poste};
pub use systeme::{Exception, Systeme};
