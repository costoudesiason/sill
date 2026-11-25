#!/usr/bin/env python3
"""WebVoyager tasks done by Claude Code driving Sill through sill-mcp: how often, how fast.

    python3 Tests/bench/fetch.py            # once: tasks and reference answers into data/
    python3 Tests/bench/run.py              # 15 tasks, one per site, fixed seed
    python3 Tests/bench/run.py --n 2
    python3 Tests/bench/run.py --sites Allrecipes,GitHub --n 6
    python3 Tests/bench/run.py --ids "Apple--3,ArXiv--7" --model opus --effort high

It runs its own copy of Sill (SILL_PROFILE=bench: its own bundle id, profile, settings and
socket), opened in the background and quit afterwards: the Sill you're using is never touched.
Tasks run one at a time. Each is `claude -p` with only Sill's tools; a second `claude -p`
with no tools judges the answer against WebVoyager's reference. Results go to results/."""
import concurrent.futures, threading, argparse, json, os, random, re, signal, socket, statistics, subprocess, sys, tempfile, threading, time
from datetime import date, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
DATA = os.path.join(HERE, "data")
RESULTS = os.path.join(HERE, "results")
APP = os.environ.get("SILL_APP", os.path.join(ROOT, "build/Sill Chromium.app"))
PROFILE = "bench"
DOMAIN = f"com.iasoncostoudes.sill.chromium.{PROFILE}"     # the bench copy's own settings
SOCKET = os.path.expanduser(f"~/Library/Application Support/Sill Chromium ({PROFILE})/agent.sock")
COPY = os.path.expanduser("~/Library/Caches/Sill Bench/Sill Bench.app")
MCP_BIN = os.path.join(COPY, "Contents/Helpers/sill-mcp")

# Tools the agent may not use: nobody is there to answer a hand-over, and nothing should be
# uploaded or saved. Everything else Sill offers is allowed; no built-in Claude Code tool is.
DENIED = ["wait_for_user", "page_upload", "passwords_save", "passwords_list", "page_sign_in"]

# ---------------------------------------------------------------- tasks

MONTHS = {m: i + 1 for i, m in enumerate(
    "january february march april may june july august september october november december".split())}
MONTH_RE = r"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?"
# Tasks that need a date still to come: a stay, a flight, a pickup.
FORWARD = re.compile(r"\b(hotel|stay|flight|fare|book|reserve|pickup|pick-up|depart|round[- ]trip|one[- ]way)\b", re.I)

def month_no(word):
    word = word.lower().rstrip(".")
    return next(n for m, n in MONTHS.items() if m.startswith(word[:3]))

def dates_in(text):
    """Explicit dates with a year: 'March 5, 2025', '5 March 2025', '20/12/2024', '2025-03-05'."""
    out = []
    for m in re.finditer(MONTH_RE + r"\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*[-–]\s*\d{1,2}(?:st|nd|rd|th)?)?,?\s+(20\d\d)", text, re.I):
        out.append((int(m.group(3)), month_no(m.group(1)), int(m.group(2))))
    for m in re.finditer(r"(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?" + MONTH_RE + r",?\s+(20\d\d)", text, re.I):
        out.append((int(m.group(3)), month_no(m.group(2)), int(m.group(1))))
    for m in re.finditer(r"\b(\d{1,2})/(\d{1,2})/(20\d\d)\b", text):
        out.append((int(m.group(3)), int(m.group(2)), int(m.group(1))))
    for m in re.finditer(r"\b(20\d\d)-(\d{2})-(\d{2})\b", text):
        out.append((int(m.group(1)), int(m.group(2)), int(m.group(3))))
    return [date(y, mo, d) for y, mo, d in out if 1 <= mo <= 12 and 1 <= d <= 31]

def stale_date(task, today):
    """A booking-like task whose explicit date has passed can't be done any more."""
    if task["web_name"] not in ("Booking", "Google Flights") and not FORWARD.search(task["ques"]):
        return False
    return any(d < today for d in dates_in(task["ques"]))

