# Resume

Bean remembers the state of each project the user works on (windows, what each shows, frames, Spaces, full screen, the command a terminal ran) and puts it back when the user returns. Nothing is written for any app: Bean learns, once per app, how to read what a window shows and how to reopen it, keeps each recipe only after it saw it work, and replays it after that without a model call. When the user comes back to a project after being away, Bean tells the brain, which offers to resume it in the notch; on the click, Bean reopens what is missing, places every window, enters full screen where it was, and relaunches the command that ran (a command the denylist flags is typed, never sent).

## Sub-features

- `resume-projects`: windows grouped into projects by what they point at (paths to their git repository, worktrees to the main one; URLs and titles to the project they name).
- `resume-describe`: what a window shows and the handle that reopens it, a core `read` recipe per app (`RecipeLearner`, read-only sandbox), replayed with the window's title, pid and id. Logged to `learning.jsonl`, recipes in `recipes.json`.
- `resume-reopen`: the core `act` recipe per app that reopens a handle without running any command, gated by Bean's own check (the title when it says the content, a new window for a terminal, otherwise vision). Leftover windows of failed tries are closed.
- `resume-relaunch`: the command that ran in a terminal window is typed into that exact window (raised and focused first) from the real program and arguments of its process, sent only if the denylist does not flag it, and checked by a new process starting.
- `resume-place`: frame, Space and full screen for any window, also windows on other Spaces.
- `resume-events`: `projectLeft` (gate never) and `projectBack` (gate always, notice "Welcome back") in `triggers.jsonl`.
- `resume-card`: the brain's `resume_project` act card; its steps are the windows to put back.

## How to get to it (user POV)

- Work in a project, leave it (switch to another one for 15 minutes, lock the screen, or close its windows), come back (open one of its windows, run a command in its folder, or unlock the Mac): the notch offers to resume it.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). Accessibility and Screen Recording granted. A Muse Spark key.
- A throwaway git project with a few windows: `S=<scratch>/resumedemo`, `git init`, a `notes.md` open in VS Code (full screen), a PDF in Preview, a Terminal window running `cd $S && python3 -m http.server 8777`.

- **Projects.** `bean probe-resume projects` prints each project root with its windows.
- **Describe.** `bean probe-resume describe <windowId> --twice`: the first pass investigates (VS Code ~20 s), the second replays the reader (0.0 s) when one was kept. `data/content.jsonl` has `investigated`, then `reader`.
- **Snapshot.** `bean probe-resume snapshot $S "Terminal:8777,Preview,Code:resumedemo"` describes the matching windows and saves the project in `data/projects.json` with its three windows.
- **Restore loop.** Close the three windows (`bean probe-resume close <id> <pid>` for the full-screen one, quit Preview, stop the server, close the Terminal window), then `bean probe-resume restore $S`. Each window prints `reopened, placed true`; VS Code also `full screen true`; Terminal `relaunched python3 -m http.server 8777`. `lsof -iTCP:8777 -sTCP:LISTEN` shows the server. First run learns the recipes; replays take 12.7 s on macOS 27.2 (run `resume-core-loop`, Oct 29). The throwaway project and the loop script live in `artifacts/resume-tools/` (`loop.sh setup|snapshot|close|restore|state`).
- **Live, through the notch.** `BEAN_RESUME_AWAY_MINUTES=0.3 bean launch`. Focus each demo window (`bean activate` the app, or click it). Close them and activate another app: `bean triggers` has `projectLeft`. Wait 20 s, then `bean shell-run "cd $S && ls"`: `bean triggers` has `projectBack` with the saved windows, the notch shows the brain's resume card (`bean shot back`). `bean press "<button>"` runs the restore with one step per window (`bean shot restoring`, `bean shot done`).
- **Proof.** The probe output, `projects.json`, the `content.jsonl` and `recipes.jsonl` lines, the triggers, the screenshots, and the window list after the restore.

## Gotchas

- Windows created on a Space the user is not on cannot be found by `kAXWindows`; Bean uses the app's focused or main window first, then the remote token. A few windows (Granola, one of two Simulators) are found by neither.
- A second full-screen request sent during the previous animation is ignored: Bean waits until the window has its own Space.
- macOS reorders Spaces by recent use (`mru-spaces` default), so the order of full-screen Spaces is not restored.
- First learning costs: Claude's session took 72 s to describe, Terminal's reopen recipe 77 s. Replays take seconds.
- Learning tries really act: a failed try can leave a window (a Little Arc window in an early probe). Close what the run opened.
- The Terminal windows `bean-verify` belong to other runs: never describe or close them.
