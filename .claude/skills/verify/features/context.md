# Context

Bean keeps a picture of the whole Mac, rebuilt in the background every 20 s and on every app switch. The picture holds every open app with its windows on all Spaces, the text of the windows Accessibility can read, every browser tab, the user's Claude Code agent sessions with their state, recent zsh commands, files changed in the last 30 minutes, and local dev servers. The brain gets this picture with every question. From it, Bean fires `agentWaiting` when an agent session finished or asks something and the user has not opened it, and `backFromBreak` when the user comes back after a long time away.

## Sub-features

- `context-windows`: every regular app, with window titles from all Spaces (CGWindowList) and text from the windows on the current Space (Accessibility). The focused window gives up to 6,000 characters, the others up to 600. Password apps and secure fields are never read.
- `context-tabs`: every tab of Arc, Chrome, Brave and Safari (AppleScript), with the active one marked. Mail and account hosts are dropped.
- `context-agents`: Claude desktop agent sessions from the last 24 h, each with its title, folder, state (`working`, `asking`, `finished`, `idle`), whether the user has seen its last turn, the open question and the last recap.
- `context-extras`: the last 20 zsh commands, up to 25 files changed in the last 30 minutes under the home folder, and dev servers listening on TCP.
- `context-log`: `context.jsonl` gets one line each time the frontmost window, the tab count or an agent state changes.
- `trigger-agent-waiting`: an agent session that is `asking` or `finished`, not seen, and quiet for `BEAN_AGENT_WAIT_SECONDS` (default 120), fires once per agent turn at a moment the user is not typing (idle 2 s or more) and not in a call. Turns older than 1 h never fire.
- `trigger-back-from-break`: after `BEAN_BREAK_SECONDS` (default 600) without input, the first input fires `backFromBreak` with the minutes away and the agent sessions waiting.

## How to get to it (user POV)

- Run Bean and work. Nothing shows: the picture is internal.
- Let an agent session finish while working in another app. A couple of minutes later, if the turn needs the user, the notch opens with the conclusion and a button.
- Come back after 10 minutes away while agents are waiting.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md), and the [brain](./brain.md) preconditions.
- Bean has Accessibility. The first tab read asks once for Automation of each running browser. Without it, `context-tabs` is empty.

- **Picture.** `bean probe-context` prints the whole picture and a footer like `built in 2.2 s: 11 apps, 6 windows, 60 tabs, 17 agent sessions, ...`. It reads the user's real agent sessions and shell log, read-only. It writes `probe-context.txt`.
- **Agent waiting.** Launch with test folders so the user's real sessions stay out: `BEAN_AGENT_SESSIONS_DIR=$PWD/artifacts/verify/$BEAN_RUN_ID/agents/sessions BEAN_AGENT_TRANSCRIPTS_DIR=$PWD/artifacts/verify/$BEAN_RUN_ID/agents/projects BEAN_AGENT_WAIT_SECONDS=10 bean launch`. Then `bean agent-waiting "<title>" "<last words ending with a question>" [cwd]` writes one session whose last turn ended 4 minutes ago and was never seen. Within 25 s, `bean triggers` has one `agentWaiting` whose `agents` line names the session, `bean gate` has `stepIn: true`, and within 15 s more `bean brain` has an answer.
- **Back from break.** `BEAN_BREAK_SECONDS=20 bean launch`, then do not touch the Mac for 25 s, then move the mouse. `bean triggers` has one `backFromBreak` with `awayMinutes`.
- **Proof.** `probe-context.txt`, the trigger, gate and brain lines, and `bean shot` of the notch.

## Gotchas

- Window text depends on Accessibility. Electron apps (Claude, VS Code, Discord, Slack) expose no text without `AXManualAccessibility`, which Bean never sets. Their titles and the agent session files still come through.
- Windows on other Spaces only give titles, never text.
- A browser tab read takes 1 to 3 s with many tabs, so tabs refresh every 60 s, not every 20 s.
- `bean agent-waiting` writes into the run folder only. Never point `BEAN_AGENT_SESSIONS_DIR` at the real Claude folder in a test.
- `backFromBreak` needs real idle time. Any input on the Mac, including the user's, resets it.
