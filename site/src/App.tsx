import { useEffect, useState } from "react";
import {
  copy as allCopy,
  CHANGELOG,
  CONTRIBUTING,
  ISSUES,
  REPO,
  SECURITY,
  SITE_VERSION,
  type Lang,
} from "./content";
import { Install } from "./components/Install";
import { DocPage } from "./components/Doc";
import { InstallPrompt } from "./components/InstallPrompt";
import { PAGES, type DocRouteId } from "./pages";
import { ROUTES, routeById, routeHref, type Route, type RouteId } from "./routes";

const LANG_KEY = "wisq.lang";

/// Pages are separate documents with real addresses, so the language choice has
/// to outlive a navigation. It lives in local storage rather than in the URL:
/// a link someone shares should open in the reader's language, not the
/// sender's.
function storedLang(): Lang | null {
  try {
    const value = localStorage.getItem(LANG_KEY);
    return value === "en" || value === "fr" ? value : null;
  } catch {
    return null;
  }
}

function rememberLang(lang: Lang) {
  try {
    localStorage.setItem(LANG_KEY, lang);
  } catch {
    /* the choice simply does not survive the navigation */
  }
}

export function App({
  route: routeId = "home",
  lang: forcedLang,
}: { route?: RouteId; lang?: Lang } = {}) {
  const route = routeById(routeId);

  // The page is pre-rendered in English at build time, so the first client
  // render must be English too or hydration mismatches. A French reader is
  // switched over in the effect below, one frame later.
  const [lang, setLang] = useState<Lang>(forcedLang ?? "en");
  const [touched, setTouched] = useState(forcedLang !== undefined);
  const copy = allCopy[lang];

  useEffect(() => {
    if (touched) return;
    const stored = storedLang();
    if (stored) {
      setLang(stored);
      return;
    }
    if (navigator.language?.toLowerCase().startsWith("fr")) setLang("fr");
  }, [touched]);

  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);

  const choose = (code: Lang) => {
    setTouched(true);
    setLang(code);
    rememberLang(code);
  };

  return (
    <>
      <a className="skip-link" href="#main">
        {copy.pages.home}
      </a>

      <header className="site-header">
        <div className="wrap header-bar">
          <a className="brand" href={routeHref(route, routeById("home"))}>
            wisq<span>▚</span>
          </a>
          <div className="lang-switch">
            {(["en", "fr"] as const).map((code) => (
              <button
                key={code}
                type="button"
                aria-pressed={lang === code}
                onClick={() => choose(code)}
              >
                {code.toUpperCase()}
              </button>
            ))}
          </div>
        </div>
        <nav className="site-nav" aria-label={copy.footer.docs}>
          <div className="wrap site-nav-inner">
            {ROUTES.filter((candidate) => candidate.listed).map((candidate) => (
              <a
                key={candidate.id}
                href={routeHref(route, candidate)}
                aria-current={candidate.id === route.id ? "page" : undefined}
              >
                {copy.pages[candidate.id]}
              </a>
            ))}
            <a href={REPO}>{copy.nav.source}</a>
          </div>
        </nav>
      </header>

      <main id="main">
        {route.id === "home" ? (
          <Landing copy={copy} route={route} />
        ) : (
          <DocPage doc={PAGES[lang][route.id as DocRouteId]} />
        )}
      </main>

      <Footer copy={copy} route={route} />
      <InstallPrompt copy={copy} />
    </>
  );
}

