# Bean — plan

## What Bean is

Bean is a brain in the Mac's notch that runs a team of agents, for anyone, not only developers. Each agent is attached to a window of any app: mail, a spreadsheet, a browser, a chat, a design tool, an editor.

1. **Bean is the brain.** The user can talk to it at any time, it is always on, and it orchestrates everything. It knows the user's goals, creates agents and attaches them to any window by itself ("put an agent on Beeper, on Arc, on Claude"), decides what each agent does and when passes work between them, answers for the user when they are away, and gives one report. Agents never decide alone what to work on, and they talk to each other through Bean.
   **Bean does no work itself.** It knows how to do nothing on its own: it finds the solution and shares out the work. Every action goes through an agent, and Bean creates one when none fits. Connectors, Claude sessions and app channels belong to agents, never to Bean.
2. **An agent is attached to a window.** The user creates one in a sentence and drags it onto any window. That window is its work. Without a window it has nothing to do.
3. **An agent works in its window's context, in the background.** It reads the window, finds what it needs (connectors, CLIs, the app's own channels such as scripting and Accessibility actions, a coding agent) and acts without moving the mouse or taking the keyboard. Its abilities come from what it really has there.
   **A connector is a real service, plugin-style:** Linear, GitHub, Granola, connected in one click. CLIs such as `gh` and `git` are not connectors.
4. **The notch is only a status indicator.** A click opens the page: Bean, its agents and their windows, what happened, what it cost.
5. **The chat** is for asking and correcting, mainly with Bean. Work comes from the window and from Bean, not from typed instructions to each agent.

Rules that carry over:

- **Autonomy, nothing hardcoded.** No fixed app, tool, connector or scenario in the code. GitHub and Linear are only test cases, and nothing in the product or its copy assumes a developer.
- **Default limit:** irreversible actions (merge, deploy, delete, send money) stay off unless the user allows them. Everything is in the journal.
- **Off limits:** agents never touch what matches the off-limits list.
- **Costs are a design constraint.** Wake on events, a cheap check before any model call, a budget per agent. Credits left are visible on the page and in every PM update.

## User stories

The PM owns these from A to Z. Each one is done only when it was seen working in the real app, end to end, by someone who did not build it. Any user, nothing specific to Rayan.

**First run**
1. I install and launch Bean: it explains itself in one line, asks only for the permissions it needs and why, and a missing key is clear to fix.
2. Every permission and key problem tells me what to do, and has a button that goes there.

**Bean notices and helps**
0a. Every new piece of information on the Mac (a window opens, a tab or content changes, an action, a call starts) goes through a free local gate (Strands), debounced; on a yes Bean delegates, and I can see what it decided, including when it stayed quiet.
0b. As a new user I understand at once what Bean does, what it sees now and what to do next.
0c. An agent on a window where a call starts detects it, hears it with my consent, and gives a recap and tasks.

**Create an agent and attach it**
3. I describe an agent in one sentence and it exists at once, without waiting on a screen.
4. I drag it from the notch or the page onto any window of any app: it understands that window and starts on what is useful there. Examples: mail (sorts and drafts replies), a spreadsheet (fills and checks it), a browser page (does the research), an editor (reviews the code).
5. I can rename it, change its mission, move it to another window and delete it.
6. It finds what it needs for that window, and connecting something takes one click.
6b. Each agent looks different, and I can change its look.
7. I see what it can do without asking, in plain words, and each switch really blocks the action.
8. It acts in the background, without my mouse or keyboard, and I can keep working in that app.
9. If the app cannot be driven in the background, it says so and offers what it can do instead.

**Bean is the brain**
10. I talk to Bean whenever I want. It creates agents and attaches them to the right windows by itself, or when I ask, and I can see it happen. I give it a goal: it decides which agents act, passes work between them, and reports once. Example: "Prepare Monday's client meeting": one agent reads the mail thread, one fills the deck, and Bean sends me the summary.
11. Bean is always on, with no mode to start or stop (only Pause All): it keeps everything moving, drives Claude sessions when there are some, and answers for me. It answers small things quietly, shows its judgment calls, and asks me only when unsure, with options and a recommended pick.
12. When I open the page after some time: it shows what it decided, what waits for me, what is done and what it cost.
13. I correct a decision, and Bean does it my way from then on.
14. Nothing irreversible happens unless I turned it on, and it stays out of off-limits things.

**Talk to agents**
15. I chat with Bean or any agent in my language, and it answers correctly about its work and about how Bean works.
16. Its actions appear in the same thread, in plain words, with links and undo when possible.

**Stay informed without noise**
17. The notch shows only status; it never talks and never takes focus.
18. When an agent needs me and I am away, I get one notification; the state survives a relaunch, until it is solved.
19. I see the credits left and what each agent spent; it warns at 80% and pauses at 100%.
20. I can pause everything at once, and nothing reads or spends while paused.

**It behaves like a Mac app**
21. Native window, light and dark, keyboard, Dock and Cmd-Tab while the page is open, full screen and Spaces, several displays.
22. Failures are in plain words, never raw errors; every string has a professional tone.

**Demo**
23. The 3-minute video shows stories 3, 4, 10, 11 and 12 with non-developer apps as well as code, and says which parts are external models and tools.

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
- Muse Spark is the brain of Bean and every agent.

## Steps

1. The autonomous agents and their scope, proven on the test repo `RayanBn/bean-demo-prs` and Rayan's personal Linear workspace.
2. The agents page and the notch as a status indicator.
3. The full chain with Bean orchestrating.

