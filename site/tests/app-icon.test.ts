/// L'icône de l'application iOS : celle qu'Apple refuse quand elle manque, et
/// refuse encore quand elle porte un canal alpha.
///
/// Aucun de ces deux refus n'apparaît à la compilation. Une application sans
/// icône se construit, se lance, s'installe depuis Xcode — et l'envoi est
/// rejeté (ITMS-90713 : la clé `CFBundleIconName` manque du bundle). Une
/// icône avec alpha passe la compilation de la même façon et se fait rejeter
/// par ITMS-90717. Ce sont donc des rouges qui n'arrivent qu'au moment de
/// livrer, et ce fichier les ramène à l'endroit où on peut les voir.

import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { inflateSync } from "node:zlib";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { appIcon, iOSAppIcon } from "../scripts/icons";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/// Le PNG, relu comme un lecteur de PNG le ferait : signature, en-tête, et le
/// CRC de chaque tronçon. Un CRC faux est la façon la plus discrète d'écrire
/// une image que rien n'affiche.
function readPNG(bytes: Uint8Array) {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  expect([...bytes.subarray(0, 8)]).toEqual(signature);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  const crc32 = (slice: Uint8Array) => {
    let c = 0xffffffff;
    for (const byte of slice) c = table[(c ^ byte) & 0xff]! ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };

  const chunks: string[] = [];
  let offset = 8;
  while (offset < bytes.length) {
    const length = view.getUint32(offset);
    const type = new TextDecoder().decode(bytes.subarray(offset + 4, offset + 8));
    const body = bytes.subarray(offset + 4, offset + 8 + length);
    expect(crc32(body)).toBe(view.getUint32(offset + 8 + length));
    chunks.push(type);
    offset += 12 + length;
  }
  expect(offset).toBe(bytes.length);
  expect(chunks).toEqual(["IHDR", "IDAT", "IEND"]);

  const width = view.getUint32(16);
  const height = view.getUint32(20);
  const colourType = bytes[25]!;

  // L'en-tête annonce un nombre de canaux ; les octets doivent en avoir
  // autant. Sans cette ligne, un encodeur qui écrirait « pas d'alpha » dans
  // l'en-tête tout en laissant quatre canaux dans les données passerait tout
  // ce qui précède — les CRC seraient justes, l'image illisible.
  const channels = colourType === 6 ? 4 : 3;
  const idatStart = 8 + 12 + 13;
  const idatLength = view.getUint32(idatStart);
  const idat = bytes.subarray(idatStart + 8, idatStart + 8 + idatLength);
  const raw = inflateSync(idat);
  expect(raw.length).toBe(height * (1 + width * channels));

  return { width, height, bitDepth: bytes[24], colourType };
}

describe("l'icône que l'App Store accepte", () => {
  test("mille vingt-quatre points de côté, opaques", () => {
    const header = readPNG(iOSAppIcon());
    expect(header.width).toBe(1024);
    expect(header.height).toBe(1024);
    expect(header.bitDepth).toBe(8);
    // 2 = truecolour sans alpha. 6 en porterait un, et l'envoi serait refusé.
    expect(header.colourType).toBe(2);
  });

  /// L'autre bord de la règle : les icônes du site gardent leur transparence.
  /// Un encodeur qui l'aurait retirée partout aurait passé le test ci-dessus.
  test("les icônes du site gardent leur canal alpha", () => {
    expect(readPNG(appIcon(512, false)).colourType).toBe(6);
    expect(readPNG(appIcon(192, true)).colourType).toBe(6);
  });

  /// Le script est la seule route vers le catalogue ; on l'exécute plutôt que
  /// de relire ce qu'il contient.
  test("le script écrit un catalogue que Xcode sait lire", () => {
    execFileSync(join(repoRoot, "scripts/build-app-icon.sh"), { cwd: repoRoot });
    const set = join(repoRoot, "App/Assets.xcassets/AppIcon.appiconset");
    const manifest = JSON.parse(readFileSync(join(set, "Contents.json"), "utf8"));
    expect(manifest.images).toHaveLength(1);
    const image = manifest.images[0];
    expect(image.size).toBe("1024x1024");
    expect(image.idiom).toBe("universal");
    expect(image.platform).toBe("ios");
    // Le nom annoncé et le fichier écrit sont la même chose — un catalogue qui
    // nomme un fichier absent se compile en une icône vide.
    expect(readdirSync(set).sort()).toEqual(["Contents.json", image.filename].sort());
    expect(statSync(join(set, image.filename)).size).toBeGreaterThan(0);
    expect(readPNG(new Uint8Array(readFileSync(join(set, image.filename)))).width).toBe(1024);
    // Et le catalogue lui-même, sans quoi Xcode ignore le dossier.
    JSON.parse(readFileSync(join(repoRoot, "App/Assets.xcassets/Contents.json"), "utf8"));
  });

  /// La garde qui compte sur la durée. `xcodegen` fige la liste des fichiers
  /// du projet : un chemin de construction qui le lance sans avoir dessiné
  /// l'icône produit une application sans icône, et personne ne le voit avant
  /// le refus d'Apple. Il y en a six aujourd'hui ; un septième ajouté sans le
  /// générateur échoue ici.
  test("tout chemin qui génère le projet dessine l'icône d'abord", () => {
    const searched = [".github/workflows", "scripts"];
    const offenders: string[] = [];
    for (const directory of searched) {
      for (const entry of readdirSync(join(repoRoot, directory))) {
        const path = join(repoRoot, directory, entry);
        if (!statSync(path).isFile()) continue;
        const text = readFileSync(path, "utf8");
        const generate = text.indexOf("xcodegen generate");
        if (generate < 0) continue;
        const icon = text.indexOf("build-app-icon");
        if (icon < 0 || icon > generate) offenders.push(join(directory, entry));
      }
    }
    expect(offenders).toEqual([]);
  });
});
