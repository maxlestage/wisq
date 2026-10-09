//! Les deux pages de repli : hors ligne, et introuvable.
//!
//! Des données, pas du balisage : `crate::doc` est le seul rendu, et une
//! traduction manquante ne compile pas.

use crate::doc::{Block, DlItem, Doc, Tone};

pub static OFFLINE_EN: Doc = Doc {
    title: "Offline",
    lede: "There is no network, and this address is not one the site keeps on the device.",
    blocks: &[
        Block::P("The first time the site is opened with a connection, its service worker stores every page of it on the device — in both languages — along with the stylesheet, the font, the WebAssembly module and the icons. From then on, every page in the navigation opens without a network. This page is what any other address gets, or every address on a device where the site has never been opened online."),
        Block::P("With a network, pages still come from the network first, and the copy on the device is only the fallback: what you read online is never a stale copy, and documentation that is quietly a week old is worse than a page that says it cannot load. Each build names its cache after its own files, so a new version of the site replaces the old copy instead of sitting beside it."),
        Block::P("The same holds once the site is installed on a Home Screen, and in the language you were reading: an address under /fr/ that fails lands on the French version of this page."),
        Block::Note { tone: Tone::Info, text: "This is the site being offline, not wisq. The local Linux machines in the app need no network at all — no server, no account, nothing to reach." },
    ],
};

pub static OFFLINE_FR: Doc = Doc {
    title: "Hors ligne",
    lede: "Il n'y a pas de réseau, et cette adresse n'est pas de celles que le site garde sur l'appareil.",
    blocks: &[
        Block::P("La première fois que le site est ouvert avec une connexion, son service worker range sur l'appareil chacune de ses pages — dans les deux langues — avec la feuille de style, la police, le module WebAssembly et les icônes. Dès lors, toutes les pages de la navigation s'ouvrent sans réseau. Cette page est ce que reçoit toute autre adresse, ou toute adresse sur un appareil où le site n'a jamais été ouvert en ligne."),
        Block::P("Avec du réseau, les pages viennent toujours d'abord du réseau, et la copie de l'appareil n'est qu'un repli : ce qu'on lit en ligne n'est jamais une copie périmée, et une documentation discrètement vieille d'une semaine est pire qu'une page qui dit ne pas pouvoir charger. Chaque construction nomme son cache d'après ses propres fichiers, donc une nouvelle version du site remplace l'ancienne copie au lieu de s'y ajouter."),
        Block::P("Il en va de même une fois le site installé sur l'écran d'accueil, et dans la langue que vous lisiez : une adresse sous /fr/ qui échoue arrive sur la version française de cette page."),
        Block::Note { tone: Tone::Info, text: "C'est le site qui est hors ligne, pas wisq. Les machines Linux locales de l'application n'ont besoin d'aucun réseau — ni serveur, ni compte, rien à joindre." },
    ],
};

pub static NOT_FOUND_EN: Doc = Doc {
    title: "Not found",
    lede: "That address does not exist on this site.",
    blocks: &[
        Block::P("It may have been renamed, or the link may have been typed by hand. The site is small, and everything it has is one of the pages below — each one is also in the navigation above, in English and in French."),
        Block::Dl(&[
            DlItem { term: "Home", detail: "What wisq is: the two ways it runs a machine, the three console protocols, the two local machines, and where the project stands." },
            DlItem { term: "Docs", detail: "How to use it: connecting to a VM, pairing the agent, booting Linux on the phone, and what to do when something does not work." },
            DlItem { term: "Agent protocol", detail: "The host agent's HTTP API, its pairing link and its TLS." },
            DlItem { term: "Architecture", detail: "The decisions the project rests on, and why each one was made." },
            DlItem { term: "Questions", detail: "Jailbreak, App Store, speed, hypervisors, licence." },
            DlItem { term: "Roadmap", detail: "What is done, and what comes next." },
            DlItem { term: "Releases", detail: "Every published version, and what it changed." },
            DlItem { term: "Privacy", detail: "What this site and the app keep, and what they never collect." },
        ]),
    ],
};

pub static NOT_FOUND_FR: Doc = Doc {
    title: "Page introuvable",
    lede: "Cette adresse n'existe pas sur ce site.",
    blocks: &[
        Block::P("Elle a peut-être été renommée, ou le lien a été saisi à la main. Le site est petit, et tout ce qu'il contient est l'une des pages ci-dessous — chacune est aussi dans la navigation au-dessus, en français et en anglais."),
        Block::Dl(&[
            DlItem { term: "Accueil", detail: "Ce qu'est wisq : les deux façons dont il fait tourner une machine, les trois protocoles de console, les deux machines locales, et où en est le projet." },
            DlItem { term: "Docs", detail: "Comment s'en servir : se connecter à une VM, appairer l'agent, démarrer Linux sur le téléphone, et quoi faire quand quelque chose ne marche pas." },
            DlItem { term: "Protocole de l'agent", detail: "L'API HTTP de l'agent hôte, son lien d'appairage et son TLS." },
            DlItem { term: "Architecture", detail: "Les décisions sur lesquelles repose le projet, et pourquoi chacune a été prise." },
            DlItem { term: "Questions", detail: "Jailbreak, App Store, vitesse, hyperviseurs, licence." },
            DlItem { term: "Feuille de route", detail: "Ce qui est fait, et ce qui vient ensuite." },
            DlItem { term: "Versions", detail: "Chaque version publiée, et ce qu'elle a changé." },
            DlItem { term: "Vie privée", detail: "Ce que ce site et l'application gardent, et ce qu'ils ne collectent jamais." },
        ]),
    ],
};