def load_tasks():
    patched = os.path.join(DATA, "browser-use.WebVoyager_data.jsonl")
    source = patched if os.path.exists(patched) else os.path.join(DATA, "WebVoyager_data.jsonl")
    if not os.path.exists(source):
        raise SystemExit("No tasks yet: run python3 Tests/bench/fetch.py first")
    tasks = [json.loads(l) for l in open(source) if l.strip()]
    refs = json.load(open(os.path.join(DATA, "reference_answer.json")))
    for t in tasks:
        n = int(t["id"].rsplit("--", 1)[1])
        ans = next((a for a in refs.get(t["web_name"], {}).get("answers", []) if a["id"] == n), None)
        t["reference"] = ans["ans"] if ans else ""
        t["reference_type"] = ans["type"] if ans else ""
        t["reference_notice"] = refs.get(t["web_name"], {}).get("notice", "")
    impossible = set()
    path = os.path.join(DATA, "browser-use.ImpossibleTasks.json")
    if os.path.exists(path): impossible = set(json.load(open(path)))
    return tasks, impossible, os.path.basename(source)

def pick(tasks, impossible, args, today):
    by_id = {t["id"]: t for t in tasks}
    if args.ids:
        ids = [i.strip() for i in args.ids.split(",") if i.strip()]
        missing = [i for i in ids if i not in by_id]
        if missing: raise SystemExit(f"Unknown task ids: {', '.join(missing)}")
        return [by_id[i] for i in ids], {}
    skipped = {"impossible": 0, "stale date": 0}
    pool = []
    for t in tasks:
        if t["id"] in impossible: skipped["impossible"] += 1; continue
        if stale_date(t, today): skipped["stale date"] += 1; continue
        pool.append(t)
    if args.sites:
        wanted = {s.strip().lower() for s in args.sites.split(",")}
        pool = [t for t in pool if t["web_name"].lower() in wanted]
        if not pool: raise SystemExit(f"No tasks for sites {args.sites}")
    # Spread across sites: shuffle each site's tasks with the seed, then take round-robin.
    rng = random.Random(args.seed)
    sites = {}
    for t in pool: sites.setdefault(t["web_name"], []).append(t)
    order = sorted(sites)
    rng.shuffle(order)
    for s in order: rng.shuffle(sites[s])
    chosen = []
    while len(chosen) < args.n and any(sites.values()):
        for s in order:
            if sites[s] and len(chosen) < args.n: chosen.append(sites[s].pop())
    return chosen, skipped

# ---------------------------------------------------------------- Sill's bench copy

def owner_of_socket():
    out = subprocess.run(["lsof", "-t", SOCKET], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None

def is_our_copy(pid):
    """True only for a process running from the bench copy: never the Sill you use."""
    exe = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return exe.startswith(COPY + "/")

def prepare_copy():
    """A clone of the built app with its own identity (bundle id …bench), so nothing aimed
    at Sill reaches it and it shares nothing with the Sill you use. APFS clone: no extra disk."""
    built = os.path.join(APP, "Contents/MacOS/Sill")
    if not os.path.exists(built): raise SystemExit(f"No Sill build at {APP} (set SILL_APP)")
    mine = os.path.join(COPY, "Contents/MacOS/Sill")
    source = COPY + ".source"   # which build the copy was made from: a different one (an A/B run) is copied again
    same = os.path.exists(source) and open(source).read() == os.path.realpath(APP)
    if same and os.path.exists(mine) and os.path.getmtime(mine) >= os.path.getmtime(built): return
    subprocess.run(["rm", "-rf", COPY]); os.makedirs(os.path.dirname(COPY), exist_ok=True)
    subprocess.run(["cp", "-Rc", APP, COPY], check=True)
    plist = os.path.join(COPY, "Contents/Info.plist")
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {DOMAIN}", plist], check=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleName Sill Bench", plist])
    subprocess.run(["codesign", "--force", "-s", "-", COPY], capture_output=True)
    os.utime(mine)
    with open(source, "w") as fh: fh.write(os.path.realpath(APP))

def use_profile(name):
    """A profile of the bench copy's own: a fresh one per run (no cart, cookies or notes from the last)."""
    global PROFILE, DOMAIN, SOCKET
    PROFILE = name
    DOMAIN = f"com.iasoncostoudes.sill.chromium.{PROFILE}"
    SOCKET = os.path.expanduser(f"~/Library/Application Support/Sill Chromium ({PROFILE})/agent.sock")

# The benchmarks' sites are mostly American: the copy keeps US time (a date picked is the date meant).
BENCH_TZ = os.environ.get("BENCH_TZ", "America/New_York")

