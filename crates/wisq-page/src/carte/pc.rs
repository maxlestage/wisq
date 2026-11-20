//! **La carte, pour une machine native** : la même [`Carte`] que la page,
//! derrière une façade qui tient ses disques.
//!
//! **Ce que la page fait en plusieurs temps, et pourquoi pas ici.** Dans la
//! page, les octets d'un disque sont loin : une requête part, la boucle hôte
//! la confie à un arrière joignable par message, et la réponse revient plus
//! tard ([`virtio_blk`](super::virtio_blk)). Une machine native n'a pas de
//! boucle d'événements, et n'en a pas besoin : le fichier est là, un `pread`
//! le lit. [`CartePc`] tient donc l'arrière de chaque disque ([`Arriere`]) et
//! fait tout le trajet d'un coup, dans [`CartePc::servir`] : relire la file,
//! lire ou écrire le fichier, rendre la réponse, lever la ligne — avant de
//! rendre la main, comme `VirtioBlock.serve` du cœur Swift pendant l'`out`.
//!
//! **Les ports ne demandent pas la RAM.** [`CartePc::port_lire`] et
//! [`CartePc::port_ecrire`] ne prennent qu'un port, une largeur et une
//! valeur : ce que le cœur a sous la main au milieu d'une instruction `in` ou
//! `out`, où sa mémoire est déjà empruntée. Une seule écriture de port lit la
//! RAM de l'invité — la notification d'un disque, qui relit sa file. Elle est
//! **notée**, et servie par [`CartePc::servir`], qui reçoit la RAM
//! ([`Ram`]). La boucle l'appelle après chaque `out` que la carte a pris
//! (elle ne coûte alors que deux booléens à lire s'il n'y a rien), ou une
//! fois par tour avant de relire les lignes ; tant qu'une notification
//! attend, [`CartePc::reveil`] le dit, et un `hlt` ne s'endort pas dessus.
//!
//! **La mémoire des périphériques ne demande pas la RAM non plus.** L'écran
//! et la tablette vivent à des adresses physiques hors de la RAM
//! ([`ecran`](super::ecran), [`tablette`](super::tablette)) : la machine
//! passe à [`CartePc::mem_lire`] et [`CartePc::mem_ecrire`] tout accès qui
//! tombe hors de la sienne, au milieu de l'instruction qui le fait. Une
//! seule de ces écritures lit la RAM — la sonnette d'une file de la
//! tablette — et elle est **notée** comme la notification d'un disque.
//! [`CartePc::servir`] sonne, puis rend à l'invité ce que le doigt a fait
//! ([`CartePc::toucher`], [`CartePc::defiler`]), à l'heure du dernier
//! [`CartePc::battre`].
//!
//! **L'heure est injectée.** L'horloge CMOS ne lit aucune horloge d'elle-même
//! ([`cmos`](super::cmos)). La machine pose l'heure
//! ([`CartePc::regler_heure`]), ou donne une horloge ([`CartePc::horloge`])
//! que la façade interroge avant chaque accès aux ports `0x70` et `0x71` —
//! ce que `Date()` fait du côté Swift, et ce qui laisse un test, ou une
//! reprise, donner l'heure qu'il veut.
//!
//! **Le mode d'emploi**, pour la boucle d'une machine :
//!
//! ```
//! use wisq_carte::pc::{ArriereMemoire, CartePc, Disque};
//! use wisq_carte::RamPlate;
//!
//! let mut ram = RamPlate(vec![0; 1 << 20]); // la RAM de l'invité, par le trait `Ram`
//! let mut carte = CartePc::nouvelle();
//! carte.regler_heure(1_793_379_909_000); // ou `carte.horloge(horloge_du_systeme)`
//! carte.brancher(Disque::Premier, ArriereMemoire(vec![0; 8 * 512])); // vda, 00:03.0, ligne 5
//! carte.brancher_ecran(1024, 768); // l'écran en 00:02.0, sa tablette en 00:07.0, ligne 10
//! // Dans la boucle, pour un `in` et un `out` que les puces du cœur ne prennent pas :
//! let lu = carte.port_lire(0x64, 1); // `None` : personne, le bus flotte (0xFF)
//! let pris = carte.port_ecrire(0x70, 1, 0x09); // `false` : personne non plus
//! // Pour un accès mémoire hors de la RAM (ici le premier pixel, puis un registre de l'écran) :
//! let peint = carte.mem_ecrire(0xE000_0000, 4, 0x00FF_FFFF); // `false` : la faute « hors mémoire »
//! let id = carte.mem_lire(0xE100_0500, 2); // `None` : la faute aussi
//! carte.battre(1_193); // le temps, en tics du 8254 : les frappes et les touchers à leur heure
//! carte.servir(&mut ram); // à chaque tour, et après un `out` pris : disques, tablette, lignes
//! let (levees, tenues) = (carte.lignes(), carte.tenues()); // → les requêtes des deux 8259
//! let peut_dormir = !carte.reveil(); // un `hlt` n'attend pas ce que personne ne lèvera
//! assert_eq!((lu, pris, levees, tenues & 0x420, peut_dormir), (Some(0x14), true, 0, 0x420, true));
//! // Pour la vue : l'image n'est recopiée que si elle a changé.
//! let cadre = &carte.ecran().expect("branché").cadre;
//! let (revision, mode) = (cadre.revision(), cadre.mode());
//! assert_eq!((peint, id, revision, mode.largeur, cadre.octets()[..4] == [0xFF, 0xFF, 0xFF, 0]), (true, Some(0xB0C5), 1, 1024, true));
//! ```

use super::ecran::Ecran;
use super::i8042::CodeTouche;
use super::tablette::Tablette;
use super::virtio_blk::{Sens, REGISTRE_DE_NOTIFICATION};
use super::{largeur_valide, Carte, Ram, Region, SansRam};

pub use super::pci::Disque;

/// **Là où vivent les octets d'un disque**, pour une machine qui peut les
/// lire tout de suite : `DiskStore` du cœur Swift, en octets et pas en
/// secteurs, parce que c'est ce que les requêtes décrivent.
///
/// `Send`, parce que la machine tourne sur le fil que l'application lui
/// donne, pas sur celui qui l'a bâtie.
pub trait Arriere: Send {
    /// La taille, en secteurs de 512 octets : ce que le pilote lira comme
    /// capacité.
    fn secteurs(&self) -> u64;

    /// **Remplir `vers` en entier** depuis le décalage `decalage`, en octets.
    /// `false` au-delà de la fin ou si la lecture échoue — le disque répond
    /// alors une erreur d'entrée-sortie, jamais des zéros à la place de ce
    /// qui manque. `true` promet que chaque octet de `vers` a été écrit.
    fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool;

    /// Écrire `octets` au décalage `decalage`. `false` au-delà de la fin ou
    /// si l'écriture échoue, et rien n'est alors promis.
    fn ecrire(&mut self, decalage: u64, octets: &[u8]) -> bool;

    /// Pousser ce qui a été écrit jusqu'au stockage durable. `false` si
    /// l'hôte l'a refusé.
    fn vider(&mut self) -> bool {
        true
    }

    /// **Combien d'octets l'invité a changés** : ce que le rapport de
    /// stockage de l'application montre (`DiskStore.bytesWritten`). Un disque
    /// en mémoire répond la taille de son image, comme du côté Swift : c'est
    /// ce qu'un instantané emporterait.
    fn octets_ecrits(&self) -> u64;
}

/// **L'image entière en mémoire** : la forme des tests et des petits disques
/// (`MemoryDiskStore` du cœur Swift).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArriereMemoire(pub Vec<u8>);

impl ArriereMemoire {
    fn plage(&self, decalage: u64, longueur: usize) -> Option<std::ops::Range<usize>> {
        let debut = usize::try_from(decalage).ok()?;
        let fin = debut.checked_add(longueur)?;
        // La capacité est en secteurs entiers : la queue d'une image dont la
        // taille n'est pas un multiple de 512 n'est pas du disque.
        (fin <= self.0.len() / 512 * 512).then_some(debut..fin)
    }
}

impl Arriere for ArriereMemoire {
    fn secteurs(&self) -> u64 {
        self.0.len() as u64 / 512
    }

    fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool {
        let Some(plage) = self.plage(decalage, vers.len()) else {
            return false;
        };
        vers.copy_from_slice(&self.0[plage]);
        true
    }

    fn ecrire(&mut self, decalage: u64, octets: &[u8]) -> bool {
        let Some(plage) = self.plage(decalage, octets.len()) else {
            return false;
        };
        self.0[plage].copy_from_slice(octets);
        true
    }

    fn octets_ecrits(&self) -> u64 {
        self.0.len() as u64
    }
}

/// **Ce que la façade garde du tampon de lecture d'une requête à l'autre**,
/// en octets. Un noyau lit par requêtes de quelques centaines de kibioctets
/// (1 280 Kio au plus par défaut) : le tampon est réemployé sans rien allouer.
/// Une requête géante — le disque en accepte jusqu'à 64 Mio — ne laisse pas
/// 64 Mio alloués derrière elle pour la vie de la machine.
///
/// **La borne est comprise** : un tampon de deux mébioctets tout juste est
/// gardé, un secteur de plus et il est rendu. Il ne grandit qu'à la taille
/// de la plus grande requête servie, jamais au double : ce qui est gardé est
/// donc ce qu'une requête a demandé.
pub const TAMPON_GARDE: usize = 2 << 20;

/// Une horloge : l'heure UTC, en millisecondes depuis 1970.
type Horloge = Box<dyn FnMut() -> i64 + Send>;

/// **La carte d'une machine native** : les périphériques, l'arrière de chaque
/// disque, et l'heure.
pub struct CartePc {
    carte: Carte,
    /// L'arrière du premier disque, puis celui du second.
    arrieres: [Option<Box<dyn Arriere>>; 2],
    /// Le pilote a notifié ce disque, et sa file n'a pas encore été relue.
    notifies: [bool; 2],
    /// Le pilote de la tablette a sonné cette file (celle des événements,
    /// puis celle de l'état), et elle n'a pas encore été relue.
    sonnettes: [bool; 2],
    /// L'heure du dernier [`CartePc::battre`], en tics du 8254 : celle des
    /// touchers rendus par [`CartePc::servir`].
    tics: u64,
    horloge: Option<Horloge>,
    /// Les octets d'une lecture, entre l'arrière et la RAM.
    tampon: Vec<u8>,
}

impl Default for CartePc {
    fn default() -> Self {
        Self::nouvelle()
    }
}

impl CartePc {
    /// Une carte comme la laisse un BIOS : ni disque, ni heure (l'invité
    /// lirait 1970).
    pub fn nouvelle() -> Self {
        Self {
            carte: Carte::nouvelle(),
            arrieres: [None, None],
            notifies: [false; 2],
            sonnettes: [false; 2],
            tics: 0,
            horloge: None,
            tampon: Vec::new(),
        }
    }

    /// **Les périphériques**, à lire : les compteurs d'un disque
    /// ([`Carte::disque`]), l'état du bus, ce qu'un test regarde.
    pub fn carte(&self) -> &Carte {
        &self.carte
    }

    // ---------------------------------------------------------------- disques

