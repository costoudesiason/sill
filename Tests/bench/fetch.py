#!/usr/bin/env python3
"""Download WebVoyager's tasks and reference answers into Tests/bench/data/.

    python3 Tests/bench/fetch.py

Files are data only: they are parsed as JSON, never run.

- WebVoyager_data.jsonl, reference_answer.json   MinorJerry/WebVoyager (the original, 643 tasks)
- browser-use.WebVoyager_data.jsonl               browser-use/eval: same tasks, some dates moved forward
- browser-use.ImpossibleTasks.json                browser-use/eval: tasks that can no longer be done
Browser Use moved stale dates to 2024/2025, which are again in the past; run.py therefore
also skips any task that still names a date before today (see run.py: stale_date)."""
import json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
RAW = "https://raw.githubusercontent.com"
FILES = {
    "WebVoyager_data.jsonl": f"{RAW}/MinorJerry/WebVoyager/main/data/WebVoyager_data.jsonl",
    "reference_answer.json": f"{RAW}/MinorJerry/WebVoyager/main/data/reference_answer.json",
    "browser-use.WebVoyager_data.jsonl": f"{RAW}/browser-use/eval/main/data/WebVoyager_data.jsonl",
    "browser-use.ImpossibleTasks.json": f"{RAW}/browser-use/eval/main/data/WebVoyagerImpossibleTasks.json",
}

def check(name, body):
    """Refuse anything that isn't the JSON we expect."""
    text = body.decode("utf-8")
    if name.endswith(".jsonl"):
        rows = [json.loads(l) for l in text.splitlines() if l.strip()]
        assert rows and all({"id", "ques", "web"} <= set(r) for r in rows), "unexpected task rows"
        return f"{len(rows)} tasks"
    obj = json.loads(text)
    return f"{len(obj)} entries"

def main():
    os.makedirs(DATA, exist_ok=True)
    for name, url in FILES.items():
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                body = r.read()
            what = check(name, body)
        except Exception as e:
            print(f"failed  {name}: {e}", file=sys.stderr)
            if not name.startswith("browser-use"): sys.exit(1)
            continue
        with open(os.path.join(DATA, name), "wb") as fh: fh.write(body)
        print(f"saved   {name:36} {what}")

if __name__ == "__main__":
    main()
