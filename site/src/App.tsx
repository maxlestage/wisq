import { useEffect, useState } from "react";
import { copy as allCopy, DOCS, REPO, type Lang } from "./content";
import { Install } from "./components/Install";

export function App({ lang: forcedLang }: { lang?: Lang } = {}) {
  // The page is pre-rendered in English at build time, so the first client
  // render must be English too or hydration mismatches. A French browser gets
  // switched over in the effect below, one frame later.
  const [lang, setLang] = useState<Lang>(forcedLang ?? "en");
  const [touched, setTouched] = useState(forcedLang !== undefined);
  const copy = allCopy[lang];

  useEffect(() => {
    if (touched) return;
    if (navigator.language?.toLowerCase().startsWith("fr")) setLang("fr");
  }, [touched]);

  useEffect(() => {
    document.documentElement.lang = lang;
  }, [lang]);

  const choose = (code: Lang) => {
    setTouched(true);
    setLang(code);
  };

  return (
    <>
      <header className="site-header">
        <div className="wrap">
          <a className="brand" href="#top">
            wisq<span>▚</span>
          </a>
          <nav className="nav-links">
            <a href="#install">{copy.nav.install}</a>
            <a href="#how">{copy.nav.how}</a>
            <a href={REPO}>{copy.nav.source}</a>
          </nav>
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
      </header>

      <main id="top">
        <section className="hero">
          <div className="wrap">
            <p className="badge">{copy.hero.badge}</p>
            <h1>{copy.hero.tagline}</h1>
            <p className="lede">{copy.hero.lede}</p>
            <div className="cta-row">
              <a className="btn btn-primary" href="#install">
                {copy.hero.ctaInstall}
              </a>
              <a className="btn btn-secondary" href={REPO}>
                {copy.hero.ctaSource}
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
      </main>

      <footer className="site-footer">
        <div className="wrap">
          <div className="footer-links">
            <a href={REPO}>{copy.footer.source}</a>
            <a href={DOCS}>{copy.footer.docs}</a>
            <a href={`${REPO}/blob/master/LICENSE`}>{copy.footer.license}</a>
          </div>
          <p className="footer-note">{copy.footer.note}</p>
        </div>
      </footer>
    </>
  );
}
