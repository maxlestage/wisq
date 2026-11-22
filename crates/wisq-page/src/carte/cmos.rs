//! **L'horloge du PC** : le MC146818 et sa mémoire CMOS, par les ports 0x70
//! (l'index) et 0x71 (la donnée). Portée depuis `X86CMOSClock` du cœur Swift
//! (`Sources/WisqVM/X86CMOSClock.swift`), registre pour registre.
//!
//! **Pourquoi elle compte.** Sans elle, l'invité n'a aucune idée de la date :
//! Debian 13 démarrait au 13 avril 2026, la date de son image, et `apt`
//! refusait toutes les signatures de ses dépôts, datées de l'avenir. TLS
//! tombe de la même façon sur des certificats « pas encore valides ». La page
//! n'avait aucune horloge murale (carte du 14 novembre, § 1.9).
//!
//! **L'heure vient de l'hôte, et elle est injectée.** Le cœur Swift lit
//! `Date()` à chaque accès. Ici il n'y a pas d'horloge à lire :
//! `SystemTime::now` panique sur `wasm32-unknown-unknown`, faute de système.
//! L'hôte pose donc l'heure UTC, en millisecondes depuis 1970
//! ([`Cmos::regler_heure_hote`]) — `web/carte.js` le fait avant chaque accès
//! à ces deux ports, avec `Date.now()` ou l'horloge que le test lui donne.
//! Ce qui reste vrai du modèle Swift : une session reprise, un téléphone
//! resté en veille, retrouvent l'heure juste sans rien rattraper, et un invité
//! qui règle l'horloge (`hwclock --systohc`) ne change que l'écart qu'il garde
//! avec l'hôte.
//!
//! **Le calendrier est écrit ici**, sans dépendance (le crate n'en a aucune) :
//! les deux conversions de Howard Hinnant entre jours depuis 1970 et date
//! grégorienne proleptique, en UTC — ce que `Calendar(identifier: .gregorian)`
//! en UTC fait du côté Swift.
//!
//! **Ce qu'elle ne fait pas**, comme le modèle Swift : ni alarme ni
//! interruption périodique (la ligne huit reste muette). **L'écart réglé par
//! l'invité**, que l'instantané du cœur Swift ne garde pas, passe dans celui
//! de la machine native ([`Cmos::sauver`]) : l'invité qui reprend lit l'heure
//! qu'il avait réglée, avancée du temps passé dehors.

use super::etat::{Ecrivain, Lecteur};

/// Les registres, aux mêmes numéros que le modèle Swift.
pub const SECONDES: u8 = 0x00;
pub const MINUTES: u8 = 0x02;
pub const HEURES: u8 = 0x04;
pub const JOUR_DE_SEMAINE: u8 = 0x06;
pub const JOUR: u8 = 0x07;
pub const MOIS: u8 = 0x08;
pub const ANNEE: u8 = 0x09;
pub const ETAT_A: u8 = 0x0A;
pub const ETAT_B: u8 = 0x0B;
pub const ETAT_C: u8 = 0x0C;
pub const ETAT_D: u8 = 0x0D;
/// Le siècle, là où le place l'ACPI des PC : Linux, sans ACPI, ne le lit pas
/// et déduit le siècle de l'année.
pub const SIECLE: u8 = 0x32;

/// Les bits du registre B.
pub const BINAIRE: u8 = 0x04;
pub const VINGT_QUATRE_HEURES: u8 = 0x02;
pub const REGLAGE: u8 = 0x80;

/// Les registres de la date, dans l'ordre où le modèle Swift les rend (et où
/// [`Cmos`] range un réglage en cours).
const REGISTRES_DE_DATE: [u8; 8] = [
    SECONDES,
    MINUTES,
    HEURES,
    JOUR_DE_SEMAINE,
    JOUR,
    MOIS,
    ANNEE,
    SIECLE,
];

const MS_PAR_JOUR: i64 = 86_400_000;

