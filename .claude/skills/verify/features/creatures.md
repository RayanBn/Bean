# Creatures

Each agent is a glossy drop colored by its hue, lit from the top. Agents at home peek out of the notch's left ear, next to Bean. The user presses one and drags it onto a window: a liquid thread holds it to the notch and snaps after 90 points, it dangles from the cursor, and the whole window under the cursor lights up with a "Put <name> on <app>" label. Dropped there, the agent works on that window: it sits on the edge (or a badge in its toolbar when there is no room above) while its mood is reading, working or needs you, then flies home after 6 idle seconds. One line next to it says what it understood and will do, then fades. A drop on nothing flies it home with "Drop it on a window".

## Sub-features

- `creature-look`: hue and mood (idle blinks and looks around, reading scans, working bounces, needsYou glows and raises a hand, sleeping snores, forming fills with color from the bottom with eyes closed).
- `creature-crew`: home agents as heads in the left ear, "+N" past three; the island widens to fit them.
- `creature-drag`: press and drag a head out of the notch; it dangles with physics; the window under the cursor is highlighted.
- `creature-drop`: drop on a window attaches the agent to it (`AgentStore.attach`) and it perches on the top edge.
- `creature-home`: drop on nothing or on the notch flies it back into the notch and detaches it.
- `creature-follow`: the perched creature follows its window when it moves or resizes; hides when the window is minimized, its app hidden, or on another Space; comes back with it.
- `creature-regrab`: a drag from the perch moves it to another window or home.
- `creature-click`: a click without a drag opens the notch list. In the list, a click opens the agents page on that agent, and every head there drags.
- `creature-bean`: Bean (`agent-head-Bean`, id `BEA00000-…-01`) is an agent too: drag it from the right ear onto a window and it perches, reads and speaks like the others; its card has no Delete. While it is out, its seat shows a dotted ring and the + and heads still work. Run `ux-proof2`: `04-bean-perched.png`, `05-card-bean.png`, then `home`.
- `creature-crowd`: agents on the same window move apart by 1.4 drop widths. Hovering the notch shows up to 6 heads, newest next to the camera.
- `creature-badge`: an agent sits in the app's own bar, as Bean's own window placed there: nothing enters the app. It is one flat glyph in the row's ink, leaning toward the agent's hue, with its eyes cut out, and full hue when it needs you. Bean reads the bar through Accessibility, off the main thread. The bar is the app's `AXToolbar`, else the controls that span the window buttons' line, else the highest row of controls. It takes one more slot beside a run of controls, on the row's line and spacing. With Screen Recording, a picture of the window alone (`BarPicture`) gives the icons' real center, size and ink, and overrules a frame much wider than what it shows. A frame the size of a button always holds, because a greyed-out button can look empty. A full row with room to the eye takes the agent between two buttons. A row with no controls seats it after the title. A window with no bar leaves it in the notch: a browser with its chrome hidden, a full-screen window with nothing on top. The bar is watched every 1.5 s, so toggling a sidebar moves or removes the seat. Without Screen Recording it keeps the Accessibility frames and a default ink.
- `creature-unplug`: "Send home" on the page flies a working drop home; hold to delete on the page removes the agent.

## How to get to it (user POV)

- Look at the notch: agents at home sit in its left ear.
- Press an agent's head and drag it onto any window. Press a perched agent and drag it elsewhere or back to the notch.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Agents are written into the run's own data before launch: `bean agent Coder 0.58 headset`, `bean agent Chat 0.85 bow`. Never write into Rayan's real data.
- One normal window to drop on, for example `open -a TextEdit` with a new document.

- **Seat without the notch.** `build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean --probe-perch <pid> [hue]` seats a real perch on that app's front window with no notch and no store, and prints each seat. It needs no notch lock. A real drop still needs `bean dragout`.
- **Look without the screen.** `build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean --probe-creature-gallery <file.png>` renders every accessory in every mood, the dangling pose and the notch head. Read the PNG.
- **Crew.** `bean launch`, then `bean head Coder` prints the head's frame in the left ear, `bean shot crew` shows the heads.
- **Drag out and drop.** `bean dragout Coder TextEdit`. It drags the head onto the TextEdit window and prints the last events: `lift` (from notch), `drop`, `perched` with the window number. `bean perch Coder` prints the perched creature's frame; its bottom sits on the window's top edge (`bean target TextEdit`). For the video, `screencapture -v -V 6 file.mov` during the drag.
- **Follow.** Move or resize the TextEdit window, then `bean perch Coder` again: it moved with the window. Minimize the window: `bean perch Coder` prints `none`.
- **Regrab.** `bean regrab Coder home` drags the perched creature onto the notch: events `lift` (from window), `home`, and `bean head Coder` finds it in the ear again.
- **No focus taken.** `bean frontmost` is the same before and after each drag.
- **CPU at rest.** `bean cpu 20` with agents idle at home and perched.

## Gotchas

- `bean agent` must run before `bean launch`: the store loads at start.
- `bean dragout` and `bean regrab` move the real cursor and need Accessibility for the launching process, like `bean tap`. They need the screen: ask before running them while someone works on the Mac.
- `bean window` and `bean tap` read the notch panel (layer 27). Perched creatures are separate panels at layer 0, and the drag overlay is at layer 28 only during a drag.
- On a full-screen Space, macOS reveals the menu bar when the cursor reaches the top. Below layer 27 that menu bar takes the press meant for Bean's head (seen live on Discord).
- Entering or leaving full screen, macOS shows a temporary window for about a second while the real one leaves the list. A perch waits 2.5 s before it rebinds, so it never jumps to that temporary window.
- Window titles in events need Screen Recording; without it `window` and `frame` are still there.

When an agent on a window has a need, a small bubble beside its drop shows one sentence and its buttons, in a non-activating panel that never takes focus. The bubble floats above other windows so its buttons stay reachable. A call consent reads "Listen to this call?" with Yes and Not now; other needs show their own option titles. Details opens the page. With no room for the drop, the bubble sits at the window's top right.
