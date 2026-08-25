# Agent Lab

Portable Docker sandboxes for Codex and Claude Code. Both tools can run in
their unrestricted mode while Docker limits them to the project folder you
explicitly mount.

## Install on a new Mac

1. Install and start Docker Desktop.
2. Clone this repository anywhere on disk.
3. Run:

   ```bash
   ./install.sh
   ```

The installer creates Docker-only named volumes for the Codex login, Claude
login, GitHub credentials, and Google Cloud credentials. It then installs
`codex-lab` and `claude-lab` symlinks in `~/.local/bin`.

If `~/.local/bin` is not already on your shell PATH, add this to `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Authenticate the services you need on that new machine:

```bash
codex-lab login
codex-lab github login
codex-lab gcloud login
codex-lab gcloud firestore-login
claude-lab login
```

Claude Code currently requires one additional first-interactive-launch choice:
run `claude-lab .`, select the subscription option, and complete the login in
that same session. Later launches reuse its Docker-only profile.

The named volumes intentionally are not in Git. Logins and any tokens stay on
the particular machine where you complete them.

## Use

Start Codex in a Docker container that can only modify the project directory
you select:

```bash
codex-lab /absolute/path/to/project
```

Run that in one terminal pane per project. The first run may take a moment to
build the image.

Inside the container, the project appears as `/workspace/<project-name>`. You
can safely start from the current directory with `codex-lab .` or `claude-lab .`;
the launcher resolves `.` before choosing the project name.

## Per-project setup

Commit an `.agent-lab.json` file at the project root. Both `codex-lab` and
`claude-lab` read it before the agent starts. Setup commands run inside the
container on every launch, so dependencies are ready when the agent begins.

```json
{
  "version": 1,
  "environment": { "NODE_ENV": "development" },
  "setup": ["npm ci"]
}
```

For Rust, select a toolchain and prefetch dependencies:

```json
{
  "version": 1,
  "toolchains": { "rust": "1.85.0" },
  "setup": ["cargo fetch"]
}
```

The Rust toolchain is cached in the agent's Docker-only profile. More examples
are included in `agent-lab.example.json` and `agent-lab.rust.example.json`.

### Shared developer base

Every lab starts with Node.js 22, pnpm, Firebase CLI 15, JDK 21, Git/GitHub
CLI, and Google Cloud CLI. Firebase emulators and Node-based build scripts can
therefore run without declaring these tools in `.agent-lab.json`.

Use the manifest only for repository-specific, repeatable setup—for example:

```json
{
  "version": 1,
  "setup": ["pnpm install --frozen-lockfile"]
}
```

Never put private registry credentials or tokens in the manifest. For a
multi-repository task, invoke the lab on the explicit common parent directory;
that parent and its children become the isolated workspace, while the rest of
your Mac remains unavailable to the agent.

Both agents receive built-in guidance on authoring this file. Start a lab once,
ask the agent to inspect the repository and prepare `.agent-lab.json`, then
exit and relaunch to run the resulting setup.

## Login once

Run this once:

```bash
codex-lab login
```

This uses Codex's device-authorisation flow: open the displayed URL on your Mac
and enter the displayed code. The login is stored in Docker's named
`codex-lab-home` volume, not in a mounted host folder. Every project session
reuses it.

## MCP servers

Portable MCP configuration is kept in that same container-only home. Add and
inspect servers with:

```bash
codex-lab mcp list
codex-lab mcp add my-server --url https://example.com/mcp
codex-lab mcp login my-server
```

For a local stdio MCP server, its executable must be installed in the container
image. Host-app MCP servers such as computer-use cannot safely be transplanted:
they depend on macOS applications and host paths.

## GitHub

Run this once to authenticate GitHub CLI with a device code and configure Git
to use HTTPS credentials:

```bash
codex-lab github login
```

Open the displayed URL on your Mac and complete the sign-in. The resulting
GitHub credentials are stored only in Docker's `codex-lab-home` volume, shared
by all lab sessions. Afterward, agents can pull and push over HTTPS. Check or
revoke this login with `codex-lab github status` or `codex-lab github logout`.
The login command also configures Git to use GitHub CLI as its credential
helper and transparently maps GitHub SSH remote URLs to HTTPS. If you
authenticated before this setup was added, run `codex-lab github setup-git`
once.

## Claude Code

Claude uses the same project manifest and shared Docker-only GitHub profile:

```bash
claude-lab /absolute/path/to/project
```

Authenticate Claude itself once with `claude-lab login`. This is separate from
GitHub authentication. Use `claude-lab github status` to inspect the shared
GitHub login or `claude-lab github login` to replace it.

## Google Cloud and Firestore

Google Cloud credentials are shared by both labs in a separate Docker-only
profile. Authenticate the gcloud CLI with:

```bash
codex-lab gcloud login
```

Then establish Application Default Credentials for Firestore client libraries:

```bash
codex-lab gcloud firestore-login
```

Both commands are headless: open the printed Google URL in your normal browser,
then paste the authorization code back into the terminal. Claude Lab uses the
same login, and exposes the identical commands through `claude-lab gcloud ...`.

## Security boundary

Codex runs with unrestricted in-container permissions, but the container is
unprivileged and has no access to the host home directory, SSH agent, Docker
socket, or any project directory other than the chosen one.

This uses a host-mounted workspace for convenient editing. For code that may be
actively hostile, use a Docker-managed workspace volume and exchange changes
through Git instead; that prevents the container from seeing host files at all.
