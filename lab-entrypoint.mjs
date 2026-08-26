#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, readdirSync, appendFileSync, writeFileSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { basename, join } from "node:path";

const workspace = process.cwd();
const manifestPath = join(workspace, ".agent-lab.json");

function fail(message) {
  console.error(`[agent-lab] ${message}`);
  process.exit(64);
}

// Environment variables that wire the container to its credential volumes and
// its own tooling. A committed manifest must not be able to repoint them.
const RESERVED_ENV = new Set([
  "HOME",
  "PATH",
  "TMPDIR",
  "GH_CONFIG_DIR",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "GIT_CONFIG_GLOBAL",
  "CLOUDSDK_CONFIG",
  "GOOGLE_APPLICATION_CREDENTIALS",
  "NPM_CONFIG_PREFIX",
]);

let manifest = {};
let manifestRaw = "";

if (existsSync(manifestPath)) {
  manifestRaw = readFileSync(manifestPath, "utf8");
  try {
    manifest = JSON.parse(manifestRaw);
  } catch (error) {
    fail(`Invalid ${manifestPath}: ${error.message}`);
  }
  if (manifest === null || typeof manifest !== "object" || Array.isArray(manifest)) {
    fail(`${manifestPath} must contain a JSON object.`);
  }
  if (manifest.version !== 1) {
    fail(`${manifestPath} must set "version": 1`);
  }
}

function validateManifest() {
  const environment = manifest.environment ?? {};
  if (typeof environment !== "object" || environment === null || Array.isArray(environment)) {
    fail("environment must be an object of string values.");
  }
  for (const [key, value] of Object.entries(environment)) {
    if (typeof value !== "string") {
      fail(`environment.${key} must be a string.`);
    }
    if (RESERVED_ENV.has(key)) {
      fail(`environment.${key} is reserved by Agent Lab and cannot be set from a manifest.`);
    }
  }
  const rust = manifest.toolchains?.rust;
  if (rust !== undefined && (typeof rust !== "string" || !/^[A-Za-z0-9._+-]+$/.test(rust))) {
    fail('toolchains.rust must be a Rust toolchain name, such as "1.85.0" or "stable".');
  }
  if (manifest.setup !== undefined && !Array.isArray(manifest.setup)) {
    fail("setup must be an array of shell commands.");
  }
  for (const command of manifest.setup ?? []) {
    if (typeof command !== "string" || !command.trim()) {
      fail("Every setup entry must be a non-empty shell command.");
    }
  }
}

// A manifest is executable code that runs before the agent starts, in a
// container that has the shared GitHub and Google Cloud credentials mounted.
// Cloning an untrusted repository and pointing a lab at it should not silently
// run its commands, so an exact copy has to be approved once.
function trustStorePath() {
  const dir = join(process.env.HOME ?? "/tmp", ".agent-lab");
  mkdirSync(dir, { recursive: true });
  return join(dir, "trusted-manifests");
}

function describeManifest() {
  const lines = [];
  const rust = manifest.toolchains?.rust;
  if (rust) lines.push(`  rust toolchain: ${rust}`);
  for (const [key, value] of Object.entries(manifest.environment ?? {})) {
    lines.push(`  env: ${key}=${value}`);
  }
  for (const command of manifest.setup ?? []) {
    lines.push(`  run: ${command}`);
  }
  return lines.length ? lines.join("\n") : "  (no commands)";
}

function promptYesNo() {
  const result = spawnSync(
    "/bin/bash",
    ["-c", 'read -r reply </dev/tty && printf "%s" "$reply"'],
    // stderr is discarded: with no controlling terminal /dev/tty simply
    // fails, and that is a decline, not something to shout about.
    { stdio: ["inherit", "pipe", "ignore"], encoding: "utf8" },
  );
  if (result.error || result.status !== 0) return false;
  return /^y(es)?$/i.test((result.stdout ?? "").trim());
}

function manifestIsTrusted() {
  const digest = createHash("sha256").update(manifestRaw).digest("hex");
  const store = trustStorePath();
  const known = existsSync(store)
    ? readFileSync(store, "utf8").split("\n").map((line) => line.trim()).filter(Boolean)
    : [];
  if (known.includes(digest)) return true;

  if (process.env.AGENT_LAB_TRUST_MANIFEST === "1") {
    appendFileSync(store, `${digest}\n`);
    return true;
  }

  console.error(`
[agent-lab] ${manifestPath} has not been approved on this machine.

Before the agent starts, it would run the following inside the container,
which has your shared GitHub and Google Cloud credentials mounted:

${describeManifest()}

Approve and remember this exact file? [y/N] `);

  if (!promptYesNo()) {
    console.error("[agent-lab] Declined. Continuing WITHOUT the manifest: no setup commands, no toolchain, no environment overrides.\n");
    return false;
  }
  appendFileSync(store, `${digest}\n`);
  return true;
}

