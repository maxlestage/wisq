/// La garde des secrets de signature, mise devant des workflows qui fautent.
///
/// `scripts/check-signing-secrets.sh` dit ce que le workflow TestFlight a le
/// droit de faire d'une clé privée : l'éprouver dans le refus précoce, et ne
/// l'écrire que sous `RUNNER_TEMP`. `verify.sh` la lance avant chaque envoi,
/// et la CI à chaque commit — mais toujours contre **ce** dépôt, où rien
/// n'est fautif. Son en-tête annonçait déjà ce fichier ; il n'existait pas.
/// Une garde qui n'a jamais refusé est une garde que personne n'a vérifiée,
/// et c'est exactement le reproche que ce dépôt a déjà fait à deux autres
/// gardes (#105, #106).
///
/// Chaque cas part du **vrai** workflow et lui inflige une faute, une seule.
/// Le contrôle est l'autre moitié : le workflow intact doit passer, sans quoi
/// les refus ne prouveraient rien — une garde qui refuse tout refuse aussi ce
/// qui est correct.
///
/// Et un refus ne suffit pas : le message est vérifié, parce qu'un rouge pour
/// une autre raison n'est pas une détection. C'est la leçon que la première
/// version de cette garde a coûté — elle cherchait le nom du secret là où le
/// `run:` ne connaît que son alias, et trois sabotages sur quatre lui ont
/// échappé.

import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// Comme pour les autres gardes en bash : le délai par défaut de Bun est de
/// cinq secondes, et un test arrêté par un chronomètre dit « rouge » sur un
/// comportement correct.
setDefaultTimeout(20_000);

const guard = join(import.meta.dir, "..", "..", "scripts", "check-signing-secrets.sh");
const workflowPath = join(import.meta.dir, "..", "..", ".github", "workflows", "testflight.yml");
const workflow = readFileSync(workflowPath, "utf8");

interface Verdict {
  code: number;
  said: string;
}

/// Pose un workflow dans une racine jetable et fait juger la garde.
function judge(contents: string): Verdict {
  const root = mkdtempSync(join(tmpdir(), "signing-guard-"));
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  writeFileSync(join(root, ".github", "workflows", "testflight.yml"), contents);
  const run = Bun.spawnSync([guard, root]);
  return {
    code: run.exitCode,
    said: new TextDecoder().decode(run.stderr) + new TextDecoder().decode(run.stdout),
  };
}

/// Une faute, appliquée et **vérifiée appliquée**.
///
/// Un sabotage qui ne s'applique pas laisse un survivant qui ressemble à un
/// trou dans la garde : ce dépôt s'est déjà fait avoir par là. La substitution
/// échoue franchement plutôt que de rendre le texte inchangé.
function sabotage(from: string, to: string): string {
  if (!workflow.includes(from)) {
    throw new Error(`le workflow ne contient pas le texte à saboter : ${from.slice(0, 60)}`);
  }
  return workflow.replace(from, to);
}

describe("la garde des secrets de signature", () => {
  /// Le contrôle. Sans lui, tous les refus d'en dessous passeraient aussi
  /// avec un `exit 1` en guise de garde.
  test("le workflow du dépôt passe", () => {
    const verdict = judge(workflow);
    expect(verdict.said).toContain("rien à signaler");
    expect(verdict.code).toBe(0);
  });

  test("elle refuse quand l'étape « Refuser tôt » a disparu", () => {
    const verdict = judge(sabotage("- name: Refuser tôt", "- name: Refuser plus tard"));
    expect(verdict.code).toBe(1);
    expect(verdict.said).toContain("« Refuser tôt » a disparu");
  });

  /// Le secret peut être **facultatif** — le certificat l'est depuis que
  /// l'envoi n° 30 a été refusé pour son absence — mais alors il doit être dit
  /// facultatif là où on refuse. Un secret ni éprouvé ni déclaré ne se
  /// verrait qu'à la signature, quinze minutes plus tard.
  test("elle refuse un secret ni éprouvé ni déclaré facultatif", () => {
    const verdict = judge(sabotage("APPLE_CERT_P12 absent", "le certificat n'est pas là"));
    expect(verdict.code).toBe(1);
    expect(verdict.said).toContain("APPLE_CERT_P12 n'est pas éprouvé");
  });

  test("elle refuse la clé App Store Connect écrite hors du temporaire du runner", () => {
    const verdict = judge(sabotage(
      'printf \'%s\\n\' "$KEY_P8" > "$RUNNER_TEMP/private_keys/AuthKey_$KEY_ID.p8"',
      'printf \'%s\\n\' "$KEY_P8" > private_keys/AuthKey.p8',
    ));
    expect(verdict.code).toBe(1);
    expect(verdict.said).toContain("ASC_KEY_P8 (KEY_P8)");
    expect(verdict.said).toContain("hors de RUNNER_TEMP");
  });

  /// Un journal d'exécution publique ne se rattrape pas : ce qui part sur la
  /// sortie est parti. La garde suit l'alias, parce que c'est sous l'alias que
  /// le secret circule dans le `run:`.
  test("elle refuse le certificat imprimé sur la sortie", () => {
    const verdict = judge(sabotage(
      'printf \'%s\' "$CERT_P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"',
      'echo "$CERT_P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"\n          echo "$CERT_P12"',
    ));
    expect(verdict.code).toBe(1);
    expect(verdict.said).toContain("APPLE_CERT_P12 (CERT_P12)");
  });

  /// **Ce cas a été payé par un refus au lancement.** L'étape du trousseau
  /// était conditionnée par `if: ${{ secrets.APPLE_CERT_P12 != '' }}`, et
  /// GitHub a répondu « Unrecognized named-value: 'secrets' » : le contexte
  /// `secrets` n'existe pas dans un `if:`. Rien ne l'a attrapé — la CI ne
  /// parse pas ce fichier, seul un `workflow_dispatch` le fait, et un
  /// workflow qui ne démarre pas ressemble à un workflow qui va bien.
  ///
  /// La faute est **muette et tardive** : elle ne se voit qu'au moment où l'on
  /// veut envoyer. Elle se lit pourtant sur le texte, et c'est ce que la garde
  /// fait maintenant.
  test("elle refuse un secret lu dans un « if », que GitHub ne sait pas résoudre", () => {
    const verdict = judge(sabotage(
      "      - name: Le certificat de distribution, dans un trousseau jetable",
      "      - name: Le certificat de distribution, dans un trousseau jetable\n        if: ${{ secrets.APPLE_CERT_P12 != '' }}",
    ));
    expect(verdict.code).toBe(1);
    expect(verdict.said).toContain("« if »");
  });

  test("elle refuse le certificat déposé dans l'arbre du dépôt", () => {
    const verdict = judge(sabotage(
      'printf \'%s\' "$CERT_P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"',
      'printf \'%s\' "$CERT_P12" | base64 --decode > .github/cert.p12',
    ));
    expect(verdict.code).toBe(1);
    expect(verdict.said).toContain("hors de RUNNER_TEMP");
  });
});