/// The footer carries what the header cannot.
///
/// A project site's footer is where someone goes when the page did not answer
/// their question: where the source is, how to report something, what the
/// licence is, whether they are being tracked. Grouping those by what the
/// reader wants — use it, understand it, contribute to it — beats one long row
/// of links in which everything is equally hard to find.
function Footer({ copy, route }: { copy: (typeof allCopy)["en"]; route: Route }) {
  const to = (id: Parameters<typeof routeById>[0]) => routeHref(route, routeById(id));
  const home = routeHref(route, routeById("home"));

  const groups: { title: string; links: { label: string; href: string }[] }[] = [
    {
      title: copy.footer.groups.product,
      links: [
        { label: copy.footer.links.install, href: `${home}#install` },
        { label: copy.pages.docs, href: to("docs") },
        { label: copy.pages.releases, href: to("releases") },
        { label: copy.pages.roadmap, href: to("roadmap") },
      ],
    },
    {
      title: copy.footer.groups.documentation,
      links: [
        { label: copy.pages.protocol, href: to("protocol") },
        { label: copy.pages.architecture, href: to("architecture") },
        { label: copy.pages.faq, href: to("faq") },
      ],
    },
    {
      title: copy.footer.groups.project,
      links: [
        { label: copy.footer.source, href: REPO },
        { label: copy.footer.links.issues, href: ISSUES },
        { label: copy.footer.links.contributing, href: CONTRIBUTING },
        { label: copy.footer.links.security, href: SECURITY },
        { label: copy.footer.links.changelog, href: CHANGELOG },
      ],
    },
  ];

  return (
    <footer className="site-footer">
      <div className="wrap footer-top">
        <div className="footer-brand">
          <a className="brand" href={home}>
            wisq<span>▚</span>
          </a>
          <p>{copy.footer.tagline}</p>
          {/* One string rather than three children: React separates adjacent
              text nodes with comment markers, which land in the HTML and make
              the line harder to read for anything that reads HTML. */}
          <p className="footer-version">
            {`${copy.footer.version} ${SITE_VERSION} · ${copy.footer.license}`}
          </p>
        </div>

        <nav className="footer-groups" aria-label={copy.footer.docs}>
          {groups.map((group) => (
            <div key={group.title}>
              <h2>{group.title}</h2>
              <ul>
                {group.links.map((link) => (
                  <li key={link.label}>
                    <a href={link.href}>{link.label}</a>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </nav>
      </div>

      <div className="wrap footer-bottom">
        <p className="footer-note">{copy.footer.note}</p>
        <p className="footer-note">{copy.footer.privacyNote}</p>
        <p className="footer-note">{copy.footer.attribution}</p>
        <div className="footer-legal">
          <a href={`${REPO}/blob/master/LICENSE`}>{copy.footer.license}</a>
          <a href={to("privacy")}>{copy.footer.links.privacy}</a>
          <a href="#main">{copy.footer.backToTop}</a>
        </div>
      </div>
    </footer>
  );
}

function Landing({ copy, route }: { copy: (typeof allCopy)["en"]; route: Route }) {
  return (
    <>
      <section className="hero">
        <div className="wrap">
          <p className="badge">{copy.hero.badge}</p>
          <h1>{copy.hero.tagline}</h1>
          <p className="lede">{copy.hero.lede}</p>
          <div className="cta-row">
            <a className="btn btn-primary" href="#install">
              {copy.hero.ctaInstall}
            </a>
            <a className="btn btn-secondary" href={routeHref(route, routeById("docs"))}>
              {copy.pages.docs}
            </a>
          </div>
        </div>
      </section>

      <section id="modes">
        <div className="wrap">
          <p className="eyebrow">{copy.modes.title}</p>
          <h2>{copy.modes.title}</h2>
          <div className="cards">
            {[copy.modes.remote, copy.modes.local].map((mode) => (
              <article className="card" key={mode.name}>
                <span className="tag">{mode.name}</span>
                <h3>{mode.head}</h3>
                <p>{mode.body}</p>
                <ul>
                  {mode.points.map((point) => (
                    <li key={point}>{point}</li>
                  ))}
                </ul>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section id="compare">
        <div className="wrap">
          <h2>{copy.compare.title}</h2>
          <p className="lede">{copy.compare.lede}</p>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  {copy.compare.columns.map((column, index) => (
                    <th key={index} scope="col">
                      {column}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {copy.compare.rows.map((row) => (
                  <tr key={row[0]}>
                    <td>{row[0]}</td>
                    <td>{row[1]}</td>
                    <td>{row[2]}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <Install copy={copy} />

      <section id="how">
        <div className="wrap">
          <h2>{copy.how.title}</h2>
          <div className="steps">
            {copy.how.steps.map((step) => (
              <div className="step" key={step.title}>
                <div className="step-num" aria-hidden="true" />
                <div>
                  <h3>{step.title}</h3>
                  <p>{step.body}</p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section id="facts">
        <div className="wrap">
          <h2>{copy.facts.title}</h2>
          <div className="facts">
            {copy.facts.items.map((fact) => (
              <div className="fact" key={fact.label}>
                <div className="value">{fact.value}</div>
                <div className="label">{fact.label}</div>
              </div>
            ))}
          </div>
        </div>
      </section>
    </>
  );
}
