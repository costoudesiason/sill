#!/usr/bin/env python3
"""BU Bench V2.1 (github.com/browser-use/benchmark) with Claude driving a copy of Sill.

    python3 Tests/bench/bubench.py --n 8 --jev            # the 8 shortest tasks
    python3 Tests/bench/bubench.py --ids bu2-014,bu2-120

The 200 tasks are long research-and-deliverable jobs, each scored against a weighted
rubric of findings. Their text is encrypted in the benchmark repository to keep it out of
training data: it is decrypted here in memory only, and never written into this repository
(results stay in the git-ignored results/ folder). Please don't publish decrypted tasks.

The agent is `claude -p` with Sill's tools and file tools inside an empty workspace
(deliverables go to ./outputs). The judge is `claude -p` given Browser Use's own findings
prompt, the rubric, the agent's trajectory (text only: no screenshots), its answer and its
files; it marks each rubric item met / violated / not assessable, and the score is the met
items' share of the weights, as Browser Use computes it. A different judge model and no
screenshots: scores are for comparing Sill builds, not with Browser Use's published ones."""
import argparse, ast, base64, concurrent.futures, hashlib, json, os, re, shutil, subprocess, sys, tempfile, threading, time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as bench   # the bench copy of Sill, claude helpers

REPO = os.environ.get("BU_BENCH_REPO", "/tmp/bubench/benchmark")
RESULTS = os.path.join(bench.HERE, "results")

AGENT_PROMPT = """{task}

How to work here:
- Use the Sill browser tools for the web. Save every file deliverable in ./outputs/ (create it), with the file tools.
- Nobody is watching: don't wait for a person. If a CAPTCHA, sign-in wall or other block stops you, say so plainly and carry on with what you can do.
- Don't buy, book, send, post, sign up or enter personal data.
- End with a short final report of what you found and what you saved."""

JUDGE_PROMPT = """{system}

Reply with ONE JSON object and nothing else:
{{"agent_task_reading": "...", "findings": [{{"item": "<item id>", "evidence": "...", "status": "met|violated|not_assessable", "not_assessable_reason": null}}], "observations": [], "infra_error": false, "pii_present": false, "reward_hacking_suspected": false, "flag_notes": null}}
Items, in order: {items}
There are no screenshots in this run: judge from the trajectory, the final result and the files.

<task>
{task}
</task>
<website>No website provided</website>
<rubric>
{rubric}
</rubric>
<agent_trajectory>
{trajectory}
</agent_trajectory>
<final_result>
{final}
</final_result>
<output_files>
{files}
</output_files>"""


def load():
    if not os.path.exists(os.path.join(REPO, "BU_Bench_V2.enc")):
        subprocess.run(["git", "clone", "--depth", "1", "https://github.com/browser-use/benchmark.git", REPO], check=True)
    from cryptography.fernet import Fernet
    key = base64.urlsafe_b64encode(hashlib.sha256(b"BU_Bench_V2").digest())
    data = json.loads(Fernet(key).decrypt(base64.b64decode(Path(REPO, "BU_Bench_V2.enc").read_text())))
    tasks = data["tasks"] if isinstance(data, dict) else data
    for t in tasks:
        w = t["weights"]
        t["weights"] = w if isinstance(w, dict) else ast.literal_eval(w)
    system = Path(REPO, "findings_judge.py").read_text()
    system = re.search(r'FINDINGS_SYSTEM_PROMPT = """(.*?)"""', system, re.S).group(1).strip()
    return tasks, system


def clip_middle(text, limit):
    if len(text) <= limit: return text
    half = limit // 2
    return text[:half] + f"\n…[{len(text) - limit} characters omitted]…\n" + text[-half:]


