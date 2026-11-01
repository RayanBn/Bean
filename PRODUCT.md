# Bean: the reference

This page wins over `PLAN.md` and the research reports wherever they differ. Every session reads it first. Only Rayan changes a decision here; the PM keeps the page up to date.

## What Bean is

Bean is a chief that lives in the Mac's notch, for everyone, not only developers. It observes the Mac continuously, understands what needs doing, finds the solution, creates agents and shares out the work. It acts on its own, needs the user as little as possible, and gives one report. The user should almost never have to poke it.

- **Bean sees everything and has no window.** It does not do the work itself: it delegates. A small step in a connected service, such as creating a ticket, is fine.
- **An agent is on one or more apps, never on a window or a tab.** Each whole app is its work: every window, every tab, every document. Putting an agent on an app is the yes to read everything in that app, so it never asks to look there. Dragging it onto another app adds that app, and taking it off one leaves the others. An app that quits stays its own, also across Bean restarts: its head waits in the notch with the app's icon, it returns to the bar with no word when the app reopens, and it may reopen the app in the background or find another route when its work needs it. Off-limits still applies. Writing and acting keep the three questions. The window it shows on is only where it sits, and it follows the app. A coding agent may also run with no app.
- **Agents never contact each other.** They report to Bean, and their questions go to Bean first.
- **Nothing is hard-coded.** No flow, app, tool or scenario in code. Meetings, Claude and Linear are examples only.

## Surfaces, in order of importance

1. **Bean alone.** Nothing to open.
2. **The notch.** State, proposals, questions, the one report, and creating an agent with "+". A question expands the notch and is answered there, as in Vibe Island and CodeIsland.
3. **The drag.** The signature gesture: drag an agent from the notch onto any app, and it works there, in the background, without taking the mouse or keyboard.
4. **The chat with Bean.** Available, secondary. Asking Bean is not the main use.
5. **The control page.** Only for people who want detail or to take over. It is not part of onboarding or of the main path.

## Use cases

1. **Installing.** An onboarding teaches Bean what the user expects of it. A snapshot of the Mac at install time defines nothing.
2. **The main one: the user asks for nothing.** Bean observes, understands, and places or creates agents and gives them work. Examples: it sees you on Claude and offers an agent that keeps your session moving and only calls you for decisions. It sees you start a Meet, plugs an agent on the browser to transcribe it, then delegates the tasks that were asked for.
3. **The drag.** The user describes an agent in a sentence and drags it onto an app.
4. **A real decision belongs to the user.** The notch asks once, in one click.
5. **Returning after being away.** One line says what is done and what waits.
6. **Wanting detail or control.** The control page: live action, changes, terminal, take over.

## How Bean observes and decides

From `bean-research/always-on-evidence.md`, sections 1 and 6 to 9. Watching and acting are two separate machines: watching can change nothing.

1. Every event goes to a local log, with no model call.
2. Code forms moments. A moment names no app: a call started, you stayed in a window, you came back to it, a service changed.
3. A standing answer for this kind of moment applies, with no model.
4. Strands filters what is left, unless the person turned the filter off in Settings. It never decides to interrupt.
5. Muse Spark gets one short call per moment: ignore, remember, offer, or place. An offer must name a concrete result and what Bean saw.
6. **Code decides if a yes is needed, with three questions:** a new source to read? Does it reach someone else? Can it not be undone? Any yes: ask. All no: do it, say so in one line, offer undo.

**Trust grows and falls.** Silent, then offer, then "keep doing it?", then alone saying so, then alone and quiet. A correction moves it back at once. What cannot be undone always asks.

**Ours in the notch, from no product, starting values in `NotchPacer`:** the wiggle on a new agent, one dot per placed agent, and the timings: no card while typing (3 s since a key), a card holds 14 s, a line holds 7 s, an app switch counts as a pause after 30 s on one app. Where everything else in the notch comes from: `side-session-notes`, `notch-sources.md`.

