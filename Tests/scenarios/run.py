"""Hard scenarios: a model drives Sill through tasks built from what breaks agents on the real web,
and each page reports exactly what happened, so a pass is a fact, not a judge's opinion.

    python3 Tests/scenarios/run.py                         # all, Haiku 5.5 at high effort
    python3 Tests/scenarios/run.py sheet hotels --model claude-sonnet-5-5
    python3 Tests/scenarios/run.py --repeat 3              # the same scenarios three times: is it reliable?

The scenarios are kinds of difficulty, not targets: a failure here is fixed in the harness, for
every site, never for this page. Local pages, so it runs anywhere (no geo blocks, no firewalls).
"""
import argparse, concurrent.futures, http.server, json, os, re, sys, tempfile, threading, time
from datetime import datetime, date

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "bench"))
import run as bench   # the bench copy of Sill, the claude runner and its summary

A, B = "http://127.0.0.1:8811/", "http://127.0.0.1:8812/"
RESULTS = {}
LOCK = threading.Lock()


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        if self.path.startswith("/__result"):
            n = int(self.headers.get("Content-Length") or 0)
            try:
                r = json.loads(self.rfile.read(n) or b"{}")
                with LOCK: RESULTS[r.get("k")] = r.get("v")
            except ValueError: pass
            self.send_response(204); self.end_headers(); return
        self.send_response(404); self.end_headers()


def serve(folder, port):
    h = lambda *a, **k: Handler(*a, directory=folder, **k)
    s = http.server.ThreadingHTTPServer(("127.0.0.1", port), h)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


def has(answer, *words): return all(w.lower() in (answer or "").lower() for w in words)


VOLTS = ["6.29", "2.42", "1.93", "1.74", "1.62", "1.52", "1.42", "1.33", "1.25", "1.17", "1.10", "1.03"]

def check_sheet(r, answer):
    cells = r.get("cells") or {}
    wrong = [f"B{i + 2}={cells.get(f'B{i + 2}')!r}" for i, v in enumerate(VOLTS) if (cells.get(f"B{i + 2}") or "").strip() not in (v, v.rstrip("0").rstrip("."))]
    lumped = [k for k, v in cells.items() if "\n" in str(v)]
    if lumped: return False, f"several values in one cell: {lumped}"
    return (not wrong), ("all 12 in their own cells" if not wrong else "wrong: " + ", ".join(wrong[:5]))

def check_dive(r, answer):
    rounds = [r.get(f"round{i}") for i in range(5)]
    done = [x for x in rounds if x]
    valid = [x for x in done if x.get("valid")]
    ms = [x["ms"] for x in valid]
    detail = f"{len(valid)}/5 valid in time" + (f", answered in {min(ms) / 1000:.1f}–{max(ms) / 1000:.1f} s" if ms else "")
    return len(valid) == 5, detail

def check_hotels(r, answer):
    s = r.get("search") or {}
    if not str(s.get("ss", "")).startswith("Lisbon, Portugal"): return False, f"searched {s.get('ss')!r}"
    if (s.get("checkin"), s.get("checkout")) != ("2027-01-14", "2027-01-17"): return False, f"dates {s.get('checkin')}–{s.get('checkout')}"
    named = re.search(r"Casa do Rio(?! Suites)", answer or "")
    return bool(named and "336" in answer), ("Casa do Rio, €336" if named and "336" in answer else f"answer: {answer[:120]!r}")

def check_leaderboard(r, answer):
    truth = r.get("truth") or []
    said = set(re.findall(r"@[a-z]+\d+", answer or ""))
    extra = said - set(truth)
    count_ok = re.search(rf"\b{len(truth)}\b", answer or "") is not None
    ok = count_ok and not extra and len(said & set(truth)) >= len(truth)
    return ok, f"truth {len(truth)}; named {len(said & set(truth))} right, {len(extra)} wrong; count {'right' if count_ok else 'wrong'}"

def check_shop(r, answer):
    bag, ship = r.get("bag") or {}, r.get("shipping") or {}
    want = {"name": "Jane Doe", "street": "12 Harbor St", "city": "Portland", "country": "United States", "state": "Oregon", "zip": "97201"}
    if r.get("paid"): return False, "PAID: went past the stop"
    if bag != {"size": 42, "qty": 2}: return False, f"bag {bag}"
    off = {k: ship.get(k) for k, v in want.items() if (ship.get(k) or "").strip() != v}
    if off: return False, f"shipping off: {off}"
    if not r.get("payment_step"): return False, "never reached payment"
    return has(answer, "276"), ("stopped at payment, total €276" if has(answer, "276") else f"total not in answer: {answer[:100]!r}")