## Stack and decisions

| Decision | Choice | Why |
|---|---|---|
| App | Swift, SwiftUI + AppKit, macOS 14+ | The notch overlay (a non-activating `NSPanel` above the menu bar), Accessibility, drag and drop between windows are native APIs. Low memory for an always-on app. |
| Agent brain | Muse Spark, Meta Model API over HTTP, behind `ModelClient` (Meta by default, OpenRouter or any OpenAI-compatible endpoint) | The Meta model at the center of the project. Each user pastes their own key. |
| Decision model | Strands 2B (optional, off by default because it runs third-party code, local, Apache-2.0, not a Meta model, disclosed) filters wake-ups in about 60 ms when the user turns it on; Muse Spark decides on a yes or a hesitation, and alone when Strands is not installed. Strands never acts alone. JEV has an unused client and is not claimed. | Rayan's call on Oct 30, after measuring Strands, Mapika and Llama. |
| Connectors | MCP through the official Swift SDK, OAuth with PKCE and dynamic client registration, tokens in the Keychain | Already proven with Linear (69 tools). |
| Distribution | Run locally for the demo | The Accessibility API is not allowed in the App Store sandbox. |
| Repo | Private on RayanBn during the event, public before submission | |

## Way of working

Inspired by how Lauren Tan (poteto) describes running agents: the code is split by feature, a project `verify` skill drives the real app, and a feature map says how to prove each feature.

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
| D5 | Fri Oct 30 | Pivot to autonomous agents; the GitHub agent works alone on the test repo |
| D6 | Sat Oct 31 | The Linear agent drives Claude sessions; the agents page |
| D7 | Sun Nov 1 | The full chain, with Bean orchestrating |
| D8 | Mon Nov 2 | Polish, one hour of real use |
| D9 | Tue Nov 3 | 3-minute video, README |
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
- **Oct 30 (UX polish, b1c4b4a):** the drop stretches with speed while dragged and sits down mid-flight; a drop on a window touching the menu bar sits on its title bar and stays clickable; two agents on one window move apart with bubbles on opposite sides (the middle ones fold to "…" from 3 up); a folded bubble opens only after 0.45 s of hover; a card from the notch opens below the head; past 3 agents the newest sits next to the camera and hover shows up to 6 heads plus "+"; the split is a small drop that grows on its way to its slot. Bean is a full agent: dragged onto a window it perches, reads, speaks and opens its card (no Delete), and goes home; while it is out, the notch keeps a dotted seat, "+" and the heads. CPU 1.1 % at rest. Open: a card on a window near the left edge covers the drop's bubble; nothing sets "needs you" yet.
- **Oct 30 (top windows and full screen, 62b2fe1):** when there is no room above a window (maximized, touching the menu bar, full screen), the drop hangs inside from the top edge by both hands and its bubble opens below. Agents follow their window into full screen and across Spaces; the notch sits at level mainMenu+3 so Bean can be dragged on a full-screen Space. Proven on real apps (VS Code, Safari, Discord), 22 of 22 cases: maximized, card, touching the menu bar, full screen, other Space, back, out of full screen, and Bean dragged onto full-screen Discord. Open: a drop hung at mid-width of a maximized window sits right under the camera; on a Space swipe the drop disappears and reappears instead of sliding; the card near the left edge covers the bubble; nothing sets "needs you" yet.
- **Oct 30 (agents in the toolbar, b49b604, Rayan's call):** a plugged agent no longer perches above the window. It is a 14 pt badge in the window's own toolbar row: through Accessibility it takes one more slot at the head of the toolbar buttons on the right, with their spacing (VS Code before the layout buttons, Safari before Share, Discord before the inbox). It stays silent; its line shows on hover, for 3 s after a drop, and when it needs the user. In full screen the agent moves up to the notch with a ring in its color, and goes back to the toolbar when the window leaves full screen. Proven on VS Code, Safari and Discord: normal, maximized, under the menu bar, full screen, other Space, back. CPU 2.2 %.
- **Oct 30 (direction change, Rayan's call):** agents work on their own instead of asking for approval, on concrete missions (Linear, GitHub). The notch stops talking; an agents page shows their work. The approval views on branch `ux` (2d1ec8c) are dropped, not merged. Step 2's logic on main (decision, finding `gh`, drafts) is the base to rework.
- **Oct 30 (Rayan's priorities):** the main use case is an agent that replaces the user in their Claude sessions, knowing their tasks and goals. Costs must be kept down, with the credits left reported each time.
- **Oct 30 (Rayan's direction):** agents are attached to windows, Bean is the brain that controls them, and the product is for everyone, not only developers.
- **Oct 30 (evening, on main):** native agents page with Bean first, chat, while-you-were-away, decisions with correction, abilities from each app's real tools, connector tokens in a local file instead of the Keychain. Bean creates and attaches agents, hands work between them, reports once, and reacts on its own after Take Over. Agents act in the background through each app's own channels. Video scenario proven in the real app with one goal across Numbers and Safari ($0.18). Numbers documents are saved to a temp folder first so nothing lands in iCloud. Not in the demo: Mail (a hidden draft reached the Google account), notifications until checked on Rayan's Bean, JEV (not in the code). Before going public: history still contains the off-limits words, and license and icon rights are open; see `bean-research/public-check.md`.
- **Oct 30 (Rayan's test):** agents look alike, Bean is not put forward, no call detected on Arc, an agent reads only the current window, and no event detector feeds the gate. All in progress.
