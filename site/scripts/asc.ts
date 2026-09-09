/// Ce que la clé App Store Connect permet de savoir avant de construire.
///
/// Trois secrets suffisent — l'émetteur, l'identifiant de la clé, la clé
/// elle-même — et ce fichier en tire le reste plutôt que de le demander :
///
///  * **l'identifiant d'équipe**, que `xcodebuild` exige pour signer et que la
///    clé ne lui apprend pas. L'API le donne sous un autre nom : le `seedId`
///    d'un identifiant d'application *est* l'identifiant d'équipe. Le premier
///    envoi a échoué exactement là — « Signing for "Wisq" requires a
///    development team » — après un pari sur le contraire ;
///  * **l'identifiant d'application**, créé s'il manque ;
///  * **la fiche d'application**, dont l'absence est le seul obstacle que rien
///    ici ne peut lever : l'API App Store Connect ne sait pas créer une fiche,
///    seulement la lire. Le dire tôt vaut mieux qu'un envoi qui échoue après
///    dix minutes de construction.

import { createSign } from "node:crypto";
import { appendFileSync } from "node:fs";

const API = "https://api.appstoreconnect.apple.com/v1";

function base64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  return Buffer.from(bytes).toString("base64")
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/// Le jeton que l'API attend : ES256, vingt minutes au plus, et l'audience
/// littérale qu'Apple impose.
///
/// La signature est demandée au format `ieee-p1363` — deux entiers de trente-
/// deux octets bout à bout. C'est ce que JOSE veut ; le format par défaut
/// d'OpenSSL est du DER, que l'API refuserait avec un 401 qui ne dit pas
/// pourquoi.
export function appStoreConnectToken(
  options: { issuerId: string; keyId: string; privateKey: string; now?: number },
): string {
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: options.keyId, typ: "JWT" }));
  const payload = base64url(JSON.stringify({
    iss: options.issuerId,
    iat: now,
    exp: now + 20 * 60,
    aud: "appstoreconnect-v1",
  }));
  const signature = createSign("SHA256")
    .update(`${header}.${payload}`)
    .sign({ key: options.privateKey, dsaEncoding: "ieee-p1363" });
  return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

