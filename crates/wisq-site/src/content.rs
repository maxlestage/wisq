//! Toute la copie, dans les deux langues, et la raison d'être de ce module est
//! la même que celle de `site/src/content.ts` qu'il remplace : les composants
//! restent de la mise en page, et rien ne peut dériver entre les versions.
//!
//! **La promesse de l'original devient ici une vraie garantie du compilateur.**
//! L'en-tête de `content.ts` dit : « une traduction manquante est une erreur de
//! type plutôt qu'une chaîne anglaise qui fuit dans la page française ». En
//! TypeScript c'était vrai par discipline de structure ; en Rust, `Copy` est un
//! `struct` sans valeur par défaut, donc une langue incomplète ne compile pas.

/// L'anglais est servi à la racine, le français sous `fr/`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lang {
    En,
    Fr,
}

impl Lang {
    /// Les deux langues, dans l'ordre où la construction écrit les pages.
    pub const ALL: [Lang; 2] = [Lang::En, Lang::Fr];

    /// Le code BCP 47 qui part dans `<html lang>`.
    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::Fr => "fr",
        }
    }

    /// Le préfixe d'adresse. Vide pour l'anglais : une langue qu'une URL ne
    /// sait pas exprimer est une langue que le web ne voit pas.
    pub fn prefix(self) -> &'static str {
        match self {
            Lang::En => "",
            Lang::Fr => "fr/",
        }
    }

    pub fn parse(code: &str) -> Option<Lang> {
        match code {
            "en" => Some(Lang::En),
            "fr" => Some(Lang::Fr),
            _ => None,
        }
    }

    pub fn copy(self) -> &'static Copy {
        match self {
            Lang::En => &EN,
            Lang::Fr => &FR,
        }
    }
}

/// La bascule de thème. Chaque libellé est un nom accessible réel : les boutons
/// montrent des icônes, et une icône sans nom est un bouton qu'un lecteur
/// d'écran ne peut pas annoncer.
pub struct ThemeCopy {
    pub label: &'static str,
    pub light: &'static str,
    pub dark: &'static str,
    pub auto: &'static str,
}

/// Les libellés de navigation des pages, un par route.
pub struct PagesCopy {
    pub home: &'static str,
    pub not_found: &'static str,
    pub docs: &'static str,
    pub protocol: &'static str,
    pub architecture: &'static str,
    pub faq: &'static str,
    pub roadmap: &'static str,
    pub releases: &'static str,
    pub privacy: &'static str,
    pub offline: &'static str,
}

pub struct FooterGroups {
    pub product: &'static str,
    pub documentation: &'static str,
    pub project: &'static str,
}

pub struct FooterCopy {
    /// Le nom accessible des deux groupes de liens — la bande sous l'en-tête et
    /// les colonnes au-dessus de la barre du bas. Les deux sont de la
    /// navigation, et un repère `nav` sans nom est un repère qu'un lecteur
    /// d'écran annonce « navigation » et rien de plus.
    pub docs: &'static str,
    pub groups: FooterGroups,
    pub note: &'static str,
    /// Une ligne sous le mot-symbole, pour qui arrive au pied sans avoir lu la
    /// page au-dessus.
    pub tagline: &'static str,
    /// Dit parce que c'est vrai et vérifiable, pas comme un slogan : un test
    /// fait échouer la construction si une adresse tierce apparaît dans le
    /// site construit.
    pub privacy_note: &'static str,
    /// Qui a écrit ceci. Tenu distinct de `attribution`, qui crédite le travail
    /// d'autrui : une ligne qui dit ce qui est à moi ne doit jamais se lire
    /// comme une revendication sur ce qui ne l'est pas.
    pub author: &'static str,
    pub attribution: &'static str,
    /// Ce par quoi la ligne de version se terminait était une licence. Il n'y en
    /// a pas, donc elle finit par le défaut nu — vrai quoi qu'on choisisse, et
    /// la ligne garde sa forme au lieu de s'arrêter après un numéro.
    pub rights: &'static str,
    /// Le droit d'auteur de la barre du bas. Un droit d'auteur n'est pas une
    /// licence : il dit qui a écrit ceci, ce qui est vrai et réglé, là où la
    /// licence disait ce que les autres peuvent en faire, ce qui ne l'est pas.
    pub copyright: &'static str,
    pub back_to_top: &'static str,
    pub version: &'static str,
}