**Starting values, set by the PM, changeable by Rayan, in `Bean/Features/Moments/moments.json`:** a moment after 2 minutes in a window or 3 returns in an hour. "Not now" is quiet for 14 days. An ignored offer expires. A yes for reading covers that app. Hearing a call always shows a visible sign, even on a standing yes. Window titles reach the cloud only after a local private check, unless the person turned the filter off. With the filter on, no check means no title. The main use case needs titles, so Strands is on by default: the first-run flow installs it as part of setup.

**What is proven, and what is Bean's own bet.** Ideas only, no code copied. "Ours" means no open project was found doing it, in the projects below and the earlier reports, so nobody should read it as proven. It is not proof that none exists. Keeping these parts is the PM's decision of Oct 31: having no precedent for local moments is Bean's stated bet.

| Part | Source, at the commit read | Status |
|---|---|---|
| Log of the front window, on the Mac | ActivityWatch `aw-watcher-window` 10638b2, `main.py` | Proven elsewhere |
| Time in a window | ActivityWatch `aw-core` 1dcab4c, `aw_transform/heartbeats.py` | Proven elsewhere |
| Time away, 180 s | ActivityWatch `aw-watcher-afk` b483926, `config.py` | Proven elsewhere |
| A call, from the audio process | screenpipe a6225fa, `meeting_watcher/audio_process/mod.rs` | Proven elsewhere |
| A stored answer with an expiry | goose b23d21c, `permission/permission_store.rs` | Proven elsewhere |
| A closed proposal is not made again | renovate 7137993, `update/branch/check-existing.ts` | Proven elsewhere |
| One short classifier call, input as untrusted data | goose b23d21c, `permission/permission_judge.rs` | Proven elsewhere |
| Code answers approve, ask or reject, outside the model | codex 67f0994, `core/src/safety.rs` | Proven elsewhere |
| Going up by the person's answer | codex 67f0994, `ReviewDecision::ApprovedForSession` | Proven elsewhere |
| The three questions | Docs of dots, Grok and Duet, with no code to read | Closed products |
| An offer expires after 30 minutes | Grok's docs | Closed product |
| Forming a moment from time and returns, and sending it to a model | None found | **Ours** |
| Strands as a filter on moments, its question and 0.167 | Our test: AUROC 0.885 on 40 cards I labelled, weak | **Ours** |
| Ignore, remember, offer, place | `always-on-evidence.md`, section 6 | **Ours** |
| Going up alone after 3 clean runs, going down on an undo | None found | **Ours** |
| 1 offer in 30 minutes, 3 a day | The report's guess. Muse's one push a day is near it (mirror, not proved authentic) | **Ours** |
| Reusing the agent made for a key | None found | **Ours** |
| Sealing by a default name list and by App Store category | `aw-watcher-window` `privacy_filter.py` has the idea, with rules the user writes | **Ours** |
| The private title question and 0.3 | Our test on 24 titles I wrote, weak | **Ours** |

The app seal stays on the Claude app. An agent there can read nothing and send nothing, so the model only judges whether to offer. On any app, when a coding session runs under the window's app (`worker.userSessionLook`), the offer waits until the person has left that window, then offers the take-over. While the session still moves it waits up to 12 minutes. On a sealed app with no such session, it shows fixed words from the skill file, which say what an agent really can do and start no work.

## Onboarding

From `bean-research/onboarding-evidence.md`, corrected by section 10 of `always-on-evidence.md`. Decided by Rayan:

- The user's objective goes to Bean first, and Bean asks what they expect of it, not through an empty box.
- The drag is real, not an animation.
- Setup installs Strands and turns it on, because Bean needs it to read window titles at all.
- The model step: local or cloud, then the provider, then the key. Only Muse Spark exists now, and local comes later.
- It does not ask to observe the user as a request, and it does not read the Mac to define them. It does tell plainly what is observed, and lets the user close things off.

## Architecture

