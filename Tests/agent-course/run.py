#!/usr/bin/env python3
"""Sill's agent test course: hard cases from real sites, driven through sill-mcp the way
an agent would (read the element list, pick by role and name, act), and checked against
what the page itself recorded.

    python3 Tests/agent-course/run.py [case ...]

It runs its own copy of Sill (SILL_PROFILE=course: its own profile, settings and socket),
opened in the background and quit afterwards: the Sill you're using is never touched.
Test values only."""
import json, os, re, subprocess, sys, threading, time, http.server, functools, socketserver

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
APP = os.environ.get("SILL_APP", os.path.join(ROOT, "build/Sill Chromium.app"))
BIN = next((a for a in sys.argv[1:] if os.path.sep in a), os.path.join(APP, "Contents/Helpers/sill-mcp"))
# The copy's settings domain is its bundle id (…course) and, as SILL_PROFILE=course, the same suite.
PROFILE = "course"
SUPPORT = os.path.expanduser(f"~/Library/Application Support/Sill Chromium ({PROFILE})")
SOCKET = os.path.join(SUPPORT, "agent.sock")
ONLY = [a for a in sys.argv[1:] if os.path.sep not in a and not a.startswith("--")]
A, B = "http://127.0.0.1:8801/", "http://localhost:8802/"
DOMAIN = f"com.iasoncostoudes.sill.chromium.{PROFILE}"   # the test copy's own settings

class Fresh(http.server.SimpleHTTPRequestHandler):
    """Never cached: a changed case page is the page the next run gets."""
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def log_message(self, *a): pass

