/// The service worker, run rather than read.
///
/// The site claims it works offline and installs to a Home Screen. Six tests
/// already covered `sw.js` — and every one of them reads it as **text** and
/// asserts that a substring appears: `toContain("new Set(")`,
/// `toContain("response.ok")`, `toContain("offlineFor")`. That is a tripwire on
/// the source, not a check of what the worker does.
///
/// **Measured.** Nine behaviours were broken one at a time in `build.tsx`, each
/// sabotage chosen to leave every grepped string in place — `addAll(wanted)`
/// became `addAll([])`, `if (response.ok)` became `if (response.ok || true)`,
/// `offlineFor` kept its name and always answered English. The built `sw.js`
/// really carried each break; it was read back out of `dist` to make sure.
/// **All nine passed the whole site suite.** A worker that precaches nothing —
/// so the site does not work offline at all — is green under 99 tests.
///
/// So this file executes the worker. A fake `caches`, a fake `fetch` that can
/// be told the network is down, and the real `sw.js` evaluated inside them;
/// then install, activate and fetch events are fired and the assertions are
/// about what ends up in the cache and what comes back to the page.
///
/// Each of the nine was re-run against this file alone, and each one fails it.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const dist = join(import.meta.dir, "..", "dist");
const source = readFileSync(join(dist, "sw.js"), "utf8");
const ORIGIN = "https://wisq.test";

/// A `Cache` with the one behaviour that matters and is easy to forget:
/// `addAll` rejects the whole list when two entries resolve to the same URL.
/// That is the defect the precache deduplication exists for, so a fake that
/// tolerated duplicates could not hold it.
class FakeCache {
  entries = new Map<string, Response>();

  constructor(private readonly network: FakeNetwork) {}

  async addAll(urls: string[]): Promise<void> {
    const resolved = urls.map((url) => new URL(url, `${ORIGIN}/sw.js`).href);
    if (new Set(resolved).size !== resolved.length) {
      throw new TypeError("addAll: deux entrées résolvent vers la même URL");
    }
    for (const href of resolved) {
      const response = await this.network.fetch(new Request(href));
      if (!response.ok) throw new TypeError(`addAll: ${href} a répondu ${response.status}`);
      this.entries.set(href, response);
    }
  }

  async put(request: Request | string, response: Response): Promise<void> {
    this.entries.set(key(request), response);
  }

  async match(request: Request | string): Promise<Response | undefined> {
    return this.entries.get(key(request));
  }
}

function key(request: Request | string): string {
  const url = typeof request === "string" ? request : request.url;
  return new URL(url, `${ORIGIN}/sw.js`).href;
}

class FakeCaches {
  open_ = new Map<string, FakeCache>();

  constructor(private readonly network: FakeNetwork) {}

  async open(name: string): Promise<FakeCache> {
    const existing = this.open_.get(name);
    if (existing) return existing;
    const cache = new FakeCache(this.network);
    this.open_.set(name, cache);
    return cache;
  }

  async keys(): Promise<string[]> {
    return [...this.open_.keys()];
  }

  async delete(name: string): Promise<boolean> {
    return this.open_.delete(name);
  }

  async match(request: Request | string): Promise<Response | undefined> {
    for (const cache of this.open_.values()) {
      const hit = await cache.match(request);
      if (hit) return hit;
    }
    return undefined;
  }
}

/// The network, and whether there is one.
class FakeNetwork {
  down = false;
  status = 200;
  body = "du réseau";
  asked: string[] = [];

  async fetch(request: Request | string): Promise<Response> {
    this.asked.push(key(request));
    if (this.down) throw new TypeError("réseau injoignable");
    return new Response(this.body, { status: this.status });
  }
}

