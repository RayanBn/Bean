# Bean — plan

## What Bean is

Bean is an agent manager that lives in the Mac's notch. Each agent has its own personality, and the user plugs it into the app where it should help.

1. At first there is only **Bean**. It lives in the notch and offers to create the user's first agent.
2. The user creates an agent with Bean, for example a code agent or an agent for private conversations. Each agent has:
   - its personality;
   - its own folder of files, its memory;
   - its connectors: the code agent needs GitHub, the conversations agent Discord or another messaging app.
3. The user plugs the agent into an app by dragging it from the notch onto the app's window, with an animation. The code agent goes on VS Code or another IDE, the conversations agent on Discord or another messaging app.
4. The agent works in that app's context:
   - in the background whenever it can;
   - it never takes over the Mac without asking. If it really has to act in the app, it asks first, and the user is never blocked.
5. Bean orchestrates, and stays discreet. It does not step in all the time. JEV decides when an agent acts, and which one.

Rules that carry over:

- **Autonomy, nothing hardcoded.** No fixed app, tool, connector or scenario in the code. Bean proposes an agent's connectors from what the user has; the demos only test that.
- **Ask before anything irreversible or outward** (a message sent, a push, a ticket created).
- **Discord:** the conversations agent drafts replies and the user approves the send. Automating a user account is against Discord's rules.

## Hackathon

- **Event:** Meta Global AI Developer Hackathon. Indie Developer track, solo.
- **Theme:** "Push the Frontier", software.
- **Dates:** Monday Oct 26 to Wednesday Nov 4, 2026.
- **Deadline:** Wed Nov 4, 9:00 PM ET (Thu Nov 5, 3:00 AM Paris). Submit at https://cerebralvalley.ai/e/meta-ai-developer-hackathon/hackathon/submit
- **Submission:** public repo, working demo video link (3 minutes, one of the main scoring items).

Rules that can disqualify:

- Everything presented is built between Oct 26 and Nov 4. The first commit is on Oct 26.
- The demo shows only what was built during the event. Judges must be able to tell what is new: say clearly which parts are external models and APIs.
- No code, data or assets without the rights to them.
- The project builds on Meta Model API, Muse Code or Meta's open-weights models.
- Banned generic projects include simple image analyzers. Bean must read as an agent that acts, not as a screenshot analyzer.
- Muse Spark stays the brain of every agent. JEV only decides when to act, since it is not a Meta model.

## Steps

Start simple, then grow the idea step by step.

1. Bean in the notch creates an agent: personality, folder, one connector. The agent shows in the notch. The user drags it onto a window, and it reads what happens there.
2. The agent helps, in the background, through its connectors.
3. Bean orchestrates several agents with JEV.
4. When really needed, the agent acts in the app, always after asking.

Demo agents: the code agent and the conversations agent (Rayan's call on Oct 30, for now).

Still to decide:

- How an agent looks in the notch and once on a window: a small minion-like creature (the PM proposes).
- The drag animation. References: Coucou (Mochi dragged onto a window to attach it as context), Super Notch (a floating agent over a window), LoomWatch (an agent that flies out of the notch). Inspiration only, no code.

## Stack and decisions

| Decision | Choice | Why |
|---|---|---|
| App | Swift, SwiftUI + AppKit, macOS 14+ | The notch overlay (a non-activating `NSPanel` above the menu bar), Accessibility, drag and drop between windows are native APIs. Low memory for an always-on app. |
| Agent brain | Muse Spark, Meta Model API over HTTP, behind `ModelClient` (Meta by default, OpenRouter or any OpenAI-compatible endpoint) | The Meta model at the center of the project. Each user pastes their own key. |
| Decision model | JEV (`typesafe-ai/jev`), with Rayan's own access | Built for calibrated yes/no scores. Not wired yet. |
| Connectors | MCP through the official Swift SDK, OAuth with PKCE and dynamic client registration, tokens in the Keychain | Already proven with Linear (69 tools). |
| Distribution | Run locally for the demo | The Accessibility API is not allowed in the App Store sandbox. |
| Repo | Private on RayanBn during the event, public before submission | |

## Way of working

Copied from how Lauren Tan (poteto) runs her agents: the code is split by feature, a project `verify` skill drives the real app, and a feature map says how to prove each feature.

Code by feature:

- `Bean/Features/<Feature>/` holds everything one feature needs: views, logic, data types. `Bean/App/` only creates the features and wires them together.
- Today: `Notch`, `MenuBar`, `Brain` (the model client and the tool loop), `Connectors`. `Bean/Shared/BeanSettings.swift` holds the settings, and environment variables override them for verification. `Bean/Shared/` also holds `JSONLog`, `Accessibility` (AX reads), `HiddenShell`, `OffLimits`, `APIKeyStore` and `AIProvider`.
- Other features drive the notch only through `NotchController`'s methods (`notice`, `think`, `show(NotchMessage)`, `done`, `rest`).
- A feature uses another only through the types and methods it exposes (the gate reads `Signal`, not `SignalCollector` internals).
- One session owns one feature folder. Parallel sessions never edit the same folder. Code that two features need moves to `Bean/Shared/`, and only then.
- Each feature folder has a matching file in the verify feature map, with the same name.

Proof:

- `.claude/skills/verify/` builds, launches and drives Bean (`bin/bean`), and keeps proof in `artifacts/verify/<run>/`.
- `.claude/skills/verify/features/` holds one file per user-facing feature: sub-feature IDs, user entry points, the exact commands that drive it and the observable result, and gotchas.
- Done means a `verify` run on the feature's file passed, with its screenshots and log lines cited. A new feature or a changed behavior updates its feature file in the same commit.
- `/maintain-verification-skill` keeps the map honest when the app changes.

## Day-by-day plan

| Day | Date | Goal |
|---|---|---|
| D5 | Fri Oct 30 | Pivot: old code removed. Step 1: create an agent, drag it onto a window |
| D6 | Sat Oct 31 | Step 2: the code agent helps through GitHub, in the background |
| D7 | Sun Nov 1 | The conversations agent; step 3: Bean orchestrates with JEV |
| D8 | Mon Nov 2 | Polish the demo, step 4 if time allows |
| D9 | Tue Nov 3 | 3-minute video, README that shows what was built during the event |
| D10 | Wed Nov 4 | Buffer, repo public, submit |

## Status

- **Oct 26–29 (first Bean, kept under the tag `old-bean`):** a notch assistant that watched the whole Mac and took control of it. Proven live: learning a repeated task and finishing it (Safari, Arc on real GitHub), hiding secrets during a screen share, putting a project's windows back, connectors with Linear. Rayan disliked that it took over the Mac and blocked him.
- **Oct 30 (pivot):** Bean becomes an agent manager in the notch (see What Bean is). The old features are removed: Actions, Browser, Context, Followup, Gate, Inspector, Inventory, Presence, Repo, Resume, Routines, Shell, Signals, StreamGuard, Triggers, the trigger brain, the screen overlay, ONNX Runtime. Kept: the notch and its mascot, the menu bar popover (provider, key, off limits), `ModelClient` with the tool loop, connectors with OAuth, `HiddenShell`, `Accessibility`. The old sessions are archived.
