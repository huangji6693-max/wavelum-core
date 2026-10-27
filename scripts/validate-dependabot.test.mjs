import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..");
const dependabotPath = path.join(repoRoot, ".github", "dependabot.yml");
const cargoTomlPath = path.join(repoRoot, "Cargo.toml");

test("dependabot.yml exists and specifies version 2", () => {
  assert.ok(fs.existsSync(dependabotPath), ".github/dependabot.yml must exist");
  const content = fs.readFileSync(dependabotPath, "utf8");
  assert.match(content, /^version:\s*2\b/m);
  assert.match(content, /^updates:/m);
});

test("dependabot.yml configures Cargo and GitHub Actions ecosystems with required schedule, limits, labels, and reviewers", () => {
  const content = fs.readFileSync(dependabotPath, "utf8");

  assert.match(content, /package-ecosystem:\s*"cargo"/);
  assert.match(content, /package-ecosystem:\s*"github-actions"/);
  assert.match(content, /interval:\s*"weekly"/);
  assert.match(content, /day:\s*"monday"/);
  assert.match(content, /open-pull-requests-limit:\s*5\b/);
  assert.match(content, /-\s*"dependencies"/);
  assert.match(content, /-\s*"security"/);
  assert.match(content, /-\s*"Husten150"/);
});

test("dependabot.yml covers every Cargo workspace member crate defined in root Cargo.toml", () => {
  const dependabotContent = fs.readFileSync(dependabotPath, "utf8");
  const cargoContent = fs.readFileSync(cargoTomlPath, "utf8");

  const membersMatch = cargoContent.match(/members\s*=\s*\[([\s\S]*?)\]/);
  assert.ok(membersMatch, "Root Cargo.toml must declare workspace members");

  const members = [...membersMatch[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  assert.ok(members.length > 0, "Workspace must contain at least one member");

  for (const member of members) {
    assert.ok(
      dependabotContent.includes(`"/${member}"`),
      `Expected .github/dependabot.yml to include workspace member directory "/${member}"`
    );
    const memberManifest = path.join(repoRoot, member, "Cargo.toml");
    assert.ok(
      fs.existsSync(memberManifest),
      `Workspace member manifest must exist at ${member}/Cargo.toml`
    );
  }
});