/// Loads `dist/sw.js` into a scope of our own and returns the handlers it
/// registered, plus the fakes it registered them against.
function load() {
  const network = new FakeNetwork();
  const caches = new FakeCaches(network);
  const handlers: Record<string, (event: never) => void> = {};
  const self = {
    addEventListener(type: string, handler: (event: never) => void) {
      handlers[type] = handler;
    },
    location: { origin: ORIGIN, href: `${ORIGIN}/sw.js` },
    skipWaiting: async () => {},
    clients: { claim: async () => {} },
  };

  // eslint-disable-next-line no-new-func
  new Function("self", "caches", "fetch", "Response", "Request", "URL", source)(
    self,
    caches,
    (request: Request | string) => network.fetch(request),
    Response,
    Request,
    URL,
  );
  return { handlers, caches, network, self };
}

/// Fires `install` (or `activate`) and waits for what it registered.
async function lifecycle(handlers: Record<string, (event: never) => void>, type: string) {
  const waited: Promise<unknown>[] = [];
  const event = { waitUntil: (promise: Promise<unknown>) => waited.push(promise) };
  handlers[type]?.(event as never);
  const settled = await Promise.allSettled(waited);
  return settled;
}

/// Fires `fetch` and returns what the worker answered, or null if it declined
/// to answer at all — which is a real outcome and the point of two of the
/// tests below.
async function request(
  handlers: Record<string, (event: never) => void>,
  input: Request,
): Promise<Response | null> {
  let answered: Promise<Response> | null = null;
  const event = {
    request: input,
    respondWith: (promise: Promise<Response>) => {
      answered = promise;
    },
  };
  handlers.fetch?.(event as never);
  return answered === null ? null : await answered;
}

const VERSION = source.match(/const VERSION = "(wisq-[0-9a-f]+)"/)![1]!;
const PRECACHE = JSON.parse(source.match(/const PRECACHE = (\[[\s\S]*?\]);/)![1]!) as string[];

