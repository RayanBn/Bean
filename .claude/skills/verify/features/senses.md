# Senses

What an agent can notice on the Mac. `Bean/Features/Senses/senses.json` lists them; each names a compiled driver (`SenseDrivers.swift`). An agent's folder holds its `senses.json` subscriptions. Bean holds Calls and Windows until it has its own file. A driver runs only while something subscribes or holds it, and stops on Pause All.

Pipe: driver, taps (hearing), `EventLog` (every event, no window text), `MomentDesk` (moments, standing answers, Strands filter, one `MomentAnswer`, three questions). A change in an app with an agent on it goes straight to that agent: its `Watch` waits for a stable page (`stablePageSeconds` in `moments.json`), `AgentWorker.heard` scores it with Strands against that agent's job, journal and todo list, and what passes wakes that agent, in one message per free moment, deduplicated by page. `gate.jsonl` keeps those scores with the agent's name. Events an agent subscribed to in an app with no agent still reach `EventGate` (settle, repeat window, own change, pause, Strands or filter), then a wake of Bean. Offline proof: `--probe-agents moment-checks`, `moments-replay`, `moment-filter`, `moment-live`.

## Tags

- `senses-tools`: `list_senses`, `request_sense`, `drop_sense`. What an agent's own app shows comes with being on it: no card, and the sense covers that app only. A connected service, or an agent on no app, gets a card: an `AgentNeed` with `consent` set to the sense id. `BEAN_WATCH_APPS=1` observes real app switches in a test run.
- `senses-pipe`: `call.started`, `window.*`, `service.changed` reach the gate log. Nothing reaches it when no one subscribes.
- `senses-off`: the switch in the inspector's Notices section. Not seen on screen yet.

## How to check, off screen

With `BEAN_DATA_DIR`, `BEAN_WINDOW_FILTER=<own word>`:

- `bean agents senses <agent-id> list | request <id> <why> [tool] | allow | refuse | off <id> | on <id> | drop <id> | ask <text>`
- `BEAN_FAKE_CALL_FILE=<path>`: the file existing means a call, in the window whose title the file holds, or the first window when it is empty. `BEAN_WATCH_CALLS=1` uses the real watcher in a test run instead.
- `BEAN_SENSE_FAKE_FILE=<path>` with the tool `fake__read`, and `BEAN_SENSE_EVERY=<s>`: a fake service in the probes.
- `bean agents events <seconds>` prints the gate decisions.
