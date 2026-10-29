# Routines

Bean watches what the user does in any app: clicks on buttons, links, rows and menu items (with the element clicked), values committed in fields, shortcuts and Return, and terminal commands. It finds sequences of three or more steps the user repeats, in the whole stream or within one app, with no rule about any app or site. When the user starts the same sequence again after doing it at least twice, Bean saves what is left as a recipe (`source: demonstrated`) and posts a `repeatSeen` event. The brain then writes the card in the notch and proposes `achieve` with that recipe. On the click, the core replays it step by step, each step checked by what it did when the user did it. A routine done as a loop over similar items ends with an `each` step that runs the same steps for every similar element on screen the user has not done yet. While the card waits, the recipe follows what the user keeps doing, so Bean never redoes a step. "Not now" snoozes that routine for a day. Every recorded action goes to `routine-actions.jsonl`; what Bean learned, announced and ran goes to `routines.jsonl`.

## Sub-features

- `routine-record`: each click, field commit, shortcut and terminal command is one line in `routine-actions.jsonl`, with the app, the element (role, label, DOM id, ancestors, page URL, link URL) and the effect seen on screen (`added`, `removed`, title). The element comes from a map of the window's controls read before the click; clicks on non-controls and secure fields are not recorded.
- `routine-learn`: after the second run of a sequence, `routines.jsonl` gets `learned` with its tokens, the number of runs and days, `in a loop` when the runs follow each other, and `in <bundle id>` when it was found inside one app's actions.
- `routine-announce`: when a new run starts (at least two steps matched, odds ≥ 0.7) or a loop run ends, `routines.jsonl` gets `matched` then `announced` with the recipe id and the steps left; `triggers.jsonl` gets `repeatSeen` (`source: routines`, `gate: always`).
- `routine-follow`: while the card waits, each new user step logs `followed` with the steps still left.
- `routine-offer`: the brain answers with `achieve` and the recipe id; the notch shows its card. `routines.jsonl` gets `proposed`.
- `routine-run`: the card's button replays the recipe; `channels.jsonl` has one line per step and an `each` line `done for N: …`; `routines.jsonl` gets `ran` (or `failed`).
- `routine-decline`: "Not now" logs `declined`; the routine is not announced again for 24 hours.

## How to get to it (user POV)

- Do the same few steps twice in any app, or in the terminal, then start them a third time. Bean offers to finish. Click the card's button or "Not now".
- The logs are `~/Library/Application Support/Bean/routine-actions.jsonl` and `routines.jsonl` for the user's copy, and `artifacts/verify/$BEAN_RUN_ID/data/` for a verification run. `Bean --routines-probe <routine-actions.jsonl>` prints what Bean learns from a recorded log, offline.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md), with an AI key (the brain writes the card).
- Nobody uses the Mac during the run: their clicks are recorded into it. Wait until `ioreg -c IOHIDSystem` shows `HIDIdleTime` above 60 s.
- `bean routine-site` serves a list of five invoices on `http://127.0.0.1:47812/$BEAN_RUN_ID/site/index.html`; each invoice page has "File it" (logs `GET /$BEAN_RUN_ID/site/filed?<n>` in `site.log`) and "Back to invoices". Open it with `open -a Safari <url>`.
- `bean click-ui <bundle-id> "<label>"` raises the element's window and clicks the element like a user; it refuses when another window covers it or when the point is not on the element.
- In Chromium browsers (Arc), use `bean click-web <bundle-id> "<text>"` or `"href=<path>"` instead: it takes the element's position from the DOM (Arc's AX hit test is wrong), raises the page's window and clicks it. `CLICK_WEB_TAB=<url part>` picks the test tab in any window; `CLICK_DRY_RUN=1` only prints the point.
- `bean close-windows <bundle-id> "<title regex>"` closes leftover windows by title (Arc's Little Arc windows opened by `open` URL steps). Close the test tabs first, so the user's main window no longer matches.
- The card's button label is the `button` field of the last line of `bean brain`.

- **Web loop.** In Safari, `click-ui` "Invoice 1042 · Acme", "File it", "Back to invoices", then the same for 1043 and 1044. `bean routine-actions` shows nine `press` lines with the right labels; `bean routines` shows `learned` … `in a loop`, then `announced` with an `each` step, then `proposed`. `bean shot card` shows the card. `bean press "<button>"`: `site.log` gets `filed?1045` and `filed?1046` once each, `channels.jsonl` ends with `done for 2: Invoice 1045 · Umbrella, Invoice 1046 · Hooli`, and `bean routines` gets `ran`. Proven in run web-13.
- **PR round in Arc (real GitHub, private test repo `RayanBn/bean-demo-prs`, four draft PRs).** Open `https://github.com/RayanBn/bean-demo-prs/pulls` in a new Arc tab. With `CLICK_WEB_TAB=bean-demo-prs`, `bean click-web company.thebrowser.Browser "<PR title>"`, then `"Ready for review"`, then `"href=/RayanBn/bean-demo-prs/pulls"`, for #4 and #3, then #4's title and "Ready for review" for #2. `bean routines` shows `learned` … `in a loop` and `announced` with an `each` step; the brain's card reads like "PR review loop: repeating on 4 PRs, finish the rest automatically." Press its button: `channels.jsonl` shows the back step, the `each` opening #1, "Ready for review", the back step, then `done for 1: Update the welcome copy`, and `gh pr list -R RayanBn/bean-demo-prs` shows #1 ready. Put the PRs back with `gh pr ready <n> --undo`. Proven in run pr-28 (7 s, no LLM fallback).
- **Terminal.** Write a `stack` script in the run directory (`reset`, `stop`, `start`, where `start` appends to `started.log`). `bean shell-run "./stack reset"`, `"./stack stop"`, `"./stack start"`, twice, then `reset` and `stop` again. `bean routines` shows `learned` with `shell|stack …` tokens and `announced`; the brain proposes the rest; pressing its button adds one line to `started.log`.
- **Decline.** On a card, `bean press "Not now"`: `routines.jsonl` gets `declined`, and no new `announced` for that routine.

## Gotchas

- Arc and other Chromium browsers expose page elements only while their window is in front: record and replay there need the browser frontmost.
- Other sessions' windows can cover the test page: `click-ui` then prints `covered` and the run is void.
- Reloading the test list shows every invoice again; the proof of filing is `site.log`.
- The brain writes its own card text and button label; read them from `bean brain`.
- A Bean may ignore SIGTERM during a replay: after `bean cleanup`, check that the run's pid is gone, and kill it if not.
- Arc opens URLs from `open` steps in Little Arc windows that stay above the main window and swallow later clicks: close them after a run.
