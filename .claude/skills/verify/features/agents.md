# Agents

The + in the notch opens a field with 3 ideas that Muse Spark prepared in the background from the Mac's installed and running apps (each a name, a 2-3 word label, a role and a pitch, naming no app). An agent is a personality and a role: it belongs to no app and has no connectors at creation, and any agent can be plugged into any window. On Return or a chip, the agent hatches at once with a color from the request, and Muse Spark writes the chosen agent: name, role, personality, voice, a greeting and an off-limits line, a hue and an accessory. The agent gets its own folder. Once plugged into a window, the agent reads that window's title and Accessibility text when it changes, keeps a short understanding in its folder, and shows a one-line bubble in its voice. An off-limits window is never read. A click on an agent opens its paper card beside it: role, what it sees, its folder, Unplug and hold-to-delete. An agent with a mission and a scope works on its own in the background: on a light timer or when it is dragged onto something, it runs a read-only check, decides with Muse Spark whether there is work, acts with its tools inside its scope, and writes what it did to its journal. An agent still being written has an empty name: the reader skips it, and an unfinished one is removed at the next launch.

## Sub-features

- `agents-propose`: 3 proposals, each a name, a role and a pitch, that name no app.
- `agents-create`: the written agent, saved as `Agents/<id>/` with `agent.json` (`connectors: []`), `persona.md`, `lines.json` (greeting, offLimits) and `memory/notes.md`.
- `agents-read`: reading on AX notifications and a 5 s poll, at most one Muse Spark call every 12 s, only when the title or text changed. Writes `memory/window.md`, sets the activity to `reading` then `idle` with the bubble. Logged to `agents.jsonl`.
- `agents-offlimits`: a window whose app, bundle id or title matches off limits is never read; the bubble is the agent's off-limits line and no model call is made.
- `agents-unplug`: unplugging stops the watch, deletes `memory/window.md` and clears the activity.
- `agents-mission`: `write` extracts `mission.json` from the request: mission, scope (only names literally in the request), allowed, `mayMerge`, `mayDeploy`, `every`. An empty scope means the agent does not act.
- `agents-guard`: every command goes through a guard in code: one plain command, nothing outside the scope or off limits, no secrets, no interpreters. Reads cannot change anything; acts cannot merge, deploy or delete unless the mission allows it; pushes name HEAD, never the main branch. Refusals are journaled.
- `agents-work`: a run reads its check, stays silent if the output did not change, asks `AgentWorker.decider` (Muse Spark today, swappable for JEV), then works with `run_shell`, `act`, connector tools, and ends with `finish` (saving its new check) or `stuck` (mood `needsYou`).
- `agents-sessions`: with `mayRunSessions`, `session_start`, `session_reply`, `session_act` and `session_close` let the agent drive Claude Code like its user, in a worktree of a repo in its scope, with file tools only, no commands, no MCP, $1 per run at most.
- `agents-journal`: `journal.jsonl` in the agent's folder: id, at, kind, did, why, result, link, undo, undoCommand, undoes. `worker.undo` runs an undo command through the guard.
- `agents-card`: `onAgentClick(id)` opens the card under the notch.

## How to get to it (user POV)

- Click Bean in the notch while it rests.
- Click a proposal, or type in the field and press Return or Create.
- Drag the agent onto a window (creatures side), then click it to open its card.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). A Muse Spark key (`MODEL_API_KEY` in the environment, the repo `.env` or the Keychain). Accessibility granted to the built Bean for reading.

- **Propose.** `bean agents propose` prints the app list sent to Muse Spark and the proposals. Run `agents-free`: 3 proposals in 10.6 s (Stack Juggler, Signal Sifter, Lab Buddy), none naming an app.
- **Create.** `bean agents create "<request>"` prints the folder tree and its files, and the agent id. Run `agents-free`: Jip, cap, hue 0.07, `connectors: []`.
- **Read.** `bean fixture "<title>" <file>` opens a window the run owns and prints its pid; `bean agents read <agent-id> <pid> 55` plugs the agent into it, prints every activity change and `window.md`, then unplugs. Edit `<file>` during the run (a first line `title: …` sets the window title) to see a second understanding. Run `agents-read`: a failed build understood in 4.3 s, the passing build 26 s later in 3.9 s, `window.md` deleted after unplug.
- **Off limits.** The same read with `BEAN_OFF_LIMITS=<word in the title>`. Run `agents-read`: one `offLimits` line, no `understood`.
- **Guard.** `bean agents guard <agent-id> read|write|undo "<command>"` prints `allowed` or the refusal, with no model call. Run `agents-gh`: 24 cases as expected.
- **Work.** `bean agents work <agent-id> [runs]` runs the loop and prints the decision, the calls, `journal.jsonl` and `mission.json`. With `BEAN_DRY_RUN=1` the model and the reads are real and no act runs. Run `agents-gh`, dry: found `gh`, read 4 diffs, drafted 4 reviews in 30.8 s; the second run stayed quiet. Without it the acts are real: only on a test repo with the user's go.
- **Coding session.** `bean agents session <agent-id> <repo> <clone-url>` clones the repo into the agent's folder, opens a worktree, starts Claude Code with `--restricted --strict-mcp-config`, resumes it, checks that it cannot read outside the worktree, and closes it. Set `BEAN_SESSION_MODEL=haiku` to keep it cheap. Run `agents-gh`: $0.0015, same session id after the resume, `/etc/hosts` refused, worktree removed.
- **Connector write.** `bean agents connector-write <server__tool> '<json>'` makes one real write, to create or clean up test data. Only with the user's go.
- **Create in the app.** `bean launch`, move the cursor onto the notch, `bean press "New agent"`, `bean fill "<text>"` (move the cursor into the field first), then Return. The drop splits off Bean and hangs under the notch while it forms; its greeting shows under it once Muse Spark has written it. Capture with `screencapture -R` around the notch. Run `ux-live2`: the split in `split-strip2.png`, the greeting and the hint in `greeting.png` and `greeting-hint.png`.
- **Plug and card.** `bean fixture "<title>" <file> onscreen` opens a visible window the run owns; `bean dragout <agent> swift-frontend` perches the agent on it and `agents.jsonl` shows `plugged` then `understood`. A click on the perch (`bean perch <agent>`, then `click.swift` on its center) opens the card; `bean press "Unplug"` logs `unplugged` and removes `memory/window.md`; `bean press "Delete"` then `bean press "Delete <name>"` removes the folder. Run `agents-ui`: Pip understood the chat in 4.9 s.

## Gotchas

- `bean agents work` without `BEAN_DRY_RUN=1` acts for real. Use a test scope, with the user's go.

- `bean agents read` needs an agent created in the same `BEAN_RUN_ID`, since agents live in the run's data dir.
- The CG window title needs Screen Recording; without it the title comes from AX only.
- Electron apps expose their text only after `AXManualAccessibility` is set on the app, which the reader does.
