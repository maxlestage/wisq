/// The written pages, assembled per language.
///
/// Three, now: the privacy statement, the offline fallback and the not-found
/// page. The guide, the agent protocol reference, the architecture note, the
/// questions, the roadmap and the release history were removed deliberately —
/// the site says what wisq is, and nothing about how to run it.

import type { Doc } from "../doc";
import type { Lang } from "../content";
import type { RouteId } from "../routes";

import { privacyEn, privacyFr } from "./privacy";
import { offlineEn, offlineFr, notFoundEn, notFoundFr } from "./offline";

export type DocRouteId = Exclude<RouteId, "home">;

export const PAGES: Record<Lang, Record<DocRouteId, Doc>> = {
  en: {
    privacy: privacyEn,
    offline: offlineEn,
    notFound: notFoundEn,
  },
  fr: {
    privacy: privacyFr,
    offline: offlineFr,
    notFound: notFoundFr,
  },
};
