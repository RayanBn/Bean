# Control page

The page is Bean's chat on the left and, on the right, one board per agent. A headline says what state the agent is in, what it is doing, what its job is, and which app it is on. Under it, a bar names every widget: a click shows it, another click takes it off. Add Widget lists every kind with one plain sentence, any window on the Mac by its picture, and the connected services. A widget with nothing to show says what fills it. Layouts persist per agent in `panes.json`.

## Sub-features

- `page-headline`: state word, current line, job, the app with a menu to move it, Stop or Resume. Its drop can be dragged onto an app.
- `page-bar`: chips for Now, Plan, Changes, Terminal, Files, Memory, History, App. Changes shows a count, or `+N −N` with a session.
- `page-picker`: the popover from Add Widget, and the content of an empty pane. Searchable.
- `page-terminal`: a real shell with no session needed, in the agent's first folder: its session's, then its open document's, then its own. Closing the widget ends its shells.
- `page-files`: a tree of a chosen folder, with files read in the page. Text and notes show as text. Anything else goes through Quick Look.
- `page-memory`: notes, corrections, its understanding, about you, goals and the job card, as files to read. Nothing here edits them, since each has one writer.
- `page-changes`: what it did in apps as sentences with Undo, and what it did to files as diffs.
- `page-plan`: its job, what it is on now, its session's tasks, and its part of Bean's plan.
- `page-history`: runs, what it said, and sessions, newest first by day.
- `page-app`: a live picture of the app's window, about once a second while the page is in front, and any of the app's windows. With no Screen Recording, what can be read, and a button to System Settings. It never prompts by itself.
- `page-window`: the same for any window, with a button that puts the agent on that app.
- `page-layout`: drag a widget by its header, drag a gap to resize, double-click a gap to make both sides even, Reset Widgets in the agent's menu.

## How to get to it (user POV)

- Open Bean from the notch list, or activate the app. The bar and Add Widget sit under the headline. New Agent is the + after the tabs.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md). `BEAN_OPEN_PAGE=1` opens the page at launch. `BEAN_WINDOW_FILTER` must name the windows the picker may list, or `*`: a test data folder otherwise sees none.

- **Click by id.** `bean find page-chip-terminal` prints `x y w h`, and `click.swift` clicks its center. Ids: `page-chip-<kind>`, `page-add`, `page-picker-<kind>`, `page-picker-window`, `page-window-put`, `page-file-<name>`, `page-memory-<file>`, `page-headline-place`, `page-pane-grab`, `page-pane-divider`.
- **Capture.** `screencapture -l <window number>`, the largest layer 0 window of Bean's pid. A popover is not part of it: use `-R` on the page's rect.
- **Drag and resize.** `bean drag x1 y1 x2 y2 s` from a widget's title onto another widget, or across a gap. `panes.json` changes, and the layout comes back after a relaunch.
- **No Screen Recording.** Launch with `BEAN_NO_PICTURES=1`.
- **Light mode on a dark Mac.** `BEAN_LAUNCH_ARGS="-NSRequiresAquaSystemAppearance YES"`.

## Gotchas

- Esc closes the page when no text field holds text. With a popover open it only closes the popover.
- `open -a Bean.app` on a test data folder shows the onboarding window instead of the page.
- The picker's window tiles sit low in the popover: search for a window if a click must land on one.
- A window on another Space or hidden can show its app icon instead of a picture in the picker.
