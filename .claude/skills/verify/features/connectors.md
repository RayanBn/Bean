# Connectors

Bean reaches the user's tools through MCP servers, whatever they are. It finds them in the user's own configs (`~/.claude.json`, Claude Desktop, `~/.codex/config.toml`, Cursor, VS Code, the folder's `.mcp.json`) and in the public MCP registry, connects with the official MCP Swift SDK (stdio for local servers, HTTP with OAuth for remote ones: PKCE, dynamic client registration, loopback redirect, tokens in the Keychain), and gives each server's tools to the brain as `<server>__<tool>`. Reads run while Bean thinks; writes become notch cards that show their arguments; destructive tools are hidden. When nothing fits, the brain can propose `connect` to a server it found.

## Sub-features

- `connectors-discover`: local servers from every known config (names, commands, env keys only, never values), and registry results for one word, `official` when the remote host matches the namespace's domain.
- `connectors-attach`: a connected server's tools are listed once per session and refreshed on `listChanged`.
- `connectors-tools`: at most 16 tools per server (up to 8 reads and 8 writes, ranked by the event's words, a match in the tool's name worth ten in its description), schemas sanitized for an OpenAI-compatible endpoint. `brain.jsonl` lists every offered tool in `offered`.
- `connectors-search`: `connector_tools` searches all of a connected server's tools for a few words and adds the matches to the brain's tools for its next turn.
- `connectors-connect`: the `connect` card connects, runs OAuth when the server asks, saves the server in `connectors.json`, and returns its tools.

## How to get to it (user POV)

- Nothing to set up: Bean finds the servers the user already configured, and proposes one from the registry when the work needs it.
- Click the `connect` card to add a server; the browser opens for its sign-in when it needs one.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). Network access for the registry.

- **Discover and attach.** `BEAN_DATA_DIR=$PWD/artifacts/verify/$BEAN_RUN_ID build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean --probe-connectors rea` prints the local servers, the registry results for `linear`, the attach time and every brain tool with its effect. Run `core-connectors`: 4 local servers, `app.linear/linear (official)`, rea 207 tools in 12 s (40 read, 135 act, 32 hidden), 14 brain tools exposed.
- **Remote OAuth.** `BEAN_DATA_DIR=<run>/data … --probe-connectors-remote <name> <url>` runs the full OAuth flow (the browser opens, the user signs in), stores the token in the Keychain (`dev.rayanbn.Bean.mcp`/`<name>`) and saves the server in that folder's `connectors.json`. Run `core-linear` (Rayan's go, his personal workspace): Linear signed in, 69 tools.
- **Read.** `--probe-connector-read <name> <tool> '<json>'` calls one read tool of a saved server without a browser; `<tool>` `*` lists every tool with its kind. Run `core-linear`: `get_user` = Rayan's personal account, `list_teams` = one team.
- **Proof.** The probe output and, once run, the `connect` card in `bean shot` and `connectors.json`.

## Gotchas

- A stdio server is started only when its command and arguments match an entry of the user's own config.
- Names that contain delete, remove, archive, destroy, drop, purge or merge are hidden, which can hide a harmless tool. `destructiveHint` does not hide a tool: the MCP spec makes it true by default for every write, and Linear sets it on `save_issue`.
- After `connect`, the new tools reach the brain at the next event.