def serve(folder, host, port):
    handler = functools.partial(Fresh, directory=folder)
    socketserver.TCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer.daemon_threads = True   # pages kept open (--keep) don't hold up the exit
    httpd = socketserver.ThreadingTCPServer((host, port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd

class MCP:
    def __init__(self, env={}):
        self.p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                  env={**os.environ, "SILL_SOCKET": SOCKET, **env})
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18"})
    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n"); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def call(self, name, **args):
        r = self.rpc("tools/call", {"name": name, "arguments": args}).get("result", {})
        text = "\n".join(c.get("text", "") for c in r.get("content", []) if c.get("type") == "text")
        return (not r.get("isError")), text

class Fail(Exception): pass

def ref(snapshot, role, name):
    """The ref of the first element with this role whose name contains `name`."""
    for line in snapshot.splitlines():
        m = re.match(r'\[(e\d+|[^\]]+)\] (\S+)(?: "([^"]*)")?', line)
        if m and (role is None or m.group(2) == role) and name.lower() in (m.group(3) or "").lower():
            return m.group(1)
    raise Fail(f"no {role or 'element'} “{name}” in the element list")

class Case:
    def __init__(self, mcp, page):
        self.m = mcp
        ok, out = mcp.call("tabs_open", url=A + page + ".html")
        if not ok: raise Fail("tabs_open: " + out[:200])
        self.tab = out.splitlines()[1].split()[0]
        self.page = {}
        self.snap = ""
        self.absorb(out)
        self.log = []
    def do(self, tool, **args):
        ok, out = self.m.call(tool, tab=self.tab, **args)
        self.log.append(f"{tool} {args} → {'ok' if ok else 'ERROR'}: {out.splitlines()[0][:140] if out else ''}")
        self.absorb(out)
        return ok, out
    def absorb(self, out):
        """Keeps a picture of the page as a model would: a full list replaces it, a change list updates it."""
        lines = out.splitlines()
        if "(no change on the page)" in out: return
        if "Changes since the last look" in out:
            for line in lines:
                if line.startswith("+ "):
                    item = line[2:]; key = item.split("]")[0] if item.startswith("[") else item
                    self.page[key] = item
                elif line.startswith("- gone: "):
                    for r in line[8:].split(","):
                        self.page.pop("[" + r.strip().split()[0], None)
        elif any(l.startswith("Tab ") for l in lines):
            start = next(i for i, l in enumerate(lines) if l.startswith("Tab "))
            self.page = {}
            for item in lines[start:]:
                key = item.split("]")[0] if item.startswith("[") else item
                self.page[key] = item
        self.snap = "\n".join(self.page.values())
    def must(self, tool, **args):
        ok, out = self.do(tool, **args)
        if "⚠ The click landed on" in out: raise Fail("wrong element: " + out.splitlines()[0])
        if "⚠ No click reached" in out: raise Fail("missed: " + out.splitlines()[0])
        if not ok: raise Fail(f"{tool} failed: {out[:200]}")
        return out
    def look(self, all=False):
        self.must("page_snapshot", all=all); return self.snap
    def result(self, wait=1.5):
        end = time.time() + wait
        while True:
            ok, out = self.m.call("page_eval", tab=self.tab, script="return window.__result")
            try: r = json.loads(out) if ok else {}
            except Exception: r = {}
            if r or time.time() > end: return r
            time.sleep(0.15)
    def close(self):
        self.m.call("tabs_close", tab=self.tab)

CASES = {}
def case(f): CASES[f.__name__.replace("_", "-")] = f; return f

@case
def shadow_open(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Nickname"), text="Blue")
    c.must("page_click", ref=ref(c.snap, "button", "Save card"))
    return c.result().get("saved") == "Blue"

@case
def shadow_closed(c):
    c.must("page_click", ref=ref(c.look(), "button", "Unlock"))
    return c.result().get("unlocked") is True

@case
def iframe_same(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Work email"), text="a@b.test", submit=True)
    return c.result().get("framedSignIn") == "a@b.test"

@case
def iframe_cross(c):
    s = c.look()
    c.must("page_type", ref=ref(s, "textbox", "Card number"), text="4242424242424242")
    c.must("page_type", ref=ref(c.snap, "textbox", "Expiry"), text="12 / 34")
    c.must("page_type", ref=ref(c.snap, "textbox", "CVC"), text="123")
    card = c.result().get("card", {})
    return card == {"n": "4242424242424242", "x": "12 / 34", "c": "123"}

@case
def covered(c):
    ok, out = c.do("page_click", ref=ref(c.look(), "button", "Download report"))
    r = c.result(0.6)
    if r.get("clickedBanner") and "cover" not in out.lower(): return "wrong element"
    if r.get("clickedTarget"): return True
    c.must("page_click", ref=ref(c.look(), "button", "Accept all"))
    c.must("page_click", ref=ref(c.look(), "button", "Download report"))
    return c.result().get("clickedTarget") is True

@case
def stale(c):
    old = c.look()
    cherries_old = ref(old, "button", "Cherries")
    out = c.must("page_click", ref=ref(old, "button", "Bananas"))
    time.sleep(0.3)
    ok, out = c.do("page_click", ref=cherries_old)
    r = c.result()
    if ok and not str(r.get("clicked", "")).startswith("Cherries"): return "wrong element"
    if not ok:
        c.must("page_click", ref=ref(c.look(), "button", "Cherries"))
    return str(c.result().get("clicked", "")).startswith("Cherries")

@case
def react_input(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Search products"), text="lamp")
    time.sleep(0.2)
    return c.result().get("model") == "lamp"

@case
def custom_select(c):
    c.must("page_click", ref=ref(c.look(), "combobox", "Country"))
    c.must("page_click", ref=ref(c.look(), "option", "Germany"))
    return c.result().get("country") == "Germany"

@case
def native_select(c):
    c.must("page_select", ref=ref(c.look(), "combobox", "Size"), value="Large")
    return c.result().get("size") == "L"

@case
def multistep_login(c):
    c.must("passwords_save", user="course@example.test", password="Course-Test-Pass-7", host="127.0.0.1")
    try:
        c.must("page_type", ref=ref(c.look(), "textbox", "Email or phone"), text="course@example.test")
        c.must("page_click", ref=ref(c.snap, "button", "Next"))
        c.must("page_wait", selector="input[type=password]", timeout=5)
        c.must("page_sign_in", user="course@example.test")
        return (c.result().get("signedIn") or {}).get("ok") is True
    finally:
        subprocess.run(["security", "delete-internet-password", "-s", "127.0.0.1", "-a", "course@example.test"], capture_output=True)

@case
def modal(c):
    c.must("page_click", ref=ref(c.look(), "button", "Rename project"))
    c.must("page_type", ref=ref(c.look(), "textbox", "New name"), text="Atlas")
    c.must("page_click", ref=ref(c.snap, "button", "Save name"))
    return c.result().get("renamed") == "Atlas"

@case
def scroll_container(c):
    c.must("page_click", text="Deep button")
    return c.result().get("deep") is True

@case
def sticky(c):
    c.must("page_click", text="Load more")
    r = c.result()
    return "wrong element" if r.get("hitHeader") else r.get("target") is True

@case
def hover_menu(c):
    c.must("page_hover", ref=ref(c.look(), "button", "Account"))
    c.must("page_click", ref=ref(c.look(), "button", "Settings"))
    return c.result().get("menu") == "settings"

@case
def dnd(c):
    c.must("page_drag", fromText="Task A", toText="Done column")
    return c.result().get("dropped") == "A"

@case
def confirm(c):
    ok, out = c.do("page_click", ref=ref(c.look(), "button", "Archive"))
    r = c.result(2)
    if "answer" in r: return True
    ok, out = c.do("page_dialog", accept=True)
    return c.result(2).get("answer") is True

@case
def animated(c):
    # Three clicks on a page that never stops moving: each done as soon as the page has answered it.
    c.look()
    t0 = time.time()
    c.must("page_do", steps=[{"click": "Add one"}, {"click": "Add one"}, {"click": "Add one"}])
    took = time.time() - t0
    if took > 1.5: raise Fail(f"three clicks took {took:.1f} s on an animated page")
    return c.result().get("count") == 3

@case
def read_script(c):
    # The listed tools are the short set; page_read pulls data with a script, and reads text.
    names = [t["name"] for t in c.m.rpc("tools/list", {})["result"]["tools"]]
    if "page_click" in names or "page_read" not in names or len(names) > 17: raise Fail(f"tools listed: {names}")
    out = c.must("page_read", script="return [...document.querySelectorAll('button')].map(b => b.textContent)")
    text = c.must("page_read", text=True)
    bare = c.must("page_read", script="document.title")   # an expression with no return still answers
    return "Add one" in out and "Live" in text and "Always moving" in bare

def sock(cmd, **args):
    """One command straight to the test copy's socket (what no tool does: a click as if the user made it)."""
    import socket as so
    s = so.socket(so.AF_UNIX, so.SOCK_STREAM); s.connect(SOCKET)
    s.sendall((json.dumps({"id": 1, "cmd": cmd, "args": args}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"): buf += s.recv(65536)
    s.close(); return json.loads(buf)

@case
def habits(c):
    # What the user clicks is learned: history_search finds the way, tabs_open shows it on the site.
    r = sock("habits.record", page=A + "spa.html", role="treeitem", name="Travel notebook", to=A + "checkout.html", title="Travel notes")
    if not r.get("ok"): raise Fail(str(r))
    ok, out = c.m.call("history_search", query="travel notebook")
    if not ok or "Travel notebook" not in out or "checkout.html" not in out: raise Fail("history_search: " + out[:300])
    ok, opened = c.m.call("tabs_open", url=A + "spa.html")
    tab = opened.splitlines()[1].split()[0] if ok else None
    if tab: c.m.call("tabs_close", tab=tab)
    return "Travel notebook" in opened

@case
def cross_tab(c):
    # Read on one page, open another, type it there: one call, no round trips.
    out = c.must("page_do", steps=[{"read": "return document.title", "as": "t"},
                                   {"open": A + "react-input.html", "as": "b"},
                                   {"type": "Search products", "text": "{{t}}"}])
    other = re.search(r"in tab (\S+) \(", out)
    if not other: raise Fail("no tab opened: " + out[:300])
    ok, got = c.m.call("page_eval", tab=other.group(1), script="return window.__result")
    c.m.call("tabs_close", tab=other.group(1))
    return "Always moving" in got

@case
def errands(c):
    # Three sites at once, one answer, no tabs left behind.
    t0 = time.time()
    ok, out = c.m.call("tabs_open", errands=[{"url": A + p + ".html", "read": "return document.title"} for p in ("spa", "lazy", "modal")])
    took = time.time() - t0
    if not ok or out.count("Read:") != 3 or out.count("Closed the tab.") != 3: raise Fail(out[:400])
    if took > 4: raise Fail(f"three errands took {took:.1f} s")
    return True

@case
def files(c):
    # A file of the user's, read; a hidden one, refused.
    # The copy's own folder: macOS would ask before it reads Downloads.
    folder = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip() + f"sill-{PROFILE}-files"
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "course-file.txt")
    with open(path, "w") as fh: fh.write("Course file: the answer is 42.")
    try:
        ok, out = c.m.call("files", read=path)
        bad, why = c.m.call("files", read=os.path.expanduser("~/.zshrc"))
    finally: os.remove(path)
    if bad: raise Fail("read a hidden file outside the everyday folders")
    return ok and "the answer is 42" in out

@case
def beside(c):
    # The agent's tab beside the user's, then apart again.
    ok, out = c.m.call("tabs_split", tab=c.tab)
    if not ok or "your-tab" not in out or "animated" not in out: raise Fail(out[:300])
    ok, _ = c.m.call("tabs_split", tab=c.tab, off=True)
    return ok

@case
def paste_rows(c):
    # A list pasted into a sheet: one line per row, tabs across columns, in one step.
    c.must("page_do", steps=[{"click": "A1"}, {"paste": "apple\t1\nbanana\t2\ncherry\t3", "on": "A1"}])
    r = c.result()
    return r.get("rows") == 3 and r.get("cols") == 2 and r.get("first") == "apple"

@case
def in_context(c):
    # "26" twice: said which with "in"; a state waited out; the page's own search form shown as an address.
    look = c.look()
    if "Form → " not in look or "/search?q={" not in look: raise Fail("form route not shown: " + look[:300])
    t0 = time.time()
    c.must("page_do", steps=[{"until_gone": "Verifying…"}, {"click": "26", "in": "January 2027"}])
    if time.time() - t0 > 4: raise Fail("too slow")
    return c.result().get("picked") == "January 2027 26"

@case
def records(c):
    # Repeated cards as data, and saved to a file without passing through the model.
    ok, out = c.m.call("page_read", tab=c.tab, records=True)
    if not ok or "Desk" not in out or "$149" not in out or "/item/desk" not in out: raise Fail(out[:300])
    # Saved into the working folder (sill-mcp's own), as an agent's deliverables are.
    path = os.path.join(os.getcwd(), "Tests", "agent-course", "last-records.json")
    ok, out = c.m.call("page_read", tab=c.tab, records=True, save=path)
    try: rows = json.load(open(path))["records"]
    except Exception as e: raise Fail(f"no file: {out[:200]} {e}")
    return ok and len(rows) == 5

@case
def zoom(c):
    # A picture of just one element, larger.
    # The cards read as one line each: • “Desk” [e5] · $149 · …
    m = re.search(r"“Desk” \[(e\d+)\]", c.look())
    if not m: raise Fail("cards not shown as records: " + c.snap[:300])
    r = c.m.rpc("tools/call", {"name": "page_screenshot", "arguments": {"tab": c.tab, "ref": m.group(1), "zoom": 3}}).get("result", {})
    kinds = [x.get("type") for x in r.get("content", [])]
    return "image" in kinds and not r.get("isError")

@case
def site_notes(c):
    # A search typed once teaches the site's search address: the next visit is told it.
    c.must("page_do", steps=[{"type": "Search trips", "text": "lamp", "submit": True}])
    ok, out = c.m.call("tabs_open", url=A + "two-months.html")
    tab = out.splitlines()[1].split()[0] if ok else None
    if tab: c.m.call("tabs_close", tab=tab)
    return "search → http://127.0.0.1:8801/search?q={query}" in out

@case
def vault(c):
    # A secret filled by Sill on its own site only; the agent's answer never shows it.
    sock("vault.set", name="course-secret", kind="password", value="s3cret-value", sites=["127.0.0.1"])
    sock("vault.set", name="course-elsewhere", kind="password", value="nope", sites=["example.com"])
    out = c.must("page_do", steps=[{"fill": "course-secret", "on": "Search products"}])
    if "s3cret-value" in out: raise Fail("the secret showed in the answer")
    bad, why = c.do("page_do", steps=[{"fill": "course-elsewhere", "on": "Search products"}])
    if "only for example.com" not in why: raise Fail("filled a secret on the wrong site: " + why[:200])
    time.sleep(0.2)
    # Anything read back from the page shows "(from the vault)" in its place, so ask the page a yes/no.
    ok, same = c.m.call("page_eval", tab=c.tab, script="return window.__result.model === 's3cret' + '-value'")
    return same.strip() == "true"

@case
def pdf(c):
    # A PDF in a tab reads as a document: its text by page, and a page drawn whole.
    ok, out = c.m.call("tabs_open", url=A + "doc.pdf", snapshot=False)
    tab = out.splitlines()[1].split()[0]
    try:
        ok, text = c.m.call("page_read", tab=tab, text=True, pages="2")
        r = c.m.rpc("tools/call", {"name": "page_screenshot", "arguments": {"tab": tab, "pdfPage": 1}}).get("result", {})
    finally:
        c.m.call("tabs_close", tab=tab)
    if "Second page words" not in text or "First page words" in text: raise Fail(text[:300])
    return "image" in [x.get("type") for x in r.get("content", [])]

@case
def recalculate(c):
    # Off course and back without a turn: a consent banner in the way is turned down (never accepted),
    # and a click that went to another page is undone when the next target was on this one.
    # The banner is turned down as soon as the page is read, before any click needs it gone.
    if c.result().get("choice") != "rejected": raise Fail(f"banner: {c.result()}")
    out = c.must("page_do", steps=[{"click": "Download report"}])
    if c.result().get("clickedTarget") is not True: raise Fail("the click under the banner didn't land: " + out[:300])
    out = c.must("page_do", steps=[{"click": "Open details"}, {"click": "Add to list"}])
    if "went back" not in out: raise Fail("no way back: " + out[:300])
    return c.result().get("added") is True

@case
def press_list(c):
    # An option chosen on press, its list gone before the click: done, not "no click reached".
    out = c.must("page_do", steps=[{"click": "Porto"}])
    return c.result().get("city") == "Porto" and "No click reached" not in out

@case
def stale_wait(c):
    # A wait for words already on the page waits for them to show again, and says when they never do.
    t0 = time.time()
    out = c.must("page_do", steps=[{"click": "Save"}, {"wait": "Saved"}])
    if not c.result().get("saved"): raise Fail(f"the wait ended before the new “Saved” ({time.time() - t0:.1f} s): " + out[:300])
    out = c.must("page_do", steps=[{"click": "Refresh"}, {"wait": "Saved"}])
    if "already on the page" not in out: raise Fail("a wait answered by old words wasn't flagged: " + out[:300])
    out = c.must("page_do", steps=[{"navigate": "reload"}, {"wait": "Saved"}])
    if "already on the page" in out: raise Fail("words on a reloaded page counted as old: " + out[:300])
    return True

@case
def drawn_select(c):
    # "select" on a dropdown the page draws itself: opened and chosen as a person would.
    c.must("page_do", steps=[{"select": "Best Match", "value": "Best Selling"}])
    return c.result().get("sort") == "Best Selling"

@case
def month_paging(c):
    # A date months ahead in a one-month calendar: paged to by its arrows; a day the page marks unavailable is
    # said to be so, not "chosen"; an amount written another way ("$100" for "$100.00") still found.
    first = c.must("page_do", steps=[{"select": "Amount", "value": "$100"}, {"date": "2027-02-14"}])
    if c.result().get("date") != "2027-02-14" or c.result().get("amount") != "100": raise Fail(f"got {c.result()}: {first[:900]}")
    ok, out = c.do("page_do", steps=[{"date": "2026-12-25"}])
    if "unavailable" not in out: raise Fail("an unavailable day wasn't reported: " + out[:300])
    return True

@case
def pick(c):
    # Type and choose the suggestion, one step.
    c.must("page_do", steps=[{"type": "City", "text": "Pr", "pick": "Prague"}])
    return c.result().get("city") == "Prague"

@case
def date_gesture(c):
    # A day in a calendar by its date: the right month of two.
    c.must("page_do", steps=[{"date": "2027-01-26"}])
    return c.result().get("picked") == "January 2027 26"

class FakeJev(http.server.BaseHTTPRequestHandler):
    """A stand-in for TypeSafe's Jev: an operation head and a click head; clicks "Add one" until three are done."""
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        q, state = body["questions"], body["state"]
        clicks = sum("Add one" in h["action"] for h in state["recent_actions"])
        add = next(k for k, v in q["click_target"]["criteria"].items() if "Add one" in v["element"])
        op = "DONE" if clicks >= 3 else "CLICK"
        answers = {"operation": {"type": "choice", "choice": op, "confidence": 0.9, "probabilities": {op: 0.9}},
                   "click_target": {"type": "choice", "choice": add, "confidence": 0.9, "probabilities": {add: 0.9}}}
        out = json.dumps({"model": "fake", "answers": answers}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass

@case
def goal(c):
    # page_goal's loop, with a stand-in for Jev: a goal of three clicks, met in three steps.
    httpd = socketserver.TCPServer(("127.0.0.1", 8803), FakeJev)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    m = MCP({"TYPESAFE_API_KEY": "test", "TYPESAFE_URL": "http://127.0.0.1:8803/"})
    try:
        if "page_goal" not in [t["name"] for t in m.rpc("tools/list", {})["result"]["tools"]]: raise Fail("page_goal not listed with a key")
        ok, out = m.call("page_goal", tab=c.tab, goal="Add one three times")
        if not ok or not out.startswith("Done") or out.count("clicked") != 3: raise Fail(out[:300])
    finally:
        m.p.stdin.close(); httpd.shutdown(); httpd.server_close()
    return c.result().get("count") == 3

class LoopingJev(http.server.BaseHTTPRequestHandler):
    """A stand-in for Jev that keeps clicking a section's header: open, closed, open. It notes whether it was told
    what each click made appear."""
    seen = []
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        q, state = body["questions"], body["state"]
        LoopingJev.seen += [a for a in state["recent_actions"] if a.get("controls_appeared")]
        head = next(k for k, v in q["click_target"]["criteria"].items() if v["element"].endswith("button Color"))
        answers = {"operation": {"type": "choice", "choice": "CLICK", "confidence": 0.9, "probabilities": {"CLICK": 0.9}},
                   "click_target": {"type": "choice", "choice": head, "confidence": 0.9, "probabilities": {head: 0.9}}}
        out = json.dumps({"model": "fake", "answers": answers}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass

@case
def goal_repeat(c):
    # page_goal hands back when the fast model clicks the same header over and over (it opens and closes, so the
    # page "changes" each time), and each step tells it what appeared: the options a section opened onto.
    httpd = socketserver.TCPServer(("127.0.0.1", 8804), LoopingJev)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    m = MCP({"TYPESAFE_API_KEY": "test", "TYPESAFE_URL": "http://127.0.0.1:8804/"})
    try:
        ok, out = m.call("page_goal", tab=c.tab, goal="Show gold laptops", max_steps=20)
        if "went back to how it was" not in out: raise Fail("not handed back on a repeat: " + out[:300])
        n = len(re.findall(r"(?m)^\d+\. clicked", out))
        if n > 3: open("/tmp/goal-out.txt", "w").write(out); raise Fail(f"{n} clicks before handing back")
        if not any("Gold" in " ".join(a["controls_appeared"]) for a in LoopingJev.seen): raise Fail("never told the options appeared")
    finally:
        m.p.stdin.close(); httpd.shutdown(); httpd.server_close()
    return True

@case
def find(c):
    # Words found anywhere on the page, in a panel's scrolled-out part too, with refs that act as they are.
    ok, out = c.do("page_read", find="Windows 11|16 GB")
    if not ok or "Windows 11" not in out or "16 GB" not in out: raise Fail("not found: " + out[:400])
    if 'checkbox "Chrome OS"' in out: raise Fail("listed a control that doesn't match: " + out[:400])
    ok, hp = c.do("page_read", find="HP")
    if 'checkbox "HP" (in "Brand")' not in hp: raise Fail("a short option's group isn't the heading just above it: " + hp[:500])
    r = re.search(r"\[(\w+)\] checkbox \"Windows 11\"", out)
    if not r: raise Fail("no ref for Windows 11: " + out[:400])
    c.must("page_do", steps=[{"click": r.group(1)}])
    ok, none = c.do("page_read", find="Purple")
    if "Nothing on the whole page" not in none: raise Fail("a missing word wasn't said to be missing: " + none[:200])
    return c.result().get("os:w11") is True

@case
def answer_check(c):
    # The draft against what was read: the line that speaks to a condition (a skill tag, not a module),
    # a figure no page showed, and a "lowest" claim with the page's own range beside it.
    c.must("page_read", text=True)
    ok, out = c.m.call("answer_check", answer="The lowest fare is $235 on TAP Air Portugal. The course has a module on Agile and costs $97.31.",
                       needs=["the fare is the lowest one-way fare", "the course has a module on Agile"])
    if not ok: raise Fail(out[:300])
    if "Agile Methodology" not in out: raise Fail("the line about Agile wasn't shown: " + out[:1500])
    if "$97.31" not in out.split("Figures not on any page")[-1]: raise Fail("a figure no page showed wasn't flagged: " + out[:600])
    if "$232" not in out: raise Fail("the page's lower amount wasn't set beside the lowest claim: " + out[:600])
    return True

@case
def page_state(c):
    # What the page is set to, read from the page: a filter ticked in a collapsed section, the tab,
    # the sort, what's typed, how many results; and after acting, the state again when it changed.
    ok, first = c.do("page_read")
    st = next((l for l in first.splitlines() if l.startswith("State: ")), "")
    for want in ("Refundable", "tab: Best", "Recommended", "1–20 of 1,131", '"JFK"'):
        if want not in st: raise Fail(f"state misses {want!r}: {st or first[:400]}")
    ok, out = c.do("page_do", steps=[{"click": "Nonstop"}, {"select": "Sort by", "value": "Price (lowest)"}, {"click": "Cheapest"}])
    if not ok: raise Fail(out[:300])
    st = next((l for l in out.splitlines() if "State: " in l), "")
    for want in ("Nonstop", "tab: Cheapest", "Price (lowest)", "1–20 of 312", "applied: Nonstop"):
        if want not in st: raise Fail(f"state after acting misses {want!r}: {st or out[:600]}")
    return True

@case
def list_end(c):
    # How far through: how many items, the total the page claims, the way to the rest, or that there's none.
    def line(out): return next((l for l in out.splitlines() if l.startswith("List: ") or l.startswith("+ List: ")), "")
    ok, out = c.do("page_navigate", url=A + "list.html?mode=pages")
    l = line(out)
    for want in ("20 alike items", "1,000 in all", "Next", "numbered pages up to 50"):
        if want not in l: raise Fail(f"pages: list line misses {want!r}: {l or out[:500]}")
    ok, out = c.do("page_navigate", url=A + "list.html?mode=more")
    l = line(out)
    if "Load more" not in l: raise Fail(f"load more: {l or out[:500]}")
    ok, out = c.do("page_navigate", url=A + "list.html?mode=scroll")
    l = line(out)
    if "more may load as you scroll" not in l: raise Fail(f"endless scroll: {l or out[:500]}")
    ok, out = c.do("page_navigate", url=A + "list.html?mode=end")
    l = line(out)
    if "page ends here" not in l or "12 alike items" not in l: raise Fail(f"the end: {l or out[:500]}")
    return True

@case
def popups(c):
    # A newsletter pop-up closed ("No thanks", never Subscribe) as the page is read; a sign-in dialog
    # the agent opened itself is left for it to use.
    time.sleep(1.6)   # it shows up after the page has loaded, as they do
    ok, out = c.do("page_read")
    if c.result().get("newsletter") != "dismissed": raise Fail(f"newsletter: {c.result()} {out[:400]}")
    if "Out of the way first: a pop-up (\"No thanks\")" not in out: raise Fail("didn't say what it closed: " + out[:400])
    ok, out = c.do("page_do", steps=[{"click": "Sign in"}])
    ok, out = c.do("page_read")
    if "Password" not in out: raise Fail("the sign-in the agent opened was closed: " + out[:500])
    c.must("page_do", steps=[{"click": "Add to basket"}])
    return c.result().get("bought") is True

@case
def failure_picture(c):
    # A step that fails comes back with a picture of the tab, so the agent sees what's there.
    r = c.m.rpc("tools/call", {"name": "page_do", "arguments": {"tab": c.tab, "steps": [{"click": "A button that is not on this page"}]}}).get("result", {})
    kinds = [x.get("type") for x in r.get("content", [])]
    if "image" not in kinds: raise Fail(f"no picture with the failure: {kinds} {str(r)[:300]}")
    r = c.m.rpc("tools/call", {"name": "page_read", "arguments": {"tab": c.tab}}).get("result", {})
    if any(x.get("type") == "image" for x in r.get("content", [])): raise Fail("a picture with a plain read: pictures are only for when something went wrong")
    return True

@case
def needs(c):
    # The task's conditions, given once: each page points at what meets each (a control with its ref,
    # how many items pass a price limit, the line that names a thing), and doesn't repeat itself.
    try:
        ok, out = c.do("page_read", needs=["nonstop flights only", "price under $300", "a course with a module on Agile"])
        block = out[out.find("For your conditions:"):] if "For your conditions:" in out else ""
        if not block: raise Fail("no block for the conditions: " + out[-600:])
        if 'checkbox "Nonstop"' not in block: raise Fail("the Nonstop control wasn't pointed at: " + block[:600])
        if "1 of 2 prices here meet it" not in block or "$235" not in block: raise Fail("the price limit wasn't counted: " + block[:600])
        ok, again = c.do("page_read")
        if "For your conditions:" in again: raise Fail("the same block again on an unchanged page")
        ok, out = c.do("page_navigate", url=A + "check.html")
        block = out[out.find("For your conditions:"):] if "For your conditions:" in out else ""
        if "Agile Methodology" not in block: raise Fail("the Agile line wasn't pointed at: " + (block or out[-600:])[:600])
        return True
    finally:
        c.m.call("page_read", tab=c.tab, needs=[])

@case
def reroute(c):
    # A dead end comes back with the way around: no results says what's narrowing it; a missing page
    # and a site that won't connect come back with a search already done (results depend on the web).
    ok, out = c.do("page_navigate", url=A + "empty.html?again=1")
    if "↪ No results here" not in out or "Narrowing it now" not in out or "Blue" not in out.split("↪ No results here")[-1]:
        raise Fail("no results: " + out[-500:])
    ok, out = c.do("page_navigate", url=A + "no-such-page.html")
    if "↪ Not found here" not in out: raise Fail("missing page: " + out[-500:])
    ok, out = c.do("page_navigate", url="http://127.0.0.1:9/catalog/blue-iphone-14-pro")
    if "↪ Dead end" not in out: raise Fail("refused connection: " + out[-600:])
    ok, again = c.do("page_read")
    if "↪ Dead end" in again: raise Fail("searched again for the same dead end")
    return True

@case
def page_map(c):
    # What kind of page it is and where its parts are, as a person sees at a glance.
    def page(url):
        ok, out = c.do("page_navigate", url=A + url)
        return next((l for l in out.splitlines() if l.startswith("Page: ")), "") or out[:400]
    p = page("shop.html")
    for want in ("results", "search [", '= "laptop"', "Brand (3)", "Price (2)", "Customer rating (2)", "sort ["):
        if want not in p: raise Fail(f"results page misses {want!r}: {p}")
    p = page("item.html")
    if not p.startswith("Page: item") or "Add to cart [" not in p: raise Fail("item page: " + p)
    p = page("signin.html")
    if not p.startswith("Page: sign-in") or "password [" not in p: raise Fail("sign-in page: " + p)
    p = page("pay.html")
    if not p.startswith("Page: checkout") or "card number [" not in p: raise Fail("checkout page: " + p)
    return True

@case
def ticking(c):
    # A page whose only change is a number ticking in place has settled; a thing with a grab cursor is a control.
    t = time.time(); c.must("page_do", steps=[{"wait": "settled"}]); took = time.time() - t
    if took > 2: raise Fail(f"a ticking countdown held settled for {took:.1f} s")
    look = c.look()
    if '"Drag me"' not in look: raise Fail("a card with a grab cursor isn't listed: " + look[:400])
    c.must("page_do", steps=[{"click": "Go"}])
    return c.result().get("go") is True

@case
def grid_cells(c):
    # A grid read as cells by address, and a paste aimed at a cell lands there.
    look = c.look()
    if "Grid " not in look: raise Fail("no grid line: " + look[:400])
    ok, out = c.do("page_do", steps=[{"paste": "x1\nx2", "on": "B2"}])
    if 'B2 "x1"' not in out or 'B3 "x2"' not in out: raise Fail("paste didn't land at B2: " + out[-700:])
    return True

@case
def stale_refs(c):
    # Refs from one look, used after the page reloaded itself between steps: found again by name, not refused;
    # and a name that isn't on a still page fails at once, not after a long wait.
    look = c.look()
    refs = [ref(look, "checkbox", n) for n in ("Free delivery", "In stock", "On sale")]
    c.must("page_do", steps=[{"click": r} for r in refs])
    if c.result().get("all") is not True: raise Fail(f"not all ticked: {c.result()}")
    t = time.time(); ok, out = c.do("page_do", steps=[{"click": "Express shipping"}]); took = time.time() - t
    if ok and "✗" not in out: raise Fail("clicked something that isn't there")
    if took > 1.5: raise Fail(f"a missing name took {took:.1f} s to be said missing")
    return True

@case
def hidden_captcha(c):
    # reCAPTCHA loaded but not asking (an invisible badge, a hidden challenge frame) is no wall; one shown is.
    look = c.look()
    if "wants a person" in look: raise Fail("a hidden reCAPTCHA was reported as a wall: " + look[:300])
    c.must("page_click", text="Show the check")
    look = c.look()
    if "wants a person" not in look or "reCAPTCHA" not in look: raise Fail("a shown reCAPTCHA wasn't reported: " + look[:300])
    return True

@case
def rounds(c):
    # The same round over several calls is noticed, and said to be sendable as one call a round;
    # a CSS selector written as a target is used as one.
    out = ""
    for i in range(2):
        c.must("page_click", text="Next")
        c.must("page_type", label="Answer", text=f"answer {i}")
        out = c.must("page_click", text="Submit")
    if "same round again" not in out: raise Fail("a repeated round wasn't noticed: " + out[-400:])
    c.must("page_do", steps=[{"click": "#go"}])
    return c.result().get("answers") == 3

@case
def wait_input(c):
    # A switched-off answer box is said to be off; one call starts, waits out the countdown until the page
    # asks for input, and comes back with the question.
    look = c.look()
    ok, out = c.do("page_do", steps=[{"click": "Start"}, {"wait": "input"}])
    if "asking for input" not in out or "Name a planet" not in out: raise Fail("didn't wait for the question: " + out[-500:])
    c.must("page_do", steps=[{"type": "Your answer", "text": "Mars"}, {"click": "Send"}])
    if c.result().get("answer") != "Mars": raise Fail(f"answer {c.result()}")
    # A page that waits on a click, not a field: the wait says so at once, naming the new button.
    t = time.time(); ok, out = c.do("page_do", steps=[{"click": "Next round"}, {"wait": "input"}]); took = time.time() - t
    if "waiting on a click" not in out or "Continue" not in out: raise Fail("a waiting button wasn't named: " + out[-400:])
    if took > 5: raise Fail(f"took {took:.1f} s to notice")
    c.must("page_do", steps=[{"wait": "text", "text": "Continue"}])
    return True

@case
def closest_name(c):
    # Several controls hold the words, one is mostly those words: that one. Two close ones stay a question.
    c.must("page_click", text="Round Trip")
    if c.result().get("trip") is not True or c.result().get("deal"): raise Fail(f"clicked {c.result()}")
    ok, out = c.do("page_click", text="Larnaca 03/12")
    if not ok and "matches" not in out: raise Fail("a partial name neither clicked nor asked: " + out[:200])
    return True

@case
def frame_consent(c):
    # A consent banner in a frame from another site: turned down (never accepted) as the page is read.
    c.look()
    r = c.result()
    if r.get("choice") != "rejected": raise Fail(f"banner in a frame: {r}")
    c.must("page_click", text="Read more")
    return c.result().get("read") is True

@case
def popup(c):
    ok, out = c.do("page_click", ref=ref(c.look(), "link", "Open help"))
    ok2, tabs = c.m.call("tabs_list")
    rows = tabs.splitlines()   # "id title (flags)" then "   url"
    new = [rows[i - 1].split()[0] for i, l in enumerate(rows) if i and "popped.html" in l]
    for t in new: c.m.call("tabs_close", tab=t)
    return bool(new) and ("Help centre" in out or "new tab" in out.lower())

@case
def spa(c):
    if "Site links: " not in c.look() or "Orders" not in c.snap: raise Fail("nav links not listed by name")
    c.must("page_click", text="Orders")   # the site's own links are listed by name: clicked by name
    c.must("page_click", text="Order #1042")
    return c.result().get("opened") is True

@case
def lazy(c):
    for _ in range(12):
        if '"Item 50"' in c.look(): break
        c.must("page_scroll", dy=1500, snapshot=False)
    c.must("page_click", ref=ref(c.look(), "button", "Item 50"))
    return c.result().get("item") == 50

@case
def editor(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Message body"), text="Hello there")
    return (c.result().get("text") or "").strip() == "Hello there"

@case
def gated(c):
    ok, out = c.do("page_click", ref=ref(c.look(), "button", "Continue"), snapshot=False)
    honest = (not ok) or "disabled" in out.lower()
    c.must("page_click", ref=ref(c.look(), "checkbox", "agree"))
    c.must("page_click", ref=ref(c.look(), "button", "Continue"))
    return c.result().get("continued") is True and (honest or "said clicked while disabled")

@case
def styled_checkbox(c):
    c.must("page_click", ref=ref(c.look(), "checkbox", "Email me updates"))
    return c.result().get("news") is True

@case
def date(c):
    c.must("page_type", ref=ref(c.look(), None, "Check-in"), text="2026-12-24")
    return c.result().get("date") == "2026-12-24"

@case
def checkout(c):
    c.must("page_type", ref=ref(c.look(), None, "Qty"), text="2")
    c.must("page_click", ref=ref(c.snap, "button", "Checkout"))
    s = c.look()
    c.must("page_type", ref=ref(s, "textbox", "Full name"), text="Test Person")
    c.must("page_type", ref=ref(c.snap, "textbox", "Postcode"), text="SW1A 1AA")
    c.must("page_select", ref=ref(c.snap, "combobox", "Delivery"), value="Express")
    c.must("page_click", ref=ref(c.snap, "button", "Continue to payment"))
    s = c.look()
    c.must("page_type", ref=ref(s, "textbox", "Card number"), text="4242424242424242")
    c.must("page_type", ref=ref(c.snap, "textbox", "Expiry"), text="12 / 34")
    c.must("page_type", ref=ref(c.snap, "textbox", "CVC"), text="123")
    c.must("page_click", ref=ref(c.snap, "button", "Review order"))
    ok, text = c.do("page_text")
    return "Total £74.00" in text and (c.result().get("card") or {}).get("n") == "4242424242424242"

@case
def context_menu(c):
    c.must("page_click", text="report.pdf", button="right")
    c.must("page_click", ref=ref(c.look(), "menuitem", "Rename"))
    return c.result().get("menu") == "rename"

@case
def longpress(c):
    c.must("page_click", ref=ref(c.look(), "button", "Hold to confirm"), hold=1.0)
    return c.result().get("held") is True

@case
def canvas(c):
    c.must("page_drag", fromSelector="#c", by=[[-120, -20], [-40, 30], [40, -30], [120, 20]])
    return (c.result().get("strokePoints") or 0) >= 4

@case
def sortable(c):
    c.must("page_drag", fromText="Bread", toText="Milk")
    return c.result().get("order") == "Bread,Milk,Eggs"

@case
def pointer_only(c):
    c.must("page_click", ref=ref(c.look(), "button", "Like"))
    return c.result().get("liked") == "mouse"

@case
def carousel(c):
    c.must("page_touch", selector="#c", kind="swipe", dx=-160)
    return c.result().get("slide") == 2

@case
def autocomplete(c):
    c.must("page_type", ref=ref(c.look(), "combobox", "City"), text="Pr")
    s = c.look()
    if '"Prague"' not in s: raise Fail("no suggestions after typing (the page listens for keyup)")
    c.must("page_press", key="ArrowDown")
    c.must("page_press", key="Enter")
    return c.result().get("city") == "Prague"

@case
def aria_slider(c):
    r = ref(c.look(), "slider", "Volume")
    c.must("page_press", ref=r, key="ArrowRight")
    c.must("page_press", ref=r, key="ArrowRight")
    return c.result().get("volume") == 5

@case
def shortcuts(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Message"), text="hello")
    c.must("page_press", key="Meta+Enter")
    sent = c.result().get("sent") == "hello"
    c.must("page_click", ref=ref(c.look(), "button", "Open settings"))
    c.must("page_press", key="Escape")
    return sent and c.result().get("closedWith") == "escape"

@case
def tab_order(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "First name"), text="Ada")
    c.must("page_press", key="Tab")
    return c.result().get("tabbed") is True

@case
def format_editor(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Note"), text="Important")
    c.must("page_press", key="Meta+A")
    c.must("page_press", key="Meta+B")
    return "<b>" in (c.result().get("html") or "") or "font-weight" in (c.result().get("html") or "")

@case
def copy_paste(c):
    # Your clipboard: there before, still there after. The agent's copy and paste use its own.
    subprocess.run(["pbcopy"], input=b"USER-CLIP", check=True)
    s = c.look()
    c.must("page_click", ref=ref(s, "textbox", "Coupon"))
    c.must("page_press", key="Meta+A"); c.must("page_press", key="Meta+C")
    c.must("page_click", ref=ref(c.snap, "textbox", "Apply coupon"))
    c.must("page_press", key="Meta+V")
    time.sleep(0.3)
    mine = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
    if mine != "USER-CLIP": raise Fail(f"your clipboard changed to {mine!r}")
    return c.result().get("pasted") == "SAVE-2026"

@case
def frame_upload(c):
    path = os.path.join(HERE, "site", "kit.js")
    c.must("page_upload", ref=ref(c.look(), None, "Passport scan"), paths=[path])
    return c.result().get("uploaded") == "kit.js"

@case
def virtual(c):
    # Only the rows in view exist: scroll the list a screenful at a time, as a person would.
    for _ in range(30):
        s = c.look()
        if '"Contact 60"' in s: break
        c.must("page_scroll", selector="#v", dy=300, snapshot=False)
    time.sleep(0.4)   # a wheel scroll glides on; rows re-render until it stops
    c.must("page_click", ref=ref(c.look(), "button", "Contact 60"))
    return c.result().get("contact") == 60

@case
def hscroll(c):
    c.must("page_click", text="Card 25")
    return c.result().get("card") == 25

@case
def popover(c):
    c.must("page_click", ref=ref(c.look(), "button", "Filters"))
    c.must("page_click", ref=ref(c.look(), "checkbox", "In stock only"))
    return c.result().get("inStock") is True

@case
def nested_frames(c):
    c.must("page_click", ref=ref(c.look(), "button", "Confirm identity"))
    return c.result().get("identity") is True

@case
def prompt(c):
    c.must("page_click", ref=ref(c.look(), "button", "New folder"))
    c.must("page_dialog", accept=True, text="Invoices")
    return c.result().get("named") == "Invoices"

@case
def leave_guard(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Draft"), text="half a thought")
    ok, out = c.do("page_click", ref=ref(c.snap, "link", "Leave page"))
    if "beforeunload" in out or "dialog" in out.lower():
        c.must("page_dialog", accept=True)
    time.sleep(0.8)
    ok, url = c.m.call("page_eval", tab=c.tab, script="return location.pathname")
    return "popped.html" in url

@case
def window_open(c):
    ok, out = c.do("page_click", ref=ref(c.look(), "button", "Sign in with Partner"))
    if "new tab" not in out and "window" not in out.lower(): raise Fail("the popup window wasn't reported")
    popup = out.split("now your current tab:")[1].split()[0]
    ok, ps = c.m.call("page_snapshot", tab=popup)
    ok, done_ = c.m.call("page_click", tab=popup, ref=ref(ps, "button", "Approve"))
    return c.result().get("partner") == "approved"

@case
def validation(c):
    c.must("page_type", ref=ref(c.look(), "textbox", "Email"), text="bob")
    out = c.must("page_click", ref=ref(c.snap, "button", "Join"))
    if "Enter a valid email address" not in out: raise Fail("the error message wasn't in the answer")
    if "[invalid" not in out: raise Fail("the field wasn't marked invalid")
    c.must("page_type", ref=ref(out, "textbox", "Email"), text="bob@example.test")
    c.must("page_click", ref=ref(c.snap, "button", "Join"))
    return c.result().get("joined") == "bob@example.test"

@case
def keyboard_stays(c):
    c = c
    # "You": a tab in front with a field focused. The agent works in its own hidden tab meanwhile.
    ok, out = c.m.call("tabs_open", url=A + "your-tab.html", front=True, snapshot=False)
    yours = out.splitlines()[1].split()[0]
    try:
        c.m.call("page_click", tab=yours, selector="#mine", snapshot=False)
        c.must("page_type", ref=ref(c.look(), "textbox", "Search products"), text="lamp")
        c.must("page_click", ref=ref(c.look(), "textbox", "Search products"))
        ok, status = c.m.call("status")
        return '"front tab"' in status or ("front tab" in status and "agent tab" not in status) or status
    finally:
        c.m.call("tabs_close", tab=yours)

def run_case(mcp, name, f, timeout=40):
    out = {}
    def go():
        c = None
        try:
            c = Case(mcp, {"keyboard-stays": "react-input", "read-script": "animated", "goal": "animated", "habits": "animated", "cross-tab": "animated", "errands": "animated", "files": "animated", "beside": "animated", "paste-rows": "grid", "in-context": "two-months", "pick": "autocomplete", "date-gesture": "two-months", "records": "cards", "zoom": "cards", "site-notes": "two-months", "vault": "react-input", "pdf": "cards", "recalculate": "consent", "press-list": "press-list", "stale-wait": "stale-wait", "drawn-select": "drawn-select", "month-paging": "month-calendar", "goal-repeat": "facets", "find": "facets", "answer-check": "check", "page-state": "state", "list-end": "list", "popups": "popups", "failure-picture": "popups", "needs": "state", "reroute": "empty", "page-map": "check", "ticking": "ticker", "grid-cells": "sheet", "stale-refs": "reloading-filters", "hidden-captcha": "hidden-captcha", "rounds": "rounds", "wait-input": "countdown", "closest-name": "closest-name", "frame-consent": "frame-consent"}.get(name, name))
            v = f(c)
            out["v"] = v
        except Fail as e: out["v"] = str(e)
        except Exception as e: out["v"] = f"crash: {e}"
        finally:
            out["log"] = c.log if c else []
            if c:
                try: c.close()
                except Exception: pass
    t = threading.Thread(target=go, daemon=True); start = time.time(); t.start(); t.join(timeout)
    if t.is_alive(): return "hang", [f"no answer after {timeout} s"], time.time() - start
    return out.get("v"), out.get("log", []), time.time() - start

def owner_of_socket():
    out = subprocess.run(["lsof", "-t", SOCKET], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None

COPY = os.path.expanduser("~/Library/Caches/Sill Agent Course/Sill Course.app")

def prepare_copy():
    """A clone of the built app with an identity of its own (bundle id …course): a quit
    aimed at Sill ("tell application id … to quit", a rebuild) can't reach it, and it
    never shares anything with the Sill you're using. APFS clone: no extra disk."""
    built = os.path.getmtime(os.path.join(APP, "Contents/MacOS/Sill"))
    if os.path.exists(COPY) and os.path.getmtime(os.path.join(COPY, "Contents/MacOS/Sill")) >= built: return
    subprocess.run(["rm", "-rf", COPY]); os.makedirs(os.path.dirname(COPY), exist_ok=True)
    subprocess.run(["cp", "-Rc", APP, COPY], check=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier com.iasoncostoudes.sill.chromium.{PROFILE}",
                    os.path.join(COPY, "Contents/Info.plist")], check=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Set :CFBundleName Sill Course", os.path.join(COPY, "Contents/Info.plist")])
    subprocess.run(["codesign", "--force", "-s", "-", COPY], capture_output=True)
    os.utime(os.path.join(COPY, "Contents/MacOS/Sill"))

def start_copy():
    """Sill's test copy, in the background, with agent control on in its own settings."""
    prepare_copy()
    subprocess.run(["defaults", "write", DOMAIN, "agentControl", "-bool", "true"])
    subprocess.run(["defaults", "write", DOMAIN, "restoresTabs", "-bool", "false"])
    if owner_of_socket(): return
    subprocess.run(["open", "-n", "-g", "--env", f"SILL_PROFILE={PROFILE}", COPY])
    for _ in range(60):
        if owner_of_socket(): time.sleep(1.5); return
        time.sleep(0.5)
    raise SystemExit("Sill's test copy didn't start")

def stop_copy():
    pid = owner_of_socket()
    if pid: os.kill(pid, 15)

def main():
    stop_copy(); time.sleep(1.5)   # always the current build (--keep only leaves it running afterwards)
    start_copy()
    a, b = serve(os.path.join(HERE, "site"), "127.0.0.1", 8801), serve(os.path.join(HERE, "other"), "127.0.0.1", 8802)
    try:
        mcp = MCP()
        # A tab of "yours" stays open throughout, as in real use: the window never empties.
        mcp.call("tabs_open", url=A + "your-tab.html", front=True, snapshot=False, remember=False)
        rows, passed = [], 0
        for name, f in CASES.items():
            if ONLY and name not in ONLY: continue
            v, log, secs = run_case(mcp, name, f)
            mark = "PASS" if v is True else ("WRONG" if str(v).startswith("wrong element") else ("HANG" if v == "hang" else "FAIL"))
            passed += mark == "PASS"
            rows.append((mark, name, secs, "" if v is True else str(v), log))
            print(f"{mark:5} {name:18} {secs:5.1f}s  {'' if v is True else str(v)[:110]}", flush=True)
            if mark == "HANG":
                mcp.p.kill()   # stuck mid-call: start a fresh one rather than leave it holding on
                mcp = MCP()
        print(f"\n{passed}/{len(rows)} passed")
        mcp.p.stdin.close(); mcp.p.wait(timeout=5)
        with open(os.path.join(HERE, "last-run.json"), "w") as fh:
            json.dump([{"result": r[0], "case": r[1], "seconds": round(r[2], 1), "why": r[3], "steps": r[4]} for r in rows], fh, indent=1)
    finally:
        if "--keep" not in sys.argv: stop_copy()
        a.shutdown(); b.shutdown()

if __name__ == "__main__":
    main()