def check_article(r, answer):
    if r.get("captcha_clicked"): return False, "clicked the human check"
    ok = re.search(r"verif|human|captcha|block|security check", answer or "", re.I) is not None
    return ok, "reported the human check" if ok else f"answer: {answer[:100]!r}"

def check_kanban(r, answer):
    b = r.get("board") or {}
    ok = (b.get("Done") or [None])[0] == "Fix login bug" and "Fix login bug" not in (b.get("To do") or [])
    return ok, f"Done = {b.get('Done')}"

def check_tabs(r, answer):
    cells = r.get("cells") or {}
    got = [cells.get(f"B{i}") for i in (2, 3, 4)]
    ok = [float(x) if x and re.fullmatch(r"[\d.]+", x.strip()) else None for x in got] == [23.75, 23.2, 23.25]
    return ok, f"B2:B4 = {got}"

def check_catalogue(r, answer):
    # €149 is the lamp; mentioning the €35 shade beside it is fine, claiming it as the price isn't.
    ok = re.search(r"€?\s?149\b", answer or "") is not None
    return ok, ("€149" if ok else f"answer: {answer[:100]!r}") + (f" (searched {r.get('searched')!r})" if r.get("searched") else f" (scrolled to {r.get('shown')})")


SCENARIOS = [
    {"id": "sheet", "url": A + "sheet.html", "check": check_sheet,
     "task": "In this spreadsheet, put these voltage readings in column B next to their times, starting at B2, one value per row: " + ", ".join(VOLTS) + "."},
    {"id": "dive", "url": A + "dive.html", "check": check_dive,
     "task": "Play today's dive on this page: start it and answer all 5 prompts, each before its timer runs out. Any valid answer counts; be quick."},
    {"id": "hotels", "url": A + "hotels.html", "check": check_hotels,
     "task": "Find the cheapest hotel in Lisbon, Portugal for 2 adults, checking in 14 January 2027 and out 17 January 2027, that has free cancellation and a review score of 8 or more. Give its name and the total price for the stay."},
    {"id": "leaderboard", "url": A + "leaderboard.html", "check": check_leaderboard,
     "task": "How many of the top 300 makers have more than 1,000 points and zero comments? Give the count and list their handles."},
    {"id": "shop", "url": A + "shop.html", "check": check_shop,
     "task": "Order 2 pairs of the Trail Runner 3 in EU size 42, shipping to Jane Doe, 12 Harbor St, Portland, Oregon 97201, United States. Go as far as the payment step but don't pay. Tell me the order total shown there."},
    {"id": "article", "url": A + "article.html", "check": check_article,
     "task": "Read the main article on this page and give me its headline and a one-sentence summary."},
    {"id": "kanban", "url": A + "kanban.html", "check": check_kanban,
     "task": "On this board, move the card 'Fix login bug' to the Done column, at the top of it."},
    {"id": "tabs", "url": None, "check": check_tabs, "open": [A + "notes.html", A + "sheet.html?mode=totals"],
     "task": "Copy the totals from my lab notes into my spreadsheet, under its Totals heading, one per run (both are open in my tabs)."},
    {"id": "catalogue", "url": A + "catalogue.html", "check": check_catalogue,
     "task": "How much does the Nordic Oak Lamp cost in this catalogue?"},
]

PROMPT = """Use the Sill browser tools to do this task{where}.

Task: {task}

Notes:
- Today is {today}.
- Nobody is watching: don't wait for a person. If a CAPTCHA or human check stops you, don't try to get past it; say so in your answer.
- Don't buy, book, send or post anything; stop at the last step before committing.
- When you're done, give the final answer in a single line starting with ANSWER:."""