From `bean-research/filesystem-evidence.md`. Two templates ship inside the app, for Bean and for an agent, with default instructions. Each agent has a readable card with its job, what it delivers, when it stays quiet, and its scope and limits. One perimeter rule is enforced in code, and only the person can widen it. Memory is small text files. Running state belongs to code.

**The types every session uses.** Do not read an agent's files directly.

- **Rules.** `Prompts.system(for:)`, `Prompts.chatSystem(for:)`, `Prompts.understanding`, `Prompts.moment`, `Prompts.writing`, from `Bean/Features/Templates/*.md`. `system` is a pure function of the template and the build: never put live data in it. Live data goes in the first message, slowest to fastest.
- **An agent's card.** `AgentFolder(agent, in: store).card` returns an `AgentCard`: `name`, `role`, `job` (`goal`, `output`, `done`, `first`, `quiet`), `targets`, `allow`, `deny`, `readOnly`, `bornFrom`, `leaveWhen`, and `forPrompt`. It is `Agents/<id>/AGENT.md`, readable by a person. Change it with `folder.updateCard { $0... }`. A model never writes it after birth.
- **Its app.** `agent.attachment`, from `state.json`. The app is what counts, and its window fields only say where the agent sits now. Never on the card, so a move cannot leave an old sentence behind.
- **Who takes work no agent was handed by name.** `worker.agentFor(work, on: window, onlyFree:, ifNoneFits:, leaveWhen:, bornFrom:)` asks the model with `Templates/choose.md`, from the real agents and their jobs, and logs `choseAgent`. A call, a moment and a taken-over session all go through it. Code only checks that the name is real and keeps Stop.
- **An agent gets made one way.** `worker.createAgent(from: sentence, bornFrom: .moment(words), on: window, leaveWhen: "the window closes, or 7 quiet days")`, behind `agentFor` when Bean is choosing. `bornFrom` is `.person`, `.drag`, `.moment` or `.bean`. Pass `readOnly: true` for reading on, with outward and irreversible off. Give it a first task with `worker.runHandedOff`.
- **Its limits.** `worker.perimeter(for: agent)` returns a `Perimeter`, read on the main actor: `refusal(AgentAction)` before any action, `isAllowed(ability)`, `turnedOff`, `halted` and `promptLine`. Off the main actor, `Perimeter(folder:window:)`. Nothing else decides, and no site calls `ActionGuard` or `AppGuard` directly. `evals/refusals.json` is the table it must keep.
- **A moment.** `MomentAnswer.ask(about:)` runs `Templates/moment.md` with its own schema, apart from `understand`. It returns a proposal. Code decides whether a yes is needed.
- **What Bean may read.** `WindowChannels.forBean()` lists windows after off limits and the local private check. With the filter on and no local check, because Strands is missing, failed or set to Cloud, no title goes out and no moment reaches the model: Bean sees the app and the window number, and the person drags an agent on. Only the person can turn the filter off, in Settings > AI (`BeanSettings.filtersWhatBeanSees`). Then titles and moments reach the chosen model unchecked. Off limits, sealed apps, the three questions, `ReadingYes`, Stop and the quiet rules still apply. `ReadingYes.add(bundleId)` records a yes for an app, and `read_window` reads only windows an agent holds or apps with a yes.
- **What the person wants.** The onboarding writes the objective with `Goals.add(words)`, and a new objective with `Goals.replace(old, with: words)`, which keeps the old one marked superseded. They go to `goals.md` in the data folder. Read them with `Goals.text`. Bean's prompt prints them, and agents get what they need through hand-offs.
- **Memory, one writer each.** `notes.md`: the agent, through the `memory` tool, 1,500 characters. `corrections.md`: code, from the person's answers, 1,500. `user.md`: only a run the person started, or what they said in chat, 800, dated. `goals.md`: code, from the person's words, 2,000, dated. What is watched, or guessed, never goes in `user.md`.

