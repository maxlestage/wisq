/// Le jeton que l'API App Store Connect accepte, vérifié sans la clé de
/// personne : une paire EC P-256 est fabriquée ici, le jeton signé avec, et
/// la signature relue avec la partie publique.
///
/// Ce qui se joue là est un 401 sans explication. L'API veut une signature
/// JOSE — deux entiers de trente-deux octets bout à bout — et le format par
/// défaut d'OpenSSL est du DER, plus long et de taille variable. Les deux
/// sont des signatures valides du même message ; une seule est acceptée.

import { describe, expect, test } from "bun:test";
import { createVerify, generateKeyPairSync } from "node:crypto";

import { appendFileSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { appStoreConnectToken, writeStepOutputs } from "../scripts/asc";

const { privateKey, publicKey } = generateKeyPairSync("ec", {
  namedCurve: "P-256",
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
});

function decode(part: string): any {
  return JSON.parse(Buffer.from(part.replaceAll("-", "+").replaceAll("_", "/"), "base64").toString());
}

describe("le jeton App Store Connect", () => {
  const now = 1_772_000_000;
  const token = appStoreConnectToken({
    issuerId: "11112222-3333-4444-5555-666677778888",
    keyId: "ABCD123456",
    privateKey,
    now,
  });
  const [header, payload, signature] = token.split(".");

  test("l'en-tête nomme l'algorithme et la clé", () => {
    expect(decode(header!)).toEqual({ alg: "ES256", kid: "ABCD123456", typ: "JWT" });
  });

  /// Apple refuse une durée de vie au-delà de vingt minutes, et l'audience
  /// est littérale : une faute ici est un 401 muet.
  test("la charge porte l'émetteur, l'audience et une vie de vingt minutes", () => {
    expect(decode(payload!)).toEqual({
      iss: "11112222-3333-4444-5555-666677778888",
      iat: now,
      exp: now + 1200,
      aud: "appstoreconnect-v1",
    });
  });

  test("rien n'est encodé avec les caractères que base64url interdit", () => {
    expect(token).not.toContain("+");
    expect(token).not.toContain("/");
    expect(token).not.toContain("=");
  });

  /// Le cœur : la signature fait exactement soixante-quatre octets — deux
  /// fois trente-deux — et non le DER de longueur variable qu'OpenSSL rend
  /// par défaut.
  test("la signature est au format JOSE, pas en DER", () => {
    const bytes = Buffer.from(signature!.replaceAll("-", "+").replaceAll("_", "/"), "base64");
    expect(bytes.length).toBe(64);
    expect(bytes[0]).not.toBe(0x30); // une séquence DER commence par 0x30
  });

  test("et elle se vérifie avec la clé publique", () => {
    const bytes = Buffer.from(signature!.replaceAll("-", "+").replaceAll("_", "/"), "base64");
    const verified = createVerify("SHA256")
      .update(`${header}.${payload}`)
      .verify({ key: publicKey, dsaEncoding: "ieee-p1363" }, bytes);
    expect(verified).toBe(true);
  });

  /// Le témoin : la même signature contre un message d'à côté doit échouer,
  /// sans quoi le test précédent ne prouverait rien.
  test("un message modifié ne se vérifie pas", () => {
    const bytes = Buffer.from(signature!.replaceAll("-", "+").replaceAll("_", "/"), "base64");
    const verified = createVerify("SHA256")
      .update(`${header}.${payload}x`)
      .verify({ key: publicKey, dsaEncoding: "ieee-p1363" }, bytes);
    expect(verified).toBe(false);
  });

  test("deux clés différentes donnent deux signatures différentes", () => {
    const other = generateKeyPairSync("ec", {
      namedCurve: "P-256",
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
      publicKeyEncoding: { type: "spki", format: "pem" },
    });
    const second = appStoreConnectToken({
      issuerId: "11112222-3333-4444-5555-666677778888",
      keyId: "ABCD123456",
      privateKey: other.privateKey,
      now,
    });
    expect(second.split(".")[2]).not.toBe(signature);
    expect(second.split(".")[0]).toBe(header);
  });
});

describe("les sorties d'étape", () => {
  /// Le fichier appartient au job entier. L'écrire plutôt que l'allonger
  /// efface ce que les étapes précédentes y avaient mis — c'est la faute que
  /// la première version de ce fichier contenait.
  test("s'ajoutent à ce que les étapes précédentes ont écrit", () => {
    const file = join(mkdtempSync(join(tmpdir(), "wisq-outputs-")), "output");
    appendFileSync(file, "venu-d-avant=oui\n");

    writeStepOutputs(file, { "team-id": "ABCDE12345", "app-exists": "true" });

    expect(readFileSync(file, "utf8")).toBe(
      "venu-d-avant=oui\nteam-id=ABCDE12345\napp-exists=true\n",
    );
  });

  /// Une valeur à rallonge romprait le format `clé=valeur` et ferait lire la
  /// suite comme d'autres sorties. Refuser est la seule réponse honnête.
  test("refusent une valeur multi-ligne", () => {
    const file = join(mkdtempSync(join(tmpdir(), "wisq-outputs-")), "output");
    expect(() => writeStepOutputs(file, { equipe: "une\ndeux" })).toThrow("multi-ligne");
  });
});