async function call(token: string, path: string, init: RequestInit = {}): Promise<any> {
  const response = await fetch(`${API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const text = await response.text();
  if (!response.ok) {
    // Le corps d'erreur d'Apple est lisible et dit ce qui manque ; le taire
    // laisserait un code HTTP nu.
    throw new Error(`${init.method ?? "GET"} ${path} → ${response.status} ${text}`);
  }
  return text ? JSON.parse(text) : {};
}

/// L'identifiant d'équipe, lu sur un identifiant d'application — celui du
/// projet s'il existe, n'importe lequel sinon, puisque le `seedId` est le même
/// pour toute l'équipe.
export async function resolveTeamId(token: string, bundleId: string): Promise<string> {
  const mine = await call(token, `/bundleIds?filter[identifier]=${encodeURIComponent(bundleId)}&limit=1`);
  const seed = mine.data?.[0]?.attributes?.seedId;
  if (seed) return seed;

  const any = await call(token, "/bundleIds?limit=1");
  const fallback = any.data?.[0]?.attributes?.seedId;
  if (fallback) return fallback;

  throw new Error(
    "aucun identifiant d'application sur ce compte : impossible d'en déduire l'équipe. "
      + "Créez-en un, ou renseignez le secret ASC_TEAM_ID.",
  );
}

/// Crée l'identifiant d'application s'il n'existe pas. `xcodebuild
/// -allowProvisioningUpdates` sait le faire aussi, mais il lui faut déjà
/// l'équipe, et l'équipe se lit sur un identifiant : le faire ici casse le
/// cercle.
export async function ensureBundleId(token: string, bundleId: string, name: string): Promise<void> {
  const existing = await call(token, `/bundleIds?filter[identifier]=${encodeURIComponent(bundleId)}&limit=1`);
  if (existing.data?.length) return;
  await call(token, "/bundleIds", {
    method: "POST",
    body: JSON.stringify({
      data: { type: "bundleIds", attributes: { identifier: bundleId, name, platform: "IOS" } },
    }),
  });
}

/// La fiche d'application existe-t-elle ? L'API ne sait pas la créer — c'est
/// le seul geste de cette chaîne qui reste humain.
export async function appExists(token: string, bundleId: string): Promise<boolean> {
  const apps = await call(token, `/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=1`);
  return Boolean(apps.data?.length);
}

/// Ce que le compte porte déjà en certificats — le nombre, par type.
///
/// **D'où vient cette question.** Vingt-sept envois ont marché en laissant
/// `xcodebuild -allowProvisioningUpdates` fabriquer le certificat de
/// signature ; chaque exécution partait d'un trousseau vide et en demandait
/// donc un neuf. Le vingt-huitième a buté sur « Your account has reached the
/// maximum number of certificates », **quinze minutes après le début de la
/// construction**, sur un message qui ne dit ni combien il y en a ni de quel
/// type. Le compte se lit ici, à la treizième seconde, pour la même clé.
///
/// **Les noms ne sont pas imprimés, et c'est délibéré** : un nom de
/// certificat porte l'identifiant d'équipe, et ce journal d'exécution est
/// public. Le nombre suffit à décider ; le nom ne sert qu'à choisir lequel
/// révoquer, et ça se fait sur developer.apple.com.
export async function certificateInventory(token: string): Promise<Record<string, number>> {
  const page = await call(token, "/certificates?limit=200");
  const byType: Record<string, number> = {};
  for (const item of page.data ?? []) {
    byType[item.attributes?.certificateType ?? "INCONNU"] ??= 0;
    byType[item.attributes?.certificateType ?? "INCONNU"]! += 1;
  }
  return byType;
}

/// La phrase que l'inventaire vaut, séparée de l'appel réseau pour être
/// éprouvable sans compte Apple.
export function describeCertificates(byType: Record<string, number>): string {
  const total = Object.values(byType).reduce((sum, n) => sum + n, 0);
  if (total === 0) return "certificats sur le compte : aucun";
  const detail = Object.keys(byType).sort()
    .map((type) => `${type} × ${byType[type]}`)
    .join(", ");
  return `certificats sur le compte : ${total} (${detail})`;
}

/// Ajoute des sorties d'étape au fichier que GitHub tend au job.
///
/// **Ajoute**, et c'est tout l'intérêt de la fonction : le fichier est partagé
/// par toutes les étapes du job, et l'écrire au lieu de l'allonger effacerait
/// les sorties de celles d'avant. Une valeur multi-ligne casserait le format
/// `clé=valeur` ; il n'en passe pas ici, et le refuser vaut mieux que
/// l'écrire à moitié.
export function writeStepOutputs(path: string, values: Record<string, string>): void {
  for (const [key, value] of Object.entries(values)) {
    if (value.includes("\n")) throw new Error(`sortie multi-ligne refusée : ${key}`);
    appendFileSync(path, `${key}=${value}\n`);
  }
}

if (import.meta.main) {
  const issuerId = process.env.ASC_ISSUER_ID ?? "";
  const keyId = process.env.ASC_KEY_ID ?? "";
  const privateKey = process.env.ASC_KEY_P8 ?? "";
  const bundleId = process.env.WISQ_BUNDLE_ID ?? "app.wisq.ios";
  if (!issuerId || !keyId || !privateKey) {
    console.error("ASC_ISSUER_ID, ASC_KEY_ID et ASC_KEY_P8 sont requis");
    process.exit(2);
  }

  const token = appStoreConnectToken({ issuerId, keyId, privateKey });
  await ensureBundleId(token, bundleId, "wisq");
  const teamId = await resolveTeamId(token, bundleId);
  const hasApp = await appExists(token, bundleId);

  // **Un diagnostic, jamais un obstacle.** Si la clé n'a pas le droit de lire
  // les certificats, l'envoi doit continuer : c'est une ligne d'information,
  // pas une condition. La taire silencieusement serait pire — la raison du
  // silence est dite.
  let certificates: string;
  try {
    certificates = describeCertificates(await certificateInventory(token));
  } catch (error) {
    certificates = `certificats sur le compte : non lus (${(error as Error).message.slice(0, 120)})`;
  }

  // Sur GitHub, ces lignes deviennent des sorties d'étape ; ailleurs elles se
  // lisent telles quelles.
  if (process.env.GITHUB_OUTPUT) {
    writeStepOutputs(process.env.GITHUB_OUTPUT, {
      "team-id": teamId,
      "app-exists": String(hasApp),
      // **Portée en sortie pour être relue à la fin du job.** Imprimée ici,
      // la phrase est enterrée sous les dizaines de milliers de lignes de
      // `xcodebuild`, et l'API des journaux ne sert que la fin d'un job : le
      // seul chiffre qui décide de la suite serait illisible là où on le lit.
      certificates,
    });
  }
  console.log(`équipe : ${teamId}`);
  console.log(`fiche d'application pour ${bundleId} : ${hasApp ? "présente" : "ABSENTE"}`);
  console.log(certificates);
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${certificates}\n`);
  }
  if (!hasApp) {
    console.error(
      `\nAucune fiche pour ${bundleId} dans App Store Connect. L'API ne sait pas la créer.`
        + "\nÀ faire une fois : App Store Connect → Mes apps → + → Nouvelle app → iOS,"
        + `\nen choisissant exactement l'identifiant ${bundleId}.`,
    );
    process.exit(3);
  }
}
