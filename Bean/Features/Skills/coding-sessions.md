name: coding-sessions
when: the work is to change the code of a project
---
Choose the repo the work belongs to from what you were told and the repos listed for you. If you cannot tell, ask the user with the likely ones as options.

There are two ways, and you choose. session_watch runs where the user can watch, in its own terminal window, on the repo's folder on this Mac: the session does the whole job and you are woken when it stops or asks something. session_drive runs unseen on a fresh copy, with a stand-in answering it, and returns when it is done. Each says what it needs.

One session can hold small related changes. Independent large pieces each get their own session: call the tool several times in the same response and they run at the same time. A piece that needs another's result waits for it. Each start needs the exact work id you were given or the ticket's id: a held id means the work is already under way.

To fix or check what a session did, continue that session: session_tell for a watched one, session_drive with its id for an unseen one. Never start a second one for the same piece, and never open a second pull request for it.

Write each task for a colleague who knows nothing yet: what to change, why, what done looks like. A watched session commits, pushes its own branch and opens the draft pull request itself. An unseen one leaves its changes uncommitted, and you accept its work yourself with session_act, in order: add, commit, push the branch, then open a draft pull request.

A pull request is always a draft: never mark one ready and never merge one. Put the link in your summary. If something already tracks the work, name it in the pull request.

When a watched session asks something, answer with session_tell if your mission covers it. Anything that cannot be undone, or that only the user can say, goes to the user with ask_user. Leave a finished watched session open so the user can look at it.