let applyManifest = false;
if (manifestRaw) {
  validateManifest();
  applyManifest = manifestIsTrusted();
}

const environment = { ...process.env, ...(applyManifest ? manifest.environment ?? {} : {}) };
environment.PATH = `${environment.HOME}/.cargo/bin:${environment.PATH}`;

// /tmp is mounted noexec, which breaks rustup and any build that execs out of
// TMPDIR, so point TMPDIR at the agent's own home. It lives in a persistent
// volume, so clear it each session instead of letting it grow forever.
// A project's .venv cannot be shared between the host and this container: they
// are different platforms, so uv finds an interpreter that does not exist here,
// deletes the virtualenv, and rebuilds it — destroying the one the host was
// using. Keep the container's environment in the agent's own volume instead,
// where it also survives between sessions. A manifest may still override this.
if (!environment.UV_PROJECT_ENVIRONMENT) {
  const key = environment.AGENT_LAB_PROJECT_KEY;
  const slot = key ? `${basename(workspace)}-${key}` : basename(workspace);
  environment.UV_PROJECT_ENVIRONMENT = join(environment.HOME, ".agent-lab-venvs", slot);
}

// Caches in the agent's home volume outlive the image that wrote them. uv
// records each interpreter's manylinux tags there, so after a base image change
// that moves glibc those records still describe the old platform: uv then
// rejects wheels the system can actually run, and says so using the old glibc
// version, which points nowhere near the cause. Drop just that cache when the
// platform changes. The expensive wheel and sdist caches are untouched.
function platformKey() {
  let osRelease = "";
  try {
    osRelease = readFileSync("/etc/os-release", "utf8");
  } catch {
    // Not Debian-shaped; the libc version alone still distinguishes platforms.
  }
  const libc = spawnSync("getconf", ["GNU_LIBC_VERSION"], { encoding: "utf8" });
  return createHash("sha256").update(`${osRelease}\n${libc.stdout ?? ""}`).digest("hex").slice(0, 16);
}

function invalidatePlatformCaches() {
  const stampDir = join(environment.HOME, ".agent-lab");
  const stampPath = join(stampDir, "platform-key");
  const key = platformKey();
  let previous = null;
  try {
    previous = readFileSync(stampPath, "utf8").trim();
  } catch {
    // No stamp yet: treat as a change so a volume predating this check is fixed.
  }
  if (previous === key) return;

  const uvCache = environment.UV_CACHE_DIR ?? join(environment.HOME, ".cache", "uv");
  let cleared = false;
  try {
    for (const entry of readdirSync(uvCache)) {
      if (entry.startsWith("interpreter-v")) {
        rmSync(join(uvCache, entry), { recursive: true, force: true });
        cleared = true;
      }
    }
  } catch {
    // No uv cache to clear.
  }
  if (cleared && previous !== null) {
    console.log("[agent-lab] container platform changed; cleared uv's cached interpreter data.");
  }
  try {
    mkdirSync(stampDir, { recursive: true });
    writeFileSync(stampPath, `${key}\n`);
  } catch (error) {
    // Not being able to record the stamp only costs a redundant clear next
    // time. It must never take the session down with it.
    console.error(`[agent-lab] could not record the platform stamp: ${error.message}`);
  }
}

try {
  invalidatePlatformCaches();
} catch (error) {
  console.error(`[agent-lab] skipping platform cache check: ${error.message}`);
}

const executableTempDir = join(environment.HOME, ".agent-lab-tmp");
rmSync(executableTempDir, { recursive: true, force: true });
mkdirSync(executableTempDir, { recursive: true });
environment.TMPDIR = executableTempDir;

function run(command, label) {
  console.log(`\n[agent-lab] ${label}: ${command}`);
  const result = spawnSync("/bin/bash", ["-lc", command], {
    cwd: workspace,
    env: environment,
    stdio: "inherit",
  });
  if (result.error) {
    console.error(`[agent-lab] failed to run ${label}: ${result.error.message}`);
    process.exit(1);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

if (applyManifest) {
  const rust = manifest.toolchains?.rust;
  if (rust) {
    run(
      "command -v rustup >/dev/null || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal",
      "installing rustup",
    );
    run(`rustup toolchain install ${rust} && rustup default ${rust}`, "selecting Rust toolchain");
  }
  for (const command of manifest.setup ?? []) {
    run(command, "setup");
  }
}

const [agent, ...args] = process.argv.slice(2);
if (!agent) {
  fail("No agent command was supplied.");
}
const result = spawnSync(agent, args, { cwd: workspace, env: environment, stdio: "inherit" });
if (result.error) {
  console.error(`[agent-lab] could not start ${agent}: ${result.error.message}`);
  process.exit(127);
}
process.exit(result.status ?? 1);
