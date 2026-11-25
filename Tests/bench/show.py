#!/usr/bin/env python3
"""A run's trajectory, short: what the agent called, what came back, what it said.

    python3 Tests/bench/show.py <transcript.json> [chars]"""
import json, sys
path = sys.argv[1]; n = int(sys.argv[2]) if len(sys.argv) > 2 else 500
for e in json.load(open(path)):
    if e.get("type") == "assistant":
        for b in e["message"]["content"]:
            if b.get("type") == "tool_use": print("CALL", b["name"].replace("mcp__sill__", ""), json.dumps(b["input"])[:n])
            elif b.get("type") == "text" and b["text"].strip(): print("SAY ", b["text"][:n].replace("\n", " | "))
    elif e.get("type") == "user" and isinstance(e.get("message", {}).get("content"), list):
        for b in e["message"]["content"]:
            if b.get("type") == "tool_result":
                c = b["content"]; t = c if isinstance(c, str) else " ".join(x.get("text", "[image]") for x in c if isinstance(x, dict))
                print("  ->", t[:n].replace("\n", " | "))
