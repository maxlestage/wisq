/// The site's public address, resolved in one place.
///
/// `build.tsx` stamps it into every canonical link, the sitemap and the social
/// card; `tests/build.test.ts` checks what was stamped. Both read it from here
/// rather than each spelling out the same fallback.
///
/// It lives in its own module, imported by the build and the tests and by
/// nothing the browser receives: reading `process.env` from a file that ends up
/// in the client bundle is a way to ship code that throws in a browser.
///
/// **Why it is not a constant.** The sitemap test used to assert `/wisq/`, the
/// path the site had on GitHub Pages — so it was a test of where the site lived
/// rather than of what the build produced, and it went red the day the site
/// moved to Heroku. Two lines below it, another test guards against exactly
/// that: "a hardcoded /wisq/ in an asset reference". One of the two had to give.
///
/// The fallback is the preview's own address, not a guess at the deployed one.
/// The deployment sets `SITE_URL`, and `scripts/heroku-build.sh` refuses to
/// build without it, so this value is only ever what it says it is: the address
/// of a build nobody publishes.
export function siteURL(): string {
  return (process.env.SITE_URL ?? "http://127.0.0.1:4321/").replace(/\/?$/, "/");
}
