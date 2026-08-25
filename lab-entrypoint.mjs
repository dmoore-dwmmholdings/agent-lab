#!/usr/bin/env node
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const workspace = process.cwd();
const manifestPath = join(workspace, ".agent-lab.json");
let manifest = {};

if (existsSync(manifestPath)) {
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (error) {
    console.error(`Invalid ${manifestPath}: ${error.message}`);
    process.exit(64);
  }
  if (manifest.version !== 1) {
    console.error(`${manifestPath} must set \"version\": 1`);
    process.exit(64);
  }
}

const environment = { ...process.env, ...(manifest.environment ?? {}) };
environment.PATH = `${environment.HOME}/.cargo/bin:${environment.PATH}`;

function run(command, label) {
  console.log(`\n[agent-lab] ${label}: ${command}`);
  const result = spawnSync("/bin/bash", ["-lc", command], {
    cwd: workspace,
    env: environment,
    stdio: "inherit",
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

const rust = manifest.toolchains?.rust;
if (rust) {
  if (typeof rust !== "string" || !/^[A-Za-z0-9._+-]+$/.test(rust)) {
    console.error("toolchains.rust must be a Rust toolchain name, such as \"1.85.0\" or \"stable\".");
    process.exit(64);
  }
  run("command -v rustup >/dev/null || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal", "installing rustup");
  run(`rustup toolchain install ${rust} && rustup default ${rust}`, "selecting Rust toolchain");
}

if (manifest.setup !== undefined && !Array.isArray(manifest.setup)) {
  console.error("setup must be an array of shell commands.");
  process.exit(64);
}
for (const command of manifest.setup ?? []) {
  if (typeof command !== "string" || !command.trim()) {
    console.error("Every setup entry must be a non-empty shell command.");
    process.exit(64);
  }
  run(command, "setup");
}

const [agent, ...args] = process.argv.slice(2);
if (!agent) {
  console.error("No agent command was supplied.");
  process.exit(64);
}
const result = spawnSync(agent, args, { cwd: workspace, env: environment, stdio: "inherit" });
process.exit(result.status ?? 1);
