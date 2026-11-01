# Bean

Bean is a chief that lives in your Mac's notch. It watches what happens on your Mac, works out what would help, and puts agents on your windows to do the work. It reports once, when there is something to say.

Built for the Meta Global AI Developer Hackathon, Indie Developer track, between Oct 26 and Nov 4, 2026.

## How it works

1. **Bean observes.** Window and app events go to a local log, with no model call. Code turns them into moments, such as "you stayed in this window" or "a service changed".
2. **Bean decides.** A local filter drops most moments. Muse Spark gets one short call for each of the others and answers ignore, remember, offer or place.
3. **Code decides if it must ask.** Bean asks first when the work needs a new source, reaches someone else, or cannot be undone. Otherwise it acts and says so in one line. Trust grows with your answers and falls at the first correction.
4. **Agents work.** Each agent has one window and works in the background, through the app's own scripting and Accessibility. Coding work goes to a Claude Code session in the background and ends in a draft pull request.

You can also drag an agent from the notch onto any window. That window becomes its work.

Merging, deploying, deleting and sending money stay off unless you allow them. Agents never touch what matches your off-limits list. Stop holds until you speak again or press Resume.

## What is ours, and what is not

Everything in this repository was written during the event.

External models and tools:

| Part | Role | License or owner |
|---|---|---|
| Muse Spark, Meta Model API | The brain of Bean and of every agent | Meta |
| Muse Voice, Meta Model API | Call audio, after you say yes | Meta |
| Strands 2B on Qwen3.5-2B-Base, run with MLX and PyTorch | Local filter on moments and window titles, installed at first run, can be turned off in Settings | Apache-2.0. Not a Meta model |
| uv and a standalone Python 3.12 | Install Strands at first run, in its own folder | Astral, Apache-2.0 and MIT. Python Software Foundation |
| Claude Code CLI | Runs coding sessions | Anthropic |
| SwiftTerm 1.10.1 | Embedded terminal | MIT |
| MCP Swift SDK 0.12.1 | Connectors such as Linear and GitHub | MCP project |

## Run it

You need macOS 14 or later, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a Meta Model API key. Claude Code is needed only for coding work.

```bash
./scripts/run.sh
```

The script builds Bean and opens it. The packages come from GitHub at the first build. It tells you if Xcode or XcodeGen is missing. With no `Bean Local Signing` certificate it signs for your Mac only, and macOS asks for its permission again after each rebuild. No `.env` file is needed.

The first run asks for your objective, your model key and the macOS permission that reads windows, shown under its real name on your macOS. It then walks you through your first drag.

Once the key passes, Bean installs Strands in the background into `~/Models/strands-decider`. It needs an Apple silicon Mac, 7 GB free and a network connection, and about 4 GB of memory while it runs.

## Known limits

- Bean is a local app, not a signed release. Accessibility rules it out of the App Store sandbox.
- Window titles reach the model after a local private check. You can turn this check off in Settings.
- With no local check, because Strands is installing, failed or cannot run on this Mac, no window title reaches the model and Bean makes no offers from what it notices. The window an agent is on still reaches the model.
