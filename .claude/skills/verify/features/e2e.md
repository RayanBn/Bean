# Main scenario, end to end

A meeting happens on a window, the agent there records it and gives Bean a recap, Bean understands what was decided, tickets exist, the work goes to agents on the windows where it belongs, those agents do it, a real draft pull request carries the code, and Bean reports once with its link. This test runs that with nobody at the Mac, in varied scenarios, and passes or fails on what changed in the world.

## Sub-features

- `e2e-runner`: `bin/e2e` starts every run in its own temp folder and prints pass rates per scenario and per step, Muse Spark calls and cost.
- `e2e-steps`: each step reads the world: the transcript, the questions raised, the tickets in the fake service, which agent is attached where, the text of each window, the branches and draft pull requests on the test repo, the code on them run for real, the cost ledger. None reads which tool was called or Bean's wording.
- `e2e-bean-did-no-work`: each change in a window is timed against who was busy, and Bean must hold no coding session of its own.
- `e2e-sessions`: how many branches is judged as a range per meeting, because several answers can be reasonable. Two branches that change the same file collide unless one is built on the other. A task that needs another must pass with that other on the same branch tip.
- `e2e-scenarios`: the variants live outside the repo because they are held out from the fixes they judge. `--scenarios` or `BEAN_E2E_SCENARIOS` names their folder, and there is no default, so a session fixing Bean does not run them by accident.
- `e2e-audit`: a run refuses to start if anything Bean is given outside the meeting's own words names the flow, such as tickets or pull requests.
- `e2e-observed`: a scenario marked `observe` is reported, not judged, past the call and the money.

## How to get to it (user POV)

There is no user path: it is a test command.

## Driving it with bean

Preconditions:

- `bean build` on the commit under test, or `--build`.
- A key: `MODEL_API_KEY` in the environment or `.env`. It is never printed.
- It takes no lock and no input: windows are off screen, no sound plays, nothing takes the mouse, the keyboard or the focus.

```bash
.claude/skills/verify/bin/e2e --scenarios <folder> --runs 3 --budget 1.5
```

- **Some scenarios.** `--only <id>,<id>` or `--skip <id>,<id>`.
- **Modes.** `--strands on` (default) runs the local gate and decider as on a real Mac, each run with its own server, about 4 GB; `--strands off` checks the Muse Spark fallback, where no window title reaches the model, so a scenario that places an agent by title fails there.
- **Claude app.** `--with-claude` adds the scenario that drives the real Claude app. It lets that app through the window filter, so the Mac must be free. After each run it stops everything if text about the task went into an existing session or if the task reached main.
- **Test repo.** `RayanBn/bean-e2e-sandbox`, private and synthetic. `--seed-sandbox` fills it once, when empty.
- **Result.** A table, the failed steps with their detail, and the spend. `artifacts/verify/e2e-<stamp>/` keeps `results.json` and, per run, the journals, what Bean understood, the tickets, the pull requests and the final text of each window. The exit code is 0 only if every run passed.
- **Budget.** No new run starts past `--budget`, in dollars of Muse Spark.

## Gotchas

- What is real: the Bean binary and its worker, gate, senses and connectors (`--probe-agents scenario`, the same wiring as the app without its windows), the recorder fed from files, Muse Voice, Muse Spark, Accessibility edits, Claude Code sessions, draft pull requests on the test repo.
- What is injected, so not covered: the call's start and end (`BEAN_FAKE_CALL_FILE`, not the microphone watcher), the sound (`say` files, not the mic or system audio), the answers to questions (`worker.answer`, not clicks on the page), the notch and the page, the ticket service. Off-screen text windows stand in for apps.
- A run's git and `gh` can reach only the test repo and local folders, and never its main: a per-run git config, a pre-push hook and `bin/e2e-gh.py` enforce it, and the run refuses to start unless that is proven. Drafts only.
- Other sessions use the test repo too. A run counts and cleans only the branches written by its own git identity.
- A clear scenario where Bean asks anyway fails `decision`, then gets Bean's own pick as an answer, so the later steps are still measured.
- Muse Voice is billed outside the ledger, so the spend shown leaves it out.
- A window in a scenario marked `revert` puts its text back one second after any edit, so an agent can report work that did not stay.
- Only Claude app scenarios use a trusted checkout: other runs set `BEAN_NO_TRUSTED_CHECKOUT` and keep their clones in the run's data folder.
- App names carry the run's tag, because `BEAN_WINDOW_FILTER` is that tag: Bean sees only this run's windows.
