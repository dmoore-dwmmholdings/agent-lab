# Agent Lab setup authoring

This project can opt into repeatable container setup with a committed
`.agent-lab.json` file in the project root. The launcher reads it before each
new Codex Lab or Claude Lab session.

The lab already includes Node.js 22, pnpm, Firebase CLI 15, JDK 21, Git/GitHub
CLI, and Google Cloud CLI. Do not add these as `toolchains` entries. Use setup
only for repository-specific, idempotent work such as `pnpm install
--frozen-lockfile`, `npm ci`, or `cargo fetch`; never put credentials, tokens,
private registry settings, or absolute host paths in this file.

The first time a lab sees a given `.agent-lab.json` it shows the commands and
asks the user to approve them, because those commands run with the shared
GitHub and Google Cloud credentials mounted. Editing the file asks again, so
keep setup minimal and explainable.

Agents run unprivileged and cannot write to the global npm prefix. `npm install
-g` works because `NPM_CONFIG_PREFIX` points at a writable directory in the
agent's own home; prefer project-local dependencies regardless.

`environment` cannot override `HOME`, `PATH`, `TMPDIR`, `NPM_CONFIG_PREFIX`, or
the GitHub and Google Cloud credential paths. Agent Lab rejects a manifest that
tries.

When the user asks you to prepare this project for Agent Lab:

1. Inspect the repository's package manager files, lockfiles, toolchain files,
   build scripts, test scripts, and documented prerequisites.
2. Create or update `.agent-lab.json` in the project root. Use version `1`.
3. Add idempotent setup commands. Prefer lockfile-respecting installs such as
   `npm ci`, `pnpm install --frozen-lockfile`, `yarn install --immutable`, or
   `cargo fetch`.
4. For Rust, set `toolchains.rust` to the version from `rust-toolchain.toml` or
   the project's documented toolchain. Agent Lab installs and caches it.
5. Put non-secret defaults in `environment`; never put credentials, API keys,
   or tokens in this committed file.
6. Explain what you added and tell the user to exit and relaunch the lab so the
   new setup runs before the next agent session.

Example:

```json
{
  "version": 1,
  "toolchains": { "rust": "1.85.0" },
  "environment": { "NODE_ENV": "development" },
  "setup": ["npm ci", "cargo fetch"]
}
```
