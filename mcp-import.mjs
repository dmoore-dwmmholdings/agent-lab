#!/usr/bin/env node
// Read MCP server definitions out of the host's Codex and Claude configuration
// and emit the shell commands that install them into both labs.
//
// This runs inside a lab image, not on the Mac, so that `agent-lab` needs
// nothing on the host but Docker. The files it reads are piped in on stdin as
// `<kind>\t<label>\t<base64>` lines; base64 keeps arbitrary file content out of
// argv and out of the shell's way.
//
// Output is shell, not data, so the caller does not have to parse JSON in bash.
// Every interpolated value goes through shellQuote(), which makes the emitted
// script inert regardless of what the source configuration contains.

const importDir = process.env.AGENT_LAB_IMPORT_DIR ?? "";
const only = process.env.AGENT_LAB_ONLY ?? "";
const LABS = only ? [only] : ["codex", "claude"];

function shellQuote(value) {
  return `'${String(value).split("'").join(`'\\''`)}'`;
}

const out = [];
function emit(...words) {
  out.push(words.join(" "));
}
function note(level, message) {
  emit("mcp_note", shellQuote(level), shellQuote(message));
}

// ---------------------------------------------------------------- TOML subset
//
// Codex keeps MCP servers in ~/.codex/config.toml. Node has no TOML parser, and
// the alternative -- asking the codex binary to read a config from a mounted
// host directory -- ties this to CLI flags that change between releases. This
// covers the value forms a config.toml actually uses: strings, numbers,
// booleans, arrays, inline tables, and nested `[a.b.c]` headers.

class TomlError extends Error {}

function parseToml(text) {
  let i = 0;
  const root = {};
  let current = root;

  const isBareKeyChar = (c) => /[A-Za-z0-9_-]/.test(c);

  function skipTrivia(newlines) {
    for (;;) {
      const c = text[i];
      if (c === undefined) return;
      if (c === " " || c === "\t" || c === "\r") { i++; continue; }
      if (c === "\n") {
        if (!newlines) return;
        i++;
        continue;
      }
      if (c === "#") {
        while (i < text.length && text[i] !== "\n") i++;
        continue;
      }
      return;
    }
  }

  function parseBasicString() {
    if (text.startsWith('"""', i)) {
      i += 3;
      if (text[i] === "\n") i++;
      const end = text.indexOf('"""', i);
      if (end === -1) throw new TomlError("unterminated multi-line string");
      const raw = text.slice(i, end);
      i = end + 3;
      return unescapeBasic(raw);
    }
    i++; // opening quote
    let raw = "";
    while (i < text.length && text[i] !== '"') {
      if (text[i] === "\\") { raw += text[i] + text[i + 1]; i += 2; continue; }
      if (text[i] === "\n") throw new TomlError("newline in basic string");
      raw += text[i++];
    }
    if (text[i] !== '"') throw new TomlError("unterminated string");
    i++;
    return unescapeBasic(raw);
  }

  function unescapeBasic(raw) {
    return raw.replace(/\\(u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}|.)/gs, (_, esc) => {
      switch (esc[0]) {
        case "n": return "\n";
        case "t": return "\t";
        case "r": return "\r";
        case "b": return "\b";
        case "f": return "\f";
        case '"': return '"';
        case "\\": return "\\";
        case "u": case "U": return String.fromCodePoint(parseInt(esc.slice(1), 16));
        // A backslash before a newline is TOML's line continuation.
        case "\n": return "";
        default: return esc;
      }
    });
  }

  function parseLiteralString() {
    if (text.startsWith("'''", i)) {
      i += 3;
      if (text[i] === "\n") i++;
      const end = text.indexOf("'''", i);
      if (end === -1) throw new TomlError("unterminated multi-line literal string");
      const raw = text.slice(i, end);
      i = end + 3;
      return raw;
    }
    i++;
    const end = text.indexOf("'", i);
    if (end === -1) throw new TomlError("unterminated literal string");
    const raw = text.slice(i, end);
    i = end + 1;
    return raw;
  }

  function parseKey() {
    skipTrivia(false);
    if (text[i] === '"') return parseBasicString();
    if (text[i] === "'") return parseLiteralString();
    let key = "";
    while (i < text.length && isBareKeyChar(text[i])) key += text[i++];
    if (!key) throw new TomlError(`expected a key at offset ${i}`);
    return key;
  }

  // Dotted keys, in both `[a.b]` headers and `a.b = 1` assignments.
  function parseKeyPath() {
    const path = [parseKey()];
    for (;;) {
      skipTrivia(false);
      if (text[i] !== ".") return path;
      i++;
      path.push(parseKey());
    }
  }

  function parseValue() {
    skipTrivia(false);
    const c = text[i];
    if (c === '"') return parseBasicString();
    if (c === "'") return parseLiteralString();
    if (c === "[") {
      i++;
      const array = [];
      for (;;) {
        skipTrivia(true);
        if (text[i] === "]") { i++; return array; }
        array.push(parseValue());
        skipTrivia(true);
        if (text[i] === ",") { i++; continue; }
        if (text[i] === "]") { i++; return array; }
        throw new TomlError(`expected , or ] at offset ${i}`);
      }
    }
    if (c === "{") {
      i++;
      const table = {};
      for (;;) {
        skipTrivia(true);
        if (text[i] === "}") { i++; return table; }
        const path = parseKeyPath();
        skipTrivia(false);
        if (text[i] !== "=") throw new TomlError(`expected = at offset ${i}`);
        i++;
        assign(table, path, parseValue());
        skipTrivia(true);
        if (text[i] === ",") { i++; continue; }
        if (text[i] === "}") { i++; return table; }
        throw new TomlError(`expected , or } at offset ${i}`);
      }
    }
    let raw = "";
    while (i < text.length && !",]}\n#".includes(text[i])) raw += text[i++];
    raw = raw.trim();
    if (raw === "true") return true;
    if (raw === "false") return false;
    if (/^[+-]?(\d[\d_]*)(\.[\d_]+)?([eE][+-]?\d+)?$/.test(raw)) return Number(raw.replace(/_/g, ""));
    if (!raw) throw new TomlError(`expected a value at offset ${i}`);
    return raw; // dates and anything else: keep the text, we do not use it
  }

  function descend(table, path) {
    let node = table;
    for (const key of path) {
      if (typeof node[key] !== "object" || node[key] === null || Array.isArray(node[key])) {
        node[key] = {};
      }
      node = node[key];
    }
    return node;
  }

  function assign(table, path, value) {
    const node = descend(table, path.slice(0, -1));
    node[path[path.length - 1]] = value;
  }

  for (;;) {
    skipTrivia(true);
    if (i >= text.length) break;
    if (text[i] === "[") {
      // `[[array of tables]]` has no meaning for MCP config; treat it as a
      // table so the parse still completes instead of throwing.
      i += text.startsWith("[[", i) ? 2 : 1;
      const path = parseKeyPath();
      skipTrivia(false);
      while (text[i] === "]") i++;
      current = descend(root, path);
      continue;
    }
    const path = parseKeyPath();
    skipTrivia(false);
    if (text[i] !== "=") throw new TomlError(`expected = at offset ${i}`);
    i++;
    assign(current, path, parseValue());
  }
  return root;
}

// ------------------------------------------------------------- normalisation

function asStringMap(value) {
  const map = {};
  if (!value || typeof value !== "object" || Array.isArray(value)) return map;
  for (const [key, entry] of Object.entries(value)) {
    if (entry !== null && entry !== undefined && typeof entry !== "object") map[key] = String(entry);
  }
  return map;
}

function asStringArray(value) {
  if (!Array.isArray(value)) return [];
  return value.filter((entry) => typeof entry !== "object" && entry !== null).map(String);
}

// One shape for both dialects. `transport` is what each lab's CLI is told.
function normalise(name, entry, source, dialect) {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
  // `enabled = false` is Codex's way of keeping a definition around without
  // running it. A disabled entry still takes part in precedence -- switching a
  // server off in this directory has to beat an enabled one of the same name
  // further up -- so it is carried as a record and dropped at emission rather
  // than discarded here. Its command and url go unvalidated on purpose: there
  // is nothing to complain about in a server nobody is going to start.
  if (entry.enabled === false) return { name, source, dialect, enabled: false };
  const record = {
    enabled: true,
    name,
    source,
    dialect,
    env: asStringMap(entry.env),
    headers: { ...asStringMap(entry.headers), ...asStringMap(entry.http_headers) },
    args: asStringArray(entry.args),
    command: typeof entry.command === "string" ? entry.command : "",
    url: typeof entry.url === "string" ? entry.url : "",
    bearerTokenEnvVar:
      typeof entry.bearer_token_env_var === "string" ? entry.bearer_token_env_var : "",
  };
  // Claude writes an explicit type; Codex and older Claude configs do not, so
  // fall back to whichever of url/command is present.
  const declared = typeof entry.type === "string" ? entry.type : "";
  if (declared === "sse") record.transport = "sse";
  else if (declared === "http") record.transport = "http";
  else if (declared === "stdio") record.transport = "stdio";
  else if (record.url) record.transport = "http";
  else record.transport = "stdio";

  // An entry with neither a command nor a URL is not a server definition --
  // usually a stray sub-table. Say so rather than dropping it in silence.
  if (record.transport === "stdio" && !record.command) {
    note("warn", `${name}: no command or url in ${source}; skipped`);
    return null;
  }
  if (record.transport !== "stdio" && !record.url) {
    note("warn", `${name}: no url in ${source}; skipped`);
    return null;
  }
  return record;
}

// ------------------------------------------------------------------- sources

// `agent-lab mcp add` builds one record from flags instead of reading files.
// It shares everything below so a hand-added server and an imported one end up
// described to each lab the same way.
function recordFromArgv(argv) {
  const at = argv.indexOf("--add");
  const rest = argv.slice(at + 1);
  const separator = rest.indexOf("--");
  const flags = separator === -1 ? rest : rest.slice(0, separator);
  const command = separator === -1 ? [] : rest.slice(separator + 1);
  const name = flags.shift();
  if (!name || name.startsWith("-")) fatal("mcp add needs a server name.");
  const entry = { env: {}, headers: {} };
  for (let n = 0; n < flags.length; n++) {
    const value = flags[n + 1];
    const needsValue = () => {
      if (value === undefined) fatal(`${flags[n]} needs a value.`);
      n++;
      return value;
    };
    switch (flags[n]) {
      case "--url": entry.url = needsValue(); break;
      case "--transport": entry.type = needsValue(); break;
      case "--env": {
        const pair = needsValue();
        const eq = pair.indexOf("=");
        if (eq < 1) fatal(`--env expects KEY=VALUE, got ${pair}`);
        entry.env[pair.slice(0, eq)] = pair.slice(eq + 1);
        break;
      }
      case "--header": {
        const pair = needsValue();
        const colon = pair.indexOf(":");
        if (colon < 1) fatal(`--header expects 'Name: value', got ${pair}`);
        entry.headers[pair.slice(0, colon)] = pair.slice(colon + 1).trim();
        break;
      }
      default: fatal(`Unknown option for mcp add: ${flags[n]}`);
    }
  }
  if (command.length > 0) {
    entry.command = command[0];
    entry.args = command.slice(1);
  }
  if (!entry.url && !entry.command) {
    fatal("mcp add needs either --url or a command after --.");
  }
  return normalise(name, entry, "the command line", "agent-lab");
}

function fatal(message) {
  process.stderr.write(`[agent-lab] ${message}\n`);
  process.exit(64);
}

const addMode = process.argv.includes("--add");

const chunks = [];
if (!addMode) {
  for await (const chunk of process.stdin) chunks.push(chunk);
}
const stdin = Buffer.concat(chunks).toString("utf8");

// Keyed by dialect *and* name. An import keeps each agent's servers to its own
// lab, so a Codex definition and a Claude definition that happen to share a name
// are two independent servers, and only sources of the same dialect compete for
// precedence: ~/.claude.json against the directory's .mcp.json, and
// ~/.codex/config.toml against the directory's .codex/config.toml.
const servers = new Map(); // "<dialect>\t<name>" -> record; later sources win
function offer(record) {
  if (!record) return;
  const key = `${record.dialect}\t${record.name}`;
  const previous = servers.get(key);
  if (previous && previous.source !== record.source) {
    note("info", `${record.name}: ${record.source} overrides ${previous.source}`);
  }
  servers.set(key, record);
}

// Which labs a record is installed into. An imported server stays with the agent
// whose configuration defined it; one built by `mcp add` has no dialect of its
// own, so it still goes to both. --only narrows either case.
function labsFor(record) {
  const home = record.dialect === "codex" || record.dialect === "claude" ? [record.dialect] : ["codex", "claude"];
  return home.filter((lab) => LABS.includes(lab));
}

if (addMode) offer(recordFromArgv(process.argv));

for (const line of stdin.split("\n")) {
  if (!line.trim()) continue;
  const [kind, label, encoded] = line.split("\t");
  let text;
  try {
    text = Buffer.from(encoded ?? "", "base64").toString("utf8");
  } catch {
    note("warn", `${label}: could not be decoded, skipped`);
    continue;
  }
  if (kind === "codex-toml") {
    let parsed;
    try {
      parsed = parseToml(text);
    } catch (error) {
      note("warn", `${label}: ${error.message}; skipped`);
      continue;
    }
    for (const [name, entry] of Object.entries(parsed.mcp_servers ?? {})) {
      offer(normalise(name, entry, label, "codex"));
    }
    continue;
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    note("warn", `${label}: ${error.message}; skipped`);
    continue;
  }
  if (kind === "claude-json") {
    // Global scope first, then this directory's local scope, so a local
    // definition of the same name wins.
    for (const [name, entry] of Object.entries(parsed.mcpServers ?? {})) {
      offer(normalise(name, entry, `${label} (user scope)`, "claude"));
    }
    const project = importDir ? parsed.projects?.[importDir] : null;
    for (const [name, entry] of Object.entries(project?.mcpServers ?? {})) {
      offer(normalise(name, entry, `${label} (local scope for this directory)`, "claude"));
    }
    continue;
  }
  for (const [name, entry] of Object.entries(parsed.mcpServers ?? {})) {
    offer(normalise(name, entry, label, "claude"));
  }
}

// ------------------------------------------------------------------ emission

// Codex takes flags; Claude takes the server object verbatim through add-json,
// which is the higher-fidelity path and the reason headers survive on that side.
function codexArgs(record) {
  const args = ["mcp", "add", record.name];
  if (record.transport === "stdio") {
    for (const [key, value] of Object.entries(record.env)) args.push("--env", `${key}=${value}`);
    args.push("--", record.command, ...record.args);
    return args;
  }
  args.push("--url", record.url);
  // Codex can read the bearer token from the environment. Without this the flag
  // is dropped, and a Codex-to-Codex round trip silently loses the server auth.
  if (record.bearerTokenEnvVar) args.push("--bearer-token-env-var", record.bearerTokenEnvVar);
  return args;
}

function claudeArgs(record) {
  const payload =
    record.transport === "stdio"
      ? { type: "stdio", command: record.command, args: record.args, env: record.env }
      : { type: record.transport, url: record.url, headers: record.headers };
  return ["mcp", "add-json", record.name, JSON.stringify(payload), "--scope", "user"];
}

const sorted = [...servers.values()].sort(
  (a, b) => a.name.localeCompare(b.name) || a.dialect.localeCompare(b.dialect),
);
if (sorted.length === 0 && !addMode) {
  note("warn", "No MCP servers found in the configuration that was read.");
}

for (const record of sorted) {
  const targets = labsFor(record);
  if (targets.length === 0) continue;
  if (!record.enabled) {
    note("info", `${record.name}: disabled in ${record.source}; removing it from ${targets.join(" and ")}`);
    for (const lab of targets) emit("mcp_drop", shellQuote(lab), shellQuote(record.name));
    continue;
  }
  const detail = record.transport === "stdio" ? record.command : record.url;
  emit("mcp_server", shellQuote(record.name), shellQuote(record.transport), shellQuote(detail), shellQuote(record.source));
  for (const lab of targets) {
    if (lab === "codex") {
      // `codex mcp add` has no way to write http_headers, and applying a server
      // replaces it. Installing the URL alone would delete a working entry and
      // leave one that cannot authenticate, so leave the Codex copy untouched.
      if (record.transport !== "stdio" && Object.keys(record.headers).length > 0) {
        note("warn", `${record.name}: its ${Object.keys(record.headers).join(", ")} header cannot be set by \`codex mcp add\`, so the Codex lab's copy is left as it is. Set it by hand in the lab's ~/.codex/config.toml if it is not there already.`);
        continue;
      }
      if (record.transport === "sse") {
        note("warn", `${record.name}: declared as SSE; Codex will be given it as a plain URL.`);
      }
      emit("mcp_apply", "codex", shellQuote(record.name), ...codexArgs(record).map(shellQuote));
    } else {
      emit("mcp_apply", "claude", shellQuote(record.name), ...claudeArgs(record).map(shellQuote));
    }
  }
}

process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