    /// **Brancher un disque** : le premier en 00:03.0 (ligne 5, `vda`), le
    /// second en 00:04.0 (ligne 6, `vdb`), dans l'ordre qu'on veut. Sa
    /// capacité est celle de l'arrière. Un disque déjà branché là est
    /// remplacé — à faire avant le démarrage, comme on branche un câble
    /// machine éteinte.
    pub fn brancher(&mut self, quel: Disque, arriere: impl Arriere + 'static) {
        self.carte.brancher(quel, arriere.secteurs());
        self.arrieres[quel.rang()] = Some(Box::new(arriere));
        self.notifies[quel.rang()] = false;
    }

    /// **Faire avancer les disques**, avec la RAM de l'invité : relire la
    /// file de ceux que le pilote a notifiés, servir chaque requête par
    /// l'arrière, rendre les réponses et lever les lignes — tout, avant de
    /// rendre la main.
    ///
    /// Rend le nombre de requêtes **prises au disque** : celles qui
    /// demandent des octets, que l'arrière les ait servies ou refusées, ou
    /// qu'il n'y ait pas d'arrière du tout (elles reçoivent alors une erreur
    /// d'entrée-sortie, et comptent quand même). Ce que le disque juge seul —
    /// un secteur au-delà de sa fin, son nom — n'y est pas compté.
    ///
    /// **Et la tablette** : les files que son pilote a sonnées sont relues,
    /// puis ce que le doigt a fait est rendu dans ses tampons, à l'heure du
    /// dernier [`CartePc::battre`] ([`Tablette::livrer`]). Ses événements ne
    /// sont pas des requêtes : ils ne comptent pas dans ce qui est rendu.
    ///
    /// Sans rien à faire, elle ne lit que quelques booléens : la boucle peut
    /// l'appeler après chaque `out`, et l'appelle une fois par tour.
    pub fn servir(&mut self, ram: &mut dyn Ram) -> usize {
        let mut passees = 0;
        for quel in Disque::TOUS {
            let rang = quel.rang();
            if !std::mem::take(&mut self.notifies[rang]) {
                continue;
            }
            self.carte.notifier(quel, ram);
            // Une réponse peut faire partir ce que la file laissait attendre
            // (`virtio_blk::PLUS_TENU`) : on reprend jusqu'à ce qu'il n'y ait
            // plus rien.
            while let Some(disque) = self.carte.disque_mut(quel) {
                let Some(requete) = disque.prendre_requete() else {
                    break;
                };
                passees += 1;
                let Some(arriere) = self.arrieres[rang].as_mut() else {
                    // Un disque sans arrière : une erreur d'entrée-sortie,
                    // pas un pilote qui attend pour toujours.
                    disque.fini(requete.id, false, ram);
                    continue;
                };
                match requete.sens {
                    Sens::Lire => {
                        // Jamais plus que la borne du disque (64 Mio).
                        let longueur = requete.longueur as usize;
                        if self.tampon.len() < longueur {
                            // À la taille demandée, pas au double : un
                            // tampon de 1 100 Kio doublé pour une requête
                            // de 1 280 passerait la garde, et serait rendu
                            // après chaque requête au lieu d'être réemployé.
                            self.tampon.reserve_exact(longueur - self.tampon.len());
                            self.tampon.resize(longueur, 0);
                        }
                        let octets = &mut self.tampon[..longueur];
                        if arriere.lire(requete.decalage, octets) {
                            disque.lu(requete.id, octets, ram);
                        } else {
                            disque.fini(requete.id, false, ram);
                        }
                    }
                    Sens::Ecrire => {
                        let reussi = arriere.ecrire(requete.decalage, &requete.octets);
                        disque.fini(requete.id, reussi, ram);
                    }
                }
            }
        }
        if self.tampon.capacity() > TAMPON_GARDE {
            self.tampon = Vec::new();
        }
        let sonnees = std::mem::take(&mut self.sonnettes);
        if let Some(tablette) = self.carte.tablette_mut() {
            for (file, sonnee) in sonnees.into_iter().enumerate() {
                if sonnee {
                    tablette.sonner(file, ram);
                }
            }
            if tablette.en_attente() {
                tablette.livrer(ram, Some(self.tics));
            }
        }
        passees
    }

    /// **Pousser les écritures des disques jusqu'au stockage durable** : ce
    /// que l'application demande quand elle passe en arrière-plan. `false` si
    /// un arrière l'a refusé.
    pub fn vider(&mut self) -> bool {
        let mut reussi = true;
        for arriere in self.arrieres.iter_mut().flatten() {
            reussi &= arriere.vider();
        }
        reussi
    }

    /// **Combien d'octets l'invité a changés sur ce disque**
    /// ([`Arriere::octets_ecrits`]), lu sur la machine vivante : ce que
    /// `GuestMachine.diskBytesWritten` rend du côté Swift, et que le rapport
    /// de stockage additionne pour les deux disques. Zéro sans arrière.
    pub fn octets_ecrits(&self, quel: Disque) -> u64 {
        self.arrieres[quel.rang()]
            .as_ref()
            .map_or(0, |arriere| arriere.octets_ecrits())
    }

    // ------------------------------------------------- l'écran et la tablette

    /// **Brancher l'écran**, et la tablette qui va avec : voir
    /// [`Carte::brancher_ecran`]. À faire avant le démarrage. `false` si le
    /// cadre du démarrage ne tient pas dans seize mébioctets.
    pub fn brancher_ecran(&mut self, largeur: u32, hauteur: u32) -> bool {
        let branche = self.carte.brancher_ecran(largeur, hauteur);
        if branche {
            // Une sonnette notée pour l'ancienne tablette n'est pas pour la
            // neuve.
            self.sonnettes = [false; 2];
        }
        branche
    }

    /// **L'écran**, s'il est branché. Son cadre ([`Ecran::cadre`]) est ce
    /// que la machine tend à la vue : le mode montré, la mémoire vidéo d'un
    /// bloc, et le compte des changements — égal à celui de la dernière
    /// image, il n'y a rien à repeindre.
    pub fn ecran(&self) -> Option<&Ecran> {
        self.carte.ecran()
    }

    /// La tablette, si un écran est branché : ce qu'un test regarde, et
    /// [`Tablette::prete`].
    pub fn tablette(&self) -> Option<&Tablette> {
        self.carte.tablette()
    }

    /// **Lire la mémoire d'un périphérique**, à une adresse physique hors de
    /// la RAM : voir [`Carte::mem_lire`]. `None` : pas à la carte.
    pub fn mem_lire(&mut self, adresse: u64, largeur: u8) -> Option<u64> {
        self.carte.mem_lire(adresse, largeur)
    }

    /// **Écrire la mémoire d'un périphérique** : voir [`Carte::mem_ecrire`].
    /// `false` : pas à la carte.
    ///
    /// La sonnette d'une file de la tablette est notée, et servie par
    /// [`CartePc::servir`] : elle seule a besoin de la RAM.
    pub fn mem_ecrire(&mut self, adresse: u64, largeur: u8, valeur: u64) -> bool {
        if (1..=8).contains(&largeur) {
            if let Some(Region::Tablette(decalage)) =
                self.carte.region(adresse, usize::from(largeur))
            {
                if let Some(file) = Tablette::sonnette(decalage) {
                    self.sonnettes[file] = true;
                    return true;
                }
            }
        }
        self.carte
            .mem_ecrire(adresse, largeur, valeur, &mut SansRam)
    }

    /// Lire un bloc de la mémoire vidéo : voir [`Carte::mem_lire_bloc`].
    pub fn mem_lire_bloc(&self, adresse: u64, vers: &mut [u8]) -> bool {
        self.carte.mem_lire_bloc(adresse, vers)
    }

    /// Écrire un bloc dans la mémoire vidéo : voir
    /// [`Carte::mem_ecrire_bloc`].
    pub fn mem_ecrire_bloc(&mut self, adresse: u64, depuis: &[u8]) -> bool {
        self.carte.mem_ecrire_bloc(adresse, depuis)
    }

    /// **Un toucher** : la position rapportée à l'écran (0 à 1), et les
    /// boutons. `false` quand l'invité n'a pas pris la tablette : voir
    /// [`Carte::toucher`]. Il part au prochain [`CartePc::servir`].
    pub fn toucher(&mut self, x: f64, y: f64, boutons: u8) -> bool {
        self.carte.toucher(x, y, boutons)
    }

    /// **La molette** : des crans, positifs vers le haut. Voir
    /// [`Carte::defiler`].
    pub fn defiler(&mut self, crans: i32) -> bool {
        self.carte.defiler(crans)
    }

    // ------------------------------------------------------------------ ports

    /// **Lire un port**, de `largeur` octets (1, 2 ou 4). `None` : personne
    /// ici, et le cœur rend ce qu'il rend pour un port vide. Voir
    /// [`Carte::port_lire`].
    pub fn port_lire(&mut self, port: u16, largeur: u8) -> Option<u32> {
        // Comme à l'écriture : une largeur impossible n'est un accès à
        // personne, et l'horloge n'est pas consultée pour elle.
        if !largeur_valide(largeur) {
            return None;
        }
        self.mettre_a_l_heure(port);
        // Aucune lecture de port ne touche à la RAM.
        self.carte.port_lire(port, largeur, &mut SansRam)
    }

    /// **Écrire un port.** `false` : personne ici. Voir
    /// [`Carte::port_ecrire`].
    ///
    /// La notification d'un disque est notée, et servie par
    /// [`CartePc::servir`] : elle seule a besoin de la RAM.
    pub fn port_ecrire(&mut self, port: u16, largeur: u8, valeur: u32) -> bool {
        if !largeur_valide(largeur) {
            return false;
        }
        self.mettre_a_l_heure(port);
        if let Some((quel, REGISTRE_DE_NOTIFICATION)) = self.carte.fenetre_au_port(port) {
            self.notifies[quel.rang()] = true;
            return true;
        }
        self.carte.port_ecrire(port, largeur, valeur, &mut SansRam)
    }

    // ------------------------------------------------------------------ lignes

    /// Les seize lignes, à niveau : voir [`Carte::lignes`].
    pub fn lignes(&self) -> u16 {
        self.carte.lignes()
    }

    /// Les lignes que la carte tient, levées ou non : voir [`Carte::tenues`].
    pub fn tenues(&self) -> u16 {
        self.carte.tenues()
    }

    /// Lever une ligne du dehors : voir [`Carte::lever`].
    pub fn lever(&mut self, ligne: u8) -> bool {
        self.carte.lever(ligne)
    }

    /// Baisser une ligne levée du dehors : voir [`Carte::baisser`].
    pub fn baisser(&mut self, ligne: u8) -> bool {
        self.carte.baisser(ligne)
    }

    /// **Quelque chose peut encore lever une ligne sans que l'invité
    /// agisse** : ce que compte [`Carte::reveil`], ou une notification que
    /// [`CartePc::servir`] n'a pas encore servie.
    pub fn reveil(&self) -> bool {
        self.a_servir() || self.carte.reveil()
    }

    /// Une notification d'un disque, ou une sonnette de la tablette, attend
    /// [`CartePc::servir`].
    pub fn a_servir(&self) -> bool {
        self.notifies.contains(&true) || self.sonnettes.contains(&true)
    }

    // ------------------------------------------------------------------ l'heure