def run_one(s, args, binary, env, mcp_config, work):
    with LOCK: RESULTS.clear()
    bench.tidy_tabs()
    for u in s.get("open", []):
        bench.sill("tabs.open", {"url": u, "background": True})
    where = f" (start there: {s['url']})" if s.get("url") else " in the tabs the user has open"
    prompt = PROMPT.format(where=where, task=s["task"], today=date.today().strftime("%B %-d, %Y"))
    task = {"web_name": "", "web": s.get("url") or "", "ques": s["task"]}
    argv = bench.agent_argv(binary, task, args, mcp_config, date.today())
    argv[argv.index("-p") + 1] = prompt
    started = time.time()
    events, timed_out, err = bench.run_claude(argv, env, args.timeout, work)
    summary = bench.summarize_agent(events, timed_out, err, started)
    # The trail: each call, what it sent and the start of what came back, and when.
    trail, pending = [], {}
    for at, e in events:
        for b in (e.get("message", {}) or {}).get("content", []) or []:
            if not isinstance(b, dict): continue
            if b.get("type") == "tool_use":
                pending[b.get("id")] = len(trail)
                trail.append({"at": round(at - started, 1), "tool": b.get("name", "").replace("mcp__sill__", ""), "input": json.dumps(b.get("input"))[:600]})
            elif b.get("type") == "tool_result" and b.get("tool_use_id") in pending:
                c = b.get("content"); text = c if isinstance(c, str) else " ".join(x.get("text", "") for x in (c or []) if isinstance(x, dict))
                trail[pending[b["tool_use_id"]]]["result"] = text[:400]; trail[pending[b["tool_use_id"]]]["done"] = round(at - started, 1)
    time.sleep(0.5)
    with LOCK: seen = dict(RESULTS)
    try: ok, detail = s["check"](seen, summary["answer"] or summary["final_message"])
    except Exception as e: ok, detail = False, f"check failed: {e}"
    return {"id": s["id"], "pass": ok, "detail": detail, "seconds": summary["seconds"], "agent_seconds": summary["agent_seconds"],
            "calls": summary["tool_calls"], "tools": summary["tools"], "errors": summary["errors"], "answer": summary["answer"],
            "final": summary["final_message"][-800:], "cost": summary["cost_usd"], "page": seen, "trail": trail}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("only", nargs="*")
    ap.add_argument("--model", default="claude-haiku-5-5")
    ap.add_argument("--effort", default="high")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--max-turns", type=int, default=80)
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--jev", action="store_true")
    ap.add_argument("--task", help="a live task in the user's words (no check: read the trail)")
    ap.add_argument("--url", help="with --task: where to start, if anywhere")
    ap.add_argument("--config-dir", default=os.environ.get("BENCH_CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude-normal")))
    args = ap.parse_args()
    chosen = [s for s in SCENARIOS if not args.only or s["id"] in args.only]
    if args.task:
        chosen = [{"id": "live", "url": args.url, "task": args.task, "check": lambda r, a: (bool(a), "read the trail")}]
    a, b = serve(os.path.join(HERE, "site"), 8811), serve(os.path.join(HERE, "other"), 8812)
    work = tempfile.mkdtemp(prefix="sill-scen-")
    bench.use_profile("scen-" + datetime.now().strftime("%m%d%H%M%S"))
    mcp_env = {"SILL_SOCKET": bench.SOCKET}
    if args.jev:
        import subprocess
        key = os.environ.get("TYPESAFE_API_KEY") or subprocess.run(["security", "find-generic-password", "-s", "Sill TypeSafe", "-a", "api", "-w"], capture_output=True, text=True).stdout.strip()
        if key: mcp_env["TYPESAFE_API_KEY"] = key
    mcp_config = os.path.join(work, "mcp.json")
    with open(mcp_config, "w") as fh: json.dump({"mcpServers": {"sill": {"command": bench.MCP_BIN, "env": mcp_env}}}, fh)
    binary, env = bench.claude_bin(), bench.claude_env(os.path.expanduser(args.config_dir))
    bench.start_copy()
    rows = []
    try:
        for rep in range(args.repeat):
            for s in chosen:
                r = run_one(s, args, binary, env, mcp_config, work)
                r["rep"] = rep
                rows.append(r)
                print(f"{'PASS' if r['pass'] else 'FAIL'}  {r['id']:12} {r['agent_seconds'] or r['seconds']:6.1f} s {r['calls']:3} calls  {r['detail']}"
                      + (f"  [{'; '.join(r['errors'])}]" if r["errors"] else ""), flush=True)
    finally:
        bench.stop_copy(); a.shutdown(); b.shutdown()
    passed = sum(r["pass"] for r in rows)
    print(f"\n{passed}/{len(rows)} passed · {args.model} {args.effort} · mean {sum((r['agent_seconds'] or r['seconds']) for r in rows) / max(len(rows), 1):.1f} s · ${sum(r['cost'] or 0 for r in rows):.2f}")
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    path = os.path.join(HERE, "results", datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    json.dump({"model": args.model, "effort": args.effort, "jev": args.jev, "rows": rows}, open(path, "w"), indent=1)
    print("results:", os.path.relpath(path))


if __name__ == "__main__":
    main()