/// **L'horloge et sa mémoire.**
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cmos {
    /// Le registre que le prochain accès à 0x71 lit ou écrit.
    index: u8,
    /// Ce que l'invité a réglé, moins l'heure de l'hôte au moment du réglage,
    /// en millisecondes.
    ecart_ms: i64,
    /// Le registre B : 24 heures, en BCD, comme le laisse un BIOS. Linux le
    /// lit et s'y plie ; il ne le change pas.
    etat_b: u8,
    /// Les registres de date pendant un réglage (le bit SET du registre B) :
    /// l'heure ne change qu'à la fin, d'un coup.
    reglage: Option<[u8; 8]>,
    /// Le reste de la mémoire CMOS, sans signification ici, mais relue telle
    /// qu'écrite.
    memoire: [u8; 128],
    /// L'heure UTC de l'hôte, en millisecondes depuis 1970, posée par l'hôte.
    hote_ms: i64,
}

impl Default for Cmos {
    fn default() -> Self {
        Self::nouvelle()
    }
}

impl Cmos {
    /// Une horloge comme un BIOS la laisse. `const` pour que la carte de la
    /// page tienne dans une `static` sans initialisation paresseuse.
    pub const fn nouvelle() -> Self {
        Self {
            index: 0,
            ecart_ms: 0,
            etat_b: VINGT_QUATRE_HEURES,
            reglage: None,
            memoire: [0; 128],
            hote_ms: 0,
        }
    }

    /// **L'heure de l'hôte**, UTC, en millisecondes depuis le 1ᵉʳ janvier
    /// 1970. Rien ne la fait avancer d'elle-même : sans réglage, l'invité lit
    /// 1970.
    pub fn regler_heure_hote(&mut self, ms: i64) {
        self.hote_ms = ms;
    }

    /// L'heure que voit l'invité, en millisecondes depuis 1970.
    pub fn heure_invite_ms(&self) -> i64 {
        self.hote_ms.wrapping_add(self.ecart_ms)
    }

    /// Le registre B tel qu'il est : ce que les tests regardent.
    pub fn etat_b(&self) -> u8 {
        self.etat_b
    }

    /// L'écriture au port 0x70.
    pub fn choisir(&mut self, octet: u8) {
        // Le bit 7 coupe les NMI sur un vrai PC ; il n'est pas de l'index.
        self.index = octet & 0x7F;
    }

    /// La lecture au port 0x71.
    pub fn lire(&self) -> u8 {
        match self.index {
            // Le bit 7 (« mise à jour en cours ») toujours à zéro : la date se
            // lit d'un coup, et Linux n'attend pas. 0x26 : le diviseur et la
            // cadence d'un BIOS.
            ETAT_A => 0x26,
            ETAT_B => self.etat_b,
            // Aucune interruption en attente.
            ETAT_C => 0,
            // Le bit 7 : la pile tient, l'heure est bonne.
            ETAT_D => 0x80,
            registre => match rang(registre) {
                Some(rang) => match &self.reglage {
                    Some(reglage) => reglage[rang],
                    None => self.encoder(champs(self.heure_invite_ms())[rang], registre),
                },
                None => self.memoire[usize::from(registre & 0x7F)],
            },
        }
    }

    /// L'écriture au port 0x71.
    pub fn ecrire(&mut self, octet: u8) {
        match self.index {
            ETAT_B => {
                let commence = octet & REGLAGE != 0 && self.etat_b & REGLAGE == 0;
                let finit = octet & REGLAGE == 0 && self.etat_b & REGLAGE != 0;
                // Les registres sont relus **avant** que B change, et décodés
                // **après** : l'ordre du modèle Swift, gardé tel quel.
                if commence {
                    self.reglage = Some(self.registres_de_date());
                }
                self.etat_b = octet;
                if finit {
                    if let Some(reglage) = self.reglage {
                        self.finir_le_reglage(reglage);
                    }
                }
            }
            // A et C : rien à régler ici. D se lit toujours valide, quoi qu'on
            // y écrive.
            ETAT_A | ETAT_C => {}
            registre => match rang(registre) {
                Some(rang) => {
                    if let Some(reglage) = &mut self.reglage {
                        reglage[rang] = octet;
                    } else {
                        // Un registre écrit sans SET : comme le vrai, il prend
                        // effet tout de suite.
                        let mut maintenant = self.registres_de_date();
                        maintenant[rang] = octet;
                        self.finir_le_reglage(maintenant);
                    }
                }
                None => self.memoire[usize::from(registre & 0x7F)] = octet,
            },
        }
    }

