# Delegation architecture

Draft for discussion, 26 November 2026. Nothing here is built yet beyond what's marked as existing.

## The goal

You hand Sill any task, a quick lookup or a job that takes hours, and it gets it right without
you watching. Three things you've settled:

- **No ambiguity.** What you mean comes from your context: your history, your habits on each
  site, your files, your accounts, where you are, what you did last time. Sill resolves a
  request against that context, and it never stops to ask about it.
- **Nothing is impossible** unless the web doesn't have it. If a person could find it, Sill
  keeps going until it does. "It isn't on the web" is only an answer when there's a record of
  every route Sill tried.
- **No plan approval.** The architecture and the model carry it. The one stop that stays is
  the existing one: before a step that pays, orders, sends, posts, deletes or changes an
  account, Sill asks.

Edge cases are handled in the harness and the code, never by helpers for particular sites.

### What "right" means

A task is done when all four of these hold:

1. **Every requirement is met.** That covers both what you said and what your context
   implies.
2. **Every requirement has evidence.** Each one is backed by something captured during the
   run: the page, the exact text, the time it was read, and a screenshot.
3. **The deliverable is in the shape you need.** That could be an answer, a file, a sheet or a
   finished form, with exact values copied exactly.
4. **Nothing was crossed without your OK.**

## Why one model in one loop isn't enough

Today the client model (Claude Code, claude.ai) runs the whole task in one conversation and
calls Sill's tools. Six benchmark rounds show where that breaks. Better clicking won't fix
these:

| Failure seen | What was missing |
|---|---|
| A Coursera course "with Agile" where Agile was only a mention, not a module | The requirements were never written down, so nobody checked them one by one |
| $235 reported when the cheapest fare was $232; a filter never applied, yet the result was used | No independent check before answering |
| BU Bench jobs of one to two hours lose their place, redo work, or stop at 100 of 1,000 rows | Progress lived only in the model's context |
| A blocked site ended the task; Amazon showed AED and the agent gave up on USD | Only the model's own ideas for another way around, and no persistence ladder |
| The agent wrote 58 scripts in 30 tasks to find controls | The harness wasn't showing enough (fixed: `find`) |
| Errors repeat on sites already seen | What worked isn't fed back into the next run |

## The shape

```
request ─► BRIEF ─► PLAN ─► DO (workers, in parallel) ─► CHECK ─► DELIVER
             ▲        ▲            │   ▲                    │
             │        └── reroute ─┘   └──── gaps ──────────┘
          context                  │
     (history, habits,          LEDGER  (requirements, evidence, progress: outside any model)
      files, site notes)           │
                                 LEARN  (site notes, routes, new course cases)
```

### 1. Brief: understand

This step turns the request plus your context into a written spec:

- **Requirements.** Each one is atomic and checkable, like a rubric item. "Under $250" says
  per night or total. "Latest" says as of when.
- **Implied requirements** that come from your context: your currency, your city, the account
  you use on that site, the format you used last time.
- **The deliverable**, in its exact shape.
- **The limits**: where to stop and ask.
- **How "done" will be judged.**

Every reading Sill had to choose is written into the spec with its reason. Nothing is guessed
silently, and nothing waits for you.

Benchmarks grade against hidden rubrics. The brief is Sill writing its own rubric first.

- **Exists:** `history_search`, habits, `files` and site notes give the context.
- **New:** the spec as a stored object, written by the strongest model.

### 2. Plan: route

- **Sources:** which sites, from your habits and site notes, then search.
- **Sub-tasks:** what can run in parallel and what depends on what.
- **Fit to size.** A lookup's plan is one step and costs no extra calls. A big job becomes a
  graph of errands.
- **Re-plan when the world disagrees:** a site blocks, data is missing, or a source
  contradicts another.

- **Exists:** `tabs_open errands=[…]` runs work in parallel.
- **New:** the plan as data that can be re-planned, and the persistence ladder below.

### 3. Do: workers

- **Each worker gets one errand and its slice of the spec**, in its own tab with its own small
  context.
- **The harness is what's been built so far:**
  - it sees what a person sees;
  - actions are verified;
  - `page_do` runs sequences;
  - a failed step is recalculated and tried again.
- **Jev drives the mechanical parts** (forms, filters, date pickers) at about 1 step per
  request.
- **Workers write to the ledger as they go**, not at the end.

- **Exists:** almost all of the harness.
- **New:** workers that report into the ledger instead of answering in prose.

### 4. Ledger: memory outside the model

The ledger is one record per task, stored by Sill. It holds:

- the spec;
- the plan and the status of each errand;
- every fact gathered, with its source URL, exact text, timestamp and screenshot crop;
- every route tried and how it ended.

What it makes possible:

- **Long jobs.** A model's context can fill up, restart or crash, the Mac can sleep, and the
  work still resumes from the ledger.
- **Parallel workers** share one record instead of each other's conversations.
- **The checker and the final answer** cite the ledger directly.

- **Exists:** the trace (screenshots per action), lists saved to files, site notes.
- **New:** the ledger itself.

### 5. Check: an independent verifier

A fresh model that didn't do the work reads the spec, the ledger and the deliverable. For each
requirement it decides whether it is met, unmet or unproven:

