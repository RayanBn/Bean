# Bean — plan

## What Bean is

Bean is an agent manager that lives in the Mac's notch. Each agent has its own personality, and the user plugs it into the app where it should help.

1. At first there is only **Bean**. It lives in the notch and offers to create the user's first agent.
2. The user creates an agent with Bean. An agent is a personality and a role, with its own folder of files, its memory. No agent is tied to an app, and none has connectors set in advance.
3. The user plugs any agent into any window by dragging it from the notch onto that window, with an animation.
4. The agent works in that window's context:
   - it works out what it needs there, connectors included, when it needs them;
   - in the background whenever it can;
   - it never takes over the Mac without asking. If it really has to act in the app, it asks first, and the user is never blocked.
5. Bean orchestrates, and stays discreet. It does not step in all the time. JEV decides when an agent acts, and which one.

Rules that carry over:

- **Autonomy, nothing hardcoded.** No fixed app, tool, connector or scenario in the code, and no agent bound to an app or a connector. The demos only test that.
- **Ask before anything irreversible or outward** (a message sent, a push, a ticket created).
- **Discord:** an agent on a Discord window drafts replies and the user approves the send. Automating a user account is against Discord's rules.

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

1. Bean in the notch creates an agent: personality, role, folder. The agent shows in the notch. The user drags it onto any window, and it reads what happens there.
2. The agent helps, in the background. It finds the connectors it needs for the window it is on.
3. Bean orchestrates several agents with JEV.
4. When really needed, the agent acts in the app, always after asking.

Demo agents: one plugged into a code window, one into a conversation (Rayan's call on Oct 30, for now). Any agent can go on any window.

Still to decide:

- Done: the look is a polished Drop (Rayan's pick: the Light finish plus a shine that sweeps across). The drag animation references were: Coucou (Mochi dragged onto a window to attach it as context), Super Notch (a floating agent over a window), LoomWatch (an agent that flies out of the notch). Inspiration only, no code.

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
- **Oct 30 (step 1, agents and creatures):**
  - Creating an agent: a click on Bean at rest opens a panel under the notch. Muse Spark looks at the Mac's apps and connectors and proposes 3 agents, for example Forge for Code with GitHub, Linear and Slack. The user picks one or describes their own. Muse Spark writes the agent (name, role, personality, look, connectors), saved in its own folder, with connectors not yet connected marked "to connect". The panel takes no focus away from the app the user is in.
  - Creatures: agents peek out of the notch next to Bean ("+N" past 3). Dragged out, an agent dangles from the cursor and the window under it lights up. Dropped, it sits on the window's top edge, follows it, hides with it, and goes home when dragged back.
  - Reading: a plugged agent reads its window's title and Accessibility text on changes and says what it sees in its own voice, for example "ok so maya needs onboarding flow eyes before friday!" in 4.9 s. Off limits stops the read, with no model call. A click on the agent opens its card: what it understands, its connectors, Unplug and Delete.
  - Not proven: reading VS Code (Electron) on a real window, Space change and full screen.
  - Then (same day): agents are free of any app. Proposals name no app or service, and a new agent has no connectors (`connectors: []`). Real run: "Stack Juggler", "Signal Sifter", "Lab Buddy" in 10.6 s, then "Jip" with its persona, lines and memory folder. The notch says "Thinking of agents for you" while Bean prepares them.
  - The look is a polished Drop: soft gradient, gloss, soft shadow, a catchlight, and a shine that sweeps across a perched or dragged drop every 8 s. The perched drop shows its bubble beside it, with its mood. Seen only in off-screen renders of the app's views, not yet in the live notch.
- **Oct 30 (UX pass, direction A "Liquid", Rayan's pick):**
  - Bean is a pearl drop with the same eyes as its agents; the green eyes are gone. At rest, the notch shows Bean, the agents' heads and a "+".
  - Creating: "+" opens a field in the notch, caret ready, with 3 ideas Muse Spark prepared in the background, so nothing waits. Return splits a new drop off Bean in 0.5 s. It is draggable at once, its color fills while Muse Spark writes its name and voice, then it greets in a paper bubble and says "Drag me onto any window."
  - Drag: a liquid thread pulls it out of the notch and snaps; the drop lands on the window with a splash. A paper bubble (warm white, ink text, a tail, no glow) says what it sees, for example "3 PRs queued, #212 stalled since Tuesday" in 6.4 s. The card is paper too and opens beside the drop; Unplug flies it home.
  - Light from the top on the drops (nothing reads as an eyebrow). CPU 0.63 % at rest, 1.6 % while a drop forms. The app in front never changed.
  - Not done: nothing sets "needs you" yet (its glow is only rendered off screen); the dotted-arc hint toward a window is replaced by the greeting line; reading VS Code, Space change and full screen are still unproven.
