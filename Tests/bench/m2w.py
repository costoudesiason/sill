#!/usr/bin/env python3
"""Online-Mind2Web tasks with Claude driving a copy of Sill, graded with screenshots.

    python3 Tests/bench/m2w.py --per-level 10 --jev        # 10 easy, 10 medium, 10 hard
    python3 Tests/bench/m2w.py --ids 0059adc6b12a3822305deb68929b2de8

Online-Mind2Web (OSU NLP): 300 tasks on 136 live websites, by difficulty. The task list
is read from Aside's public results (github.com/at-inc/aside-benchmarks, mind2web/results),
which also gives a point of comparison: Aside reports 297/300 with GPT-5.5. The grader here
is Online-Mind2Web's WebJudge (judges.py: its prompts word for word) on a Claude model, reading
the pictures the harness took after every action (never shown to the agent). The paper's judge
model is o4-mini; compare with that in mind."""
import argparse, concurrent.futures, json, os, random, re, subprocess, sys, tempfile, threading, time
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as bench
import judges
from bubench import run_with_input, trajectory

ASIDE = os.environ.get("ASIDE_REPO", "/tmp/aside/aside-benchmarks")
RESULTS = os.path.join(bench.HERE, "results")

AGENT_PROMPT = """Use the Sill browser tools to do this task on {web}:

{task}

- Nobody is watching: don't wait for a person. If a CAPTCHA or sign-in wall stops you, say so.
- Don't buy, pay, book, send, post or enter personal data: stop at the last step before anything that commits, with everything set.
- Leave the page showing the result. End with a short answer starting ANSWER: saying what you did and what the page shows."""

JUDGE = """You grade a web agent's run on an Online-Mind2Web task. Decide whether the agent fully accomplished the task on the live website.

Task (on {web}): {task}

Rules:
- Identify the task's key requirements (the item, every filter, sort, date, location, quantity, and the final state asked for).
- SUCCESS only when every requirement is met and shown in the evidence: the pictures, the page states in the trajectory, or the agent's answer backed by them. A requirement claimed but not evidenced is not met.
- When the task needs a commit the agent was told not to make (pay, book, send), stopping at the last step with everything set counts as success.
- FAIL when a requirement is missing, wrong, or blocked, or the agent gave up.

<trajectory>
{traj}
</trajectory>
<answer>
{answer}
</answer>

Reply with exactly two lines:
VERDICT: SUCCESS or VERDICT: FAIL
REASON: one sentence"""


def load():
    if not os.path.isdir(os.path.join(ASIDE, "mind2web", "results")):
        subprocess.run(["git", "clone", "--depth", "1", "https://github.com/at-inc/aside-benchmarks.git", ASIDE], check=True)
    tasks = []
    folder = os.path.join(ASIDE, "mind2web", "results")
    for d in sorted(os.listdir(folder)):
        try: r = json.load(open(os.path.join(folder, d, "result.json")))
        except Exception: continue
        tasks.append({"id": r["task_id"], "level": r.get("level", "?"), "task": r["task"], "web": r["website"],
                      "aside": r.get("graderVerdict") or r.get("outcome")})
    return tasks


