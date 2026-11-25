#!/usr/bin/env python3
"""Grade a saved Online-Mind2Web or WebVoyager run again from its trace, with another judge.

    python3 Tests/bench/rejudge.py Tests/bench/results/m2w-<stamp>.json
    python3 Tests/bench/rejudge.py Tests/bench/results/<stamp>.json --judge-model gpt-5.6-luna

The run is not repeated: the judge reads the same pictures and actions the first one did."""
import argparse, concurrent.futures, json, os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as bench
import judges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results")
    ap.add_argument("--judge-model", default="gpt-5.6-luna")
    ap.add_argument("--judge-effort", default="xhigh")
    ap.add_argument("--parallel", type=int, default=4)
    args = ap.parse_args()
    saved = json.load(open(args.results))
    trail = args.results[:-5]
    m2w = os.path.basename(args.results).startswith("m2w-")
    binary = bench.claude_bin()
    env = bench.claude_env(os.path.expanduser("~/.claude-normal"))
    work = tempfile.mkdtemp(prefix="sill-rejudge-")

    def one(r):
        folder = os.path.join(trail, r["id"].replace("/", "_"))
        steps = judges.read_trace(folder)
        claude = judges.Claude(binary, env, args.judge_model, work, args.judge_effort)
        # The answer read again from the transcript, whole (an older run may have kept only its first line).
        answer = r.get("answer") or ""
        transcript = os.path.join(folder, "transcript.json") if m2w else folder + ".json"
        if os.path.exists(transcript):
            events = [(e.get("at", 0), e) for e in json.load(open(transcript))]
            s = bench.summarize_agent(events, False, [], 0)
            answer = s["answer"] or s["final_message"][-1500:] or answer
            r["answer"] = answer
        if m2w: ok, detail = judges.webjudge(claude, r["task"], steps, answer)
        else: ok, detail = judges.webvoyager_judge(claude, r["question"], steps, answer)
        with open(os.path.join(folder, f"judge-{args.judge_model}.json"), "w") as fh: json.dump(detail, fh, indent=1)
        return r, ("SUCCESS" if ok else "FAIL"), detail

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
        for r, verdict, detail in pool.map(one, saved["results"]):
            rows.append({**r, "verdict_" + args.judge_model: verdict})
            print(f"  {r.get('level', r.get('site', '')):8} was {r['verdict']:7} now {verdict:7} {(r.get('task') or r.get('question'))[:80]}", flush=True)
    now = sum(x["verdict_" + args.judge_model] == "SUCCESS" for x in rows)
    was = sum(x["verdict"] == "SUCCESS" for x in rows)
    print(f"\n{args.judge_model}: {now}/{len(rows)} (first judge {saved.get('judge_model', '?')}: {was}/{len(rows)})")
    if m2w:
        for level in ("easy", "medium", "hard"):
            rs = [x for x in rows if x.get("level") == level]
            if rs: print(f"  {level:6} {sum(x['verdict_' + args.judge_model] == 'SUCCESS' for x in rs)}/{len(rs)}")
    saved["results"] = rows
    with open(args.results[:-5] + f"-{args.judge_model}.json", "w") as fh: json.dump(saved, fh, indent=1)


if __name__ == "__main__":
    main()