    /// Les huit registres de date, lus comme l'invité les lirait.
    fn registres_de_date(&self) -> [u8; 8] {
        let mut lus = [0; 8];
        for (rang, &registre) in REGISTRES_DE_DATE.iter().enumerate() {
            lus[rang] = match &self.reglage {
                Some(reglage) => reglage[rang],
                None => self.encoder(champs(self.heure_invite_ms())[rang], registre),
            };
        }
        lus
    }

    /// La nouvelle heure de l'invité, lue dans les registres tels qu'il les a
    /// écrits, devient un écart avec l'hôte.
    fn finir_le_reglage(&mut self, registres: [u8; 8]) {
        self.reglage = None;
        let mut valeurs = [0i64; 8];
        for (rang, (&registre, &octet)) in REGISTRES_DE_DATE.iter().zip(&registres).enumerate() {
            valeurs[rang] = self.decoder(octet, registre);
        }
        // Un siècle à zéro (ce que laisse un invité qui ne l'écrit pas) vaut
        // vingt, comme du côté Swift.
        let siecle = if valeurs[7] > 0 { valeurs[7] } else { 20 };
        let date = date_en_ms(
            siecle * 100 + valeurs[6],
            valeurs[5],
            valeurs[4],
            valeurs[2],
            valeurs[1],
            valeurs[0],
        );
        self.ecart_ms = date.wrapping_sub(self.hote_ms);
    }

    /// **En BCD ou en binaire selon le registre B**, et l'heure en douze
    /// heures s'il le demande : le bit 7 dit l'après-midi.
    pub fn encoder(&self, valeur: i64, registre: u8) -> u8 {
        let mut nombre = valeur;
        let mut apres_midi = false;
        if registre == HEURES && self.etat_b & VINGT_QUATRE_HEURES == 0 {
            apres_midi = nombre >= 12;
            nombre = if nombre % 12 == 0 { 12 } else { nombre % 12 };
        }
        // Tout champ de date tient dans un octet ; le siècle d'une année au
        // delà de 9999 serait tronqué, ce qu'aucun invité ne verra.
        let octet = if self.etat_b & BINAIRE != 0 {
            nombre as u8
        } else {
            (((nombre / 10) << 4) | (nombre % 10)) as u8
        };
        if apres_midi {
            octet | 0x80
        } else {
            octet
        }
    }

    /// L'inverse d'[`Cmos::encoder`], sous le même registre B.
    pub fn decoder(&self, octet: u8, registre: u8) -> i64 {
        let douze_heures = registre == HEURES && self.etat_b & VINGT_QUATRE_HEURES == 0;
        let mut brut = octet;
        let mut apres_midi = false;
        if douze_heures {
            apres_midi = brut & 0x80 != 0;
            brut &= 0x7F;
        }
        let mut nombre = if self.etat_b & BINAIRE != 0 {
            i64::from(brut)
        } else {
            i64::from(brut >> 4) * 10 + i64::from(brut & 0x0F)
        };
        if douze_heures {
            nombre = nombre % 12 + if apres_midi { 12 } else { 0 };
        }
        nombre
    }
}

/// Le rang d'un registre de date, ou rien pour les autres.
fn rang(registre: u8) -> Option<usize> {
    REGISTRES_DE_DATE.iter().position(|&r| r == registre)
}

/// **Les champs d'une date**, dans l'ordre de [`REGISTRES_DE_DATE`] :
/// secondes, minutes, heures, jour de la semaine (le dimanche vaut un, comme
/// pour `Calendar`), jour, mois, année sur deux chiffres, siècle.
fn champs(ms: i64) -> [i64; 8] {
    let jours = ms.div_euclid(MS_PAR_JOUR);
    let dans_le_jour = ms.rem_euclid(MS_PAR_JOUR) / 1000;
    let (annee, mois, jour) = civil_depuis_jours(jours);
    // Le 1ᵉʳ janvier 1970 était un jeudi : le cinquième jour, en comptant le
    // dimanche pour un.
    let semaine = (jours + 4).rem_euclid(7) + 1;
    [
        dans_le_jour % 60,
        dans_le_jour / 60 % 60,
        dans_le_jour / 3600,
        semaine,
        jour,
        mois,
        annee.rem_euclid(100),
        annee.div_euclid(100),
    ]
}

