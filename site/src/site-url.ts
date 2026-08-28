/// The site's public address, resolved in one place.
///
/// `build.tsx` stamps it into every canonical link, the sitemap, `robots.txt`
/// and the social card; `tests/build.test.ts` checks what was stamped. Both
/// read it from here rather than each spelling out the same rule.
///
/// It lives in its own module, imported by the build and the tests and by
/// nothing the browser receives: reading `process.env` from a file that ends up
/// in the client bundle is a way to ship code that throws in a browser.
///
/// **Why the deployment does not have to know its own name.** It used to.
/// `scripts/heroku-build.sh` refused to build without `SITE_URL`, on the
/// reasoning that a wrong canonical link is invisible in a browser and wrong in
/// every sitemap entry — true, and the wrong conclusion. It made a deployment
/// from a phone impossible without a configuration step, and three builds in a
/// row failed on exactly that.
///
/// The address is now resolved where it is actually known: the server sees the
/// host every request arrives on. When `SITE_URL` is unset the build stamps
/// `REQUEST_ORIGIN` — a sentinel that is not a reachable address — and
/// `scripts/serve.ts` replaces it with the origin of the request being
/// answered. The site is then correct on whatever host serves it, with nothing
/// to configure, and a sentinel that escaped the rewrite would be a visibly
/// broken link rather than a plausible wrong one.
///
/// `SITE_URL` still works, and is what to set to pin the address — behind a
/// custom domain, say, where the origin a dyno sees is not the one readers use.
export const REQUEST_ORIGIN = "https://origine-de-la-requete.invalid/";

export function siteURL(): string {
  const configured = process.env.SITE_URL;
  if (!configured) return REQUEST_ORIGIN;
  return configured.replace(/\/?$/, "/");
}
