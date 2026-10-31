# Bean: the reference

This page wins over `PLAN.md` and the research reports wherever they differ. Every session reads it first. Only Rayan changes a decision here; the PM keeps the page up to date.

## What Bean is

Bean is a chief that lives in the Mac's notch, for everyone, not only developers. It observes the Mac continuously, understands what needs doing, finds the solution, creates agents and shares out the work. It acts on its own, needs the user as little as possible, and gives one report. The user should almost never have to poke it.

- **Bean sees everything and has no window.** It does not do the work itself: it delegates. A small step in a connected service, such as creating a ticket, is fine.
- **Each agent is attached to one window of any app.** That window is its work. A coding agent may also run with no window.
- **Agents never contact each other.** They report to Bean, and their questions go to Bean first.
- **Nothing is hard-coded.** No flow, app, tool or scenario in code. Meetings, Claude and Linear are examples only.

## Surfaces, in order of importance

1. **Bean alone.** Nothing to open.
2. **The notch.** State, proposals, questions, the one report, and creating an agent with "+". A question expands the notch and is answered there, as in Vibe Island and CodeIsland.
3. **The drag.** The signature gesture: drag an agent from the notch onto any window, and it works there, in the background, without taking the mouse or keyboard.
4. **The chat with Bean.** Available, secondary. Asking Bean is not the main use.
5. **The control page.** Only for people who want detail or to take over. It is not part of onboarding or of the main path.

## Use cases

1. **Installing.** An onboarding teaches Bean what the user expects of it. A snapshot of the Mac at install time defines nothing.
2. **The main one: the user asks for nothing.** Bean observes, understands, and places or creates agents and gives them work. Examples: it sees you on Claude and offers an agent that keeps your session moving and only calls you for decisions. It sees you start a Meet, plugs an agent on the browser to transcribe it, then delegates the tasks that were asked for.
3. **The drag.** The user describes an agent in a sentence and drags it onto a window.
4. **A real decision belongs to the user.** The notch asks once, in one click.
5. **Returning after being away.** One line says what is done and what waits.
6. **Wanting detail or control.** The control page: live action, changes, terminal, take over.

## How Bean observes and decides

From `bean-research/always-on-evidence.md`, sections 1 and 6 to 9. Watching and acting are two separate machines: watching can change nothing.

1. Every event goes to a local log, with no model call.
2. Code forms moments. A moment names no app: a call started, you stayed in a window, you came back to it, a service changed.
3. A standing answer for this kind of moment applies, with no model.
4. Strands filters what is left. It never decides to interrupt.
5. Muse Spark gets one short call per moment: ignore, remember, offer, or place. An offer must name a concrete result and what Bean saw.
6. **Code decides if a yes is needed, with three questions:** a new source to read? Does it reach someone else? Can it not be undone? Any yes: ask. All no: do it, say so in one line, offer undo.

**Trust grows and falls.** Silent, then offer, then "keep doing it?", then alone saying so, then alone and quiet. A correction moves it back at once. What cannot be undone always asks.

**Starting values, set by the PM, changeable by Rayan:** a moment after 2 minutes in a window or 3 returns in an hour. "Not now" is quiet for 14 days. An ignored offer expires. A yes for reading covers that app. Hearing a call always shows a visible sign, even on a standing yes. Window titles reach the cloud only after a local private check.

## Onboarding

From `bean-research/onboarding-evidence.md`, corrected by section 10 of `always-on-evidence.md`. Decided by Rayan:

- The user's objective goes to Bean first, and Bean asks what they expect of it, not through an empty box.
- The drag is real, not an animation.
- The model step: local or cloud, then the provider, then the key. Only Muse Spark exists now, and local comes later.
- It does not ask to observe the user as a request, and it does not read the Mac to define them. It does tell plainly what is observed, and lets the user close things off.

## Architecture

From `bean-research/filesystem-evidence.md`. Two templates ship inside the app, for Bean and for an agent, with default instructions. Each agent has a readable card with its job, what it delivers, when it stays quiet, and its scope and limits. One perimeter rule is enforced in code, and only the person can widen it. Memory is small text files. Running state belongs to code.

## Rules for every session

- **Evidence over invention.** Use patterns from products that proved them, and name the source. Copy ideas only: never code or prompt text. Only code written during the hackathon. An outside library is named in the README.
- **No time limit in what you recommend or build.** Say what is true, and the PM handles the calendar.
- **Cost is not a user feature.** No spend, credits or budget on the user's screens or in their copy. It stays internal, to protect the user's money and the demo.
- **Paid model calls are scarce.** Use the build, offline probes, recorded data and fake data first. Every paid run counts against the part's cap, including direct calls.
- **Done means seen working in the real app,** with screenshots or log lines. Say what was not seen.
- **The screen is shared.** Use `BEAN_WINDOW_FILTER`, test data folders and the sandbox repo. Never Mail, the real Claude app or real Linear. Wait if Rayan is on the Mac. Check the frontmost app before each real key, and never leave a modifier key held. Never quit anyone else's Bean.
- **Merging:** your own worktree, rebase on `main`, merge and push. Never commit a key. Delete your test data.
- **Never use anything from CoffeeBean or LinkedList LLC.**
- **Reversible safety rules in code are fine:** they protect the user. Say so when a rule decides something a model would otherwise judge.

## Out for now

Local models (after), a second coding CLI, a marketplace, live call transcription.