def grade(binary, env, t, events, answer, model, cwd):
    shots = []
    for _, e in events:
        if e.get("type") == "user" and isinstance(e.get("message", {}).get("content"), list):
            for b in e["message"]["content"]:
                if b.get("type") == "tool_result" and isinstance(b.get("content"), list):
                    shots += [x for x in b["content"] if isinstance(x, dict) and x.get("type") == "image" and x.get("source", {}).get("data")]
    if len(shots) > 8: shots = [shots[round(i * (len(shots) - 1) / 7)] for i in range(8)]
    traj = trajectory(events)
    if len(traj) > 120_000: traj = traj[:40_000] + "\n…\n" + traj[-80_000:]
    content = [{"type": "text", "text": JUDGE.format(web=t["web"], task=t["task"], traj=traj, answer=answer or "(none)")}]
    content += [{"type": "image", "source": s["source"]} for s in shots]
    argv = [binary, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", model,
            "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--disable-slash-commands", "--no-session-persistence", "--max-turns", "2"]
    evs, _, err = run_with_input(argv, env, 300, cwd, json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n")
    out = next((e.get("result") or "" for _, e in evs if e.get("type") == "result"), "")
    m = re.search(r"VERDICT:\s*(SUCCESS|FAIL)", out, re.I)
    reason = re.search(r"REASON:\s*(.+)", out)
    return (m.group(1).upper() if m else "ERROR"), (reason.group(1).strip() if reason else out[:200])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--per-level", type=int, default=10)
    ap.add_argument("--ids", default="")
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--model", default="claude-sonnet-5-5")
    ap.add_argument("--judge-model", default="gpt-5.6-luna")
    ap.add_argument("--judge-effort", default="xhigh")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--jev", action="store_true")
    ap.add_argument("--keep-profile", action="store_true", help="reuse the bench profile (default: a fresh one per run)")
    ap.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max"])
    ap.add_argument("--config-dir", default=os.environ.get("BENCH_CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude-normal")))
    args = ap.parse_args()

    tasks = load()
    if args.ids:
        want = set(i.strip() for i in args.ids.split(","))
        chosen = [t for t in tasks if t["id"] in want]
    else:
        rng = random.Random(args.seed)
        chosen = []
        for level in ("easy", "medium", "hard"):
            pool = [t for t in tasks if t["level"] == level]
            rng.shuffle(pool)
            chosen += pool[:args.per_level]
    binary = bench.claude_bin()
    env = bench.claude_env(os.path.expanduser(args.config_dir))
    work = tempfile.mkdtemp(prefix="sill-m2w-")
    if not args.keep_profile: bench.use_profile("bench-" + datetime.now().strftime("%m%d%H%M%S"))
    mcp_env = {"SILL_SOCKET": bench.SOCKET}
    if args.jev:
        key = os.environ.get("TYPESAFE_API_KEY") or subprocess.run(["security", "find-generic-password", "-s", "Sill TypeSafe", "-a", "api", "-w"],
                                                                   capture_output=True, text=True).stdout.strip()
        if key: mcp_env["TYPESAFE_API_KEY"] = key
    mcp_config = os.path.join(work, "mcp.json")
    with open(os.open(mcp_config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        json.dump({"mcpServers": {"sill": {"command": bench.MCP_BIN, "env": mcp_env}}}, fh)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    trail = os.path.join(RESULTS, f"m2w-{stamp}")
    os.makedirs(trail, exist_ok=True)
    print(f"{len(chosen)} Online-Mind2Web tasks · agent {args.model}{' + Jev' if args.jev else ''} · judge {args.judge_model} (with pictures) · {args.timeout} s each", flush=True)
    bench.stop_copy(); bench.start_copy()
    rows, lock = [], threading.Lock()

    def one(t):
        prompt = AGENT_PROMPT.format(web=t["web"], task=t["task"])
        argv = [binary, "-p", prompt, "--dangerously-skip-permissions", "--output-format", "stream-json", "--verbose", "--model", args.model,
                "--mcp-config", mcp_config, "--strict-mcp-config", "--tools", "", "--allowedTools", "mcp__sill__*",
                "--disallowedTools", ",".join(["WebFetch", "WebSearch", "Bash", "Task", "Agent"] + [f"mcp__sill__{d}" for d in bench.DENIED]),
                "--disable-slash-commands", "--no-session-persistence", "--max-turns", "80"] + (["--effort", args.effort] if args.effort else [])
        traced = os.path.join(trail, t["id"]); os.makedirs(traced, exist_ok=True)
        config = os.path.join(work, f"mcp-{t['id']}.json")
        with open(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
            json.dump({"mcpServers": {"sill": {"command": bench.MCP_BIN, "env": {**mcp_env, "SILL_TRACE_DIR": traced}}}}, fh)
        argv[argv.index(mcp_config)] = config
        started = time.time()
        events, timed_out, err = bench.run_claude(argv, env, args.timeout, work)
        s = bench.summarize_agent(events, timed_out, err, started)
        # WebJudge, as Online-Mind2Web's paper runs it, on the pictures the harness took after every action.
        ok, detail = judges.webjudge(judges.Claude(binary, env, args.judge_model, work, args.judge_effort), t["task"], judges.read_trace(traced), s["answer"] or s["final_message"][-1500:])
        verdict = "SUCCESS" if ok else "FAIL"
        reason = (detail["verdict"].split("Thoughts:")[-1].split("Status:")[0].strip() or "no verdict")[:400]
        with open(os.path.join(traced, "judge.json"), "w") as fh: json.dump(detail, fh, indent=1)
        with open(os.path.join(traced, "transcript.json"), "w") as fh:
            json.dump([{"at": round(at - started, 2), **e} for at, e in events], fh)
        row = {"id": t["id"], "level": t["level"], "task": t["task"], "web": t["web"], "aside": t["aside"], "verdict": verdict, "reason": reason,
               **{k: s[k] for k in ("seconds", "tool_calls", "tools", "cost_usd", "errors", "answer")}}
        with lock:
            rows.append(row)
            print(f"  [{t['level']:6}] {verdict:7} {row['seconds']:5.0f} s {row['tool_calls']:3} calls  {t['task'][:70]}  ({reason[:80]})", flush=True)
            json.dump({"when": stamp, "git": bench.git_rev(), "model": args.model, "jev": args.jev, "copy_restarts": len(bench.RESTARTS), "judge_model": args.judge_model, "results": rows},
                      open(os.path.join(RESULTS, f"m2w-{stamp}.json"), "w"), indent=1)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
            for f in [pool.submit(one, t) for t in chosen]: f.result()
    finally:
        bench.stop_copy()
        if not args.keep_profile: bench.discard_profile()
    print()
    for level in ("easy", "medium", "hard", None):
        rs = [r for r in rows if level is None or r["level"] == level]
        if not rs: continue
        ok = sum(r["verdict"] == "SUCCESS" for r in rs)
        secs = sorted(r["seconds"] for r in rs)
        print(f"{level or 'all':6} {ok}/{len(rs)} ({ok / len(rs):.0%}) · median {secs[len(secs) // 2]:.0f} s · mean {sum(r['tool_calls'] for r in rs) / len(rs):.1f} calls")
    if bench.RESTARTS: print(f"warning: the bench copy of Sill crashed and was restarted {len(bench.RESTARTS)} time(s) during this run")
    print(f"cost ${sum(r['cost_usd'] or 0 for r in rows):.2f} · results Tests/bench/results/m2w-{stamp}.json")


if __name__ == "__main__":
    main()