/// **Une date en millisecondes depuis 1970, à la façon indulgente de
/// `Calendar.date(from:)`** : un mois treize est janvier de l'année suivante,
/// un jour zéro le dernier du mois d'avant. Un invité qui écrit des octets
/// sans sens obtient donc une date, pas une erreur — et le jour de la semaine
/// est ignoré, comme du côté Swift.
fn date_en_ms(annee: i64, mois: i64, jour: i64, heure: i64, minute: i64, seconde: i64) -> i64 {
    let mois_total = annee * 12 + (mois - 1);
    let jours = jours_depuis_civil(mois_total.div_euclid(12), mois_total.rem_euclid(12) + 1, 1)
        + (jour - 1);
    (jours * 86_400 + heure * 3600 + minute * 60 + seconde) * 1000
}

/// Jours depuis le 1ᵉʳ janvier 1970 d'une date grégorienne (Howard Hinnant,
/// `days_from_civil`), pour un mois de 1 à 12.
fn jours_depuis_civil(annee: i64, mois: i64, jour: i64) -> i64 {
    let annee = if mois <= 2 { annee - 1 } else { annee };
    let ere = annee.div_euclid(400);
    let annee_de_l_ere = annee - ere * 400;
    let mois_depuis_mars = (mois + 9) % 12;
    let jour_de_l_annee = (153 * mois_depuis_mars + 2) / 5 + jour - 1;
    let jour_de_l_ere =
        annee_de_l_ere * 365 + annee_de_l_ere / 4 - annee_de_l_ere / 100 + jour_de_l_annee;
    ere * 146_097 + jour_de_l_ere - 719_468
}

/// La date grégorienne d'un nombre de jours depuis 1970 (Howard Hinnant,
/// `civil_from_days`) : année, mois de 1 à 12, jour de 1 à 31.
fn civil_depuis_jours(jours: i64) -> (i64, i64, i64) {
    let z = jours + 719_468;
    let ere = z.div_euclid(146_097);
    let jour_de_l_ere = z - ere * 146_097;
    let annee_de_l_ere = (jour_de_l_ere - jour_de_l_ere / 1460 + jour_de_l_ere / 36_524
        - jour_de_l_ere / 146_096)
        / 365;
    let jour_de_l_annee =
        jour_de_l_ere - (365 * annee_de_l_ere + annee_de_l_ere / 4 - annee_de_l_ere / 100);
    let mois_depuis_mars = (5 * jour_de_l_annee + 2) / 153;
    let jour = jour_de_l_annee - (153 * mois_depuis_mars + 2) / 5 + 1;
    let mois = if mois_depuis_mars < 10 {
        mois_depuis_mars + 3
    } else {
        mois_depuis_mars - 9
    };
    let annee = annee_de_l_ere + ere * 400 + i64::from(mois <= 2);
    (annee, mois, jour)
}

// ------------------------------------------------- l'état, pour l'instantané

impl Cmos {
    /// **L'état de l'horloge**, pour l'instantané de la machine native
    /// ([`super::etat`]) : l'index, l'écart réglé par l'invité, le
    /// registre B, un réglage en cours, la mémoire, et l'heure de l'hôte
    /// (que l'horloge de la machine qui reprend remplacera au premier accès).
    pub(crate) fn sauver(&self, e: &mut Ecrivain) {
        e.u8(self.index);
        e.i64(self.ecart_ms);
        e.u8(self.etat_b);
        e.oui(self.reglage.is_some());
        e.0.extend_from_slice(&self.reglage.unwrap_or([0; 8]));
        e.0.extend_from_slice(&self.memoire);
        e.i64(self.hote_ms);
    }

