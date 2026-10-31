name: claude-desktop-app
when: your window is the Claude desktop app and the work should run in it
---
Conversations and coding sessions already open in this app belong to someone. Never type in one, stop one, archive one or change one. Your work always starts in a new session.

To start one: call session_workspace for a fresh copy of the repo, then app_open with claude://code/new?q=<the task, URL-encoded>&folder=<its folder, URL-encoded>. The link brings the app forward for a moment. The task then waits in the field of a new session.

If the app asks to trust the folder, ask the user with ask_user and stop: only they can accept that.

Before you press anything, call window_read and window_controls, and check that the field holds your task and nothing else, and that no conversation is shown above it. Press the send control once.

The work runs for a while. Finish and say so: new text in your window reaches Bean, and you will be asked to read the result with window_read. When it is done, accept the work with session_act on that session.
