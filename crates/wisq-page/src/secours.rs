//! **Le secours de l'émetteur, dans la page** : l'instruction que
//! l'émetteur refuse, exécutée par l'interpréteur (`wisq_vm::pc::secours`).
//!
//! Les registres, ce module les lit et les rend lui-même dans les globales de
//! la machine, par le module d'accès (`hote.rs`). La boucle de la page n'a à
//! faire que ce qu'elle seule sait faire : lire et récrire la mémoire de
//! l'invité à travers ses tables de pages, et livrer une faute. L'échange
//! passe par trois tampons de ce module — le code, la fenêtre, le rendu —
//! dont elle demande l'adresse avant chaque appel (la mémoire du module peut
//! grandir).
//!
//! Il vit dans l'instance de la boucle (`emetteur(...).hote`), pas dans celle
//! qui traduit : la pile du x87 doit survivre à une trappe de l'émetteur.

#[cfg(target_arch = "wasm32")]
mod page {
    use std::sync::Mutex;
    use wisq_vm::pc::secours::{Etat, Issue, Secours, FENETRE_MAX};
    use wisq_vm::x86_wasm::{
        CONTROL_SLOT, FPU_CONTROL_SLOT, FPU_STATUS_SLOT, FS_BASE_SLOT, GS_SLOT, MXCSR_SLOT,
        RFLAGS_SLOT, RIP_SLOT, XMM_SLOT,
    };

    struct Tampons {
        secours: Secours,
        code: [u8; 16],
        fenetre: Vec<u8>,
        rendu: [u64; 2],
        etat: Etat,
    }

    static TAMPONS: Mutex<Option<Tampons>> = Mutex::new(None);

    /// Aucun appel sortant sous ce verrou ne peut rappeler la page : le
    /// module d'accès ne fait que lire et écrire des globales.
    fn avec<R>(faire: impl FnOnce(&mut Tampons) -> R) -> R {
        let mut verrou = TAMPONS.lock().unwrap_or_else(|poison| poison.into_inner());
        faire(verrou.get_or_insert_with(|| Tampons {
            secours: Secours::new(),
            code: [0; 16],
            fenetre: vec![0; FENETRE_MAX],
            rendu: [0; 2],
            etat: Etat::default(),
        }))
    }

    fn lire(slot: usize) -> u64 {
        crate::hote::lire(slot as i32).unwrap_or(0) as u64
    }

    fn ecrire(slot: usize, valeur: u64) {
        let _ = crate::hote::ecrire(slot as i32, valeur as i64);
    }

    fn charger() -> Etat {
        let mut etat = Etat::default();
        for (rang, registre) in etat.regs.iter_mut().enumerate() {
            *registre = lire(rang);
        }
        etat.rip = lire(RIP_SLOT);
        etat.rflags = lire(RFLAGS_SLOT);
        etat.fs_base = lire(FS_BASE_SLOT);
        etat.gs_base = lire(GS_SLOT);
        etat.cr0 = lire(CONTROL_SLOT);
        etat.cr4 = lire(CONTROL_SLOT + 3);
        etat.fpu_control = lire(FPU_CONTROL_SLOT) as u16;
        etat.fpu_status = lire(FPU_STATUS_SLOT) as u16;
        for (rang, xmm) in etat.xmm.iter_mut().enumerate() {
            *xmm = [lire(XMM_SLOT + 2 * rang), lire(XMM_SLOT + 2 * rang + 1)];
        }
        etat.mxcsr = lire(MXCSR_SLOT) as u32;
        etat
    }

    fn rendre(etat: &Etat) {
        for (rang, registre) in etat.regs.iter().enumerate() {
            ecrire(rang, *registre);
        }
        ecrire(RIP_SLOT, etat.rip);
        ecrire(RFLAGS_SLOT, etat.rflags);
        ecrire(FPU_CONTROL_SLOT, u64::from(etat.fpu_control));
        ecrire(FPU_STATUS_SLOT, u64::from(etat.fpu_status));
        for (rang, xmm) in etat.xmm.iter().enumerate() {
            ecrire(XMM_SLOT + 2 * rang, xmm[0]);
            ecrire(XMM_SLOT + 2 * rang + 1, xmm[1]);
        }
        ecrire(MXCSR_SLOT, u64::from(etat.mxcsr));
    }

    /// Où écrire l'instruction (seize octets).
    #[no_mangle]
    extern "C" fn secours_code() -> *mut u8 {
        avec(|t| t.code.as_mut_ptr())
    }

    /// Où écrire la fenêtre, et la relire après (`FENETRE_MAX` octets).
    #[no_mangle]
    extern "C" fn secours_fenetre() -> *mut u8 {
        avec(|t| t.fenetre.as_mut_ptr())
    }

    /// Les deux nombres du dernier rendu (voir `secourir`).
    #[no_mangle]
    extern "C" fn secours_rendu() -> *const u64 {
        avec(|t| t.rendu.as_ptr())
    }

    /// **Essayer l'instruction** de `longueur` octets, avec la fenêtre de
    /// `taille` octets lue à `base` (`taille` nul : pas encore de fenêtre).
    ///
    /// `0` : faite — l'état attend `secours_valider` ; `1` : il faut
    /// `[rendu[0], rendu[0] + rendu[1])` ; `2` : une exception, vecteur
    /// `rendu[0]`, code `rendu[1]` (`u64::MAX` s'il n'y en a pas) ; `3` :
    /// illisible.
    #[no_mangle]
    extern "C" fn secourir(longueur: u32, base: u64, taille: u32) -> u32 {
        let mut etat = charger();
        avec(|t| {
            let longueur = (longueur as usize).min(t.code.len());
            let taille = (taille as usize).min(FENETRE_MAX);
            let code = t.code;
            let fenetre = (taille > 0).then(|| (base, &mut t.fenetre[..taille]));
            let issue = t.secours.executer(&mut etat, &code[..longueur], fenetre);
            match issue {
                Issue::Faite => {
                    t.etat = etat;
                    0
                }
                Issue::Memoire { adresse, taille } => {
                    t.rendu = [adresse, taille as u64];
                    1
                }
                Issue::Exception { vecteur, code } => {
                    t.rendu = [u64::from(vecteur), code.map_or(u64::MAX, u64::from)];
                    2
                }
                Issue::Illisible => 3,
            }
        })
    }

    /// **La fenêtre est récrite** : l'état devient celui de la machine.
    #[no_mangle]
    extern "C" fn secours_valider() {
        let etat = avec(|t| {
            t.secours.valider();
            t.etat
        });
        rendre(&etat);
    }

    /// **L'écriture a fauté** : rien n'est acquis.
    #[no_mangle]
    extern "C" fn secours_annuler() {
        avec(|t| t.secours.annuler());
    }
}
