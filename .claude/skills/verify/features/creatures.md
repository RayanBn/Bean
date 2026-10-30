# Creatures

Each agent is a glossy drop colored by its hue, lit from the top (no highlight streak on the face). Agents at home peek out of the notch's left ear, next to Bean; past three, the ear shows "+N". The user presses one and drags it out: a liquid thread holds it to the notch and snaps after 90 points, then it dangles from the cursor and swings, and the top edge of the window under the cursor lights up in its color. Dropped on a window, it flies onto that window's top edge, lands with a squash and two droplets, and sits there following the window. Dropped on nothing or back on the notch, it flies home. Its line shows in a warm paper bubble that folds to "…" after 8 s and opens again on hover. Bean never takes focus, and only the creature itself catches clicks.

## Sub-features

- `creature-look`: hue and mood (idle blinks and looks around, reading scans, working bounces, needsYou glows and raises a hand, sleeping snores, forming fills with color from the bottom with eyes closed).
- `creature-crew`: home agents as heads in the left ear, "+N" past three; the island widens to fit them.
- `creature-drag`: press and drag a head out of the notch; it dangles with physics; the window under the cursor is highlighted.
- `creature-drop`: drop on a window attaches the agent to it (`AgentStore.attach`) and it perches on the top edge.
- `creature-home`: drop on nothing or on the notch flies it back into the notch and detaches it.
- `creature-follow`: the perched creature follows its window when it moves or resizes; hides when the window is minimized, its app hidden, or on another Space; comes back with it.
- `creature-regrab`: a drag from the perch moves it to another window or home.
- `creature-click`: a click without a drag calls `CreatureController.onAgentClick(id)`.
- `creature-bubble`: `AgentStore.activity[id].bubble` shows in a paper bubble beside the perched creature; it folds after 8 s and opens on hover.
- `creature-bean`: Bean (`agent-head-Bean`, id `BEA00000-…-01`) is an agent too: drag it from the right ear onto a window and it perches, reads and speaks like the others; its card has no Delete. While it is out, its seat shows a dotted ring and the + and heads still work. Run `ux-proof2`: `04-bean-perched.png`, `05-card-bean.png`, then `home`.
- `creature-crowd`: agents on the same window move apart (1.4 drop widths) and their bubbles take opposite sides; with 3 or more, the middle ones fold to "…". Hovering the notch shows up to 6 heads, newest next to the camera.
- `creature-unplug`: Unplug on the card flies the perched creature home; Delete (hold 1 s) pops it into droplets.

## How to get to it (user POV)

- Look at the notch: agents at home sit in its left ear.
- Press an agent's head and drag it onto any window. Press a perched agent and drag it elsewhere or back to the notch.

## Driving it with bean

Preconditions:

- Baseline from [README](./README.md).
- Agents are written into the run's own data before launch: `bean agent Coder 0.58 headset`, `bean agent Chat 0.85 bow`. Never write into Rayan's real data.
- One normal window to drop on, for example `open -a TextEdit` with a new document.

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
- `bean window` and `bean tap` read the notch panel (layer 25). Perched creatures are separate panels at layer 0, and the drag overlay is at layer 26 only during a drag.
- Window titles in events need Screen Recording; without it `window` and `frame` are still there.