def trajectory(events):
    """The agent's steps as the judge reads them: its words, each tool call, each result (clipped)."""
    out, n = [], 0
    for _, e in events:
        if e.get("type") == "assistant":
            for b in e.get("message", {}).get("content", []) or []:
                if b.get("type") == "text" and b["text"].strip():
                    n += 1; out.append(f"[step {n}] agent: {b['text'].strip()}")
                elif b.get("type") == "tool_use":
                    n += 1; out.append(f"[step {n}] call {b['name'].replace('mcp__sill__', '')}: {json.dumps(b.get('input'))[:3000]}")
        elif e.get("type") == "user" and isinstance(e.get("message", {}).get("content"), list):
            for b in e["message"]["content"]:
                if b.get("type") == "tool_result":
                    c = b.get("content")
                    t = c if isinstance(c, str) else " ".join(x.get("text", "") for x in c or [] if isinstance(x, dict))
                    out.append(f"   result: {clip_middle(t, 12000)}")
    return "\n".join(out)


def files_text(folder):
    out = []
    for p in sorted(Path(folder).rglob("*")):
        if p.is_file():
            try: body = p.read_text(errors="replace")
            except Exception: body = f"(binary, {p.stat().st_size} bytes)"
            out.append(f"=== {p.relative_to(folder)} ===\n{clip_middle(body, 40_000)}")
    return "\n\n".join(out) or "(no files)"


