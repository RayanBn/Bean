name: muse-code
when: the work goes through Muse Code, Meta's coding agent, the command-line tool muse
---
Muse Code runs from your terminal as `muse`. `muse exec` runs one prompt without its interface and ends when the turn ends, which is what you want. `muse` alone opens an interactive program, and `muse resume` reopens a session in it. Look at `muse --help` and `muse exec --help` for the rest.

Write the task to a file outside the project, so nothing of yours lands in the repo, for a colleague who knows nothing yet: what to change, why, and what done looks like. Then run it in the project's folder, in the foreground, with no & or nohup, so the person watches it:

muse exec --prompt-file /tmp/task.md --session-id "$(uuidgen)" --disable-approval --max-model-steps 200

- `--prompt-file <path>` reads the prompt from a file. Use it for anything longer than a line, so no quoting can break it.
- `--session-id <uuid>` names the session. Keep the id, and note it with your memory tool if the work may go on later: running `muse exec` with the same id continues that conversation, so Muse still knows what it did. A session takes one run at a time.
- `--disable-approval` turns off approval prompts. Nobody can answer one in `muse exec`. The sandbox stays on.
- `--max-model-steps <n>` caps the steps. Reaching the cap ends the run as a failure, so continue the session if the work was going well.
- `--json` writes one JSON event per line, when you need the events. Keep it on screen too: `muse exec --json ... | tee /tmp/run.jsonl`. Without it you read plain text as it comes.

A run can take many minutes. Do not sit polling it: finish your run and say it is under way, and you get a new run with its result when it ends. Muse saying it is done is not proof. Check the result yourself with what shows it: read the file, `git diff`, run the tests, run the program. If it is not right, send Muse a message in the same session saying what is wrong, then check again.

Exit code 0 means the turn completed, 1 that it failed, was cancelled or hit the step cap, 2 a mistake in the options, and 130 or 143 that it was stopped.

The sandbox keeps `.git` read-only and asks for network access host by host, so a commit or a push inside the run can fail. When it does, read what it changed with `git status` and `git diff`, then commit and push yourself from your terminal.

If it says it is not signed in, only the person can do that with `muse login`: say so.