    /// **Poser l'heure UTC**, en millisecondes depuis 1970. Rien ne la fait
    /// avancer d'elle-même : la machine la repose quand elle veut, ou donne
    /// une horloge ([`CartePc::horloge`]).
    pub fn regler_heure(&mut self, ms: i64) {
        self.carte.regler_heure(ms);
    }

    /// **Donner une horloge** : elle est lue avant chaque accès aux ports
    /// `0x70` et `0x71`, et à ce moment-là seulement. En natif,
    /// [`horloge_du_systeme`] ; dans un test, l'heure qu'on veut.
    pub fn horloge(&mut self, horloge: impl FnMut() -> i64 + Send + 'static) {
        self.horloge = Some(Box::new(horloge));
    }

    fn mettre_a_l_heure(&mut self, port: u16) {
        if !matches!(port, 0x70 | 0x71) {
            return;
        }
        if let Some(horloge) = self.horloge.as_mut() {
            self.carte.regler_heure(horloge());
        }
    }

    /// **Le temps qui passe**, en tics du 8254 depuis le départ de la
    /// machine : voir [`Carte::battre`]. C'est aussi l'heure des touchers
    /// que le prochain [`CartePc::servir`] rendra.
    pub fn battre(&mut self, tics: u64) {
        self.tics = tics;
        self.carte.battre(tics);
    }

    // ---------------------------------------------------------- clavier, souris

    /// Une touche posée tout de suite : voir [`Carte::touche`].
    pub fn touche(&mut self, code: CodeTouche, enfoncee: bool) {
        self.carte.touche(code, enfoncee);
    }

    /// Une frappe posée à son tour : voir [`Carte::taper`].
    pub fn taper(&mut self, code: CodeTouche, enfoncee: bool) -> bool {
        self.carte.taper(code, enfoncee)
    }

    /// Un texte, tapé au rythme d'une main : voir [`Carte::taper_texte`].
    pub fn taper_texte(&mut self, texte: &str) -> usize {
        self.carte.taper_texte(texte)
    }

    /// Un mouvement de souris : voir [`Carte::souris`].
    pub fn souris(&mut self, dx: i32, dy: i32, boutons: u8) {
        self.carte.souris(dx, dy, boutons);
    }

    /// L'invité a tiré la ligne de remise à zéro : voir
    /// [`Carte::remise_demandee`].
    pub fn remise_demandee(&self) -> bool {
        self.carte.remise_demandee()
    }
}

