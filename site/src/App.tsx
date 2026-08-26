import {
  AUTHOR,
  AUTHOR_URL,
  copy as allCopy,
  SITE_VERSION,
  type Lang,
} from "./content";
import { DocPage } from "./components/Doc";
import type { Doc } from "./doc";
import { InstallPrompt } from "./components/InstallPrompt";
import { Logo } from "./components/Logo";
import { ThemeSwitch } from "./components/ThemeSwitch";
import { LANGS, ROUTES, routeById, routeHref, type Page, type RouteId } from "./routes";

/// The language is the address, not a setting.
///
/// Every page exists twice — `docs/` and `fr/docs/` — each pre-rendered in its
/// own language, so the first paint is already right, a shared link opens in
/// the language it was written in, and a search engine can index both.
///
/// Two behaviours used to live here, as an effect and an `onClick`: remember
/// that a reader has chosen a language, and send a French-speaking reader from
/// the English home page to the French one when they never have. Both now live
/// in `main.ts`, attached to this markup rather than compiled into it — see
/// `LANG_KEY` there. The links themselves never needed React: each one is a
/// real address, and following it has always worked with no JavaScript at all.

/// The document a written page shows, passed in rather than looked up.
///
/// It used to be `PAGES[lang][route]`, and that one import put **every** page,
/// in **both** languages, into the bundle every visitor downloads: 61 KB raw
/// and 21.6 KB over the wire, measured, for prose almost none of them will
/// read. A reader landing on the home page was paying for the privacy policy
/// in French.
///
/// The document now travels in the HTML that already contains it, as JSON
/// beside the markup — so a page carries its own text and nothing else, and
/// hydration still has it synchronously, with no second request and no
/// suspense boundary in the middle of a document.
export function App({
  route: routeId = "home",
  lang = "en",
  doc,
}: { route?: RouteId; lang?: Lang; doc?: Doc } = {}) {
  const page: Page = { route: routeById(routeId), lang };
  const route = page.route;
  const copy = allCopy[lang];

  return (
    <>
      <a className="skip-link" href="#main">
        {copy.pages.home}
      </a>

      <header className="site-header">
        <div className="wrap header-bar">
          <a className="brand" href={routeHref(page, routeById("home"))}>
            wisq<span>▚</span>
          </a>
          <ThemeSwitch copy={copy} />
          {/* Links, not buttons: each one is a real address, so it can be
              opened in a new tab, bookmarked, and followed with no JavaScript
              at all. */}
          <nav className="lang-switch" aria-label={copy.nav.language}>
            {LANGS.map((code) => (
              <a
                key={code}
                href={routeHref(page, route, code)}
                hrefLang={code}
                aria-current={code === lang ? "true" : undefined}
              >
                {code.toUpperCase()}
              </a>
            ))}
          </nav>
        </div>
        {/* Every page of the site, one scrollable strip. Links rather than a
            menu: each is a real address, so it can be opened in a new tab,
            bookmarked, and followed with no JavaScript at all. */}
        <nav className="site-nav" aria-label={copy.footer.docs}>
          <div className="wrap site-nav-inner">
            {ROUTES.filter((candidate) => candidate.listed).map((candidate) => (
              <a
                key={candidate.id}
                href={routeHref(page, candidate)}
                aria-current={candidate.id === route.id ? "page" : undefined}
              >
                {copy.pages[candidate.id]}
              </a>
            ))}
          </div>
        </nav>
      </header>

      <main id="main">
        {route.id === "home" ? (
          <Landing copy={copy} page={page} />
        ) : (
          <DocPage doc={doc!} />
        )}
      </main>

      <Footer copy={copy} page={page} />
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
function Footer({ copy, page }: { copy: (typeof allCopy)["en"]; page: Page }) {
  const to = (id: Parameters<typeof routeById>[0]) => routeHref(page, routeById(id));
  const home = to("home");

  const groups: { title: string; links: { label: string; href: string }[] }[] = [
    {
      title: copy.footer.groups.product,
      links: [
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
        { label: copy.pages.home, href: to("home") },
        { label: copy.pages.privacy, href: to("privacy") },
      ],
    },
  ];

  return (
    <footer className="site-footer">
      <div className="wrap footer-top">
        <div className="footer-brand">
          {/* The mark and the name, the same pair as the hero at a size the
              footer can hold. Inside the link, so the whole lockup is the way
              home rather than only the four letters. */}
          <a className="brand footer-brand-link" href={home}>
            <Logo className="footer-logo" />
            <span className="footer-wordmark">
              wisq<span>▚</span>
            </span>
          </a>
          <p>{copy.footer.tagline}</p>
          {/* One string rather than three children: React separates adjacent
              text nodes with comment markers, which land in the HTML and make
              the line harder to read for anything that reads HTML. */}
          <p className="footer-version">
            {`${copy.footer.version} ${SITE_VERSION} · ${copy.footer.rights}`}
          </p>
          {/* Authorship sits with the wordmark, where a reader looks for who
              made a thing. The credit to other people's work stays in the
              bottom bar and is not touched by this: a line saying what is mine
              must never read as a claim over what is not. */}
          <p className="footer-author">
            {`${copy.footer.author} `}
            <a href={AUTHOR_URL} rel="author">
              {AUTHOR}
            </a>
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
          <span>{copy.footer.copyright}</span>
          <a href={to("privacy")}>{copy.pages.privacy}</a>
          <a href="#main">{copy.footer.backToTop}</a>
        </div>
      </div>
    </footer>
  );
}

function Landing({ copy, page }: { copy: (typeof allCopy)["en"]; page: Page }) {
  return (
    <>
      <section className="hero">
        <div className="wrap hero-grid">
          <div className="hero-text">
            <p className="badge">{copy.hero.badge}</p>
            <h1>{copy.hero.tagline}</h1>
            <p className="lede">{copy.hero.lede}</p>
          </div>
          {/* The mark and the name as one block. The mark alone is a picture
              of `▚`, which says what the product does but not what it is
              called; the two together are the thing a reader recognises later.
              The wordmark is real text rather than part of the drawing, so it
              is selectable, searchable, and read aloud. */}
          <div className="hero-lockup">
            <Logo className="hero-logo" />
            <p className="hero-wordmark">wisq</p>
          </div>
        </div>
      </section>

      <section id="modes">
        <div className="wrap">
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
