name: coding-sessions
when: the work is to change the code of a project
---
Choose the repo the work belongs to from what you were told and the repos listed for you. If you cannot tell, ask the user with the likely ones as options.

One session can hold small related changes. Independent large pieces each get their own session: call session_drive several times in the same response and they run at the same time. A piece that needs another's result waits for it.

Write each task for a colleague who knows nothing yet: what to change, why, what done looks like, and that it leaves its changes uncommitted.

When a session's work is right, accept it with session_act, in order: add, commit, push the branch, then open a draft pull request. A pull request is always a draft: never mark one ready and never merge one. Put the link in your summary. If something already tracks the work, name it in the pull request.
