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
`codex-lab`, `claude-lab`, and `lume-lab` symlinks in `~/.local/bin`.

Images are built automatically the first time each lab is used. Pass
`./install.sh --build` to build both up front instead.

If `~/.local/bin` is not already on your shell PATH, add this to `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Authenticate the services you need on that new machine:

```bash
codex-lab login
codex-lab github login
codex-lab github identity "Your Name" you@example.com
codex-lab gcloud login
codex-lab gcloud firestore-login
claude-lab login
```

The named volumes intentionally are not in Git. Logins and any tokens stay on
the particular machine where you complete them.

## Use

Start an agent in a container that can only modify the project directory you
select:

```bash
codex-lab /absolute/path/to/project
# or
claude-lab /absolute/path/to/project
```

Run that in one terminal pane per project. Inside the container, the project
appears as `/workspace/<project-name>`. You can safely start from the current
directory with `codex-lab .` or `claude-lab .`; the launcher resolves `.`
before choosing the project name.

For a multi-repository task, invoke the lab on the explicit common parent
directory; that parent and its children become the isolated workspace, while
the rest of your Mac remains unavailable to the agent.

## Keeping images current

Nothing rebuilds an image on its own. After pulling changes to this repository,
or to pick up a new agent release or Framewatch version, rebuild explicitly:

```bash
codex-lab build          # headless image
codex-lab build --gui    # GUI image
claude-lab build
```

`build` pulls a fresh base image by default; add `--no-pull` to skip that.

Launching also rebuilds automatically when the `Dockerfile`, the entrypoints, or
the guidance file are newer than the image that was built from them. A stale
image otherwise fails in ways that look unrelated to the real cause. Set
`AGENT_LAB_SKIP_STALE_CHECK=1` to suppress that check.

Each agent and flavour has its own image (`codex-lab-project`,
`codex-lab-gui-project`, `claude-lab-project`, `claude-lab-gui-project`), and
they share the expensive base layers, so the second build of a pair is fast.

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

For Python, uv is already present, so the manifest only needs the sync step:

```json
{
  "version": 1,
  "setup": ["uv sync --locked"]
}
```

The Rust toolchain is cached in the agent's Docker-only profile. More examples
are included in `agent-lab.example.json` and `agent-lab.rust.example.json`.

A manifest is executable code, so the first time a lab sees a particular
`.agent-lab.json` it prints the commands and asks for approval. Approving
remembers that exact file by hash; editing it asks again. Declining starts the
agent with the manifest ignored entirely. Set `AGENT_LAB_TRUST_MANIFEST=1` to
approve without prompting, for unattended use.

`environment` cannot override the variables Agent Lab uses to wire up the
container: `HOME`, `PATH`, `TMPDIR`, `NPM_CONFIG_PREFIX`, and the GitHub and
Google Cloud credential paths.

### Shared developer base

Every lab starts with Node.js 22, pnpm, uv, Firebase CLI 15, JDK 21, Git/GitHub
CLI, and Google Cloud CLI. Firebase emulators and Node-based build scripts can
therefore run without declaring these tools in `.agent-lab.json`.

Python is handled by uv, which installs its own interpreters, so `uv sync
--locked` works without declaring a Python version. There is no `pip` on PATH
by design; use `uv pip` if you need that interface.

Use the manifest only for repository-specific, repeatable setup—for example:

```json
{
  "version": 1,
  "setup": ["pnpm install --frozen-lockfile"]
}
```

Never put private registry credentials or tokens in the manifest.

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
GitHub credentials are stored only in Docker's `agent-lab-github` volume,
shared by both labs. Afterward, agents can pull and push over HTTPS. Check or
revoke this login with `codex-lab github status` or `codex-lab github logout`.
The login command also configures Git to use GitHub CLI as its credential
helper and transparently maps GitHub SSH remote URLs to HTTPS. If you
authenticated before this setup was added, run `codex-lab github setup-git`
once.

`claude-lab github ...` operates on the same shared login.

## Claude Code

Claude uses the same project manifest and shared Docker-only GitHub profile:

```bash
claude-lab /absolute/path/to/project
```

Authenticate Claude itself once with `claude-lab login`, and inspect or clear it
with `claude-lab status` / `claude-lab logout`. This is separate from GitHub
authentication.

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

## GUI paths

### Default: Linux desktop inside Docker

Use the Docker GUI path for web apps, Linux desktop apps, Electron apps that
support Linux, and automated visual checks:

```bash
codex-lab gui /absolute/path/to/project
# or: claude-lab gui .
```

Then open http://localhost:6080/vnc.html in a Mac browser. The project is still
the only host folder mounted into the container. This image provides X11,
Framewatch's `linux-x11` backend, and `framewatch` on PATH. An agent can use
`framewatch windows` and `framewatch shot` against apps it starts in that
desktop. This is the recommended default because it is much faster and uses the
same Docker isolation as normal Agent Lab sessions.

The desktop is published on `127.0.0.1` only, because the VNC server runs
without a password. Override with `AGENT_LAB_GUI_BIND` only on a network you
control.

Only one container can own a host port, so a second GUI lab needs its own:

```bash
AGENT_LAB_GUI_PORT=6081 claude-lab gui /another/project
```

### Native macOS: Lume VM

For Xcode, Apple frameworks, or actual macOS-window capture, use the optional
Lume path on Apple Silicon Macs:

```bash
codex-lab lume /absolute/path/to/project
# or: claude-lab lume .
```

Lume runs a real local macOS VM through Apple's Virtualization framework; it is
not a Linux Docker container. On first invocation Agent Lab creates the VM,
shares only the invoked project, bootstraps the chosen agent, Firebase tooling,
and Framewatch's macOS backend, then starts the agent in that shared project.
Every provisioning step is skipped on later launches once it is already
present, so a repeat launch is quick.

The agent opens in the VM's own Terminal window rather than over SSH, because
`lume ssh` provides no controlling terminal and a full-screen TUI needs one.
Terminal is launched with `open`, not AppleScript: driving it via `osascript`
requires macOS Automation consent that cannot be granted from an SSH session,
so that approach simply hangs on a fresh guest. Interact with the agent in the
VM's native display. Complete its one-time login inside the guest; it remains
inside that VM.

A Lume VM has exactly one runner and binds its shared directory at boot, so one
VM serves one project at a time. Launching the same project again reuses the
running VM instead of restarting it; a different project needs its own VM via
`AGENT_LAB_LUME_VM=<name>`.

The harness waits for Remote Login before provisioning. If a first boot takes
longer than three minutes, it prints the exact `lume setup` recovery command.

Change the default guest password before sensitive work, and set
`AGENT_LAB_LUME_PASSWORD` so the launcher can still reach the guest. That
password is passed to `lume ssh` and is briefly readable inside the guest while
Homebrew is installed, so treat it as a throwaway rather than a reused secret.

Agent Lab pins Framewatch to version `0.8.5`. Override that default with
`AGENT_LAB_FRAMEWATCH_VERSION=<version>` when needed.

| Path | Best for | Tradeoff |
| --- | --- | --- |
| `codex-lab gui` / `claude-lab gui` | Fast visual testing and Linux/X11 Framewatch | Not macOS; cannot capture host macOS windows |
| `codex-lab lume` / `claude-lab lume` | Xcode and native macOS Framewatch | First VM download/setup is large and slower |

## Security boundary

Agents run with unrestricted in-container permissions, but the container is
unprivileged, drops all capabilities, sets `no-new-privileges`, caps its
process count, and has no access to the host home directory, SSH agent, Docker
socket, or any project directory other than the chosen one.

What the container *does* have is your shared GitHub token and Google Cloud
credentials, mounted at `/github` and `/gcloud`. Anything that runs inside a
session can read them, which includes the project's own `.agent-lab.json` setup
commands and anything the agent is talked into running. The manifest approval
prompt exists for exactly this reason.

For a repository you do not trust, leave the credentials out entirely:

```bash
AGENT_LAB_NO_CREDENTIALS=1 codex-lab /path/to/untrusted-repo
```

This uses a host-mounted workspace for convenient editing. For code that may be
actively hostile, also prefer a Docker-managed workspace volume and exchange
changes through Git; that prevents the container from seeing host files at all.

### Environment reference

| Variable | Effect |
| --- | --- |
| `AGENT_LAB_NO_CREDENTIALS=1` | Do not mount the shared GitHub/Google Cloud volumes |
| `AGENT_LAB_TRUST_MANIFEST=1` | Approve `.agent-lab.json` without prompting |
| `AGENT_LAB_PIDS_LIMIT=<n>` | Container process cap (default 4096) |
| `AGENT_LAB_SKIP_STALE_CHECK=1` | Do not auto-rebuild an image older than its build inputs |
| `AGENT_LAB_GUI_BIND=<ip>` | Host interface for the noVNC port (default `127.0.0.1`) |
| `AGENT_LAB_GUI_PORT=<port>` | Host port for the noVNC desktop (default `6080`) |
| `AGENT_LAB_SCREEN=<WxHxD>` | Virtual screen geometry (default `1920x1080x24`) |
| `AGENT_LAB_LUME_VM=<name>` | Lume VM name |
| `AGENT_LAB_LUME_PASSWORD=<pw>` | Guest password for `lume ssh` |
| `AGENT_LAB_FRAMEWATCH_VERSION=<v>` | Framewatch version to install |
