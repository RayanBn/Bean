#!/usr/bin/env python3
"""Stands in front of gh in the e2e test: only draft pull requests on the sandbox repo get through."""
import os, subprocess, sys

real, sandbox = os.environ["E2E_GH_REAL"], os.environ["E2E_SANDBOX"]
args = sys.argv[1:]
with open(os.environ["E2E_GH_LOG"], "a") as log:
    log.write(" ".join(args)[:300] + "\n")


def option(*names):
    for name in names:
        if name in args and args.index(name) + 1 < len(args):
            return args[args.index(name) + 1]
    return next((a.split("=", 1)[1] for a in args for n in names if a.startswith(n + "=")), None)


def origin():
    url = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True).stdout.strip()
    return "/".join(url.removesuffix(".git").split("/")[-2:])


def refuse(why):
    sys.exit(f"gh: {why}")


head = args[:2]
if not args or "--help" in args or "-h" in args or args[0] in ("help", "version", "--version"):
    pass
elif head[:1] == ["auth"]:
    if head != ["auth", "status"] and head != ["auth", "git-credential"]:
        refuse("not available here")
elif head[:1] == ["pr"] or head == ["repo", "view"]:
    named = next((a for a in args[2:] if a.count("/") == 1 and not a.startswith("-")), None) if head[0] == "repo" else None
    repo = option("--repo", "-R") or named or origin()
    if repo.lower() != sandbox.lower():
        refuse(f"{repo} cannot be reached from here")
    if head[1:] and head[1] in ("merge", "ready", "lock", "unlock"):
        refuse(f"pr {head[1]} is not allowed here")
    if head == ["pr", "create"] and "--draft" not in args and "-d" not in args:
        refuse("only draft pull requests are allowed here: use --draft")
else:
    refuse(f"{' '.join(head)} is not available here")
os.execv(real, ["gh", *args])
