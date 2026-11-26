# Sill on WebVoyager

How often, and how fast, Claude finishes real web tasks when its only tools are Sill's
(`sill-mcp`). The tasks are a sample of [WebVoyager](https://github.com/MinorJerry/WebVoyager)
(643 tasks on 15 live sites: Allrecipes, Amazon, Apple, ArXiv, BBC News, Booking, Cambridge
Dictionary, Coursera, ESPN, GitHub, Google Flights, Google Map, Google Search, Hugging Face,
Wolfram Alpha).

For each task it records: success (judged against WebVoyager's reference answer), wall time,
the number and names of tool calls, failed tool calls, turns, tokens, cost and the answer.

## Run it

    python3 Tests/bench/fetch.py                 # once: tasks + reference answers into data/
    python3 Tests/bench/run.py                   # 15 tasks, one per site, seed 7, Sonnet
    python3 Tests/bench/run.py --n 30 --model opus --effort high
    python3 Tests/bench/run.py --sites "Allrecipes,GitHub" --n 6
    python3 Tests/bench/run.py --ids "ArXiv--28,Google Search--23"
    python3 Tests/bench/run.py --list            # show the sample, run nothing

Other flags: `--timeout` (s per task, default 240), `--max-turns` (60), `--judge-model`
(sonnet), `--seed`, `--keep` (leave the bench copy running), `--config-dir`.
`SILL_APP` picks the build to copy (default `build/Sill Chromium.app` in this checkout).

- **Its own Sill.** The app is cloned to `~/Library/Caches/Sill Bench/Sill Bench.app` with bundle
  id `com.iasoncostoudes.sill.chromium.bench`, started with `SILL_PROFILE=bench` (own profile,
  settings and socket at `~/Library/Application Support/Sill Chromium (bench)/agent.sock`) and
  quit at the end, only if the process holding that socket runs from the clone. Your Sill and
  the agent course's copy are never touched. A fresh profile means no cookies and no sign-ins.
- **The agent** is `claude -p` with `CLAUDE_CONFIG_DIR=~/.claude-normal` and no
  `ANTHROPIC_*`/`CLAUDE*` variables inherited (as your `claude` shell function), `--tools ""`
  (no built-in tools: no Bash, WebFetch, WebSearch), `--strict-mcp-config` with only Sill,
  `--allowedTools mcp__sill__*`, and Sill's `wait_for_user`, `page_upload`, `page_sign_in`
  and `passwords_*` denied (nobody is there to answer). It runs from an empty temp folder.
  The prompt names the site and its address, today's date, asks it not to buy/book/post, and
  asks for a final line starting `ANSWER:`.
- **The judge** is a second `claude -p --model sonnet` with no tools. It sees the task, the
  reference answer (and whether WebVoyager marks it "golden" or only "possible") and the agent's
  `ANSWER:` line, and replies SUCCESS or FAIL with a reason.
- Tasks run one at a time. Each starts with the bench copy's tabs closed. A run that hits the
  timeout is killed (claude and its sill-mcp) and judged on whatever answer it gave (usually none).
- Results: `results/<timestamp>.json` (config, totals, every task's tools and answer), and a
  table: pass/fail, seconds, tool calls; success rate, median and mean seconds, mean tool calls.

`run.py` checks first that `claude` can answer with that config dir. If `~/.claude-normal`'s
sign-in has expired, sign in again there (`CLAUDE_CONFIG_DIR=~/.claude-normal claude auth login`)
or point `--config-dir` elsewhere.

### Options worth knowing

- `--parallel N` (default 3): tasks at once, each Claude in its own tabs (Sill keeps a current tab per client).
- `--jev`: gives the agent `page_goal`, driven by TypeSafe's Jev (key from `TYPESAFE_API_KEY` or the Keychain item "Sill TypeSafe"). Claude hands it the goal and values; Jev does the clicking.
- Every task's whole transcript is saved under `results/<timestamp>/<task id>.json`, to see where the time went.

## Which tasks

`fetch.py` takes the original tasks and references, plus Browser Use's copy of the tasks
([browser-use/eval](https://github.com/browser-use/eval), where dates in the past were moved to
2024/2025) and its list of 55 tasks that can no longer be done. `run.py` uses Browser Use's tasks,
drops the impossible ones, and also drops any booking-like task (Booking, Google Flights, or one
that books, reserves or departs) whose explicit date has passed again: 60 of them in November 2026.
Dates without a year are kept; the prompt tells the agent to use their next occurrence. Historical
dates (ArXiv announcements, past NBA scores, Wolfram Alpha) are kept. That leaves 528 tasks; the
default sample takes one per site with a fixed seed.

## Caveats

- **Small samples.** 15 tasks is a smoke reading, not a score: one task is ±7 points. Use
  `--n 60` or more before comparing with published numbers.
- **Text-only judge.** WebVoyager's own judge is GPT-4V looking at the final screenshots and the
  answer; this one reads only the answer. It can't see that the agent really applied a filter or
  added to the cart, and it trusts specific-sounding answers it can't check. Expect it to be more
  lenient on "do X" tasks and comparable on "find X" tasks.
- **Live sites drift.** References are from late 2023; most are marked "possible", and the judge
  is told to accept any answer that meets the task. Golden ones (fixed facts) must match.
- **Fresh profile, one Mac, one IP.** Cookie walls, regional redirects and bot checks (Amazon,
  Booking, Google) show up as failures; the agent can't hand over to a person.
- **Time** is wall time per task including Claude Code's start-up (a few seconds), not just
  browsing; model latency dominates.

## How others report on WebVoyager

Everyone patches the dataset, the judge and the sample differently, so these are not directly
comparable to each other or to this harness.

| Agent | WebVoyager | Notes | Source |
|---|---|---|---|
| WebVoyager (GPT-4V), original paper | 59.1% | 643 tasks, human evaluation | [He et al. 2024](https://arxiv.org/abs/2401.13919) |
| Agent-E (text only) | 73.1% | 643 tasks; 150-220 s and ~25 LLM calls per task | [Abuelsaad et al. 2024](https://arxiv.org/abs/2407.13032) |
| Claude 3.5 Sonnet computer use | 56.0% | as listed by OpenAI | [OpenAI, Computer-Using Agent](https://openai.com/index/computer-using-agent/) |
| OpenAI Operator (CUA) | 87.0% | OpenAI calls most WebVoyager tasks "relatively simple" | [OpenAI, Computer-Using Agent](https://openai.com/index/computer-using-agent/) |
| Skyvern 2.0 | 85.85% | 8 tasks removed, some dates and answers updated | [Skyvern blog](https://blog.skyvern.com/skyvern-2-0-state-of-the-art-web-navigation-with-85-8-on-webvoyager-eval/) |
| Browser Use (GPT-4o) | 89.1% | 586 tasks (55 impossible removed), dates moved, failed/unknown verdicts reviewed by hand | [Browser Use report](https://browser-use.com/posts/sota-technical-report), [browser-use/eval](https://github.com/browser-use/eval) |
| Browser Use v0.1.40 (GPT-4o), reproduced by Notte | 60.2% | WebVoyager30 subset, LLM judge | [nottelabs/open-operator-evals](https://github.com/nottelabs/open-operator-evals) |
| Magnitude | 93.9% | patched dates, a few tasks removed; ~15.5 steps per task | [magnitudedev/webvoyager](https://github.com/magnitudedev/webvoyager) |
| Alumnium MCP + Claude Code (Sonnet 4.6) | 98.5% | 610 tasks, dates moved to 2026, GPT-5 judge; cites Surfer 2 at 97.1% | [Alumnium blog](https://alumnium.ai/blog/webvoyager-benchmark/) |

**Online-Mind2Web** (300 tasks on 136 live sites, human evaluation;
[Xue et al. 2025, "An Illusion of Progress?"](https://arxiv.org/abs/2504.01382),
[OSU-NLP-Group/Online-Mind2Web](https://github.com/OSU-NLP-Group/Online-Mind2Web)) was built
because WebVoyager overstates agents: a plain search agent solves up to 51% of WebVoyager but
22% of Online-Mind2Web. There, Operator scored 61.3%, Claude 3.7 computer use 56.3%,
Browser Use (GPT-4o) 30.0%, Claude 3.5 computer use 29.0% and Agent-E 28.0%.

## Saved for later: Odysseys2

The yardstick for delegated work: 100 long live-web tasks built by CMU and Browser Use from
real user requests, graded against 982 rubric checks (shopping, research, finance and law,
directories, media, property, local and travel). MIT license. https://odysseysbench.com/v2/

- Data: `~/Library/Caches/Sill Bench/datasets/odysseys2` (github.com/ljang0/odysseys2-benchmark
  at 02d42e1, checksums verified). Not read: keep it unseen until we run it.
- Protocol in its `EVALUATION.md`: judge gpt-5.6-luna at xhigh with `judge-prompt.txt` byte for
  byte, 3600 s per task, every rubric item weight 1, a reward-hacking check that zeroes a task.
- Published (mean score /100, tasks fully passed): GPT-6 Astra 84.6, 47; Opus 5.5 on
  BrowserCode 71.2, 18; Grok 4.7 68.2, 13; GPT-5.6 Luna 55–60, 4–8.
- No runner yet: write one like `bubench.py` (same findings-judge family) when we're ready.

Also worth knowing: WebTailBench v2 (Microsoft, May 2026, `microsoft/WebTailBench` test_v2):
609 refreshed everyday tasks (flights, hotels, restaurants, tickets, shopping lists,
comparisons) for breadth on short and medium tasks.
