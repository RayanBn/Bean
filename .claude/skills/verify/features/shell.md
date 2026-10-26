# Shell

With the user's consent, Bean adds one line to `~/.zshrc` that sources `bean.zsh` from Bean's data folder. From then on, every new zsh session, in any terminal (Terminal, iTerm2, Ghostty, Warp, VS Code, Claude), writes one JSON line per command to `shell.jsonl`: the command, its exit code, the directory, the start and end times, and the terminal. Commands that look like they hold a secret (`passw`, `token`, `secret`, `api key`) are not written. Bean reads the file every second. A failed command becomes a `commandFailed` trigger. The same command failing three times within 10 minutes becomes `repeatedFailure`, which the gate always lets through (`rule: repeatedFailure`).

## Sub-features

- `shell-consent`: on the first launch without the hook, the notch asks "Want me to notice when a terminal command keeps failing…" with "Not now" and "Allow". "Allow" writes the marker line and `bean.zsh`, then shows "New terminals". "Not now" is remembered and never asked again.
- `shell-log`: each command in a new zsh writes one `shell.jsonl` line with `cmd`, `exit`, `cwd`, `start`, `end`, `term`.
- `shell-secret`: a command that mentions a secret is not logged.
- `shell-failed`: a non-zero exit (except 130 and 148, an interrupt or a suspend) writes a `commandFailed` trigger with `command`, `exitCode`, `cwd` and the terminal's app.
- `shell-repeated`: the third failure of the same command in 10 minutes writes `repeatedFailure` with `failures` and `failureMinutes`, once per streak. A success of that command resets it.

## How to get to it (user POV)

- Launch Bean for the first time and click "Allow" in the notch. Then open a new terminal tab.
- Run a command that fails, three times.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Verification runs never touch the real `~/.zshrc`. `bean launch` sets `BEAN_ZSHRC=artifacts/verify/$BEAN_RUN_ID/.zshrc`, and pre-consents unless `BEAN_SHELL_FRESH=1` is set.
- `bean shell-run "<command>" [times] [term]` runs the command in a real interactive zsh in a PTY with `ZDOTDIR` set to the run directory, so it loads the run's `.zshrc`. The default `term` is `vscode`.

- **Consent.** Run `BEAN_SHELL_FRESH=1 bean launch`, then `bean shot consent`. The notch asks for consent with "Not now" and "Allow". Run `bean press "Allow"`. The run's `.zshrc` ends with the marker and a `source` line, `data/bean.zsh` exists, and the notch shows "New terminals" before going back to rest.
- **Log and repeat.** Write a `build.sh` in the run directory that prints an error and exits with 1. Run `bean shell-run "./build.sh" 3`. `data/shell.jsonl` has three lines with `"exit":1` and `"term":"vscode"`. `bean triggers` has three `commandFailed` lines and one `repeatedFailure` with `failures: 3` and `app: VS Code`. `bean gate` has a decision for `repeatedFailure` with `stepIn: true` and `rule: repeatedFailure`, and `bean brain` has an answer for it with a `repo` summary of the Bean repo.
- **Proof.** `consent.png`, the `.zshrc`, and the `shell.jsonl`, `triggers.jsonl`, `gate.jsonl` and `brain.jsonl` lines.

## Gotchas

- Only new shells load the hook. Already-open terminals keep running without it until they are reopened.
- The hook records the command, not its output. For a VS Code terminal, Muse Spark sees the output only if it is visible in the screenshot. With `bean shell-run`, nothing is on screen, so `stay_quiet` is the expected answer.
- Commands from a VS Code terminal can be explained but not run: Bean only types into Terminal, iTerm2, Warp and Ghostty.
- "Not now" sets the user default `BeanShellHooksDeclined`. Run `defaults delete dev.rayanbn.Bean BeanShellHooksDeclined` to see the question again.
- Bash and fish are not covered.