- **Evidence that matters is re-checked:** the price, the date, the filter actually applied.
  The checker reopens the page and reads it again rather than trusting the worker.
- **Gaps go back to Plan as specific errands.** For example: "Requirement 4, Agile as a
  module, is unproven. Open the syllabus."
- **The loop ends** when every requirement is met, or a gap is shown to be absent from the
  web, with the routes tried as proof.

This is the part that turns "usually right" into "right". It catches what the worker talked
itself into.

- **New:** all of it.

### 6. Deliver

- The answer or file in the shape the spec set, built from the ledger, with sources.
- Any reading Sill chose, stated in one line.
- No claim that isn't in the ledger.

### 7. Learn

After each task, what worked goes back into Sill's memory:

- **Site notes:** the route that worked, the site's pace, its search address, its quirks.
- **Habits.**
- **Lessons for every site.** A failure whose cause is general becomes a course case, so the
  fix is tested on all sites, never kept as a special case for that site.

Next time the brief and the plan start from what's known, and that's where much of the speed
comes from.

- **Exists:** site notes and habits.
- **New:** writing lessons back from the ledger after each task.

## The persistence ladder

The "no impossible tasks" rule is written in code, as an ordered list of general routes the
planner climbs before anything is called missing:

1. **The same page, again:** wait it out, dismiss what's in the way, scroll, expand, page
   through (the recalculation that exists today).
2. **The same site, another way in:** its own search, a direct address from site notes or the
   URL pattern, its sitemap, a different section, a mobile or print view.
3. **Another source that has the same thing:** the maker instead of the shop, the registry
   instead of the aggregator.
4. **Search the web,** first with the site named, then without, then with other wordings.
5. **Saved and indirect copies:** cached pages, archives, the document behind the page (PDF,
   API JSON the page itself loads), the site's export.
6. **Hand to you** only for what a person must do (a CAPTCHA, a code, a passkey), then carry
   on.

Each rung is recorded in the ledger. "Not on the web" is the record of all six.

## Edge cases, as code

Every kind below is handled generally, never per site:

- **Seeing:** shadow DOM, frames from other sites, canvas, virtual and infinite lists,
  controls hidden or drawn over their own look. *(Mostly built.)*
- **Doing:** custom widgets, drag, sliders, date pickers, typing that triggers suggestions,
  hover menus. *(Mostly built; Jev handles the mechanical ones.)*
- **Flow:**
  - sign-in and two-step codes: the vault and `wait_for_user`;
  - consent banners and pop-ups: recalculate;
  - new tabs and dialogs.
- **Network:**
  - geo and currency: say what's shown and convert in the ledger, or route through your
    region when Sill has it;
  - blocks and certificate swaps: use the ladder;
  - sleep: resume from the ledger.
- **Data:**
  - pagination to the true end;
  - exports;
  - exact strings and Unicode copied exactly;
  - timestamps on every reading.
- **Time:** data that changes while you watch; dates that have passed; "latest" resolved
  against today.
- **Scale:** hundreds of items handled through errands and the ledger, never one context.

## Speed

Sill itself acts in milliseconds; the time goes on model round trips. The design keeps those
few:

- **Small tasks skip the machinery:** one brief line, no separate check unless something was
  inferred.
- **The fast model drives the mechanical steps**, and parallel workers run the big jobs.
- **Known routes come from site notes**, so workers go straight to the right page.
- **The checker re-reads only what a requirement depends on**, not the whole job.

## Where it runs

**Recommendation: Sill owns the task runtime.** Its loop calls models directly:

- the strongest model for Brief, Plan and Check;
- Sonnet 5.5 for workers;
- Jev for mechanical steps.

Outside agents get one `delegate` tool that returns the result with its ledger. Today's
fine-grained tools stay for clients that want to drive themselves.

Why Sill rather than the client:

- The ledger, the resume after sleep and the parallel workers have to live somewhere that
  outlasts one chat.
- It keeps behaviour the same no matter which client asked: Claude Code, claude.ai or a
  script.

## Measuring it

- **Practice set** (the tasks of rounds 1–6): for finding problems.
- **Held-out set** (`Tests/bench/heldout.py`): measured at checkpoints only, with the
  instructions frozen.
- **Odysseys2:** the yardstick for this architecture. It has 100 long tasks built from real
  user requests and 982 rubric checks, with the same judge we use (gpt-5.6-luna, xhigh) and 60
  minutes per task. It's saved in `~/Library/Caches/Sill Bench/datasets/odysseys2`, unread, for
  when we're ready.
- **Per part, not just a total:**
  - how often the brief's requirements match the rubric;
  - how often the checker catches a wrong answer before delivery;
  - how often the ladder finds a route the first try missed;
  - mechanical failures (a click that didn't land, a control not found).

## Build order

1. **Ledger and spec as stored objects.** Everything else reads and writes them.
2. **Checker**, run against the spec and ledger. It's the biggest jump in being right, and it
   works with today's single loop before workers exist.
3. **The persistence ladder** inside Plan.
4. **Workers in parallel** sharing the ledger, plus resume after sleep or crash.
5. **Learning written back** after every task.
6. **The `delegate` tool**, then Odysseys2 against the published scores.
