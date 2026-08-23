/// The written pages, assembled per language.
///
/// The landing page is a layout of its own; everything else is a document, so
/// adding a page is adding content and a route rather than a component.

import type { Doc } from "../doc";
import type { Lang } from "../content";
import type { RouteId } from "../routes";

import { docsEn, docsFr } from "./docs";
import { protocolEn, protocolFr } from "./protocol";
import { architectureEn, architectureFr } from "./architecture";
import { faqEn, faqFr } from "./faq";
import { roadmapEn, roadmapFr } from "./roadmap";
import { releasesEn, releasesFr } from "./releases";
import { offlineEn, offlineFr, notFoundEn, notFoundFr } from "./offline";

export type DocRouteId = Exclude<RouteId, "home">;

export const PAGES: Record<Lang, Record<DocRouteId, Doc>> = {
  en: {
    docs: docsEn,
    protocol: protocolEn,
    architecture: architectureEn,
    faq: faqEn,
    roadmap: roadmapEn,
    releases: releasesEn,
    offline: offlineEn,
    notFound: notFoundEn,
  },
  fr: {
    docs: docsFr,
    protocol: protocolFr,
    architecture: architectureFr,
    faq: faqFr,
    roadmap: roadmapFr,
    releases: releasesFr,
    offline: offlineFr,
    notFound: notFoundFr,
  },
};

export { RELEASED_VERSIONS } from "./releases";