    /// Relue, ou rien : un index au-delà de 0x7F (le bit 7 n'en est pas,
    /// [`Cmos::choisir`]), ou un réglage en cours sans le bit SET du registre
    /// B — ou le bit sans réglage —, n'ont pas été écrits par [`Cmos::sauver`].
    pub(crate) fn relire(l: &mut Lecteur) -> Option<Self> {
        let index = l.u8()?;
        let ecart_ms = l.i64()?;
        let etat_b = l.u8()?;
        let en_reglage = l.oui()?;
        let registres: [u8; 8] = l.prendre(8)?.try_into().ok()?;
        let memoire: [u8; 128] = l.prendre(128)?.try_into().ok()?;
        let hote_ms = l.i64()?;
        if index > 0x7F || en_reglage != (etat_b & REGLAGE != 0) {
            return None;
        }
        if !en_reglage && registres != [0; 8] {
            return None;
        }
        Some(Self {
            index,
            ecart_ms,
            etat_b,
            reglage: en_reglage.then_some(registres),
            memoire,
            hote_ms,
        })
    }
}

#[cfg(test)]
pub(crate) mod tests {
    //! Les cinq cas de `Tests/WisqVMTests/X86CMOSClockTests.swift`, portés un
    //! pour un, au même moment et aux mêmes octets. Le cinquième passe par
    //! les ports de la [`Carte`](super::super::Carte) au lieu de ceux de
    //! `X86Machine`. Un sixième tient le calendrier lui-même, que le Swift
    //! n'avait pas à tester (il est à Foundation), et un septième le réglage
    //! en binaire, qu'aucun cas Swift ne tenait.
    use super::*;

    /// Le 30 octobre 2026, 17 h 05 min 09 s UTC, un vendredi — le moment des
    /// tests Swift.
    pub(crate) const MOMENT_MS: i64 = 1_793_379_909_000;

    fn horloge() -> Cmos {
        let mut horloge = Cmos::nouvelle();
        horloge.regler_heure_hote(MOMENT_MS);
        horloge
    }

    fn lire(horloge: &mut Cmos, registre: u8) -> u8 {
        horloge.choisir(registre);
        horloge.lire()
    }

    #[test]
    fn the_moment_of_the_swift_tests_is_the_one_written_here() {
        // Le moment est écrit en millisecondes ; le calendrier doit le
        // relire au jour près, et aller-retour.
        assert_eq!(date_en_ms(2026, 10, 30, 17, 5, 9), MOMENT_MS);
        assert_eq!(champs(MOMENT_MS), [9, 5, 17, 6, 30, 10, 26, 20]);
        // Les bords du calendrier : un 29 février, un passage de siècle non
        // bissextile, la veille de 1970 et l'indulgence de `Calendar`.
        assert_eq!(champs(date_en_ms(2024, 2, 29, 0, 0, 0))[4..6], [29, 2]);
        assert_eq!(champs(date_en_ms(2100, 2, 29, 0, 0, 0))[4..6], [1, 3]);
        assert_eq!(champs(-1000), [59, 59, 23, 4, 31, 12, 69, 19]);
        assert_eq!(
            date_en_ms(2026, 13, 1, 0, 0, 0),
            date_en_ms(2027, 1, 1, 0, 0, 0)
        );
        assert_eq!(
            date_en_ms(2026, 3, 0, 0, 0, 0),
            date_en_ms(2026, 2, 28, 0, 0, 0)
        );
        for jours in (-800_000..800_000).step_by(997) {
            let (a, m, j) = civil_depuis_jours(jours);
            assert_eq!(jours_depuis_civil(a, m, j), jours, "{a}-{m}-{j}");
        }
    }

    /// **La date de l'hôte, en BCD**, telle qu'un BIOS la laisse : l'invité
    /// démarre au bon jour, et sa pile est bonne.
    #[test]
    fn the_guest_reads_the_host_date_in_bcd() {
        let mut h = horloge();
        assert_eq!(lire(&mut h, 0x00), 0x09);
        assert_eq!(lire(&mut h, 0x02), 0x05);
        assert_eq!(lire(&mut h, 0x04), 0x17);
        assert_eq!(lire(&mut h, 0x06), 0x06, "vendredi : le dimanche vaut un");
        assert_eq!(lire(&mut h, 0x07), 0x30);
        assert_eq!(lire(&mut h, 0x08), 0x10);
        assert_eq!(lire(&mut h, 0x09), 0x26);
        assert_eq!(lire(&mut h, 0x32), 0x20);
        assert_eq!(
            lire(&mut h, 0x0A) & 0x80,
            0,
            "jamais « mise à jour en cours »"
        );
        assert_eq!(lire(&mut h, 0x0B), 0x02, "24 heures, BCD");
        assert_eq!(lire(&mut h, 0x0D), 0x80, "l'heure est valide");
        assert_eq!(lire(&mut h, 0x0C), 0);
        // Le bit 7 de l'index coupe les NMI ; il ne change pas le registre.
        h.choisir(0x80 | 0x09);
        assert_eq!(h.lire(), 0x26);
    }

