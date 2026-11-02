name: muse-code
when: the work goes through Muse Code, Meta's coding agent, the command-line tool muse
---
Muse Code runs from your terminal as `muse`. `muse exec` runs one prompt without its interface and ends when the turn ends, which is what you want. `muse` alone opens an interactive program, and `muse resume` reopens a session in it. Look at `muse --help` and `muse exec --help` for the rest.

Write the task to a file, for a colleague who knows nothing yet: what to change, why, and what done looks like. Then run it in the project's folder:

muse exec --prompt-file task.md --session-id "$(uuidgen)" --disable-approval --max-model-steps 200

- `--prompt-file <path>` reads the prompt from a file. Use it for anything longer than a line, so no quoting can break it.
- `--session-id <uuid>` names the session. Keep the id: running `muse exec` with the same id continues that work, so a fix goes in the same session.
- `--disable-approval` turns off approval prompts. Nobody can answer one in `muse exec`. The sandbox stays on.
- `--max-model-steps <n>` caps the steps. Reaching the cap ends the run as a failure, so continue the session if the work was going well.
- `--json` writes one JSON event per line. Send it to a file and read that file: `muse exec --json ... > run.jsonl`. Without it you read plain text as it comes.

A run can take many minutes. Wait for it with a long wait and look again until the shell is back at the prompt. Exit code 0 means the turn completed, 1 that it failed, was cancelled or hit the step cap, 2 a mistake in the options, and 130 or 143 that it was stopped.

The sandbox keeps `.git` read-only and asks for network access host by host, so a commit or a push inside the run can fail. When it does, read what it changed with `git status` and `git diff`, then commit and push yourself from your terminal.

If it says it is not signed in, only the person can do that with `muse login`: say so.