def judge(binary, env, task, system, events, final, folder, model, cwd):
    items = list(task["weights"])
    prompt = JUDGE_PROMPT.format(system=system, items=", ".join(items), task=task["task"], rubric=task["rubric"],
                                 trajectory=clip_middle(trajectory(events), 300_000), final=clip_middle(final, 60_000),
                                 files=clip_middle(files_text(folder), 200_000))
    argv = [binary, "-p", prompt, "--output-format", "stream-json", "--verbose", "--model", model,
            "--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--disable-slash-commands", "--no-session-persistence", "--max-turns", "2"]
    evs, _, err = bench.run_claude(argv, env, 600, cwd)
    out = next((e.get("result") or "" for _, e in evs if e.get("type") == "result"), "")
    m = re.search(r"\{.*\}", out, re.S)
    if not m: return {"error": f"judge said: {out[:300] or (err[-1] if err else 'nothing')}"}
    try: j = json.loads(m.group(0))
    except ValueError as e: return {"error": f"judge JSON: {e}"}
    # Browser Use's arithmetic: worst finding per item wins; score = met weight / total; a canary leak or hacking zeroes it.
    sev = {"met": 0, "not_assessable": 1, "violated": 2}
    status = {}
    for f in j.get("findings", []):
        i, s = f.get("item"), f.get("status")
        if i in task["weights"] and s in sev and (i not in status or sev[s] > sev[status[i]]): status[i] = s
    canary = task.get("canary")
    leak = bool(canary) and (canary in final or canary in files_text(folder))
    earned = sum(w for i, w in task["weights"].items() if status.get(i) == "met")
    rh = bool(j.get("reward_hacking_suspected")) or leak
    return {"score": 0.0 if rh else earned / sum(task["weights"].values()), "earned": earned, "status": status,
            "observations": j.get("observations", []), "infra_error": j.get("infra_error"), "rh": rh, "canary_leak": leak,
            "findings": j.get("findings", [])}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=8, help="the N shortest tasks (default 8)")
    ap.add_argument("--ids", default="")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--judge-model", default="sonnet")
    ap.add_argument("--timeout", type=int, default=1500, help="seconds per task (default 1500; Browser Use allows 3600)")
    ap.add_argument("--max-turns", type=int, default=150)
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--jev", action="store_true")
    ap.add_argument("--config-dir", default=os.environ.get("BENCH_CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude-normal")))
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    tasks, system = load()
    if args.ids:
        want = [i.strip() for i in args.ids.split(",") if i.strip()]
        chosen = [t for t in tasks if t["id"] in want]
    else:
        chosen = sorted(tasks, key=lambda t: len(t["task"]))[:args.n]
    binary = bench.claude_bin()
    env = bench.claude_env(os.path.expanduser(args.config_dir))
    root = tempfile.mkdtemp(prefix="sill-bubench-")
    mcp_env = {"SILL_SOCKET": bench.SOCKET}
    if args.jev:
        key = os.environ.get("TYPESAFE_API_KEY") or subprocess.run(["security", "find-generic-password", "-s", "Sill TypeSafe", "-a", "api", "-w"],
                                                                   capture_output=True, text=True).stdout.strip()
        if key: mcp_env["TYPESAFE_API_KEY"] = key
    mcp_config = os.path.join(root, "mcp.json")
    with open(os.open(mcp_config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as fh:
        json.dump({"mcpServers": {"sill": {"command": bench.MCP_BIN, "env": mcp_env}}}, fh)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    trail = os.path.join(RESULTS, f"bubench-{stamp}")
    os.makedirs(trail, exist_ok=True)
    print(f"{len(chosen)} BU Bench V2.1 tasks · agent {args.model}{' + Jev' if args.jev else ''} · judge {args.judge_model} · {args.timeout} s each", flush=True)

    if not args.keep: bench.stop_copy()
    bench.start_copy()
    rows, lock = [], threading.Lock()

    def one(t):
        work = os.path.join(root, t["id"]); os.makedirs(os.path.join(work, "outputs"), exist_ok=True)
        argv = [binary, "-p", AGENT_PROMPT.format(task=t["task"]), "--dangerously-skip-permissions",
                "--output-format", "stream-json", "--verbose", "--model", args.model,
                "--mcp-config", mcp_config, "--strict-mcp-config",
                "--tools", "Read,Write,Edit,Glob",
                "--allowedTools", "mcp__sill__*,Read,Write,Edit,Glob",
                "--disallowedTools", ",".join(["WebFetch", "WebSearch", "Bash", "Task", "Agent"] + [f"mcp__sill__{d}" for d in bench.DENIED]),
                "--disable-slash-commands", "--no-session-persistence", "--max-turns", str(args.max_turns)]
        started = time.time()
        events, timed_out, err = bench.run_claude(argv, env, args.timeout, work)
        s = bench.summarize_agent(events, timed_out, err, started)
        final = s["final_message"]
        j = judge(binary, env, t, system, events, final, os.path.join(work, "outputs"), args.judge_model, root)
        row = {"id": t["id"], "title": t["title"], "seconds": s["seconds"], "tool_calls": s["tool_calls"], "tools": s["tools"],
               "cost_usd": s["cost_usd"], "errors": s["errors"], "turns": s["turns"], **j}
        shutil.copytree(os.path.join(work, "outputs"), os.path.join(trail, t["id"], "outputs"), dirs_exist_ok=True)
        with open(os.path.join(trail, t["id"], "events.json"), "w") as fh:
            json.dump([{"at": round(at - started, 2), **e} for at, e in events], fh)
        with lock:
            rows.append(row)
            sc = row.get("score")
            print(f"  {t['id']} {t['title'][:40]:40} score {sc if sc is None else round(sc, 2)}  {row['seconds']:6.0f} s  {row['tool_calls']:3} calls"
                  + (f"  [{'; '.join(row['errors'])}]" if row["errors"] else "") + (f"  judge: {row['error']}" if row.get("error") else ""), flush=True)
            with open(os.path.join(RESULTS, f"bubench-{stamp}.json"), "w") as fh:
                json.dump({"when": stamp, "git": bench.git_rev(), "model": args.model, "jev": args.jev, "judge_model": args.judge_model,
                           "timeout": args.timeout, "results": rows}, fh, indent=1)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
            for f in [pool.submit(one, t) for t in chosen]: f.result()
    finally:
        if not args.keep: bench.stop_copy()
    scored = [r["score"] for r in rows if r.get("score") is not None]
    if scored:
        print(f"\nmean score {sum(scored) / len(scored):.3f} over {len(scored)} tasks · median {sorted(r['seconds'] for r in rows)[len(rows) // 2]:.0f} s"
              f" · ${sum(r['cost_usd'] or 0 for r in rows):.2f}")


if __name__ == "__main__":
    main()
