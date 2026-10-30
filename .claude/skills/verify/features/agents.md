# Agents

A click on Bean at rest makes Bean look at the Mac (installed and running apps, MCP servers in the user's configs, connectors already in Bean) and ask Muse Spark for 2 or 3 agents that fit this user. A panel under the notch shows them with a field to describe another one. Muse Spark writes the chosen agent: name, role, personality, voice, a greeting and an off-limits line, a hue and an accessory, and the connectors it needs, marked connected or to connect. The agent gets its own folder. Once plugged into a window, the agent reads that window's title and Accessibility text when it changes, keeps a short understanding in its folder, and shows a one-line bubble in its voice. An off-limits window is never read. A click on an agent opens its card: what it understands, its connectors, Unplug and Delete.

## Sub-features

- `agents-propose`: 2 or 3 proposals from the Mac's inventory, each with a pitch and connectors.
- `agents-create`: the written agent, saved as `Agents/<id>/` with `agent.json`, `persona.md`, `lines.json` (greeting, offLimits), `connectors.json` (`connected` or `toConnect`, with the local config or the official registry server when found) and `memory/notes.md`.
- `agents-read`: reading on AX notifications and a 5 s poll, at most one Muse Spark call every 12 s, only when the title or text changed. Writes `memory/window.md`, sets the activity to `reading` then `idle` with the bubble. Logged to `agents.jsonl`.
- `agents-offlimits`: a window whose app, bundle id or title matches off limits is never read; the bubble is the agent's off-limits line and no model call is made.
- `agents-unplug`: unplugging stops the watch, deletes `memory/window.md` and clears the activity.
- `agents-card`: `onAgentClick(id)` opens the card under the notch.

## How to get to it (user POV)

- Click Bean in the notch while it rests.
- Click a proposal, or type in the field and press Return or Create.
- Drag the agent onto a window (creatures side), then click it to open its card.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). A Muse Spark key (`MODEL_API_KEY` in the environment, the repo `.env` or the Keychain). Accessibility granted to the built Bean for reading.

- **Propose.** `bean agents propose` prints the inventory sent to Muse Spark and the proposals. Run `agents-create`: 3 proposals in 8.3 s (ShipIt in Xcode, Noto in Granola, Ping Tamer in Beeper).
- **Create.** `bean agents create "<request>"` prints the folder tree and its files, and the agent id. Run `agents-create`: Patch, cap, hue 0.58, GitHub and node_repl to connect.
- **Read.** `bean fixture "<title>" <file>` opens a window the run owns and prints its pid; `bean agents read <agent-id> <pid> 55` plugs the agent into it, prints every activity change and `window.md`, then unplugs. Edit `<file>` during the run (a first line `title: …` sets the window title) to see a second understanding. Run `agents-read`: a failed build understood in 4.3 s, the passing build 26 s later in 3.9 s, `window.md` deleted after unplug.
- **Off limits.** The same read with `BEAN_OFF_LIMITS=<word in the title>`. Run `agents-read`: one `offLimits` line, no `understood`.
- **Create in the app.** `bean launch`, `bean tap`: the notch thinks, then the panel lists the proposals under the notch (`bean shot` covers only the island; capture the panel with `screencapture -R` under it). `bean fill "<text>"` then `bean press "Create"`, or `bean press "<proposal name>"`, writes the agent; the notch says `<name> is here` and its head joins the crew. `bean frontmost` is unchanged throughout. Run `agents-ui`: Pip from the field, Brick from the BuildBean proposal.
- **Plug and card.** `bean fixture "<title>" <file> onscreen` opens a visible window the run owns; `bean dragout <agent> swift-frontend` perches the agent on it and `agents.jsonl` shows `plugged` then `understood`. A click on the perch (`bean perch <agent>`, then `click.swift` on its center) opens the card; `bean press "Unplug"` logs `unplugged` and removes `memory/window.md`; `bean press "Delete"` then `bean press "Delete <name>"` removes the folder. Run `agents-ui`: Pip understood the chat in 4.9 s.

## Gotchas

- `bean agents read` needs an agent created in the same `BEAN_RUN_ID`, since agents live in the run's data dir.
- The CG window title needs Screen Recording; without it the title comes from AX only.
- Electron apps expose their text only after `AXManualAccessibility` is set on the app, which the reader does.
