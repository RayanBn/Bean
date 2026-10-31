name: claude-desktop-app
when: your window is this app
app: com.anthropic.claudefordesktop
does: runs coding sessions the user can watch
sessions: yes
sealed: yes
link: claude://code/new
---
Conversations and coding sessions already in this app belong to someone: you cannot read them and you never touch them. Your work always starts in a new session, in a folder of its own.

The user can watch a session here. If they asked for background work, or the folder cannot be used here, session_drive runs it unseen instead.

To start one: call session_workspace, then app_open with claude://code/new?q=<the task, URL-encoded>&folder=<its folder, URL-encoded>. Write the task for a colleague who knows nothing yet: what to change, why, what done looks like, and that it leaves its changes uncommitted. Then call window_controls: if it lists the field with your task, press the send control once.

If the app asks something only the user can answer, such as trusting the folder, ask the user with ask_user and stop. Never answer it yourself.

Then call session_wait. When the work is right, accept it yourself with session_act, as for any coding session.