def start_copy():
    prepare_copy()
    subprocess.run(["defaults", "write", DOMAIN, "agentControl", "-bool", "true"])
    subprocess.run(["defaults", "write", DOMAIN, "restoresTabs", "-bool", "false"])
    if owner_of_socket(): return
    subprocess.run(["open", "-n", "-g", "--env", f"SILL_PROFILE={PROFILE}", "--env", f"TZ={BENCH_TZ}", COPY])
    for _ in range(180):
        if owner_of_socket(): time.sleep(1.5); return
        time.sleep(0.5)
    raise SystemExit("Sill's bench copy didn't start")

def stop_copy():
    pid = owner_of_socket()
    if pid and is_our_copy(pid):
        os.kill(pid, signal.SIGTERM)
        for _ in range(20):
            if not owner_of_socket(): return
            time.sleep(0.25)
    elif pid:
        print(f"warning: {SOCKET} is held by pid {pid}, which isn't the bench copy; left alone", file=sys.stderr)

def sill(cmd, args=None, timeout=15):
    """One command on the bench copy's socket."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(timeout)
    s.connect(SOCKET)
    s.sendall((json.dumps({"id": 1, "cmd": cmd, "args": args or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: break
        buf += chunk
    s.close()
    return json.loads(buf or b"{}")

def tidy_tabs():
    """Close what the last task left open: each task starts from one blank tab."""
    try:
        tabs = sill("tabs.list").get("result", [])
        if isinstance(tabs, dict): tabs = tabs.get("tabs", [])
        for t in tabs:
            sill("tabs.close", {"tab": t["id"]})
    except Exception as e:
        print(f"  (couldn't tidy tabs: {e})", file=sys.stderr)

# ---------------------------------------------------------------- Claude Code

def claude_bin():
    found = subprocess.run(["zsh", "-ic", "whence -p claude"], capture_output=True, text=True).stdout.strip().splitlines()
    path = found[-1] if found else ""
    if not path or not os.path.exists(path):
        path = os.path.expanduser("~/.local/bin/claude")
    return path

def claude_env(config_dir):
    """As the user's `claude` shell function: their normal config dir, no API overrides,
    and nothing inherited from a Claude Code session this may be running inside."""
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("CLAUDE") or k.startswith("ANTHROPIC"))}
    env["CLAUDE_CONFIG_DIR"] = config_dir
    return env

def run_claude(argv, env, timeout, cwd):
    """Run claude -p with stream-json; yields (events, timed_out, stderr). Kills the whole
    process group (claude and its sill-mcp) at the deadline."""
    p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                         text=True, env=env, cwd=cwd, start_new_session=True)
    events, err = [], []
    def read_out():
        for line in p.stdout:
            line = line.strip()
            if not line: continue
            try: events.append((time.time(), json.loads(line)))
            except ValueError: err.append(line)
    def read_err():
        for line in p.stderr: err.append(line.rstrip())
    to, te = threading.Thread(target=read_out, daemon=True), threading.Thread(target=read_err, daemon=True)
    to.start(); te.start()
    timed_out = False
    try:
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try: os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL); p.wait()
    to.join(2); te.join(2)
    return events, timed_out, err

AGENT_PROMPT = """Use the Sill browser tools to do this task on {web} (start there: {url}).

Task: {ques}

Notes:
- Today is {today}. If the task names a date without a year, use its next occurrence.
- Nobody is watching: don't wait for a person. If a CAPTCHA, sign-in wall or other block stops you, say so in your answer.
- Don't buy, book, send or post anything; stop at the last step before committing and report what you found.
- When you're done, give the final answer in a single line starting with ANSWER: (include the specifics the task asks for: names, numbers, prices, links)."""

def agent_argv(binary, task, args, mcp_config, today):
    prompt = AGENT_PROMPT.format(web=task["web_name"], url=task["web"], ques=task["ques"].strip(), today=today.strftime("%B %-d, %Y"))
    argv = [binary, "-p", prompt, "--dangerously-skip-permissions",
            "--output-format", "stream-json", "--verbose",
            "--model", args.model,
            "--mcp-config", mcp_config, "--strict-mcp-config",
            "--tools", "",                                   # no built-in tools at all
            "--allowedTools", "mcp__sill__*",
            "--disallowedTools", ",".join(["WebFetch", "WebSearch", "Bash", "Task", "Agent"] + [f"mcp__sill__{t}" for t in DENIED]),
            "--disable-slash-commands", "--no-session-persistence",
            "--max-turns", str(args.max_turns)]
    if args.effort: argv += ["--effort", args.effort]
    return argv

