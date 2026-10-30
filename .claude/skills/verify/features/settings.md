# Menu bar and settings

Bean has a menu bar icon: a small black notch with two eyes (slits when paused). A click on it opens a compact popover:

- **Header**: Bean, "Watching" or "Paused", and a switch to pause.
- **AI**: provider (Meta, OpenRouter, OpenAI-compatible), base URL (OpenAI-compatible only), model (a menu for Meta, a field otherwise), reasoning (Meta only), and the API key as a pill (Keychain, Repo .env, Environment, Missing, or Optional) with a paste field that shows only when the key is missing or after "Change".
- **SETTINGS** (collapsible, remembered in `menuBarSettingsOpen`): **Off limits** (`BeanSettings.offLimits`): chips with a remove button (AX "Remove <item>") and a field that adds an entry on Return.
- **Permissions**: shown only when Accessibility is missing, with an "Open" button.
- **About Bean** and **Quit Bean** (⌘Q).

Pausing sets `BeanSettings.shared.paused`: the notch eyes close at rest and the icon shows slits. A click on Bean in the notch at rest only makes the eyes pop open for a moment: there is no rest message any more.

## Sub-features

- `menubar-open`: the icon opens and closes the popover. Bean's notch keeps the focus rules; the popover is a normal transient popover.
- `menubar-pause`: the switch pauses and resumes; the notch eyes and the icon follow.
- `menubar-key`: saving a key writes the provider's Keychain item and the pill turns green.
- `menubar-settings`: the SETTINGS group opens and closes, and each row writes `BeanSettings.shared` right away.
- `notch-rest-poke`: a click on the notch at rest keeps the 279×32 rest frame.

## How to get to it (user POV)

- Click the Bean icon in the menu bar, right of the notch.
- Or right-click Bean in the notch: the same popover opens under the island. On a crowded menu bar macOS puts the icon behind the notch, where it cannot be seen or clicked.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Run with `BEAN_KEYCHAIN_SERVICE=dev.rayanbn.Bean.verify-<run>` so the run never reads or writes the real Keychain item.

- **Open.** `bean menubar popover` presses the status item through Accessibility (`statusitem.swift`), prints the popover bounds and saves `popover.png`. `bean menubar` again closes it.
- **Look without pressing.** `bean popover <name>` prints the bounds and captures the popover as it is.
- **Key.** With `BEAN_IGNORE_ENV_FILE=1` and no `MODEL_API_KEY`, open the popover: the key pill says Missing and the paste field shows. `bean fill "LLM_verify_fake_key"`, `bean press "Save"`: `security find-generic-password -s $BEAN_KEYCHAIN_SERVICE.meta-api -a MODEL_API_KEY` finds the item and the pill says Keychain. Delete the item after the run.
- **Provider.** `bean choose "Meta (Muse Spark)" "OpenRouter"`: the Model row becomes a field holding `meta-llama/llama-4-maverick`, the key pill says Missing, and `defaults read dev.rayanbn.Bean provider` prints `openRouter`. `bean choose "OpenRouter" "OpenAI-compatible"` adds the Base URL row and an Optional key. Switch back to Meta and remove the `provider` and `model.*` defaults the run wrote: they are shared with the user's copy.
- **Settings group.** `bean press "Settings"`, or a `click.swift` on the "SETTINGS" row, then `bean popover popover-settings`: the popover grows to show Off limits.
- **Pause.** Click the switch at the popover's top right (`click.swift`), then `bean popover popover-paused` and `bean shot` the notch: the eyes are slits. Click again to resume.
- **Rest poke.** `bean tap` at rest: the frame stays 279×32.
- **Icon.** The icon hides behind an expanded notch, and the menu bar may be auto-hidden: rest the notch first, move the cursor to the top edge, then `screencapture -R` the menu bar.
- **Off limits.** Open the popover with a real right-click on the island, click the "Add a site, app or name" field, check that `NSWorkspace.shared.frontmostApplication` is Bean, type a test entry and Return, read `defaults read dev.rayanbn.Bean offLimits`, then `bean press "Remove <entry>"`. Proof: run `offlimits` (`from-notch.png`, `added.png`, `removed.png`).
- **Proof.** `popover.png`, `popover-settings.png`, `popover-paused.png`, `paused-notch-and-icon.png`, `icon.png`, `rest-poke.png`.

## Gotchas

- Environment variables win over the popover (`BEAN_PROVIDER`, `BEAN_BASE_URL`, `BEAN_BRAIN_MODEL`, `BEAN_BRAIN_EFFORT`, `BEAN_OFF_LIMITS`).
- Verification runs share Bean's user defaults with the user's copy. Never change a setting during a run without putting it back, and delete the `menuBarSettingsOpen` key the run created.
- A worktree build has no repo `.env`, so the key shows "Missing" there.
- Never type a real key in a verification run.
- `bean frontmost` (System Events) can still name the previous app while Bean is active. Before typing into the popover, check `NSWorkspace.shared.frontmostApplication` instead, so keystrokes never land in another app.
- The user's off-limits list is real data: add only a test entry and remove it before the run ends.

The menu bar popover is now minimal: status, Pause, Open Bean, Settings, Quit. Every setting lives in the page's Settings section; see agents.md. Steps above that use the popover for settings are out of date.
