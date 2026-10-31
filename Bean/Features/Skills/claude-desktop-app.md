name: claude-desktop-app
when: your window is this app
app: com.anthropic.claudefordesktop
does: runs coding sessions the user can watch
sessions: yes
sealed: yes
controls: AXButton=New | AXPopUpButton=Folder:* | AXMenuItem=* | AXTextArea=Prompt | AXCheckBox=Worktree | AXButton=Send
not: Open folder*
opens: New
sends: Send
asks: Trust workspace
existing: /local_
---
Conversations and coding sessions already in this app belong to someone: you cannot read them and you never touch them. Your work always starts in a new session.

The user watches your session here: that is why you are on this window.

To start one, call window_controls after each press, because the controls change:
- Press New.
- Press the Folder control. Its menu lists recent folders by name. Press the project's folder, even if it already looks chosen. If it is not in the menu, ask the user with ask_user and stop.
- Fill Prompt with the task, written for a colleague who knows nothing yet: what to change, why, what done looks like. The session does the whole job itself, so say it works on its own branch, commits and pushes that branch, opens a draft pull request, gives the link, merges nothing and never touches main. It leaves trackers and other connected services alone: you handle those, so do not name their tickets in the task.
- Worktree must be on, value 1. Press it only if it is 0.
- Press Send once. Send only shows once Prompt holds your text: if it is missing, fill Prompt again and call window_controls. That is not a reason to stop.

Then call session_wait. Its answer gives the result, the branch and the pull request. Before you start a session, look at the ones you already started: the same work never gets a second one, even after a failed try, and each task keeps to its own session. If the session stopped short of a pull request, finish the job with session_act on that session.

If the app asks something only the user can answer, such as trusting a folder, ask the user once with ask_user and stop. Never answer it yourself, and do not try again until they have answered.