/// L'invite d'installation. Deux formes, parce que les plateformes diffèrent :
/// un navigateur qui émet `beforeinstallprompt` reçoit un bouton, et iOS — qui
/// ne l'émet jamais, et qui est la plateforme dont ce projet parle — reçoit les
/// trois gestes qui marchent.
pub struct PwaCopy {
    pub title: &'static str,
    pub body: &'static str,
    pub action: &'static str,
    pub ios_title: &'static str,
    pub ios_body: &'static str,
    pub dismiss: &'static str,
}

pub struct Copy {
    pub language: &'static str,
    pub theme: ThemeCopy,
    pub pages: PagesCopy,
    pub footer: FooterCopy,
    pub pwa: PwaCopy,
}

/// Qui a écrit ceci, et la version que le pied annonce.
pub const AUTHOR: &str = "Maxime Nathan Lestage";
pub const AUTHOR_URL: &str = "https://github.com/maxlestage";
pub const SITE_VERSION: &str = "0.4.0";

pub static EN: Copy = Copy {
    language: "Language",
    theme: ThemeCopy {
        label: "Theme",
        light: "Light",
        dark: "Dark",
        auto: "Match system",
    },
    pages: PagesCopy {
        home: "Home",
        not_found: "Not found",
        docs: "Docs",
        protocol: "Agent protocol",
        architecture: "Architecture",
        faq: "Questions",
        roadmap: "Roadmap",
        releases: "Releases",
        privacy: "Privacy",
        offline: "Offline",
    },
    footer: FooterCopy {
        docs: "Site",
        groups: FooterGroups {
            product: "Product",
            documentation: "Documentation",
            project: "Project",
        },
        note: "The agent speaks TLS by default, pinned by the pairing link — no certificate authority to run. Plain VNC itself stays unencrypted: trusted network or tunnel for the console.",
        tagline: "Virtual machines on your iPhone: remote at full speed, or a real Linux kernel on the phone itself.",
        privacy_note: "No analytics, no cookies, no third-party requests. This page loaded nothing from anyone else.",
        author: "Designed and developed by",
        attribution: "RISC-V execution semantics ported from mini-rv32ima by Charles Lohr (MIT).",
        rights: "All rights reserved",
        copyright: "© 2026 Maxime Nathan Lestage",
        back_to_top: "Back to top",
        version: "Version",
    },
    pwa: PwaCopy {
        title: "Keep wisq one tap away",
        body: "Install this site and it opens like an app, works without a network, and stops asking.",
        action: "Install",
        ios_title: "Add to your Home Screen",
        ios_body: "Tap the Share button, then Add to Home Screen.",
        dismiss: "Not now",
    },
};

pub static FR: Copy = Copy {
    language: "Langue",
    theme: ThemeCopy {
        label: "Thème",
        light: "Clair",
        dark: "Sombre",
        auto: "Selon le système",
    },
    pages: PagesCopy {
        home: "Accueil",
        not_found: "Introuvable",
        docs: "Docs",
        protocol: "Protocole de l'agent",
        architecture: "Architecture",
        faq: "Questions",
        roadmap: "Feuille de route",
        releases: "Versions",
        privacy: "Vie privée",
        offline: "Hors ligne",
    },
    footer: FooterCopy {
        docs: "Site",
        groups: FooterGroups {
            product: "Produit",
            documentation: "Documentation",
            project: "Projet",
        },
        note: "L'agent parle TLS par défaut, épinglé par le lien d'appairage — aucune autorité de certification à exploiter. Le VNC nu reste non chiffré : réseau de confiance ou tunnel pour la console.",
        tagline: "Des machines virtuelles sur votre iPhone : à distance à pleine vitesse, ou un vrai noyau Linux sur le téléphone lui-même.",
        privacy_note: "Aucune mesure d'audience, aucun cookie, aucune requête tierce. Cette page n'a rien chargé chez qui que ce soit.",
        author: "Conçu et développé par",
        attribution: "Sémantique d'exécution RISC-V portée de mini-rv32ima, de Charles Lohr (MIT).",
        rights: "Tous droits réservés",
        copyright: "© 2026 Maxime Nathan Lestage",
        back_to_top: "Haut de page",
        version: "Version",
    },
    pwa: PwaCopy {
        title: "Gardez wisq à une touche",
        body: "Installez ce site : il s'ouvre comme une application, fonctionne sans réseau, et cesse de demander.",
        action: "Installer",
        ios_title: "Ajouter à l'écran d'accueil",
        ios_body: "Touchez le bouton Partager, puis « Sur l'écran d'accueil ».",
        dismiss: "Plus tard",
    },
};
