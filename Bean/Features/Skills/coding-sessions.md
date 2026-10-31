name: coding-sessions
when: the work is to change the code of a project
---
Choose the repo the work belongs to from what you were told and the repos listed for you. If you cannot tell, ask the user with the likely ones as options.

One session can hold small related changes. Independent large pieces each get their own session: call session_drive several times in the same response and they run at the same time. A piece that needs another's result waits for it. A start needs the exact work id you were given, or the ticket's id. A held id means that work is already under way. Your run ends once they are started: you are woken with the outcome when each ends.

To fix or check what a session did, continue that session. Never start a second one for the same piece, and never open a second pull request for it.

Write each task for a colleague who knows nothing yet: what to change, why, what done looks like, and that it leaves its changes uncommitted, because committing and pushing are yours and never the session's.

When a session's work is right, accept it yourself with session_act, in order, without asking the session to do any of it: add, commit, push the branch, then open a draft pull request. A pull request is always a draft: never mark one ready and never merge one. Put the link in your summary. If something already tracks the work, name it in the pull request.
