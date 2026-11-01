# Calls

When a call starts, Bean asks once: nothing is heard until the person says yes. The yes starts the recording, with a visible sign, on Bean first. Bean's judgment then picks who takes the call among its real agents and their jobs, and makes a new agent through the normal maker only if none fits. When the call ends, the chosen agent writes the recap and tasks, which reach the person, and Bean gives out the work in it. An agent whose job needs calls can say so in advance, and Bean sees that when it chooses.

## Sub-features

- `calls-sense`: `CallSense` in `Features/Followup` is a self-contained unit that knows nothing of agents: what it detects, the permissions it needs, and its events (`started`, `recording`, `ended`, `heard`, `failed`). `CallWatcher` finds the process holding the mic. It starts after 3 s (`BEAN_CALL_START_SECONDS`) and ends 8 s after the mic is released (`BEAN_CALL_END_SECONDS`).
- `calls-request`: the tool `request_hearing_calls` writes `hear-calls.json` in the agent's folder. It starts nothing: Bean's roster then says the agent asked to hear calls. The consent question is always on Bean, with `consent`, and options "This call only" and "Not now". After two yeses it also offers "Always listen here", which adds a switch per app on Bean.
- `calls-request-proof`: run `noh-french`: a job in French about meeting recaps asked in 3 of 3 landings, an invoices job in 0 of 2. On the earlier prompt the same French job asked in 2 of 3.
- `calls-choice`: `AgentWorker.agentFor` picks, with `Templates/choose.md`, and logs `choseAgent` in `work.jsonl`. `bean agents choose <work> [free]` runs it alone.
- `calls-listening`: `CallListening` starts the sense, asks, records on a yes, gives the sign to the chosen agent, and on `heard` asks that agent for the recap and tasks and hands them to Bean.

## How to get to it (user POV)

Start a call in any app, and answer the card in the notch.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). A test agent in the run's data, attached to the app under test.
- A key for the model. `BEAN_DECIDER=muse` is enough.
- **Never use a real call or real people without the PM's slot.**

- **Prepare.** `swift .claude/skills/verify/bin/fake-call.swift <script> <dir>` writes `me.caf` and `them.caf`, one line per sentence: `me|<voice>|<text>`. It plays nothing.
- **Request.** `bean agents land-real <sentence> <title>` prints `asked to hear calls`, with `BEAN_KEEP_WORDS=1` to keep the sentence as the goal.
- **App name.** `bean agents call-name <pid> [bundle]` prints the app a helper process belongs to.
- **Off screen.** `BEAN_MIC_FILE=<dir>/me.caf BEAN_THEM_FILE=<dir>/them.caf BEAN_CALL_LOCALE=en_US bean agents hear <agent-id> <seconds>`. It simulates the call. No mic and no system audio are used. `hearing.jsonl` shows `recording` and `transcribed` with frame counts. `<agent-id>` only names the app the call is in. The chosen agent's journal has the recap, and Bean's the hand-off.
- **Detection.** `bean agents call-watch 20` with `swift .claude/skills/verify/bin/holdmic.swift 10` running holds the real mic and prints `start` and `end` with the process chain. The orange dot shows.
- **Language and engine.** `BEAN_TRANSCRIBER=apple|metaVoice` picks the engine, `BEAN_CALL_LOCALE` forces one language. Muse Voice is the default. Apple runs the user's two first languages per track and keeps the better confidence. Muse Voice detects the language, and Apple runs beside it as a backup. Muse Voice sends real audio to Meta: only fake calls in tests.
- **In the app.** It takes a slot: a private call, alone, on a window with an agent. macOS asks once for the microphone and for system audio.

## Gotchas

- The real recorder needs Bean to have the microphone and System Audio Recording permissions, under Bean's own identity: launch with `BEAN_LAUNCH_OPEN=1`. Without system audio, `them` stays silent.
- A window on another Space or a browser's other tab does not matter: detection follows the process, not the tab, so a mic used by any tab of that browser counts.

Detection is the `calls` sense: see `senses.md`. In a test run it needs `BEAN_WATCH_CALLS=1`.
- The calls sense runs whenever Bean is not paused. `--probe-hands callOffer pid:<n> "This call only"` checks it with no paid call.