**No `bean.sqlite` for now (decided).** Readable files and one writer per fact are what hold up today, and the import risks more than it gains. Real data is small, the writes that could overwrite each other now append, and a database would not stop the same work getting a new id. New running state goes in a `JSONLog` or one JSON file with one writer. Evidence: `side-session-notes`, `bean-sqlite-decision.md`.

Merging code stays off whatever any switch says, until Rayan decides otherwise: `AbilityFinder.opensMerge` and `ActionGuard.mergeRefusal`.

## Rules for every session

- **Evidence over invention.** Use patterns from products that proved them, and name the source. Copy ideas only: never code or prompt text. Only code written during the hackathon. An outside library is named in the README.
- **No time limit in what you recommend or build.** Say what is true, and the PM handles the calendar.
- **Cost is not a user feature.** No spend, credits or budget on the user's screens or in their copy. It stays internal, to protect the user's money and the demo.
- **Paid model calls are scarce: $5 in total for all parts from Nov 1.** Use the build, offline probes, recorded data and fake data first. Every paid run needs the PM's go and counts against the part's cap, including direct calls.
- **Done means seen working in the real app,** with screenshots or log lines. Say what was not seen.
- **The screen is shared.** Use `BEAN_WINDOW_FILTER`, test data folders and the sandbox repo. Never Mail, the real Claude app or real Linear. Wait if Rayan is on the Mac. Check the frontmost app before each real key, and never leave a modifier key held. Never quit anyone else's Bean.
- **Merging:** your own worktree, rebase on `main`, merge and push. Never commit a key. Delete your test data.
- **Reversible safety rules in code are fine:** they protect the user. Say so when a rule decides something a model would otherwise judge.
- **Safety rule: an agent stays on its own app.** Putting an agent on an app is the reading yes for that app, for as long as it is there: nothing is kept after it leaves. `app_script` refuses a script that names another app, a position instead of a document's title, or anything off limits, and one that moves the person's view or runs code on a page. Off limits filters every window and tab in `app_windows`, `app_window_read` and `tab_read`. Code decides this, not the model: `WindowChannels.refusal`, `AppGuard.refusal`.
- **Safety rule: a sleeping tab wakes only out of sight.** A tab the browser put to sleep answers no script, and only selecting it wakes it. Waking runs its page, so `tab_read` never wakes one by itself: the model weighs its title and address and asks with `wake`, and a live call, a room or playing media stays asleep unless the person asked for that very tab. The step is shown. `AppTabs` selects it and goes back in one script, and only when no window of the app is on screen: nothing shows, and the front app, active tab and active space end as they were. On screen it shows for about 50 ms, so it waits until the person has left, then the agent gets a new run. Agents still never select a tab themselves. Code decides this, not the model.
- **Safety rule: Stop is the user's decision.** A session the user stopped, and the plan steps not yet done around it, restart only after they speak again or press Resume. No wake, plan check or hand-off restarts them, across a relaunch too. Code decides this, not the model: `StoppedWork` and `stoppedWorkRefusal`.

## What an agent says

- **Nothing is hard-coded.** No code forces an agent to act, speak, keep quiet or skip a question. Landing on an app starts no scripted action. The agent judges from its job, and its prompt says how it should judge.
- **What good judgment looks like.** It does not recite what it sees. It speaks with a result or one of the three questions. It looks through the app before asking. When there is nothing worth saying, it says nothing.
- **Putting an agent on an app is the person's yes.** Nothing an app shows is held back from the agent on it, apart from the person's own off-limits list.
- **The onboarding window speaks for Bean alone.** No agent talks in it.
- **An agent sits in the app's own bar, as Bean's own window placed there.** Bean finds a free place in the bar of any app by detecting it, with no app named in the code. Nothing enters the app. With no place in the bar, the agent is on the app all the same and shows in the notch with the app's icon, until a place appears.

## Out for now

Local models (after), a second coding CLI, a marketplace, live call transcription.
