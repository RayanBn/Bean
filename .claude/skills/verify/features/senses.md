# Senses

What an agent can notice on the Mac. `Bean/Features/Senses/senses.json` lists them; each names a compiled driver (`SenseDrivers.swift`). An agent's folder holds its `senses.json` subscriptions. Bean holds Calls and Windows until it has its own file. A driver runs only while something subscribes or holds it, and stops on Pause All.

Pipe: driver, taps (hearing), off-limits, subscribers, `EventGate` (settle, repeat window, own change, pause, Strands or filter), then a wake of Bean that names the agents watching.

## Tags

- `senses-tools`: `list_senses`, `request_sense`, `drop_sense`. The card is an `AgentNeed` with `consent` set to the sense id.
- `senses-pipe`: `call.started`, `window.*`, `service.changed` reach the gate log. Nothing reaches it when no one subscribes.
- `senses-off`: the switch in the inspector's Notices section. Not seen on screen yet.

## How to check, off screen

With `BEAN_DATA_DIR`, `BEAN_WINDOW_FILTER=<own word>`:

- `bean agents senses <agent-id> list | request <id> <why> [tool] | allow | refuse | off <id> | on <id> | drop <id>`
- `BEAN_FAKE_CALL_FILE=<path>`: the file existing means a call. `BEAN_WATCH_CALLS=1` uses the real watcher in a test run instead.
- `BEAN_SENSE_FAKE_FILE=<path>` with the tool `fake__read`, and `BEAN_SENSE_EVERY=<s>`: a fake service in the probes.
- `bean agents events <seconds>` prints the gate decisions.
