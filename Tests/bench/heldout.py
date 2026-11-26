"""The held-out set: tasks never run while the harness was being changed.

    python3 Tests/bench/heldout.py draw     # once: picks the tasks, writes heldout.json
    python3 Tests/bench/heldout.py check    # are the instructions still the frozen ones?
    python3 Tests/bench/heldout.py run      # runs all three on the held-out tasks

Rules, so the number means something:
- `draw` leaves out every task that appears in results/ (the practice set), and prints
  only counts, never the tasks, so nobody reads them before the run.
- Run it at checkpoints, not to tune: don't change the harness from a held-out task's
  trace. A failure seen here goes back into the practice set or the course as a new,
  general case, and the held-out task is retired and replaced by a fresh draw.
- The model-facing instructions are frozen (fingerprint in heldout.json). `run` refuses
  if they changed, so a held-out score never mixes harness work with prompt tuning.
"""
import glob, hashlib, json, os, random, re, subprocess, sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FILE = os.path.join(HERE, "heldout.json")
SIZES = {"webvoyager": 90, "mind2web": 60, "bubench": 16}   # mind2web: a third per level
SEED = 20261126


def fingerprint():
    """The text the agent model reads as instructions: Sill's MCP instructions and each
    runner's task prompt. Tool behaviour can change; this text can't."""
    parts = []
    src = open(os.path.join(ROOT, "Sources", "sill-mcp", "main.swift")).read()
    m = re.search(r'let instructions = """(.*?)\n"""', src, re.S)
    if not m: raise SystemExit("Couldn't find Sill's instructions in main.swift")
    parts.append(m.group(1))
    for name in ("run.py", "m2w.py", "bubench.py"):
        m = re.search(r'AGENT_PROMPT = """(.*?)"""', open(os.path.join(HERE, name)).read(), re.S)
        parts.append(m.group(1) if m else "")
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:16]


def seen():
    """Every task id in any saved result: the practice set."""
    ids = set()
    for f in glob.glob(os.path.join(HERE, "results", "*.json")):
        try: d = json.load(open(f))
        except Exception: continue
        for r in (d.get("results", []) if isinstance(d, dict) else d):
            if isinstance(r, dict) and r.get("id"): ids.add(r["id"])
    return ids


def draw():
    if os.path.exists(FILE): raise SystemExit("heldout.json already exists: the set is drawn once")
    sys.path.insert(0, HERE)
    import run, m2w, bubench
    used = seen()
    rng = random.Random(SEED)

    tasks, impossible, _ = run.load_tasks()
    pool = [t for t in tasks if t["id"] not in used and t["id"] not in impossible and not run.stale_date(t, date.today())]
    sites = {}
    for t in pool: sites.setdefault(t["web_name"], []).append(t["id"])
    order = sorted(sites); rng.shuffle(order)
    for s in order: rng.shuffle(sites[s])
    wv = []
    while len(wv) < SIZES["webvoyager"] and any(sites.values()):
        for s in order:
            if sites[s] and len(wv) < SIZES["webvoyager"]: wv.append(sites[s].pop())

    mw = []
    tasks = m2w.load()
    for level in ("easy", "medium", "hard"):
        p = sorted(t["id"] for t in tasks if t["level"] == level and t["id"] not in used)
        rng.shuffle(p); mw += p[:SIZES["mind2web"] // 3]

    tasks, _ = bubench.load()
    p = sorted(t["id"] for t in tasks if t["id"] not in used)
    bu = rng.sample(p, min(SIZES["bubench"], len(p)))

    data = {"drawn": date.today().isoformat(), "seed": SEED, "instructions": fingerprint(),
            "commit": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
            "practice_ids_left_out": len(used),
            "webvoyager": wv, "mind2web": mw, "bubench": bu, "retired": []}
    json.dump(data, open(FILE, "w"), indent=1)
    print(f"held out: {len(wv)} WebVoyager, {len(mw)} Online-Mind2Web, {len(bu)} BU Bench "
          f"({len(used)} practice tasks left out) · instructions {data['instructions']}")


def check(quiet=False):
    data = json.load(open(FILE))
    now = fingerprint()
    if now != data["instructions"]:
        raise SystemExit(f"Instructions changed since the freeze ({data['instructions']} → {now}): "
                         "a held-out score now would mix prompt tuning in. Put them back, or freeze again on purpose.")
    if not quiet: print(f"instructions frozen at {now}: unchanged")
    return data


def run_all(extra):
    data = check(quiet=True)
    common = ["--effort", "high", "--jev", "--parallel", "4"] + extra
    for script, key in (("m2w.py", "mind2web"), ("run.py", "webvoyager"), ("bubench.py", "bubench")):
        ids = [i for i in data[key] if i not in data["retired"]]
        print(f"== {script}: {len(ids)} held-out tasks", flush=True)
        subprocess.run([sys.executable, os.path.join(HERE, script), "--ids", ",".join(ids)] + common, cwd=ROOT)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "draw": draw()
    elif cmd == "check": check()
    elif cmd == "run": run_all(sys.argv[2:])
    else: raise SystemExit(__doc__)