def summarize_agent(events, timed_out, err, started):
    tools, tool_errors, text = [], 0, []
    result, first_tool_at = None, None
    for at, e in events:
        if e.get("type") == "assistant":
            for block in e.get("message", {}).get("content", []) or []:
                if block.get("type") == "tool_use":
                    tools.append(block.get("name", "").replace("mcp__sill__", ""))
                    first_tool_at = first_tool_at or at
                elif block.get("type") == "text":
                    text.append(block.get("text", ""))
        elif e.get("type") == "user":
            content = e.get("message", {}).get("content", [])
            if isinstance(content, list):
                tool_errors += sum(1 for b in content if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"))
        elif e.get("type") == "result":
            result = e
    final = (result or {}).get("result") or "\n".join(text)
    answers = [l.split("ANSWER:", 1)[1].strip() for l in final.splitlines() if "ANSWER:" in l]
    if not answers:   # the line may be in an earlier message when the last one is a sign-off
        answers = [l.split("ANSWER:", 1)[1].strip() for l in "\n".join(text).splitlines() if "ANSWER:" in l]
    errors = []
    if timed_out: errors.append("timeout")
    if result and result.get("is_error"): errors.append(f"agent error: {(result.get('result') or result.get('subtype') or '')[:200]}")
    if result and result.get("subtype") not in (None, "success"): errors.append(f"agent stopped: {result.get('subtype')}")
    if not result and not timed_out: errors.append("no result event" + (f": {' | '.join(err[-3:])[:300]}" if err else ""))
    usage = (result or {}).get("usage") or {}
    return {
        "seconds": round(time.time() - started, 1),          # wall time, claude's start-up included
        "agent_seconds": round((result.get("duration_ms") or 0) / 1000, 1) if result else None,
        "first_tool_seconds": round(first_tool_at - started, 1) if first_tool_at else None,
        "tool_calls": len(tools),
        "tools": tools,
        "tool_errors": tool_errors,
        "turns": (result or {}).get("num_turns"),
        "models": sorted(((result or {}).get("modelUsage") or {}).keys()),   # what actually answered
        "cost_usd": (result or {}).get("total_cost_usd"),
        "input_tokens": sum(usage.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")),
        "output_tokens": usage.get("output_tokens"),
        "answer": answers[-1] if answers else "",
        "final_message": final[-2000:],
        "errors": errors,
    }

JUDGE_PROMPT = """You are grading a web agent on a WebVoyager benchmark task. You see only the task, a reference answer and the agent's final answer (no screenshots).

Task (on {web}): {ques}

Reference answer ({kind}): {ref}
{notice}
The agent's answer: {answer}

Grading rules:
- A "possible" reference is one valid answer among many; live sites change (prices, ratings, review counts, news). Accept a different answer when it plausibly and specifically satisfies every requirement of the task.
- A "golden" reference is the expected answer; the agent's answer must agree with it.
- FAIL when the answer is missing, vague, says the agent was blocked or couldn't finish, ignores a requirement of the task, or contradicts a golden reference.

Reply with exactly two lines:
VERDICT: SUCCESS or VERDICT: FAIL
REASON: one sentence"""

def judge(binary, env, task, answer, model, cwd):
    if not answer.strip():
        return "FAIL", "no ANSWER line"
    prompt = JUDGE_PROMPT.format(web=task["web_name"], ques=task["ques"].strip(), kind=task["reference_type"] or "unknown",
                                 ref=task["reference"] or "(none)", answer=answer,
                                 notice=f"Reference note: {task['reference_notice'].strip()}\n" if task["reference_notice"].strip() else "")
    argv = [binary, "-p", prompt, "--output-format", "stream-json", "--verbose", "--model", model,
            "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--disable-slash-commands", "--no-session-persistence", "--max-turns", "2"]
    events, timed_out, err = run_claude(argv, env, 120, cwd)
    out = next((e.get("result") or "" for _, e in events if e.get("type") == "result"), "")
    m = re.search(r"VERDICT:\s*(SUCCESS|FAIL)", out, re.I)
    reason = re.search(r"REASON:\s*(.+)", out)
    if not m: return "ERROR", f"judge said: {out[:200] or (err[-1] if err else 'nothing')}"
    return m.group(1).upper(), reason.group(1).strip() if reason else ""

def preflight(binary, env, cwd, model):
    """One trivial request, so a signed-out config fails here and not as 15 failed tasks."""
    argv = [binary, "-p", "Reply with just: ok", "--output-format", "stream-json", "--verbose", "--model", model,
            "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--no-session-persistence", "--max-turns", "1"]
    events, _, err = run_claude(argv, env, 90, cwd)
    r = next((e for _, e in events if e.get("type") == "result"), None)
    if not r or r.get("is_error"):
        why = (r or {}).get("result") or " | ".join(err[-3:]) or "no answer"
        raise SystemExit(f"claude can't run with CLAUDE_CONFIG_DIR={env['CLAUDE_CONFIG_DIR']}: {why}\n"
                         f"Sign in there (CLAUDE_CONFIG_DIR={env['CLAUDE_CONFIG_DIR']} claude auth login) or pass --config-dir.")

# ---------------------------------------------------------------- main

def git_rev():
    r = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    return r.stdout.strip()

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=15, help="number of tasks (default 15)")
    ap.add_argument("--sites", help="comma-separated web_name filter, e.g. 'Allrecipes,GitHub'")
    ap.add_argument("--ids", help="comma-separated task ids, e.g. 'Apple--3,ArXiv--7' (skips filtering)")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--model", default="sonnet", help="agent model (default sonnet)")
    ap.add_argument("--judge-model", default="sonnet")
    ap.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max"], help="agent effort (default: claude's own)")
    ap.add_argument("--timeout", type=int, default=240, help="seconds per task (default 240)")
    ap.add_argument("--max-turns", type=int, default=60)
    ap.add_argument("--jev", action="store_true", help="give the agent page_goal, driven by TypeSafe's Jev")
    ap.add_argument("--parallel", type=int, default=3, help="tasks at once (default 3; 1 = one at a time, tabs tidied between)")
    ap.add_argument("--config-dir", default=os.environ.get("BENCH_CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude-normal")),
                    help="CLAUDE_CONFIG_DIR for claude (default ~/.claude-normal, as the user's claude function)")
    ap.add_argument("--keep", action="store_true", help="leave the bench copy running afterwards")
    ap.add_argument("--list", action="store_true", help="print the chosen tasks and exit")
    args = ap.parse_args()

    today = date.today()
    tasks, impossible, source = load_tasks()
    chosen, skipped = pick(tasks, impossible, args, today)
    if args.list:
        for t in chosen: print(f"{t['id']:22} {t['ques'][:110]}")
        if skipped: print(f"\nleft out of the pool: {skipped}")
        return

    binary = claude_bin()
    env = claude_env(os.path.expanduser(args.config_dir))
    work = tempfile.mkdtemp(prefix="sill-bench-")    # empty cwd: no project CLAUDE.md
    preflight(binary, env, work, args.model)
    version = subprocess.run([binary, "--version"], capture_output=True, text=True, env=env).stdout.strip()
    mcp_env = {"SILL_SOCKET": SOCKET}
    if args.jev:
        # TypeSafe's Jev drives the clicking (page_goal): the key from the env, else the Keychain item Sill uses.
        key = os.environ.get("TYPESAFE_API_KEY") or subprocess.run(["security", "find-generic-password", "-s", "Sill TypeSafe", "-a", "api", "-w"],
                                                                   capture_output=True, text=True).stdout.strip()
        if not key: raise SystemExit("--jev needs a TypeSafe key (TYPESAFE_API_KEY, or the Keychain item \"Sill TypeSafe\").")
        mcp_env["TYPESAFE_API_KEY"] = key
    # In a file only you can read, not on a command line where `ps` would show the key.
    mcp_config = os.path.join(work, "mcp.json")
    with open(os.open(mcp_config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        json.dump({"mcpServers": {"sill": {"command": MCP_BIN, "env": mcp_env}}}, fh)

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    os.makedirs(RESULTS, exist_ok=True)
    out_path = os.path.join(RESULTS, f"{stamp}.json")
    print(f"{len(chosen)} tasks from {source} · agent {args.model}{' · effort ' + args.effort if args.effort else ''} · judge {args.judge_model} · {args.timeout} s each")
    if skipped: print(f"left out of the pool: {skipped['impossible']} impossible (Browser Use's list), {skipped['stale date']} with dates now past")

    if not args.keep: stop_copy()      # always the current build
    start_copy()
    rows = []
    trail = os.path.join(RESULTS, stamp)          # each task's whole transcript, to see what went wrong
    os.makedirs(trail, exist_ok=True)
    lock = threading.Lock()
    def one(i, t):
        if args.parallel == 1: tidy_tabs()
        with lock: print(f"[{i}/{len(chosen)}] {t['id']}: {t['ques'][:90]}", flush=True)
        started = time.time()
        events, timed_out, err = run_claude(agent_argv(binary, t, args, mcp_config, today), env, args.timeout, work)
        with open(os.path.join(trail, t["id"].replace("/", "_") + ".json"), "w") as fh:
            json.dump([{"at": round(at - started, 2), **e} for at, e in events], fh, indent=1)
        row = {"id": t["id"], "site": t["web_name"], "question": t["ques"], "reference": t["reference"],
               "reference_type": t["reference_type"], **summarize_agent(events, timed_out, err, started)}
        row["verdict"], row["judge_reason"] = judge(binary, env, t, row["answer"], args.judge_model, work)
        with lock:
            rows.append(row)
            print(f"    {t['id']}: {row['verdict']:7} {row['seconds']:6.1f} s  {row['tool_calls']:3} tools  {row['answer'][:100]}"
                  + (f"  [{'; '.join(row['errors'])}]" if row["errors"] else ""), flush=True)
            write(out_path, args, version, source, skipped, sorted(rows, key=lambda r: [x["id"] for x in chosen].index(r["id"])))
    try:
        tidy_tabs()
        # Several agents at once, each in its own tabs (Sill keeps a current tab per client).
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
            for f in [pool.submit(one, i, t) for i, t in enumerate(chosen, 1)]: f.result()
    finally:
        if not args.keep: stop_copy()
    rows.sort(key=lambda r: [x["id"] for x in chosen].index(r["id"]))

    report(rows)
    print(f"\nresults: {os.path.relpath(out_path, ROOT)}")

def totals(rows):
    secs = [r["seconds"] for r in rows]
    passed = sum(r["verdict"] == "SUCCESS" for r in rows)
    return {
        "tasks": len(rows), "passed": passed,
        "success_rate": round(passed / len(rows), 3) if rows else None,
        "median_seconds": round(statistics.median(secs), 1) if secs else None,
        "mean_seconds": round(statistics.mean(secs), 1) if secs else None,
        "mean_tool_calls": round(statistics.mean(r["tool_calls"] for r in rows), 1) if rows else None,
        "timeouts": sum("timeout" in r["errors"] for r in rows),
        "cost_usd": round(sum(r["cost_usd"] or 0 for r in rows), 3),
    }

def write(path, args, version, source, skipped, rows):
    with open(path, "w") as fh:
        json.dump({"when": datetime.now().isoformat(timespec="seconds"), "git": git_rev(), "app": APP,
                   "claude": version, "config_dir": args.config_dir, "model": args.model, "effort": args.effort, "jev": args.jev, "judge_model": args.judge_model,
                   "timeout": args.timeout, "seed": args.seed, "tasks_file": source, "left_out": skipped,
                   "judge": "text-only (task, reference, agent answer); WebVoyager's own judge uses screenshots and GPT-4V",
                   "totals": totals(rows), "results": rows}, fh, indent=1)

def report(rows):
    print(f"\n{'task':22} {'result':7} {'secs':>6} {'tools':>5}  why")
    for r in rows:
        print(f"{r['id']:22} {r['verdict']:7} {r['seconds']:6.1f} {r['tool_calls']:5}  {r['judge_reason'][:80]}")
    t = totals(rows)
    if not rows: return
    print(f"\n{t['passed']}/{t['tasks']} passed ({t['success_rate']:.0%}) · median {t['median_seconds']} s · mean {t['mean_seconds']} s"
          f" · mean {t['mean_tool_calls']} tool calls · {t['timeouts']} timeouts · ${t['cost_usd']}")

if __name__ == "__main__":
    main()