    /// **Le binaire, et les douze heures**, quand le registre B les demande.
    #[test]
    fn binary_and_twelve_hour_modes() {
        let mut h = horloge();
        h.choisir(0x0B);
        h.ecrire(BINAIRE);
        assert_eq!(lire(&mut h, 0x04), 5 | 0x80, "5 h de l'après-midi");
        assert_eq!(lire(&mut h, 0x09), 26);
        h.choisir(0x0B);
        h.ecrire(BINAIRE | VINGT_QUATRE_HEURES);
        assert_eq!(lire(&mut h, 0x04), 17);
        assert_eq!(h.encoder(0, 0x04), 0);
        h.etat_b = 0;
        assert_eq!(h.encoder(0, 0x04), 0x12, "minuit s'écrit 12 du matin");
        assert_eq!(h.decoder(0x12, 0x04), 0);
        assert_eq!(h.decoder(0x92, 0x04), 12, "midi");
    }

    /// **Régler l'horloge** (`hwclock --systohc`) : SET, les registres, SET
    /// retiré. L'heure de l'invité suit, et l'hôte n'est pas touché ; pendant
    /// le réglage, la lecture rend ce qui a été écrit.
    #[test]
    fn the_guest_sets_the_clock() {
        let mut h = horloge();
        h.choisir(0x0B);
        h.ecrire(0x02 | REGLAGE);
        // **L'horloge est figée pendant le réglage** — ce que le cas Swift
        // ne tenait pas : sans la copie des registres au début du réglage,
        // chaque écriture prenait effet tout de suite et le test restait
        // vert (le sabotage l'a montré). Une heure passe chez l'hôte ; les
        // registres que l'invité n'a pas encore écrits n'en savent rien.
        h.regler_heure_hote(MOMENT_MS + 3_600_000);
        assert_eq!(lire(&mut h, 0x04), 0x17, "figée pendant le réglage");
        for (registre, valeur) in [
            (0x00, 0x00),
            (0x02, 0x30),
            (0x04, 0x08),
            (0x07, 0x01),
            (0x08, 0x01),
            (0x09, 0x27),
        ] {
            h.choisir(registre);
            h.ecrire(valeur);
        }
        assert_eq!(
            lire(&mut h, 0x09),
            0x27,
            "relu tel qu'écrit pendant le réglage"
        );
        h.choisir(0x0B);
        h.ecrire(0x02);
        assert_eq!(h.heure_invite_ms(), date_en_ms(2027, 1, 1, 8, 30, 0));
        assert_eq!(h.hote_ms, MOMENT_MS + 3_600_000, "l'hôte n'est pas touché");
        assert_eq!(lire(&mut h, 0x09), 0x27);
        assert_eq!(lire(&mut h, 0x04), 0x08);
        // Une heure écrite sans SET prend effet tout de suite, le reste gardé.
        h.choisir(0x04);
        h.ecrire(0x10);
        assert_eq!(lire(&mut h, 0x04), 0x10);
        assert_eq!(lire(&mut h, 0x09), 0x27);
        // Et l'écart suit l'hôte : une heure plus tard chez lui, une heure
        // plus tard chez l'invité.
        h.regler_heure_hote(MOMENT_MS + 7_200_000);
        assert_eq!(lire(&mut h, 0x04), 0x11);
        // Le siècle écrit compte, et un siècle à zéro vaut vingt.
        h.choisir(0x32);
        h.ecrire(0x19);
        assert_eq!(
            (lire(&mut h, 0x32), lire(&mut h, 0x09)),
            (0x19, 0x27),
            "1927"
        );
        h.choisir(0x32);
        h.ecrire(0x00);
        assert_eq!(
            (lire(&mut h, 0x32), lire(&mut h, 0x09)),
            (0x20, 0x27),
            "2027"
        );
    }

