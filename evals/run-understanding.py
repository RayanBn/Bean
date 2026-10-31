#!/usr/bin/env python3
"""Replays evals/bean-understanding.jsonl through Bean's understand step. Paid: one model call per case.

run-understanding.py <Bean binary> <run id> [case ids]
"""
import json, os, re, shutil, subprocess, sys, tempfile, uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
app, run_id = sys.argv[1], sys.argv[2]
only = set(sys.argv[3:])
LEDGER = Path.home() / "Library/Application Support/Bean/ledger.jsonl"
TEAM = [("Mira", "Keeps track of what is said in the calls on this window.", ("us.zoom.xos", "zoom.us", "Weekly call"), []),
        ("Alex", "Keeps the budget sheet totals right.", ("com.apple.iWork.Numbers", "Numbers", "evalw budget sheet"), []),
        ("Bri", "Keeps the project brief up to date.", ("com.apple.iWork.Pages", "Pages", "evalw project brief"), []),
        ("Dex", "Keeps the pricing deck up to date.", ("com.apple.iWork.Keynote", "Keynote", "evalw pricing deck"), []),
        ("Sam", "Fixes failing builds in rayanbn/bean-demo-prs.", None, ["rayanbn/bean-demo-prs"])]


def seed(data):
    for index, (name, role, window, targets) in enumerate(TEAM):
        agent = str(uuid.uuid4()).upper()
        folder = data / "Agents" / agent
        (folder / "memory").mkdir(parents=True)
        attachment = {"bundleId": window[0], "appName": window[1], "pid": 0, "windowNumber": 100 + index, "windowTitle": window[2]} if window else None
        (folder / "agent.json").write_text(json.dumps({"id": agent, "name": name, "role": role, "personality": "", "look": {"hue": 0.5, "accessory": "none"}, "connectors": [], "attachment": attachment, "createdAt": "2026-10-31T10:00:00Z"}))
        (folder / "persona.md").write_text(f"# {name}\n\n## How I talk\nShort.\n")
        (folder / "job.json").write_text(json.dumps({"goal": role, "output": "A short result.", "done": "The result exists.", "first": "Read what is there.", "quiet": "Nothing changed."}))
        (folder / "lines.json").write_text(json.dumps({"greeting": "Ready.", "offLimits": "That is off limits."}))
        (folder / "mission.json").write_text(json.dumps({"mission": role, "targets": [{"kind": "repo", "name": t} for t in targets], "every": 300}))


def spent():
    total = 0.0
    for line in LEDGER.read_text().splitlines():
        if run_id in line:
            try:
                total += json.loads(line)["usd"]
            except ValueError:
                pass
    return total


score = 0
cases = [json.loads(line) for line in (HERE / "bean-understanding.jsonl").read_text().splitlines()]
for case in cases:
    if only and case["id"] not in only:
        continue
    if spent() > 0.08:
        sys.exit("stopped: this replay's spend limit")
    root = Path(tempfile.mkdtemp(prefix="understanding-"))
    data = root / "data"
    seed(data)
    env = {k: v for k, v in os.environ.items() if not k.startswith("BEAN_")}
    env |= {"BEAN_DATA_DIR": str(data), "BEAN_RUN_ID": run_id, "BEAN_WINDOW_FILTER": "zz-none", "BEAN_DECIDER": "muse"}
    env["MODEL_API_KEY"] = next(line.split("=", 1)[1].strip().strip('"') for line in (Path.home() / "Hackathons/Bean/.env").read_text().splitlines() if line.startswith("MODEL_API_KEY="))
    subprocess.run([app, "--probe-agents", "adopt-bean"], env=env, capture_output=True, text=True, timeout=60)
    (data / "Agents/BEA00000-0000-0000-0000-000000000001/goals.md").write_text("- Keep the budget sheet totals right.\n- Keep the main branch of rayanbn/bean-demo-prs green.\n")
    result = subprocess.run([app, "--probe-agents", "understand", case["source"], case["text"]], env=env, capture_output=True, text=True, timeout=180)
    if not (data / "Agents/BEA00000-0000-0000-0000-000000000001/memory/understanding.jsonl").exists():
        sys.exit(f"no understanding: {result.stdout[-400:]} {result.stderr[-400:]}")
    found = json.loads((data / "Agents/BEA00000-0000-0000-0000-000000000001/memory/understanding.jsonl").read_text().splitlines()[-1])["understanding"]
    steps = " ".join(f"{s['who']} {s['what']}" for s in found["steps"]).lower()
    word = lambda w: {"linear": "linear|ticket", "code": "sam|bean-demo-prs", "brief": "brief|bri\\b", "sheet": "sheet|alex", "deck": "deck|dex"}.get(w, w)
    missing = [w for w in case["route"] if not re.search(word(w), steps)]
    forbidden = [w for w in case["forbid"] if re.search(word(w), steps)]
    asked = any(not d["canDecide"] for d in found["decisions"])
    decide_ok = case["decide"] == "any" or (case["decide"] == "asks") == asked
    understood = re.search(case["understood"], found["summary"].lower()) is not None
    good = understood and not missing and not forbidden and decide_ok
    score += good
    print(f"{'ok  ' if good else 'FAIL'} {case['id']}: understood {understood}, missing {missing}, forbidden {forbidden}, asked {asked} wanted {case['decide']}")
    print("     steps:", [f"{s['who']}: {s['what'][:70]}" for s in found["steps"]])
    shutil.rmtree(root, ignore_errors=True)
print(f"score {score}, spent ${spent():.4f}")
