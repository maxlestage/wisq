import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { copy } from "../src/content";

/// The site advertises numbers about the codebase. Numbers on a landing page
/// rot silently, so this reads the repository and fails when a claim stops
/// being true — the same discipline as the protocol guard rails.
const repoRoot = join(import.meta.dir, "..", "..");

function swiftTestFunctionCount(): number {
  let total = 0;
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir)) {
      const path = join(dir, entry);
      if (statSync(path).isDirectory()) {
        walk(path);
      } else if (entry.endsWith(".swift")) {
        total += readFileSync(path, "utf8").match(/^\s*func test[A-Z_]/gm)?.length ?? 0;
      }
    }
  };
  walk(join(repoRoot, "Tests"));
  return total;
}

function claimedValue(label: RegExp): number {
  const item = copy.en.facts.items.find((entry) => label.test(entry.label));
  if (!item) throw new Error(`aucun chiffre annoncé ne correspond à ${label}`);
  return Number(item.value);
}

describe("advertised claims match the repository", () => {
  test("the test count is the real one", () => {
    expect(claimedValue(/tests/)).toBe(swiftTestFunctionCount());
  });

  test("the CI gate count matches the workflow", () => {
    const workflow = readFileSync(join(repoRoot, ".github/workflows/ci.yml"), "utf8");
    // Count two-space keys only after the `jobs:` line — `on:` has children at
    // the same indentation and would otherwise be counted as jobs.
    const jobsSection = workflow.slice(workflow.indexOf("\njobs:"));
    const jobs = jobsSection.match(/^ {2}[a-z][\w-]*:$/gm)?.length ?? 0;
    // The site counts GitGuardian alongside our own jobs.
    expect(claimedValue(/gates|portes/)).toBe(jobs + 1);
  });
});