/// **L'heure du système**, UTC, en millisecondes depuis 1970 : l'horloge
/// d'une machine native ([`CartePc::horloge`]). Pas dans la page, qui n'a pas
/// d'horloge à lire (`SystemTime::now` y panique).
#[cfg(not(target_arch = "wasm32"))]
pub fn horloge_du_systeme() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(depuis) => i64::try_from(depuis.as_millis()).unwrap_or(i64::MAX),
        // Une horloge réglée avant 1970 : négatif, et la CMOS sait le lire.
        Err(avant) => i64::try_from(avant.duration().as_millis()).map_or(i64::MIN, |ms| -ms),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    //! **La façade, conduite comme le noyau conduit la machine** : par les
    //! ports, et rien d'autre. Chaque cas énumère le bus, place et ouvre les
    //! fenêtres, fait la poignée de main du pilote, pose une file dans la
    //! RAM, notifie par le port — puis appelle `servir`, comme la boucle.
    //!
    //! Les cas « à travers le périphérique » de `VirtioBlockTests` et de
    //! `X86SecondDiskTests` du cœur Swift, où le disque est servi pendant la
    //! notification, se retrouvent ici : c'est la façade qui rend ce
    //! comportement-là à la carte de la page, qui répond plus tard.
    use super::super::cmos::tests::MOMENT_MS;
    use super::super::i8042::LIMITE_DE_FRAPPE;
    use super::super::pci::tests::adresse;
    use super::super::virtio_blk::{LIMITE_DE_FILE, PLUS_GRANDE_REQUETE, PLUS_TENU};
    use super::super::RamPlate;
    use super::*;
    use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Où chaque disque pose sa fenêtre et sa file : le premier à `0xC000`
    /// et à la page 1, le second à `0xC040` et à la page 0x20.
    pub(crate) struct Poste {
        pub(crate) quel: Disque,
        pub(crate) fenetre: u16,
        pub(crate) page: u32,
    }

    pub(crate) const PREMIER: Poste = Poste {
        quel: Disque::Premier,
        fenetre: 0xC000,
        page: 1,
    };
    pub(crate) const SECOND: Poste = Poste {
        quel: Disque::Second,
        fenetre: 0xC040,
        page: 0x20,
    };

    impl Poste {
        fn descripteurs(&self) -> u64 {
            u64::from(self.page) * 4096
        }
        fn disponibles(&self) -> u64 {
            self.descripteurs() + 0x800
        }
        fn servies(&self) -> u64 {
            self.descripteurs() + 0x1000
        }
        /// L'en-tête de la requête `n`, et son octet de statut.
        fn entete(&self, n: u64) -> u64 {
            self.descripteurs() + 0x3000 + n * 0x20
        }
        fn statut_a(&self, n: u64) -> u64 {
            self.entete(n) + 0x10
        }

        /// **Ce que fait le noyau pour trouver et ouvrir le disque** : la
        /// BAR0 mesurée, placée, les ports activés, puis la poignée de main
        /// de `virtio_pci_legacy` et la file posée à sa page.
        pub(crate) fn ouvrir(&self, carte: &mut CartePc) {
            let emplacement = self.quel.emplacement();
            let cfg = |carte: &mut CartePc, registre: u32, largeur: u8, valeur: u32| {
                assert!(carte.port_ecrire(0xCF8, 4, adresse(emplacement, registre)));
                assert!(carte.port_ecrire(0xCFC, largeur, valeur));
            };
            carte.port_ecrire(0xCF8, 4, adresse(emplacement, 0));
            assert_eq!(carte.port_lire(0xCFC, 4), Some(0x1001_1AF4), "un disque");
            cfg(carte, 0x10, 4, 0xFFFF_FFFF);
            assert_eq!(carte.port_lire(0xCFC, 4), Some(0xFFFF_FFC1), "0x40 ports");
            cfg(carte, 0x10, 4, u32::from(self.fenetre));
            cfg(carte, 0x04, 2, 0x0005);
            let f = self.fenetre;
            for statut in [0, 1, 3] {
                assert!(carte.port_ecrire(f + 0x12, 1, statut));
            }
            let offertes = carte.port_lire(f, 4).expect("la fenêtre répond");
            carte.port_ecrire(f + 0x04, 4, offertes);
            carte.port_ecrire(f + 0x0E, 2, 0);
            assert_eq!(carte.port_lire(f + 0x0C, 2), Some(LIMITE_DE_FILE));
            carte.port_ecrire(f + 0x08, 4, self.page);
            carte.port_ecrire(f + 0x12, 1, 7);
        }

        /// Poser la requête `n` (têtes `3n`, `3n + 1`, `3n + 2`) et la
        /// publier : l'en-tête, un tampon, l'octet de statut à `0xFF`.
        pub(crate) fn requete(
            &self,
            ram: &mut RamPlate,
            n: u16,
            genre: u32,
            secteur: u64,
            tampon: (u64, u32),
        ) {
            let entete = self.entete(u64::from(n));
            ram.ecrire(entete, &genre.to_le_bytes());
            ram.ecrire(entete + 4, &0u32.to_le_bytes());
            ram.ecrire(entete + 8, &secteur.to_le_bytes());
            ram.ecrire(self.statut_a(u64::from(n)), &[0xFF]);
            let tete = 3 * n;
            let mut decrire = |i: u16, a: u64, longueur: u32, drapeaux: u16, suivant: u16| {
                let at = self.descripteurs() + u64::from(i) * 16;
                ram.ecrire(at, &a.to_le_bytes());
                ram.ecrire(at + 8, &longueur.to_le_bytes());
                ram.ecrire(at + 12, &drapeaux.to_le_bytes());
                ram.ecrire(at + 14, &suivant.to_le_bytes());
            };
            decrire(tete, entete, 16, 1, tete + 1);
            // Une lecture (genre 0) et la demande de nom (8) écrivent dans
            // le tampon : inscriptible.
            let inscriptible = u16::from(genre != 1) * 2;
            decrire(tete + 1, tampon.0, tampon.1, inscriptible | 1, tete + 2);
            decrire(tete + 2, self.statut_a(u64::from(n)), 1, 2, 0);
            ram.ecrire(
                self.disponibles() + 4 + u64::from(n % 128) * 2,
                &tete.to_le_bytes(),
            );
            ram.ecrire(self.disponibles() + 2, &(n + 1).to_le_bytes());
        }

        pub(crate) fn notifier(&self, carte: &mut CartePc) {
            assert!(carte.port_ecrire(self.fenetre + 0x10, 2, 0));
        }

        pub(crate) fn statut(&self, ram: &RamPlate, n: u64) -> u8 {
            ram.0[self.statut_a(n) as usize]
        }

        /// L'index de l'anneau des servies.
        pub(crate) fn rendues(&self, ram: &RamPlate) -> u16 {
            let a = self.servies() as usize + 2;
            u16::from_le_bytes([ram.0[a], ram.0[a + 1]])
        }
    }

    /// Une image de `secteurs` secteurs, chacun rempli de son numéro plus
    /// `plus`.
    pub(crate) fn image(secteurs: usize, plus: u8) -> Vec<u8> {
        (0..secteurs)
            .flat_map(|s| [(s as u8).wrapping_add(plus); 512])
            .collect()
    }

    pub(crate) fn ram() -> RamPlate {
        RamPlate(vec![0; 0x40_0000])
    }

    /// Une carte avec son premier disque de huit secteurs, ouverte.
    fn carte_ouverte() -> (CartePc, RamPlate) {
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Premier, ArriereMemoire(image(8, 1)));
        PREMIER.ouvrir(&mut carte);
        (carte, ram())
    }

    /// **Un disque en mémoire lit et écrit sur place, par secteurs entiers**
    /// (`MemoryDiskStore`) : rien au-delà de la fin, et la queue d'une image
    /// dont la taille n'est pas un multiple de 512 n'est pas du disque.
    #[test]
    fn a_memory_backend_reads_and_writes_in_place() {
        let mut disque = ArriereMemoire(vec![1; 1024 + 100]);
        assert_eq!(disque.secteurs(), 2);
        assert!(disque.ecrire(512, &[9, 9]));
        let mut quatre = [0; 4];
        assert!(disque.lire(510, &mut quatre));
        assert_eq!(quatre, [1, 1, 9, 9]);
        assert!(!disque.ecrire(1023, &[7, 7]), "à cheval sur la fin");
        assert!(!disque.lire(1023, &mut quatre[..2]));
        assert!(
            !disque.lire(1024, &mut quatre[..1]),
            "la queue n'existe pas"
        );
        assert!(!disque.ecrire(1024, &[7]));
        assert!(!disque.lire(u64::MAX, &mut quatre), "sans faire le tour");
        assert_eq!(quatre, [1, 1, 9, 9], "un refus ne touche à rien");
        assert_eq!(disque.0[1023..1025], [1, 1]);
        // **Le bord exact** : jusqu'au dernier octet du disque, oui ; rien du
        // tout, posé à la fin, oui encore (`MemoryDiskStore.range` admet
        // `offset == count`) ; rien du tout, posé dans la queue ou au-delà,
        // non — la queue n'est pas du disque, même pour zéro octet.
        assert!(disque.lire(1020, &mut quatre) && disque.ecrire(1020, &[1; 4]));
        assert_eq!(quatre, [1; 4], "les quatre derniers");
        assert!(disque.lire(1024, &mut []) && disque.ecrire(1024, &[]));
        assert!(!disque.lire(1025, &mut []) && !disque.ecrire(1025, &[]));
        assert!(!disque.lire(1124, &mut []) && !disque.ecrire(1124, &[]));
        assert!(!disque.lire(u64::MAX, &mut []) && !disque.ecrire(u64::MAX, &[]));
        assert_eq!(disque.0, {
            let mut attendu = vec![1; 1024 + 100];
            attendu[512..514].fill(9);
            attendu
        });
        assert!(disque.vider(), "rien à pousser");
    }

    /// **La carte passe d'un fil à l'autre** avec ses disques : la machine
    /// est bâtie sur le fil de l'application et tourne sur le sien.
    #[test]
    fn the_card_can_be_sent_to_the_machine_thread() {
        fn passe<T: Send>() {}
        passe::<CartePc>();
    }

    /// **Une lecture, par les ports, de bout en bout.** La notification ne
    /// fait rien d'elle-même — elle n'a pas la RAM — mais la carte se dit
    /// réveillable ; `servir` lit le secteur, pose le statut, lève la ligne
    /// 5 ; l'acquittement la baisse.
    #[test]
    fn a_read_is_served_before_serve_returns() {
        let (mut carte, mut ram) = carte_ouverte();
        assert_eq!(carte.port_lire(0xC014, 4), Some(8), "huit secteurs");
        PREMIER.requete(&mut ram, 0, 0, 5, (0x10_0000, 1024));
        assert!(!carte.reveil());
        PREMIER.notifier(&mut carte);

        assert!(carte.a_servir() && carte.reveil(), "notée, pas servie");
        assert_eq!(carte.lignes(), 0);
        assert_eq!(PREMIER.statut(&ram, 0), 0xFF, "rien n'a touché à la RAM");
        assert_eq!(PREMIER.rendues(&ram), 0);

        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 0), 0, "réussi");
        assert_eq!(ram.0[0x10_0000], 6, "le secteur cinq porte des 6");
        assert_eq!(ram.0[0x10_0000 + 511], 6);
        assert_eq!(ram.0[0x10_0000 + 512], 7, "puis le six, des 7");
        assert_eq!(ram.0[0x10_0000 + 1023], 7);
        assert_eq!(ram.0[0x10_0000 + 1024], 0, "et pas un octet de plus");
        assert_eq!(PREMIER.rendues(&ram), 1);
        assert_eq!(carte.lignes(), 1 << 5, "la ligne du premier disque");
        assert!(!carte.a_servir());
        assert!(carte.reveil(), "tant que la ligne est tenue");
        assert_eq!(carte.carte().disque(Disque::Premier).unwrap().servies, 1);

        assert_eq!(carte.port_lire(0xC013, 1), Some(1), "l'acquittement");
        assert_eq!(carte.lignes(), 0);
        assert!(!carte.reveil());
        assert_eq!(carte.servir(&mut ram), 0, "plus rien à faire");
    }

    /// **Une écriture arrive à l'arrière, et se relit.** Les octets sont
    /// ceux de la RAM au moment de `servir`.
    #[test]
    fn a_write_reaches_the_backend_and_reads_back() {
        let (mut carte, mut ram) = carte_ouverte();
        ram.0[0x10_0000..0x10_0200].fill(0xAB);
        PREMIER.requete(&mut ram, 0, 1, 2, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 0), 0);

        // Relue par une seconde requête, vers un autre tampon, avec ses
        // voisins que l'écriture n'a pas touchés.
        PREMIER.requete(&mut ram, 1, 0, 1, (0x20_0000, 1536));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 1), 0);
        assert_eq!(ram.0[0x20_0000..0x20_0200], [2; 512], "le secteur un");
        assert_eq!(ram.0[0x20_0200..0x20_0400], [0xAB; 512], "le deux, écrit");
        assert_eq!(ram.0[0x20_0400..0x20_0600], [4; 512], "le trois");
        assert_eq!(PREMIER.rendues(&ram), 2);
    }

    /// **Le second disque est en 00:04.0, sur la ligne 6**, avec son
    /// arrière à lui : `testSlotFourIsASecondVirtioDiskAndTheBridgeStaysSingle`
    /// et `testEachDiskAnswersItsOwnWindow` du cœur Swift, jusqu'aux octets.
    #[test]
    fn the_second_disk_has_its_own_window_line_and_bytes() {
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Premier, ArriereMemoire(image(8, 1)));
        carte.brancher(Disque::Second, ArriereMemoire(image(16, 0x80)));
        PREMIER.ouvrir(&mut carte);
        SECOND.ouvrir(&mut carte);
        let mut ram = ram();
        // Les deux lignes annoncées, par le bus.
        carte.port_ecrire(0xCF8, 4, adresse(4, 0x3C));
        assert_eq!(carte.port_lire(0xCFC, 1), Some(6));
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x3C));
        assert_eq!(carte.port_lire(0xCFC, 1), Some(5), "deux lignes, pas une");
        // Chacun sa capacité, par sa fenêtre.
        assert_eq!(carte.port_lire(0xC014, 4), Some(8));
        assert_eq!(carte.port_lire(0xC054, 4), Some(16));
        assert_eq!(carte.port_lire(0xC080, 4), None, "et personne après");

        // Une lecture sur le second seul : sa ligne, ses octets, et le
        // premier n'a rien vu. **Le premier a pourtant de quoi faire** : une
        // requête publiée dans sa file, que son pilote n'a pas encore
        // notifiée. Un disque n'est servi que sur sa propre notification
        // (`VirtioBlock.serve`, appelé par l'`out` de sa fenêtre à lui) ;
        // sans cette requête-là, rien ne montrerait qu'il a été servi à tort.
        PREMIER.requete(&mut ram, 0, 0, 3, (0x20_0000, 512));
        SECOND.requete(&mut ram, 0, 0, 3, (0x10_0000, 512));
        assert!(!carte.a_servir() && !carte.reveil(), "rien n'attend encore");
        SECOND.notifier(&mut carte);
        // Notée pour le second seul : elle compte autant que celle du
        // premier, et un `hlt` ne s'endort pas dessus.
        assert!(carte.a_servir() && carte.reveil(), "notée, pas servie");
        assert_eq!(carte.lignes(), 0);
        assert_eq!(SECOND.statut(&ram, 0), 0xFF, "rien n'a touché à la RAM");
        assert_eq!(carte.servir(&mut ram), 1);
        assert!(!carte.a_servir());
        assert_eq!(ram.0[0x10_0000..0x10_0200], [0x83; 512]);
        assert_eq!(SECOND.statut(&ram, 0), 0);
        assert_eq!(carte.lignes(), 1 << 6);
        assert_eq!(carte.tenues() & 0x60, 0x60, "la carte tient les deux");
        assert_eq!(carte.port_lire(0xC013, 1), Some(0), "le premier se tait");
        assert_eq!(carte.lignes(), 1 << 6, "et n'acquitte pas pour l'autre");
        // La requête du premier attend toujours sa notification : ni
        // réponse, ni octet, ni compte.
        assert_eq!(PREMIER.statut(&ram, 0), 0xFF, "pas servie pour l'autre");
        assert_eq!(PREMIER.rendues(&ram), 0);
        assert_eq!(ram.0[0x20_0000..0x20_0200], [0; 512]);
        let premier = carte.carte().disque(Disque::Premier).unwrap();
        assert_eq!((premier.servies, premier.refusees), (0, 0));
        assert_eq!(
            carte.servir(&mut ram),
            0,
            "et un tour de plus n'y change rien"
        );
        assert_eq!(PREMIER.statut(&ram, 0), 0xFF);

        // Les deux notifiés avant un seul `servir` : chacun est servi par
        // son arrière, et les deux lignes sont levées. La requête du premier
        // est celle qui attendait.
        SECOND.requete(&mut ram, 1, 1, 15, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        SECOND.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 2);
        assert_eq!(ram.0[0x20_0000..0x20_0200], [4; 512], "le premier disque");
        assert_eq!(carte.lignes(), (1 << 5) | (1 << 6));
        assert_eq!(carte.port_lire(0xC053, 1), Some(1));
        assert_eq!(carte.lignes(), 1 << 5);
        // L'écriture est allée sur le second, pas sur le premier : son
        // dernier secteur se relit, et le quinzième du premier n'existe pas.
        SECOND.requete(&mut ram, 2, 0, 15, (0x30_0000, 512));
        PREMIER.requete(&mut ram, 1, 0, 15, (0x30_0200, 512));
        // Dans l'autre sens aussi : le premier notifié seul, la requête
        // publiée du second attend la sienne.
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 0, "le disque la juge seul");
        assert_eq!(PREMIER.statut(&ram, 1), 1);
        assert_eq!(SECOND.statut(&ram, 2), 0xFF, "pas servie pour l'autre");
        assert_eq!(SECOND.rendues(&ram), 2);
        assert_eq!(ram.0[0x30_0000..0x30_0200], [0; 512]);
        SECOND.notifier(&mut carte);
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1, "celle du second, et elle seule");
        assert_eq!(ram.0[0x30_0000..0x30_0200], [0x83; 512]);
        assert_eq!(SECOND.statut(&ram, 2), 0);
        assert_eq!(PREMIER.statut(&ram, 1), 1, "au-delà du premier disque");
        assert_eq!(ram.0[0x30_0200..0x30_0400], [0; 512]);
    }

    /// **L'ordre de branchement est libre**, et un second disque seul ne se
    /// fait pas passer pour le premier (`testTheOrderOfAttachingDoesNotMatter`,
    /// `testWithoutASecondDiskSlotFourIsEmpty`).
    #[test]
    fn the_order_of_plugging_does_not_matter() {
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Second, ArriereMemoire(image(16, 0)));
        carte.port_ecrire(0xCF8, 4, adresse(3, 0));
        assert_eq!(carte.port_lire(0xCFC, 4), Some(0xFFFF_FFFF), "trois, vide");
        carte.port_ecrire(0xCF8, 4, adresse(4, 0));
        assert_eq!(carte.port_lire(0xCFC, 4), Some(0x1001_1AF4));
        assert_eq!(carte.tenues() & 0x60, 0x40, "la ligne 6 seule");
        carte.brancher(Disque::Premier, ArriereMemoire(image(8, 0)));
        let bus = &carte.carte().pci;
        assert_eq!(bus.second.disque.as_ref().map(|d| d.secteurs()), Some(16));
        assert_eq!(bus.premier.disque.as_ref().map(|d| d.secteurs()), Some(8));
        // Et sans second disque, l'emplacement quatre est vide.
        let mut seul = CartePc::nouvelle();
        seul.brancher(Disque::Premier, ArriereMemoire(image(8, 0)));
        seul.port_ecrire(0xCF8, 4, adresse(4, 0));
        assert_eq!(seul.port_lire(0xCFC, 4), Some(0xFFFF_FFFF));
        assert_eq!(seul.tenues() & 0x60, 0x20);
    }

    /// Un arrière qui échoue quand on le lui demande, et qui compte ses
    /// appels.
    struct Capricieux {
        image: ArriereMemoire,
        casse: bool,
        lectures: Arc<AtomicUsize>,
        vidages: Arc<AtomicUsize>,
    }

    impl Arriere for Capricieux {
        fn secteurs(&self) -> u64 {
            self.image.secteurs()
        }
        fn lire(&mut self, decalage: u64, vers: &mut [u8]) -> bool {
            self.lectures.fetch_add(1, Ordering::Relaxed);
            !self.casse && self.image.lire(decalage, vers)
        }
        fn ecrire(&mut self, decalage: u64, octets: &[u8]) -> bool {
            !self.casse && self.image.ecrire(decalage, octets)
        }
        fn vider(&mut self) -> bool {
            self.vidages.fetch_add(1, Ordering::Relaxed);
            !self.casse
        }
        fn octets_ecrits(&self) -> u64 {
            self.image.octets_ecrits()
        }
    }

    /// **Un arrière qui échoue est une erreur d'entrée-sortie**, pour une
    /// lecture comme pour une écriture : le pilote a sa réponse, sa ligne, et
    /// la RAM n'a reçu aucun octet inventé.
    #[test]
    fn a_failing_backend_is_an_io_error() {
        let lectures = Arc::new(AtomicUsize::new(0));
        let vidages = Arc::new(AtomicUsize::new(0));
        let mut carte = CartePc::nouvelle();
        carte.brancher(
            Disque::Premier,
            Capricieux {
                image: ArriereMemoire(image(8, 1)),
                casse: true,
                lectures: lectures.clone(),
                vidages: vidages.clone(),
            },
        );
        PREMIER.ouvrir(&mut carte);
        let mut ram = ram();
        ram.0[0x10_0000..0x10_0200].fill(0x77);
        PREMIER.requete(&mut ram, 0, 0, 2, (0x10_0000, 512));
        PREMIER.requete(&mut ram, 1, 1, 2, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 2);
        assert_eq!(
            lectures.load(Ordering::Relaxed),
            1,
            "l'arrière a été appelé"
        );
        assert_eq!(PREMIER.statut(&ram, 0), 1, "la lecture : erreur");
        assert_eq!(PREMIER.statut(&ram, 1), 1, "l'écriture : erreur");
        assert_eq!(ram.0[0x10_0000..0x10_0200], [0x77; 512], "rien d'inventé");
        assert_eq!(PREMIER.rendues(&ram), 2, "mais les deux sont rendues");
        assert_eq!(carte.lignes(), 1 << 5);
        let disque = carte.carte().disque(Disque::Premier).unwrap();
        assert_eq!((disque.servies, disque.refusees), (0, 2));
        // Et le vidage qu'un arrière refuse se sait.
        assert!(!carte.vider());
        assert_eq!(vidages.load(Ordering::Relaxed), 1);
    }

    /// **Vider pousse chaque disque**, une fois chacun — **que l'autre
    /// accepte ou refuse** —, et le refus d'un seul se sait, qu'il soit le
    /// premier ou le second. `GuestMachine.flushDisk` pousse les deux sans
    /// condition ; ici le refus remonte en plus, et il ne doit ni cacher le
    /// second disque (l'ISO refuse, le disque vierge n'est jamais poussé),
    /// ni être caché par lui (une perte annoncée comme réussie).
    #[test]
    fn flushing_reaches_every_backend() {
        let neuf = |casse: bool, vidages: &Arc<AtomicUsize>| Capricieux {
            image: ArriereMemoire(image(8, 1)),
            casse,
            lectures: Arc::new(AtomicUsize::new(0)),
            vidages: vidages.clone(),
        };
        let vidages = Arc::new(AtomicUsize::new(0));
        let mut carte = CartePc::nouvelle();
        assert!(carte.vider(), "sans disque, rien à pousser");
        carte.brancher(Disque::Premier, neuf(false, &vidages));
        carte.brancher(Disque::Second, neuf(false, &vidages));
        assert!(carte.vider());
        assert_eq!(vidages.load(Ordering::Relaxed), 2);

        // Qui refuse : le premier seul, le second seul, les deux. Chacun son
        // compte, pour voir lequel a été poussé.
        for (premier_casse, second_casse) in [(true, false), (false, true), (true, true)] {
            let quoi = format!("premier cassé : {premier_casse}, second : {second_casse}");
            let (du_premier, du_second) =
                (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
            let mut carte = CartePc::nouvelle();
            carte.brancher(Disque::Premier, neuf(premier_casse, &du_premier));
            carte.brancher(Disque::Second, neuf(second_casse, &du_second));
            assert!(!carte.vider(), "un refus se sait ({quoi})");
            assert_eq!(
                (
                    du_premier.load(Ordering::Relaxed),
                    du_second.load(Ordering::Relaxed)
                ),
                (1, 1),
                "les deux poussés, une fois chacun ({quoi})"
            );
        }
        // Un seul disque, le second, et il refuse : rien ne le cache.
        let du_second = Arc::new(AtomicUsize::new(0));
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Second, neuf(true, &du_second));
        assert!(!carte.vider());
        assert_eq!(du_second.load(Ordering::Relaxed), 1);
    }

    /// **Ce qui se juge sans les octets n'appelle pas l'arrière** : un
    /// secteur au-delà du disque est refusé par le disque lui-même, et le nom
    /// du disque se rend sans rien lire.
    #[test]
    fn what_needs_no_bytes_never_reaches_the_backend() {
        let lectures = Arc::new(AtomicUsize::new(0));
        let mut carte = CartePc::nouvelle();
        carte.brancher(
            Disque::Premier,
            Capricieux {
                image: ArriereMemoire(image(8, 1)),
                casse: false,
                lectures: lectures.clone(),
                vidages: Arc::new(AtomicUsize::new(0)),
            },
        );
        PREMIER.ouvrir(&mut carte);
        let mut ram = ram();
        PREMIER.requete(&mut ram, 0, 0, 8, (0x10_0000, 512));
        PREMIER.requete(&mut ram, 1, 8, 0, (0x10_0000, 20));
        PREMIER.requete(&mut ram, 2, 0, 7, (0x20_0000, 1024));
        PREMIER.notifier(&mut carte);
        assert_eq!(
            carte.servir(&mut ram),
            0,
            "le disque les a jugées seul : aucune n'est prise"
        );
        assert_eq!(lectures.load(Ordering::Relaxed), 0);
        assert_eq!(PREMIER.statut(&ram, 0), 1, "le secteur huit n'existe pas");
        assert_eq!(PREMIER.statut(&ram, 1), 0);
        assert_eq!(&ram.0[0x10_0000..0x10_0009], b"wisq-disk");
        assert_eq!(PREMIER.statut(&ram, 2), 1, "à cheval sur la fin");
        assert_eq!(ram.0[0x20_0000..0x20_0400], [0; 1024]);
        assert_eq!(PREMIER.rendues(&ram), 3);
    }

    /// **Tout ce que le pilote a publié est servi par un seul `servir`**,
    /// même au-delà de ce que le disque tient dehors à la fois : 40 lectures
    /// de deux mébioctets font 80 Mio, plus que les 64 de la borne. La file
    /// attend, chaque réponse la fait reprendre, et rien ne reste en route.
    /// (Quarante, parce qu'une file de 128 descripteurs en porte 42 de trois.)
    #[test]
    fn one_serve_drains_more_than_the_card_holds_at_once() {
        const UNE: u32 = 2 << 20;
        const COMBIEN: u16 = 40;
        assert!(u64::from(COMBIEN) * u64::from(UNE) > PLUS_TENU);
        assert!(u32::from(COMBIEN) * 3 <= LIMITE_DE_FILE);
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Premier, ArriereMemoire(image(8192, 0)));
        PREMIER.ouvrir(&mut carte);
        let mut ram = ram();
        // Le même tampon pour toutes : seuls comptent ici les statuts.
        for n in 0..COMBIEN {
            PREMIER.requete(&mut ram, n, 0, u64::from(n) * 8, (0x10_0000, UNE));
        }
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), usize::from(COMBIEN));
        assert_eq!(PREMIER.rendues(&ram), COMBIEN);
        for n in 0..u64::from(COMBIEN) {
            assert_eq!(PREMIER.statut(&ram, n), 0, "la requête {n}");
        }
        let disque = carte.carte().disque(Disque::Premier).unwrap();
        assert_eq!((disque.tenus(), disque.dehors()), (0, 0));
        assert!(!disque.en_attente(), "la file n'attend plus personne");
        // La dernière lue est la 39 : les secteurs 312 et suivants.
        assert_eq!(ram.0[0x10_0000], (312 % 256) as u8);
        assert_eq!(ram.0[0x10_0000 + 512], (313 % 256) as u8);
    }

    /// **Le tampon de lecture ne reste pas grand** : une requête de quatre
    /// mébioctets servie, la façade ne garde pas quatre mébioctets ; une
    /// requête ordinaire, elle, réemploie le sien.
    #[test]
    fn a_giant_request_does_not_leave_its_buffer_behind() {
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Premier, ArriereMemoire(image(16_384, 0)));
        PREMIER.ouvrir(&mut carte);
        let mut ram = RamPlate(vec![0; 0x80_0000]);
        PREMIER.requete(&mut ram, 0, 0, 0, (0x10_0000, 64 << 10));
        PREMIER.notifier(&mut carte);
        carte.servir(&mut ram);
        assert!(
            carte.tampon.capacity() >= 64 << 10,
            "gardé pour la suivante"
        );
        PREMIER.requete(&mut ram, 1, 0, 0, (0x10_0000, 4 << 20));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 1), 0);
        assert!(carte.tampon.capacity() <= TAMPON_GARDE);
    }

    /// **Ce que la façade garde est borné à deux mébioctets, borne
    /// comprise**, et ne grandit qu'à la taille demandée. Les nombres sont
    /// écrits ici en toutes lettres, pas pris à [`TAMPON_GARDE`] : c'est sa
    /// valeur que ce cas tient.
    #[test]
    fn the_buffer_kept_between_requests_is_two_mebibytes_at_most() {
        const KIO: u32 = 1 << 10;
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Premier, ArriereMemoire(image(16_384, 0)));
        PREMIER.ouvrir(&mut carte);
        let mut ram = RamPlate(vec![0; 0x80_0000]);
        let mut n = 0;
        let mut lire = |carte: &mut CartePc, longueur: u32| {
            PREMIER.requete(&mut ram, n, 0, 0, (0x10_0000, longueur));
            PREMIER.notifier(carte);
            assert_eq!(carte.servir(&mut ram), 1);
            assert_eq!(PREMIER.statut(&ram, u64::from(n)), 0, "{longueur} octets");
            n += 1;
            (carte.tampon.as_ptr(), carte.tampon.capacity())
        };
        assert_eq!(carte.tampon.capacity(), 0, "rien avant la première");
        // 1 100 Kio, puis 1 280 : le tampon grandit à 1 280 Kio, pas au
        // double de 1 100 (2 200 Kio, au-delà de la garde, qui le ferait
        // rendre après chaque requête). La suivante le réemploie tel quel.
        let (_, apres_1100) = lire(&mut carte, 1100 * KIO);
        assert!(apres_1100 >= 1100 << 10);
        let garde = lire(&mut carte, 1280 * KIO);
        assert!(
            garde.1 >= 1280 << 10 && garde.1 <= 2 << 20,
            "{} octets gardés",
            garde.1
        );
        assert_eq!(lire(&mut carte, 1280 * KIO), garde, "réemployé tel quel");
        assert_eq!(lire(&mut carte, 512), garde, "une petite aussi");
        // Deux mébioctets tout juste : gardés.
        let deux = lire(&mut carte, 2 << 20);
        assert_eq!(deux.1, 2 << 20, "deux mébioctets, gardés");
        assert_eq!(lire(&mut carte, 2 << 20), deux);
        // Un secteur de plus : rendu. Et la requête d'après repart d'un
        // tampon à sa taille.
        assert_eq!(lire(&mut carte, (2 << 20) + 512).1, 0, "au-delà : rendu");
        assert_eq!(lire(&mut carte, 64 * KIO).1, 64 << 10);
        assert_eq!(lire(&mut carte, 4 << 20).1, 0);
    }

    /// Le mot de huit octets du rang `rang` d'un disque sans période
    /// (l'étape finale de splitmix64) : deux endroits du disque ne se
    /// ressemblent pas, et un octet venu d'ailleurs — d'une autre requête,
    /// d'un tampon réemployé — se voit.
    fn mot_du_disque(rang: u64) -> [u8; 8] {
        let mut z = rang.wrapping_add(1).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        (z ^ (z >> 31)).to_le_bytes()
    }

    fn disque_sans_periode(secteurs: u64) -> Vec<u8> {
        (0..secteurs * 64).flat_map(mot_du_disque).collect()
    }

    /// Où `rendus` s'écarte de ce que le disque sans période porte à partir
    /// du secteur `secteur` : `None` si chaque octet est le bon.
    fn premier_ecart(rendus: &[u8], secteur: u64) -> Option<usize> {
        assert_eq!(rendus.len() % 8, 0);
        rendus
            .chunks_exact(8)
            .zip(secteur * 64..)
            .position(|(huit, rang)| huit != mot_du_disque(rang))
            .map(|mot| mot * 8)
    }

    /// **Chaque octet d'une lecture vient de l'arrière, quelle que soit sa
    /// taille** : 1 280 Kio (la plus grande requête d'un noyau, par défaut),
    /// la même taille ailleurs sur le disque par le tampon réemployé, une
    /// courte derrière une longue, puis la plus grande que le disque accepte
    /// (64 Mio) — comparées **octet pour octet** à ce que le disque porte.
    /// Un tampon réemployé ne rend rien de la requête d'avant, et ne déborde
    /// pas dans la RAM au-delà de ce que la requête demande.
    #[test]
    fn every_byte_of_a_read_comes_from_the_backend_whatever_its_size() {
        const ORDINAIRE: u32 = 1280 << 10;
        const TAMPON: usize = 0x10_0000;
        // La requête géante, et un mébioctet de disque devant elle.
        let secteurs = PLUS_GRANDE_REQUETE / 512 + 2048;
        let mut carte = CartePc::nouvelle();
        carte.brancher(
            Disque::Premier,
            ArriereMemoire(disque_sans_periode(secteurs)),
        );
        PREMIER.ouvrir(&mut carte);
        let mut ram = RamPlate(vec![0; (PLUS_GRANDE_REQUETE + 0x20_0000) as usize]);
        let lire =
            |carte: &mut CartePc, ram: &mut RamPlate, n: u16, secteur: u64, longueur: u32| {
                PREMIER.requete(ram, n, 0, secteur, (TAMPON as u64, longueur));
                PREMIER.notifier(carte);
                assert_eq!(carte.servir(ram), 1, "la requête {n}");
                assert_eq!(PREMIER.statut(ram, u64::from(n)), 0, "la requête {n}");
                assert_eq!(
                    premier_ecart(&ram.0[TAMPON..][..longueur as usize], secteur),
                    None,
                    "la requête {n} : {longueur} octets au secteur {secteur}"
                );
            };

        // La première : le tampon de la façade est neuf, et plein de zéros.
        lire(&mut carte, &mut ram, 0, 0, ORDINAIRE);
        assert_eq!(ram.0[TAMPON + ORDINAIRE as usize..][..512], [0; 512]);
        let garde = (carte.tampon.as_ptr(), carte.tampon.capacity());
        // **Il y a bien un tampon à réemployer** : sans cette ligne, un
        // tampon rendu après chaque requête (capacité nulle, deux fois) passe
        // l'égalité plus bas.
        assert!(
            garde.1 >= ORDINAIRE as usize && garde.1 <= TAMPON_GARDE,
            "{} octets gardés après une requête de {ORDINAIRE}",
            garde.1
        );
        // La même taille, ailleurs : le tampon porte encore la précédente.
        lire(&mut carte, &mut ram, 1, 2047, ORDINAIRE);
        assert_eq!(
            (carte.tampon.as_ptr(), carte.tampon.capacity()),
            garde,
            "le tampon est réemployé, sans rien allouer"
        );
        // Une courte derrière une longue : ses trois secteurs, et pas un
        // octet de plus — la suite de la RAM est encore la lecture d'avant.
        lire(&mut carte, &mut ram, 2, 5, 1536);
        assert_eq!(
            premier_ecart(&ram.0[TAMPON + 1536..][..ORDINAIRE as usize - 1536], 2050),
            None,
            "au-delà de la requête, la RAM n'a pas bougé"
        );
        // La plus grande que le disque accepte, jusqu'au dernier secteur.
        lire(&mut carte, &mut ram, 3, 2048, PLUS_GRANDE_REQUETE as u32);
        assert!(
            carte.tampon.capacity() <= TAMPON_GARDE,
            "et rien n'en reste"
        );
        // Puis une ordinaire, par un tampon neuf.
        lire(&mut carte, &mut ram, 4, 1, ORDINAIRE);
        assert_eq!(PREMIER.rendues(&ram), 5);
        let disque = carte.carte().disque(Disque::Premier).unwrap();
        assert_eq!((disque.servies, disque.refusees), (5, 0));
    }

    /// **Chaque octet d'une écriture arrive à l'arrière, là où elle est
    /// posée** : 1 280 Kio d'un trait, relus avec le secteur d'avant et celui
    /// d'après, que l'écriture n'a pas touchés. La grande lecture par l'autre
    /// bout — une écriture tronquée et dite réussie serait une perte muette.
    #[test]
    fn every_byte_of_a_large_write_reaches_the_backend() {
        const ORDINAIRE: usize = 1280 << 10;
        const ECRIT: usize = 0x10_0000;
        const RELU: usize = 0x40_0000;
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Premier, ArriereMemoire(image(4096, 1)));
        PREMIER.ouvrir(&mut carte);
        let mut ram = RamPlate(vec![0; 0x80_0000]);
        // Ce que l'invité écrit : les octets du disque sans période, pris à
        // son secteur 7.
        let ecrits = &disque_sans_periode(7 + ORDINAIRE as u64 / 512)[7 * 512..];
        ram.0[ECRIT..][..ORDINAIRE].copy_from_slice(ecrits);
        PREMIER.requete(&mut ram, 0, 1, 301, (ECRIT as u64, ORDINAIRE as u32));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 0), 0);
        // Relue avec ses deux voisins.
        PREMIER.requete(&mut ram, 1, 0, 300, (RELU as u64, ORDINAIRE as u32 + 1024));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 1), 0);
        assert_eq!(ram.0[RELU..][..512], [45; 512], "le secteur 300, intact");
        assert_eq!(
            premier_ecart(&ram.0[RELU + 512..][..ORDINAIRE], 7),
            None,
            "chaque octet écrit, à sa place"
        );
        let apres = (301 + ORDINAIRE / 512 + 1) as u8;
        assert_eq!(
            ram.0[RELU + 512 + ORDINAIRE..][..512],
            [apres; 512],
            "le secteur d'après, intact"
        );
        // Et rien n'est allé ailleurs : le début et la fin du disque.
        PREMIER.requete(&mut ram, 2, 0, 0, (RELU as u64, 512));
        PREMIER.requete(&mut ram, 3, 0, 4095, (RELU as u64 + 512, 512));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 2);
        assert_eq!(ram.0[RELU..][..512], [1; 512]);
        assert_eq!(
            ram.0[RELU + 512..][..512],
            [0; 512],
            "4095 + 1, sur un octet"
        );
    }

    /// **Un disque rebranché est servi par son nouvel arrière** : la
    /// capacité, les octets et le compte des octets changés sont ceux du
    /// neuf, et rien de l'ancien ne revient — ni ses secteurs, ni ce que
    /// l'invité y avait écrit. L'autre disque garde le sien.
    #[test]
    fn a_disk_plugged_again_is_served_by_its_new_backend() {
        let mut carte = CartePc::nouvelle();
        carte.brancher(Disque::Premier, ArriereMemoire(image(8, 1)));
        carte.brancher(Disque::Second, ArriereMemoire(image(4, 0x40)));
        PREMIER.ouvrir(&mut carte);
        let mut ram = ram();
        // L'ancien : huit secteurs, et l'invité écrit le deuxième.
        ram.0[0x10_0000..0x10_0200].fill(0xAB);
        PREMIER.requete(&mut ram, 0, 1, 2, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 0), 0);
        assert_eq!(carte.octets_ecrits(Disque::Premier), 8 * 512);

        // Le neuf, au même emplacement : seize secteurs, d'autres octets.
        carte.brancher(Disque::Premier, ArriereMemoire(image(16, 0x80)));
        PREMIER.ouvrir(&mut carte);
        SECOND.ouvrir(&mut carte);
        // Le pilote repart de zéro : une file neuve dans une RAM neuve.
        ram.0.fill(0);
        assert_eq!(carte.port_lire(0xC014, 4), Some(16), "la capacité du neuf");
        assert_eq!(carte.octets_ecrits(Disque::Premier), 16 * 512);
        assert_eq!(
            carte.octets_ecrits(Disque::Second),
            4 * 512,
            "l'autre reste"
        );
        // Le secteur écrit sur l'ancien, un secteur que l'ancien avait, et un
        // qu'il n'avait pas : tous du neuf.
        PREMIER.requete(&mut ram, 0, 0, 2, (0x10_0000, 512));
        PREMIER.requete(&mut ram, 1, 0, 5, (0x10_0200, 512));
        PREMIER.requete(&mut ram, 2, 0, 12, (0x10_0400, 1024));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 3);
        for n in 0..3 {
            assert_eq!(PREMIER.statut(&ram, n), 0, "la requête {n}");
        }
        assert_eq!(ram.0[0x10_0000..0x10_0200], [0x82; 512], "ni 0xAB, ni 3");
        assert_eq!(ram.0[0x10_0200..0x10_0400], [0x85; 512]);
        assert_eq!(
            ram.0[0x10_0400..0x10_0600],
            [0x8C; 512],
            "au-delà de l'ancien"
        );
        assert_eq!(ram.0[0x10_0600..0x10_0800], [0x8D; 512]);
        // Une écriture va au neuf, et s'y relit.
        ram.0[0x20_0000..0x20_0200].fill(0xCD);
        PREMIER.requete(&mut ram, 3, 1, 15, (0x20_0000, 512));
        PREMIER.requete(&mut ram, 4, 0, 15, (0x20_0200, 512));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 2);
        assert_eq!((PREMIER.statut(&ram, 3), PREMIER.statut(&ram, 4)), (0, 0));
        assert_eq!(ram.0[0x20_0200..0x20_0400], [0xCD; 512]);
        // Et le second disque est toujours servi par le sien.
        SECOND.requete(&mut ram, 0, 0, 3, (0x30_0000, 512));
        SECOND.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(ram.0[0x30_0000..0x30_0200], [0x43; 512]);
    }

    /// **Un disque sans arrière répond une erreur**, pas un silence : la
    /// carte de la page branchée à la main, sans personne derrière.
    #[test]
    fn a_disk_without_a_backend_answers_an_error() {
        let mut carte = CartePc::nouvelle();
        carte.carte.brancher(Disque::Premier, 8);
        PREMIER.ouvrir(&mut carte);
        let mut ram = ram();
        PREMIER.requete(&mut ram, 0, 0, 0, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1, "prise au disque, donc comptée");
        assert_eq!(PREMIER.statut(&ram, 0), 1);
        assert_eq!(carte.lignes(), 1 << 5);
        assert_eq!(carte.octets_ecrits(Disque::Premier), 0, "personne derrière");
        // **Une écriture aussi** : personne ne l'a faite, elle n'est donc pas
        // réussie. Une lecture dite « réussie » sans octets est déjà une
        // erreur pour le disque ; une écriture dite réussie serait une perte
        // que le pilote ne verrait jamais.
        assert_eq!(carte.port_lire(0xC013, 1), Some(1), "acquittée");
        ram.0[0x10_0000..0x10_0200].fill(0xAB);
        PREMIER.requete(&mut ram, 1, 1, 3, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        assert_eq!(carte.servir(&mut ram), 1);
        assert_eq!(PREMIER.statut(&ram, 1), 1, "l'écriture : erreur");
        assert_eq!(PREMIER.rendues(&ram), 2, "mais rendue");
        assert_eq!(carte.lignes(), 1 << 5);
        let disque = carte.carte().disque(Disque::Premier).unwrap();
        assert_eq!((disque.servies, disque.refusees), (0, 2));
    }

    /// **Une notification devenue sans objet ne sert rien** : la remise à
    /// zéro du pilote entre l'`out` et `servir`, ou un disque rebranché.
    #[test]
    fn a_notification_outlived_by_a_reset_serves_nothing() {
        let (mut carte, mut ram) = carte_ouverte();
        PREMIER.requete(&mut ram, 0, 0, 0, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        assert!(carte.port_ecrire(0xC012, 1, 0), "la remise à zéro");
        assert_eq!(carte.servir(&mut ram), 0);
        assert_eq!(PREMIER.statut(&ram, 0), 0xFF);
        assert_eq!(carte.lignes(), 0);
        assert!(!carte.reveil());
        // Rebranché : la notification notée pour l'ancien est oubliée.
        let (mut carte, mut ram) = carte_ouverte();
        PREMIER.requete(&mut ram, 0, 0, 0, (0x10_0000, 512));
        PREMIER.notifier(&mut carte);
        carte.brancher(Disque::Premier, ArriereMemoire(image(8, 1)));
        assert!(!carte.a_servir());
        assert_eq!(carte.servir(&mut ram), 0);
        assert_eq!(PREMIER.statut(&ram, 0), 0xFF);
        // **Celle de l'autre disque, elle, reste** : rebrancher le premier
        // n'oublie pas ce que le pilote du second a notifié, dans un sens
        // comme dans l'autre.
        for (rebranche, notifie) in [(PREMIER, SECOND), (SECOND, PREMIER)] {
            let mut carte = CartePc::nouvelle();
            carte.brancher(Disque::Premier, ArriereMemoire(image(8, 1)));
            carte.brancher(Disque::Second, ArriereMemoire(image(8, 0x41)));
            PREMIER.ouvrir(&mut carte);
            SECOND.ouvrir(&mut carte);
            let mut ram = self::ram();
            rebranche.requete(&mut ram, 0, 0, 0, (0x10_0000, 512));
            notifie.requete(&mut ram, 0, 0, 2, (0x20_0000, 512));
            rebranche.notifier(&mut carte);
            notifie.notifier(&mut carte);
            carte.brancher(rebranche.quel, ArriereMemoire(image(8, 0x81)));
            assert!(carte.a_servir() && carte.reveil(), "l'autre attend encore");
            assert_eq!(carte.servir(&mut ram), 1, "et elle seule est servie");
            assert_eq!(notifie.statut(&ram, 0), 0);
            let attendu = if notifie.quel == Disque::Premier {
                3
            } else {
                0x43
            };
            assert_eq!(ram.0[0x20_0000..0x20_0200], [attendu; 512]);
            assert_eq!(rebranche.statut(&ram, 0), 0xFF, "l'ancienne est oubliée");
            assert_eq!(ram.0[0x10_0000..0x10_0200], [0; 512]);
        }
    }

    /// **Les ports de la carte restent ceux de la carte**, et une largeur
    /// impossible n'est à personne — notification comprise.
    #[test]
    fn the_facade_keeps_the_cards_ports_and_widths() {
        let (mut carte, mut ram) = carte_ouverte();
        assert_eq!(carte.port_lire(0x64, 1), Some(0x14));
        assert_eq!(carte.port_lire(0x3F8, 1), None, "le port série est au cœur");
        assert!(!carte.port_ecrire(0x80, 1, 0));
        assert!(carte.port_ecrire(0x64, 1, 0xAA));
        assert_eq!(carte.port_lire(0x60, 1), Some(0x55));
        // **La largeur de l'accès passe la façade, dans les deux sens.** Un
        // `outb` à `0xCF8` n'écrit qu'un octet : l'adresse devient `0x80`,
        // pas `0x8000_1880` ; un `outw` en écrit deux ; et un `inb`, un
        // `inw` ne rendent que les leurs.
        assert!(carte.port_ecrire(0xCF8, 4, adresse(3, 0)));
        assert_eq!(carte.port_lire(0xCFC, 4), Some(0x1001_1AF4));
        assert_eq!(carte.port_lire(0xCFC, 2), Some(0x1AF4));
        assert_eq!(carte.port_lire(0xCFC, 1), Some(0xF4));
        assert!(carte.port_ecrire(0xCF8, 1, 0x8000_1880));
        assert_eq!(carte.port_lire(0xCF8, 4), Some(0x80), "un octet écrit");
        assert!(carte.port_ecrire(0xCF8, 2, 0x8000_1880));
        assert_eq!(carte.port_lire(0xCF8, 4), Some(0x1880), "puis deux");
        assert!(carte.port_ecrire(0xCF8, 4, 0x8000_1880));
        assert_eq!(carte.port_lire(0xCF8, 4), Some(0x8000_1880));
        PREMIER.requete(&mut ram, 0, 0, 0, (0x10_0000, 512));
        assert!(!carte.port_ecrire(0xC010, 3, 0), "trois octets : personne");
        assert!(!carte.a_servir());
        assert_eq!(carte.servir(&mut ram), 0);
        // Fenêtre fermée, la notification n'est à personne non plus.
        carte.port_ecrire(0xCF8, 4, adresse(3, 0x04));
        carte.port_ecrire(0xCFC, 2, 0);
        assert!(!carte.port_ecrire(0xC010, 2, 0));
        assert!(!carte.a_servir());
        assert!(!carte.remise_demandee());
        carte.port_ecrire(0x64, 1, 0xFE);
        assert!(carte.remise_demandee());
    }

    /// **Le clavier, la souris et les lignes du dehors passent par la
    /// façade** : chaque passage est jugé par ce que l'invité en lit, pas par
    /// ce que la fonction rend.
    #[test]
    fn the_keyboard_the_mouse_and_the_outside_lines_go_through_the_facade() {
        let mut carte = CartePc::nouvelle();
        // Une touche posée tout de suite.
        carte.touche(CodeTouche::ESPACE, true);
        assert_eq!(carte.lignes(), 1 << 1);
        assert_eq!(carte.port_lire(0x60, 1), Some(0x39));
        // **La touche nommée, dans le sens nommé** : relâchée, une autre
        // touche, une touche étendue avec son préfixe. Une façade qui ne
        // relâcherait jamais, ou qui poserait toujours la même, laisserait
        // l'invité avec une touche enfoncée que Xorg répète sans fin.
        let a = CodeTouche::simple(0x1E);
        for (code, enfoncee, lus) in [
            (CodeTouche::ESPACE, false, &[0xB9][..]),
            (a, true, &[0x1E]),
            (a, false, &[0x9E]),
            (CodeTouche::HAUT, true, &[0xE0, 0x48]),
            (CodeTouche::HAUT, false, &[0xE0, 0xC8]),
        ] {
            carte.touche(code, enfoncee);
            assert_eq!(carte.lignes(), 1 << 1);
            for &lu in lus {
                assert_eq!(carte.port_lire(0x60, 1), Some(lu), "{code:?} {enfoncee}");
            }
            assert_eq!(carte.lignes(), 0, "et rien d'autre");
        }
        // Un texte, à son rythme : rien avant le battement.
        assert_eq!(carte.taper_texte("a"), 2);
        assert!(carte.reveil());
        assert_eq!(carte.lignes(), 0);
        // Une seconde de l'invité par battement : toute frappe est à l'heure.
        const SECONDE: u64 = 1_193_182;
        let mut tics = 1;
        carte.battre(tics);
        assert_eq!(carte.port_lire(0x60, 1), Some(0x1E));
        tics += SECONDE;
        carte.battre(tics);
        assert_eq!(carte.port_lire(0x60, 1), Some(0x9E), "puis relâchée");
        assert!(!carte.reveil());
        // **Le texte nommé, en entier, et son compte** : trois caractères
        // font six frappes, lues dans l'ordre. Une façade qui taperait
        // toujours « a », ou seulement le premier caractère, laisserait le
        // bureau sans clavier.
        assert_eq!(carte.taper_texte("ls\n"), 6, "trois touches, deux sens");
        for lu in [0x26, 0xA6, 0x1F, 0x9F, 0x1C, 0x9C] {
            assert!(carte.reveil(), "il en reste");
            tics += SECONDE;
            carte.battre(tics);
            assert_eq!(carte.port_lire(0x60, 1), Some(lu));
            assert_eq!(carte.lignes(), 0, "une à la fois");
        }
        assert!(!carte.reveil());
        assert_eq!(carte.taper_texte(""), 0, "rien à taper");
        assert_eq!(carte.taper_texte("A"), 4, "Maj, A, A, Maj");
        for lu in [0x2A, 0x1E, 0x9E, 0xAA] {
            tics += SECONDE;
            carte.battre(tics);
            assert_eq!(carte.port_lire(0x60, 1), Some(lu));
        }
        assert!(!carte.reveil());

        // Une frappe à son tour : prise, en file, posée au battement.
        assert!(carte.taper(CodeTouche::ESPACE, true), "la file la prend");
        assert!(carte.reveil(), "une frappe attend son heure");
        assert_eq!(carte.lignes(), 0, "pas avant le battement");
        tics += SECONDE;
        carte.battre(tics);
        assert_eq!(carte.lignes(), 1 << 1);
        assert_eq!(carte.port_lire(0x60, 1), Some(0x39));
        assert!(!carte.reveil());
        // Par la file aussi, la touche nommée dans le sens nommé : chaque
        // frappe est lue par l'invité à son battement.
        for (code, enfoncee, lus) in [
            (CodeTouche::ESPACE, false, &[0xB9][..]),
            (a, true, &[0x1E]),
            (a, false, &[0x9E]),
            (CodeTouche::HAUT, true, &[0xE0, 0x48]),
            (CodeTouche::HAUT, false, &[0xE0, 0xC8]),
        ] {
            assert!(carte.taper(code, enfoncee), "{code:?} {enfoncee}");
            assert_eq!(carte.lignes(), 0, "pas avant le battement");
            tics += SECONDE;
            carte.battre(tics);
            for &lu in lus {
                assert_eq!(carte.port_lire(0x60, 1), Some(lu), "{code:?} {enfoncee}");
            }
            assert_eq!(carte.lignes(), 0, "et rien d'autre");
            assert!(!carte.reveil());
        }
        // La file pleine refuse un enfoncement, et la façade le dit.
        let mut prises = 0;
        while carte.taper(a, true) {
            prises += 1;
            assert!(prises <= LIMITE_DE_FRAPPE, "la file n'a pas de fond");
        }
        assert_eq!(prises, LIMITE_DE_FRAPPE);
        // Pleine, elle prend encore le relâchement de la touche qu'elle
        // laisse enfoncée — une fois —, et rien d'autre : ni le relâchement
        // d'une touche déjà relevée, ni un enfoncement.
        assert!(!carte.taper(CodeTouche::ESPACE, false), "déjà relevée");
        assert!(!carte.taper(CodeTouche::ESPACE, true));
        assert!(carte.taper(a, false), "celle que la file tient enfoncée");
        assert!(!carte.taper(a, false), "une fois");

        // La souris, allumée par l'invité (`A8`, puis `F4` par `D4`) : un
        // mouvement lève la ligne 12 et se lit en un paquet de trois octets.
        let mut carte = CartePc::nouvelle();
        carte.souris(5, 3, 1);
        assert_eq!(carte.lignes(), 0, "éteinte, elle se tait");
        for (port, octet) in [(0x64, 0xA8), (0x64, 0xD4), (0x60, 0xF4)] {
            assert!(carte.port_ecrire(port, 1, octet));
        }
        assert_eq!(
            carte.port_lire(0x60, 1),
            Some(0xFA),
            "l'accusé de la souris"
        );
        assert_eq!(carte.lignes(), 0);
        carte.souris(5, 3, 1);
        assert_eq!(carte.lignes(), 1 << 12);
        let paquet = [(); 3].map(|()| carte.port_lire(0x60, 1));
        assert_eq!(paquet, [Some(0x29), Some(5), Some(0xFD)], "Y vers le haut");
        assert_eq!(carte.lignes(), 0, "lu, la ligne retombe");
        // **Le mouvement nommé, avec les boutons nommés** : un autre geste
        // rend un autre paquet, dans chacun de ses trois octets.
        carte.souris(-7, 2, 2);
        let paquet = [(); 3].map(|()| carte.port_lire(0x60, 1));
        assert_eq!(
            paquet,
            [Some(0x08 | 0x02 | 0x10 | 0x20), Some(0xF9), Some(0xFE)],
            "à gauche, vers le bas, bouton droit"
        );
        carte.souris(0, -1, 4);
        let paquet = [(); 3].map(|()| carte.port_lire(0x60, 1));
        assert_eq!(paquet, [Some(0x08 | 0x04), Some(0), Some(1)], "le milieu");
        assert_eq!(carte.lignes(), 0);

        // Une ligne du dehors : levée, tenue, puis baissée — et elle reste
        // tenue, pour que la boucle l'efface.
        assert_eq!(carte.tenues() & (1 << 9), 0);
        assert!(carte.lever(9));
        assert_eq!(carte.lignes(), 1 << 9);
        assert_eq!(carte.tenues() & (1 << 9), 1 << 9);
        assert!(carte.baisser(9));
        assert_eq!(carte.lignes(), 0, "baissée : la ligne 9 est retombée");
        assert_eq!(carte.tenues() & (1 << 9), 1 << 9);
        // La ligne nommée, et pas une autre : la 10 levée ne relève pas la 9.
        assert!(carte.lever(10));
        assert_eq!(carte.lignes(), 1 << 10);
        assert!(carte.lever(9));
        assert!(carte.baisser(10));
        assert_eq!(carte.lignes(), 1 << 9, "la 9 reste, la 10 retombe");
        assert!(carte.baisser(9));
        assert_eq!(carte.lignes(), 0);
        // Les lignes des puces du cœur ne sont pas à la carte.
        for ligne in [0, 2, 4, 16] {
            assert!(!carte.lever(ligne) && !carte.baisser(ligne), "{ligne}");
        }
        assert_eq!(carte.lignes(), 0);
    }

    /// **Les octets changés se lisent sur la machine vivante**, disque par
    /// disque, une fois l'arrière rangé derrière la façade
    /// (`GuestMachine.diskBytesWritten`).
    #[test]
    fn the_bytes_written_are_read_through_the_facade() {
        let mut carte = CartePc::nouvelle();
        assert_eq!(carte.octets_ecrits(Disque::Premier), 0, "sans disque");
        assert_eq!(carte.octets_ecrits(Disque::Second), 0);
        carte.brancher(Disque::Premier, ArriereMemoire(image(8, 1)));
        carte.brancher(Disque::Second, ArriereMemoire(vec![0; 16 * 512 + 100]));
        // Un disque en mémoire répond la taille de son image, queue comprise
        // (`MemoryDiskStore.bytesWritten`).
        assert_eq!(carte.octets_ecrits(Disque::Premier), 8 * 512);
        assert_eq!(carte.octets_ecrits(Disque::Second), 16 * 512 + 100);
    }

    /// **L'heure est celle qu'on injecte** : posée, ou lue à une horloge
    /// avant chaque accès à la CMOS — et seulement alors.
    #[test]
    fn the_clock_is_the_one_the_machine_injects() {
        let annee = |carte: &mut CartePc| {
            carte.port_ecrire(0x70, 1, 0x09);
            carte.port_lire(0x71, 1)
        };
        let mut carte = CartePc::nouvelle();
        assert_eq!(annee(&mut carte), Some(0x70), "sans heure : 1970");
        carte.regler_heure(MOMENT_MS);
        assert_eq!(annee(&mut carte), Some(0x26));
        // À la seconde près, pas au jour : 17 h 05 min 09 s, le 30 octobre.
        for (registre, valeur) in [
            (0x00, 0x09),
            (0x02, 0x05),
            (0x04, 0x17),
            (0x07, 0x30),
            (0x08, 0x10),
        ] {
            carte.port_ecrire(0x70, 1, registre);
            assert_eq!(
                carte.port_lire(0x71, 1),
                Some(valeur),
                "registre {registre:#04x}"
            );
        }
        // **L'heure nommée, pas une heure fixe** : reposée un jour, une
        // heure, une minute et une seconde plus tard, puis un an plus tôt.
        let lire_tout = |carte: &mut CartePc| {
            [0x00, 0x02, 0x04, 0x07, 0x08, 0x09].map(|registre| {
                carte.port_ecrire(0x70, 1, registre);
                carte.port_lire(0x71, 1).expect("la CMOS répond")
            })
        };
        const PLUS_TARD: i64 = MOMENT_MS + (86_400 + 3_600 + 60 + 1) * 1_000;
        carte.regler_heure(PLUS_TARD);
        assert_eq!(
            lire_tout(&mut carte),
            [0x10, 0x06, 0x18, 0x31, 0x10, 0x26],
            "18 h 06 min 10 s, le 31 octobre 2026"
        );
        carte.regler_heure(MOMENT_MS - 365 * 86_400_000);
        assert_eq!(
            lire_tout(&mut carte),
            [0x09, 0x05, 0x17, 0x30, 0x10, 0x25],
            "le 30 octobre 2025"
        );

        let heure = Arc::new(AtomicI64::new(MOMENT_MS));
        let lectures = Arc::new(AtomicUsize::new(0));
        let (h, l) = (heure.clone(), lectures.clone());
        let mut carte = CartePc::nouvelle();
        carte.horloge(move || {
            l.fetch_add(1, Ordering::Relaxed);
            h.load(Ordering::Relaxed)
        });
        assert_eq!(
            lectures.load(Ordering::Relaxed),
            0,
            "pas avant qu'on demande"
        );
        assert_eq!(annee(&mut carte), Some(0x26));
        assert_eq!(lectures.load(Ordering::Relaxed), 2, "un `out`, un `in`");
        // Un an plus tard à l'horloge : la CMOS le dit au prochain accès.
        heure.store(MOMENT_MS + 366 * 86_400_000, Ordering::Relaxed);
        assert_eq!(annee(&mut carte), Some(0x27));
        // Les autres ports ne la consultent pas — ni le voisin `0x72`, ni
        // une largeur impossible, qui n'est un accès à personne.
        carte.port_lire(0x64, 1);
        carte.port_ecrire(0xCF8, 4, 0);
        assert_eq!(carte.port_lire(0x72, 1), None);
        assert!(!carte.port_ecrire(0x72, 1, 0));
        assert!(!carte.port_ecrire(0x70, 3, 0x09));
        assert_eq!(carte.port_lire(0x71, 3), None);
        assert_eq!(lectures.load(Ordering::Relaxed), 4);
        // **Ce que l'horloge rend est posé à la seconde**, pas au jour ni à
        // l'année : c'est le chemin d'une machine (`horloge_du_systeme`).
        heure.store(PLUS_TARD, Ordering::Relaxed);
        assert_eq!(
            lire_tout(&mut carte),
            [0x10, 0x06, 0x18, 0x31, 0x10, 0x26],
            "18 h 06 min 10 s, le 31 octobre 2026, lus à l'horloge"
        );
        assert_eq!(
            lectures.load(Ordering::Relaxed),
            4 + 12,
            "six `out` et six `in` de plus"
        );
        heure.store(PLUS_TARD + 59_000, Ordering::Relaxed);
        assert_eq!(lire_tout(&mut carte)[..2], [0x09, 0x07], "la minute suit");
    }

    /// L'horloge du système donne une heure d'aujourd'hui, pas 1970. En
    /// natif seulement : la page n'a pas d'horloge du système, elle pose l'heure.
    #[cfg(not(target_arch = "wasm32"))]
    #[test]
    fn the_system_clock_is_a_date_of_this_century() {
        let ms = horloge_du_systeme();
        // Entre 2024 et 2100.
        assert!((1_704_067_200_000..4_102_444_800_000).contains(&ms), "{ms}");
        let mut carte = CartePc::nouvelle();
        carte.horloge(horloge_du_systeme);
        carte.port_ecrire(0x70, 1, 0x32);
        assert_eq!(carte.port_lire(0x71, 1), Some(0x20), "le siècle");
    }
}
