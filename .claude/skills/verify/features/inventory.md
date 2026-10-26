# Inventory

Bean keeps an event-driven inventory of the whole Mac and logs every change. Nothing reads it yet: it is the data foundation. Apps come from KVO on `runningApplications`, windows from one Accessibility observer per app on a dedicated thread plus the WindowServer window list (all Spaces, with Space ids), the focused window's text from a capped walk after focus changes and typing pauses, tabs from AppleScript when a browser window changes, processes outside apps from a light PID diff every 3 s plus kqueue exit events, and system state from notifications (network, power, displays, lock, sleep, Spaces, volumes). The full snapshot is built only on demand.

## Sub-features

- `inventory-apps`: Dock, menu bar and non-Apple background apps, with pid, path and launch date. Launch and quit are logged as `appLaunched` and `appQuit`. XPC services and Bean's own children are skipped.
- `inventory-windows`: every window of every app with title, size, Space id, focus, minimized, and whether Accessibility sees it (only windows on the current Space). Logged as `windowOpened`, `windowClosed`, `windowFocused`, `titleChanged`, `windowMinimized`, `windowRestored`, `tabChanged`.
- `inventory-text`: the focused window's text, walked with batched reads, capped at 250 ms, 5,000 nodes and 20,000 characters, web content first. Electron and Chromium apps get `AXManualAccessibility` once a minute while in front, except VS Code, Cursor and Claude. Logged as `textChanged` with size and timing only.
- `inventory-tabs`: all tabs of Arc, Chrome, Brave and Safari, re-read 2 s after a browser window event. Logged as `tabsChanged`.
- `inventory-processes`: user processes outside app bundles with their arguments. Logged as `processStarted`, `processExec`, `processExited`.
- `inventory-system`: host, macOS, uptime, battery, network, audio output, mic, camera, displays, volumes, lock, sleep, Space changes.
- `inventory-snapshot`: `inventory.json`, written when Bean gets `SIGUSR1` or by the probe.

## How to get to it (user POV)

- Nothing to do: it runs with Bean. The log is `~/Library/Application Support/Bean/inventory.jsonl`.
- `kill -USR1 <Bean pid>` writes `inventory.json` next to it.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). Bean has Accessibility and Screen Recording (window titles of other apps need Screen Recording).

- **Snapshot.** `BEAN_PROBE_SECONDS=4 build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean --probe-inventory` prints the system, apps with windows and Spaces, tracked processes with arguments, the focused window text, tabs, agents and ports, then `--- built in N s`. With `BEAN_DATA_DIR` set, the run writes its own `inventory.jsonl` and `inventory.json`.
- **Window events.** During a 25 s probe run, `open -a TextEdit`, make a document with text through AppleScript, close it and quit. `inventory.jsonl` has `appLaunched`, `windowOpened`, `windowFocused`, `textChanged` (the document text size), `windowClosed` and `appQuit` for TextEdit.
- **Text of one app.** `Bean --probe-text <bundle-id>` prints that app's focused window text, nodes and milliseconds. Arc gives the page text first.
- **CPU.** Run the probe for 80 s and sample `top -pid`: about 0.5 % at rest on the dev Mac (run `inv-3`).
- **Proof.** The probe output, the event lines, and the CPU samples.

## Gotchas

- Windows on other Spaces have titles and Space ids but no Accessibility data, so no focus, no minimized state and no text.
- Apps without a focused window on the current Space give no text.
- macOS has no push event for new non-app processes without root and an Endpoint Security entitlement, so new processes are found by a PID diff every 3 s. Processes that live less than that can be missed.
- The probe uses real Automation for the browsers: the first run asks once per browser.