describe("what the service worker actually does", () => {
  /// The whole offline claim in one assertion: after installing, the pages are
  /// in a cache. `addAll([])` — a worker that precaches nothing — passes every
  /// text-matching test and fails this one.
  test("installing puts every precached file in the cache", async () => {
    const { handlers, caches } = load();
    await lifecycle(handlers, "install");

    const cache = await caches.open(VERSION);
    expect(cache.entries.size).toBeGreaterThanOrEqual(PRECACHE.length);
    for (const entry of PRECACHE) {
      expect(cache.entries.has(key(entry)), `absent du cache : ${entry}`).toBe(true);
    }
  });

  /// Both offline documents are precached too, whether or not they are already
  /// in the list: they are the last thing a reader gets, so they cannot be the
  /// one file the network is needed for.
  test.each([["./offline/"], ["./fr/offline/"]])(
    "the offline page %s is installed",
    async (page) => {
      const { handlers, caches } = load();
      await lifecycle(handlers, "install");
      const cache = await caches.open(VERSION);
      expect(cache.entries.has(key(page))).toBe(true);
    },
  );

  /// `Cache.addAll` rejects the entire list when two entries resolve to the
  /// same URL, and a rejected install leaves no worker at all — the site keeps
  /// working and quietly stops being installable. The offline pages are also
  /// precached pages, so the list it is given always has duplicates in it
  /// unless something removes them.
  test("installing survives the offline pages already being precached", async () => {
    const { handlers } = load();
    const settled = await lifecycle(handlers, "install");
    expect(settled.every((result) => result.status === "fulfilled"), "l'installation a été rejetée").toBe(
      true,
    );
  });

  /// A cache from a previous deploy must not outlive it, or a reader keeps a
  /// version of the site nothing can replace.
  test("activating deletes every cache but this version's", async () => {
    const { handlers, caches } = load();
    await caches.open("wisq-une-vieille-version");
    await caches.open(VERSION);
    await lifecycle(handlers, "activate");
    expect(await caches.keys()).toEqual([VERSION]);
  });

  /// Documentation that is quietly a week stale is worse than a spinner, so a
  /// page comes from the network when there is one — even when a copy is
  /// already cached. The cached copy is deliberately different, or the two
  /// strategies would be indistinguishable.
  test("a page comes from the network when there is one", async () => {
    const { handlers, caches, network } = load();
    const cache = await caches.open(VERSION);
    await cache.put(`${ORIGIN}/docs/`, new Response("du cache"));
    network.body = "du réseau";

    const response = await request(handlers, new Request(`${ORIGIN}/docs/`, { mode: "navigate" } as never));
    expect(await response!.text()).toBe("du réseau");
  });

  /// And the copy it keeps is the one it just served, so the next visit
  /// without a network gets that page rather than the fallback.
  test("a page that loaded is kept for the next time", async () => {
    const { handlers, caches, network } = load();
    network.body = "la page";
    await request(handlers, new Request(`${ORIGIN}/docs/`, { mode: "navigate" } as never));
    await Promise.resolve();
    await Promise.resolve();

    const cached = await caches.match(`${ORIGIN}/docs/`);
    expect(await cached!.text()).toBe("la page");
  });

  /// A 404 from a mistyped link, or a 500 from a half-finished deploy, kept and
  /// served back afterwards — including once the site is fine again.
  test.each([[404], [500]])("a page that answered %i is not kept", async (status) => {
    const { handlers, caches, network } = load();
    network.status = status;
    await request(handlers, new Request(`${ORIGIN}/faute-de-frappe/`, { mode: "navigate" } as never));
    await Promise.resolve();
    await Promise.resolve();

    expect(await caches.match(`${ORIGIN}/faute-de-frappe/`)).toBeUndefined();
  });

  /// With no network and nothing cached, the reader gets the offline page in
  /// the language of the address that failed — not English for everyone.
  test.each([
    ["/quelque-chose/", "./offline/"],
    ["/fr/quelque-chose/", "./fr/offline/"],
  ])("with no network, %s falls back to %s", async (path, page) => {
    const { handlers, caches, network } = load();
    await lifecycle(handlers, "install");
    const cache = await caches.open(VERSION);
    // Distinctive bodies, because the two offline pages are otherwise the same
    // shape and a fallback that always answered English would look right.
    await cache.put(key("./offline/"), new Response("hors ligne en anglais"));
    await cache.put(key("./fr/offline/"), new Response("hors ligne en français"));
    network.down = true;

    const response = await request(handlers, new Request(`${ORIGIN}${path}`, { mode: "navigate" } as never));
    const expected = page === "./offline/" ? "hors ligne en anglais" : "hors ligne en français";
    expect(await response!.text()).toBe(expected);
  });

  /// A page already visited comes back from the cache rather than the fallback:
  /// the fallback is for what was never seen.
  test("with no network, a page already visited comes back itself", async () => {
    const { handlers, caches, network } = load();
    await lifecycle(handlers, "install");
    const cache = await caches.open(VERSION);
    await cache.put(`${ORIGIN}/docs/`, new Response("la vraie page"));
    network.down = true;

    const response = await request(handlers, new Request(`${ORIGIN}/docs/`, { mode: "navigate" } as never));
    expect(await response!.text()).toBe("la vraie page");
  });

  /// A content-hashed name can never be stale, so asking the network about one
  /// is a round trip that can only answer "still the same".
  test("a hashed asset comes from the cache without touching the network", async () => {
    const { handlers, caches, network } = load();
    const asset = PRECACHE.find((entry) => /chunk-[a-z0-9]+\.js$/.test(entry))!;
    const cache = await caches.open(VERSION);
    await cache.put(key(asset), new Response("du cache"));
    network.asked = [];

    const response = await request(handlers, new Request(key(asset)));
    expect(await response!.text()).toBe("du cache");
    expect(network.asked, "le réseau a été interrogé pour un nom haché").toEqual([]);
  });

  /// Two requests the worker must not touch at all. Answering them means
  /// standing between the page and something this cache knows nothing about —
  /// a form post, or a third-party address.
  test("a cross-origin request is left alone", async () => {
    const { handlers } = load();
    const response = await request(handlers, new Request("https://ailleurs.invalid/x"));
    expect(response, "le worker a répondu pour une autre origine").toBeNull();
  });

  test("a non-GET request is left alone", async () => {
    const { handlers } = load();
    const response = await request(handlers, new Request(`${ORIGIN}/x`, { method: "POST" }));
    expect(response, "le worker a répondu pour un POST").toBeNull();
  });
});
