# Context

Bean listens to events and never polls. Light state is kept up to date by file events: what each app is working on (learned read recipes, rerun when the files they read change), changed files (FSEvents on the home folder, `~/Library` and dot folders excluded) and zsh commands (a file event on `shell.jsonl`). The full picture of the Mac is assembled only when the brain needs it, in about 2 s. The picture holds every open app with its windows on all Spaces, the text of the windows Accessibility can read, every browser tab, what the user's apps are working on (sessions, documents, jobs) with their state, recent zsh commands, files changed in the last 30 minutes, and local dev servers. The brain gets this picture with every question. No app is known in advance: after an app has been in front for `BEAN_WATCH_LEARN_MINUTES` (default 10) in total, Bean learns by itself, in a sandbox, a read recipe that prints what the app is working on (see [actions](./actions.md), recipes). From it, Bean fires `unseenChange` when something in an app changed state while the user was elsewhere and they have not opened that app since, and `backFromBreak` when the user comes back after a long time away.

## Sub-features

- `context-windows`: every regular app, with window titles from all Spaces (CGWindowList) and text from the windows on the current Space (Accessibility). The focused window gives up to 6,000 characters, the others up to 600. Password apps and secure fields are never read.
- `context-tabs`: every tab of Arc, Chrome, Brave and Safari (AppleScript), with the active one marked. Mail and account hosts are dropped.
- `context-activities`: for each app with a learned read recipe, its items of the last 24 h (title, state `working`/`waiting`/`done`/`idle`, `needsUser`, the question or last words) and whether the user has looked at the app since the item changed.
- `context-extras`: the last 20 zsh commands, up to 25 files changed in the last 30 minutes under the home folder, and dev servers listening on TCP.
- `context-learn`: an app used long enough with no read recipe gets one learned in the background (at most 4 a day, one at a time), logged in `learning.jsonl`.
- `context-log`: `activities.jsonl` gets one line each time an item changes while its app is not in front.
- `trigger-unseen-change`: an item that changed while its app was not in front, still unseen after `BEAN_WAIT_SECONDS` (default 120), fires once per change at a moment the user is not typing (idle 2 s or more) and not in a call. Activating the app marks its items seen. Changes older than 1 h never fire. Several items go in one trigger (`waiting`).
- `trigger-back-from-break`: after `BEAN_BREAK_SECONDS` (default 600) without input, the first input fires `backFromBreak` with the minutes away and the unseen items Bean has not announced yet.

## How to get to it (user POV)

- Run Bean and work. Nothing shows: the picture is internal.
- Let something finish in another app (an agent session, a job) while working elsewhere. A couple of minutes later, if it needs the user, the notch opens with the conclusion and a button.
- Come back after 10 minutes away while things are waiting.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md), and the [brain](./brain.md) preconditions.
- Bean has Accessibility. The first tab read asks once for Automation of each running browser. Without it, `context-tabs` is empty.

- **Picture.** `bean probe-context` prints the whole picture and a footer like `built in 2.2 s: 11 apps, 6 windows, 60 tabs, 9 activities, ...`. It reads the user's real data and shell log, read-only. It writes `probe-context.txt`.
- **Learn a read recipe.** `BEAN_DATA_DIR=$PWD/artifacts/verify/$BEAN_RUN_ID build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean --probe-learn <bundle-id> read watch` learns what that app is working on, prints the recipe, its watched paths and a replay. Run `core-learn` (Claude desktop): learned in 65 s, 15 rounds, about 235k prompt tokens; the replay lists the real sessions with titles, states and last words.
- **Unseen change.** `bean watch-fixture working false "<title>" "<detail>"` before `BEAN_WAIT_SECONDS=10 bean launch` seeds a read recipe for `BEAN_FIXTURE_BUNDLE` (default `com.apple.Notes`, not in front) over a file in the run folder. After launch, `bean watch-fixture done true "<title>" "<last words with a decision>"`. Within 20 s, `bean triggers` has one `unseenChange` whose `waiting` line names the item, `bean gate` decides, and on a yes `bean brain` has an answer.
- **Back from break.** `BEAN_BREAK_SECONDS=20 bean launch`, then do not touch the Mac for 25 s, then move the mouse. `bean triggers` has one `backFromBreak` with `awayMinutes`.
- **Proof.** `probe-context.txt`, the trigger, gate and brain lines, and `bean shot` of the notch.

## Gotchas

- Window text depends on Accessibility. Some Electron apps expose no text without `AXManualAccessibility`. What they work on still comes through their learned read recipe.
- Windows on other Spaces only give titles, never text.
- A browser tab read takes 1 to 3 s with many tabs. It happens only when the brain asks for the picture.
- A run's `recipes.json` lives in its data folder. A learned recipe copied there reads the user's real app data, read-only; a real item that changed in the last hour can make Bean step in during the run. Never press an offered button that merges, pushes or posts.
- Learning calls the model for 10 to 25 rounds (about $0.30). Do not loop it.
- `backFromBreak` needs real idle time. Any input on the Mac, including the user's, resets it.
