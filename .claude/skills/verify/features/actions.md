# App actions

An agent acts in the app of its window without the mouse or keyboard, through what that app exposes: its AppleScript dictionary, its Accessibility controls and menus, its URLs, and the user's shortcuts. Nothing is written per app. Sending, deleting, buying, running code and running shortcuts are off until the user allows them. If the app cannot be driven, the agent gets a plain reason.

## Sub-features

- `actions-surface`: `app_surface` lists the scripting commands and objects, controls, menus, URLs and the Automation state. `app_dictionary` reads one term in detail.
- `actions-script`: `app_script` runs one AppleScript that may only talk to that app.
- `actions-control`: `window_controls` and `window_act` fill a field or press a control, and read back what was filled.
- `actions-menu`: `app_menu` lists the menu items or chooses one without opening the menu.
- `actions-open`: `app_open` opens a URL the app handles, without bringing it forward.
- `actions-guard`: `WindowChannels.refusal` and `AppGuard` check every action against the agent's abilities. Keystrokes, `activate`, shell, other apps and secret fields are never allowed. Risky words are matched in English, French, Spanish and German.

## How to get to it (user POV)

Attach an agent to a window. It uses these tools when its work needs that app. Its abilities show on its page, and its actions in its journal.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- `BEAN_DATA_DIR` is set. The probe refuses to run without it, and with it Bean never asks macOS for Automation consent unless `BEAN_ASK_AUTOMATION=1`.

- **Permission, no dialog.** `Bean --probe-app-actions permission <bundle>...` prints `allowed`, `needsConsent`, `refused` or `notOpen`.
- **Surface.** `Bean --probe-app-actions surface <bundle>` prints what the app exposes and which of its commands are risky. It works on a closed app and does not open it.
- **Guard.** `Bean --probe-app-actions script-guard <bundle> '<script>' [allowed,words]` prints `REFUSED: <reason>` or `ALLOWED`, and runs nothing.
- **Accessibility, off screen.** `swift .claude/skills/verify/bin/fixture-controls.swift` opens a window off screen and prints its pid. `Bean --probe-app-actions controls pid:<pid>`, then `control pid:<pid> set Draft "text"` and `control pid:<pid> press "Save draft"`: the fixture logs the change. `Send`, `Supprimer`, `Buy now` and `Password` are refused.
- **Live page, Safari.** Serve a local page with `python3 -m http.server --bind 127.0.0.1`, then `script com.apple.Safari 'tell application "Safari" to make new document with properties {URL:"http://127.0.0.1:<port>/page.html"}'`. Address its window as `com.apple.Safari#<title>` in `controls`, `control`, `read`, `menus`, `menu`. Close it with `cleanup`.
- **Through the model.** Write `Agents/<id>/agent.json` with the attachment and `mission.json` in the run's data, then `--probe-agents work <id> 1`, with the key from the environment.
- **Script.** `Bean --probe-app-actions script <bundle> '<script>'` runs through the guard, and only if Automation is already allowed.

## Gotchas

- The first script to an app makes macOS show "Bean wants to control <app>". A test that opens an app or that dialog shows on the screen: ask for a slot.
- Never name another app in a script, even in a test: it is refused.
- A `file://` URL in Safari stops on a "Confirm the file to load" panel, so `app_open` refuses `file:`. Use a local server.
- Safari ignores a value set on an unfocused web field. `WindowControls.setValue` reads back, and only then focuses the field inside the app, without activating Safari.
- Most Safari menu items are greyed out while Safari is not frontmost, so `app_menu` reports that plainly.
- A new Numbers document autosaves to iCloud Drive at once, and closing it without saving does not remove the file. Check `~/Library/Mobile Documents/com~apple~Numbers/Documents` after a test and delete what the test made.
- Bean must run through `open` for an Automation test: as a child of a terminal or Claude, macOS checks the parent's permission instead.
- Bean only sees on-screen windows, so a hidden app gives no window to attach to.
- Mail's script `delete` does not remove an outgoing message. It goes away when Mail quits, if it was never saved.
- Safari needs Develop, Allow JavaScript from Apple Events for `do JavaScript`. Without it, use `app_control` on the page's fields.