    /// **Régler l'horloge en binaire** (`hwclock` sous un registre B
    /// binaire) : les registres écrits se décodent en binaire, l'heure en
    /// douze heures comprise. Décodés en BCD, `27` (`0x1B`) donnait 2021.
    #[test]
    fn the_guest_sets_the_clock_in_binary() {
        let mut h = horloge();
        h.choisir(0x0B);
        h.ecrire(BINAIRE | REGLAGE);
        for (registre, valeur) in [
            (0x00, 7),
            (0x02, 45),
            (0x04, 8 | 0x80),
            (0x07, 19),
            (0x08, 12),
            (0x09, 27),
            (0x32, 20),
        ] {
            h.choisir(registre);
            h.ecrire(valeur);
        }
        h.choisir(0x0B);
        h.ecrire(BINAIRE);
        assert_eq!(
            h.heure_invite_ms(),
            date_en_ms(2027, 12, 19, 20, 45, 7),
            "8 h de l'après-midi, le 19 décembre 2027"
        );
        assert_eq!(lire(&mut h, 0x09), 27);
        assert_eq!(lire(&mut h, 0x04), 8 | 0x80);
    }

    /// Le reste de la mémoire CMOS se relit tel qu'écrit.
    #[test]
    fn the_rest_of_the_memory_is_kept() {
        let mut h = horloge();
        h.choisir(0x0F);
        h.ecrire(0xA5);
        assert_eq!(lire(&mut h, 0x0F), 0xA5);
        h.choisir(0x0D);
        h.ecrire(0);
        assert_eq!(lire(&mut h, 0x0D), 0x80, "le registre D ne s'écrit pas");
    }
}

#[cfg(test)]
mod tests_de_l_etat {
    //! **L'horloge sauvée et relue** ([`Cmos::sauver`]) : un réglage en
    //! cours passe, et ce que `sauver` n'écrit jamais est refusé.
    use super::super::etat::essais::{chaque_coupure_refusee, octets_de, relu, se_relit};
    use super::*;

    fn reglee() -> Cmos {
        let mut cmos = Cmos::nouvelle();
        cmos.regler_heure_hote(1_793_379_909_000);
        cmos.choisir(0x0B);
        cmos.ecrire(VINGT_QUATRE_HEURES | REGLAGE);
        cmos.choisir(ANNEE);
        cmos.ecrire(0x31);
        cmos.choisir(0x40);
        cmos.ecrire(0x5A);
        cmos
    }

    #[test]
    fn a_clock_in_the_middle_of_a_setting_reads_back() {
        let cmos = reglee();
        assert!(cmos.reglage.is_some(), "un réglage en cours");
        let octets = octets_de(&cmos, Cmos::sauver);
        assert_eq!(relu(&octets, Cmos::relire), Some(cmos.clone()));
        chaque_coupure_refusee(&octets, Cmos::relire);
        // Fini, le réglage pose son écart ; il passe l'instantané aussi.
        let mut finie = cmos;
        finie.choisir(0x0B);
        finie.ecrire(VINGT_QUATRE_HEURES);
        assert_ne!(finie.ecart_ms, 0);
        let octets = octets_de(&finie, Cmos::sauver);
        assert_eq!(relu(&octets, Cmos::relire), Some(finie));
    }

    #[test]
    fn what_the_clock_never_holds_is_refused() {
        let cmos = reglee();
        let relit = |abimer: fn(&mut Cmos)| se_relit(&cmos, abimer, Cmos::sauver, Cmos::relire);
        assert!(relit(|_| {}), "tel quel");
        assert!(!relit(|c| c.index = 0x80), "un index avec le bit 7");
        assert!(
            !relit(|c| c.etat_b &= !REGLAGE),
            "un réglage sans le bit SET"
        );
        let neuve = Cmos::nouvelle();
        assert!(
            !se_relit(&neuve, |c| c.etat_b |= REGLAGE, Cmos::sauver, Cmos::relire),
            "le bit SET sans réglage"
        );
        // Sans réglage, les huit octets écrits à sa place sont nuls.
        let mut octets = octets_de(&neuve, Cmos::sauver);
        assert_eq!(octets[10], 0, "aucun réglage");
        octets[11] = 1;
        assert_eq!(
            relu(&octets, Cmos::relire),
            None,
            "des registres de réglage sans réglage"
        );
    }
}
