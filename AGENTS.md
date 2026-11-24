# Driving Sill from an agent

Sill can be driven by AI agents and scripts on the same Mac: Claude Code, Codex, Cursor,
Devin's local runner, or anything that speaks MCP or a line of JSON.

## Turn it on

Sill › Settings › **Agents** › **Allow agents to control Sill**. Off by default.

Sill then listens on a Unix socket:

    ~/Library/Application Support/Sill/agent.sock            (Sill on WebKit)
    ~/Library/Application Support/Sill Chromium/agent.sock   (Sill on Chromium)

- The folder is yours alone (0700), the socket 0600, and every connection's other end is
  checked to be the same user before anything is read. Nothing listens on the network.
- Private windows are never visible. Password fields never give up their values.
- Only `http` and `https` addresses can be opened. Tabs an agent opens are marked
  `openedByAgent`.
- Agents work in the background. Their tabs open behind yours, and clicks, typing,
  keys, scrolling and screenshots go into the page through Chrome DevTools: your
  pointer, keyboard and front tab are never touched. While an agent works in a tab,
  six dots twinkle beside its icon, and if you bring it to the front, its page's
  edges glow.

## What the harness guarantees

- **It sees what a person sees**: open shadow roots, same-origin frames, frames in other
  processes (card forms, embedded sign-ins; refs like `f2:e7`), and closed shadow roots
  (through Chromium's accessibility tree; refs like `a913`).
- **It never acts on a guess**: a ref from an older element list is refused, not matched
  to a lookalike. Disabled or covered elements are reported, with what covers them.
  Elements are clicked only once they've stopped moving, and every click is checked
  afterwards: if it landed elsewhere, the answer says so.
- **It says what happened**: a dialog or a new tab an action opened, what a field reads
  after typing, a page still loading, headings and the page's own error messages, fields
  marked invalid. Nothing reports an empty page mid-navigation. A click that didn't
  arrive is reported, never "clicked".
- **It stays out of your way**: the agent has its own clipboard (yours is put back after
  its ⌘C and ⌘V), agent keys never reach Sill's menus (an agent's ⌘-chord
  can't close your window), the keyboard stays in your tab, and an agent closing the last
  tab of your last window leaves an empty tab rather than no window.

`Tests/agent-course/` is the proof: 46 cases taken from what breaks agents on real sites
(shadow DOM, cross-origin card frames, covered buttons, re-rendering lists, custom
dropdowns, two-step sign-in, dialogs, popups, drag and drop, infinite lists, a full
checkout, right-click menus, long press, drawing, sortable lists, touch, keystroke-driven
suggestions, custom sliders, shortcuts, copy and paste, virtual lists, popovers, nested
frames, prompt and leave-page dialogs, popup windows, validation). It runs its own copy of
Sill (own identity, profile and settings) in the background; yours is never touched:

    python3 Tests/agent-course/run.py

## Asking first

Settings › Agents › **Ask before**: *Risky steps* (default), *Every change*, or *Never*.
On *Risky steps*, a click or Enter whose words suggest paying, ordering, sending,
posting, deleting or account changes is judged by Apple's on-device model, and Sill
asks only when it says so. Everything else goes straight through. Uploads always ask.
CAPTCHAs and human checks are never solved by the agent: it calls `wait_for_user`.
Card details always ask. Questions appear in a small card in the corner of the screen;
they don't cover your window or take the keyboard.

Settings › Agents › **Agent activity** shows everything agents did (never what they
typed). From claude.ai, `page_eval` is off unless you turn on **Let claude.ai run
scripts in pages**. **Sign out claude.ai** ends every claude.ai sign-in at once.

While an agent works, the Mac doesn't idle-sleep; a closed lid still sleeps it, and
Sill reconnects to the relay as soon as it wakes.

## claude.ai

claude.ai calls connectors from the internet, so it reaches Sill through a small
relay you run (`relay/`, deployed to Railway). Sill's helper dials out to the relay
and keeps the line open.

1. Deploy `relay/` with `RELAY_SECRET` set (`openssl rand -hex 32`).
2. Sill › Settings › Agents › **Let claude.ai control Sill** › Relay: the relay's
   address and its key (kept in your Keychain).
3. In claude.ai: Settings › Connectors › Add custom connector, with the relay's
   address followed by `/mcp`.
4. Click **Allow** in the dialog Sill shows. Nothing signs in without it.

Change `RELAY_SECRET` to sign every client out.

## MCP

`sill-mcp` ships inside the app:

    /Applications/Sill.app/Contents/Helpers/sill-mcp

Claude Code:

    claude mcp add sill -- /Applications/Sill.app/Contents/Helpers/sill-mcp

Codex:

    codex mcp add sill -- /Applications/Sill.app/Contents/Helpers/sill-mcp

Any client (JSON config):

```json
{ "mcpServers": { "sill": { "command": "/Applications/Sill.app/Contents/Helpers/sill-mcp" } } }
```

## Tools

| Tool | What it does | Arguments |
|---|---|---|
| `status` | App version, window and tab counts | — |
| `tabs_list` | Open tabs: id, url, title, loading, selected, asleep, openedByAgent | — |
| `tabs_open` | Open an address in a new background tab, waiting for it to load; it becomes your current tab | `url`, `front`, `wait`, `timeout` |
| `tabs_select` | Bring a tab to the front | `tab` |
| `tabs_close` | Close a tab | `tab` |
| `page_navigate` | Load an address in a tab | `tab`, `url`, `wait`, `timeout` |
| `page_back` / `page_forward` / `page_reload` | History and reload, waiting for the page | `tab` |
| `page_wait` | Wait for load, a CSS selector, or some text | `tab`, `selector`, `text`, `timeout` |
| `page_text` | Visible text, url and title | `tab`, `maxChars` |
| `page_snapshot` | Interactive elements with refs (`e12`), role, name, value, href, box | `tab`, `all` |
| `page_click` | Click by ref, selector, visible text or a point, in any tab: right-click, long press (`hold`), ⌘/⇧-click | `tab`, `ref`, `selector`, `text`, `x`, `y`, `double`, `button`, `hold`, `modifiers` |
| `page_hover` | Move the mouse over an element | `tab`, `ref`, `selector`, `text` |
| `page_type` | Type key by key (pages see real keystrokes), then read the field back | `tab`, `ref`, `selector`, `label`, `text`, `clear`, `submit` |
| `page_select` | Choose a `<select>` option by value or label | `tab`, `ref`, `selector`, `text`, `value` |
| `page_press` | Press a key or chord (Enter, Tab, Escape, arrows, Meta+A, Meta+B…), optionally on an element | `tab`, `key`, `ref` |
| `page_scroll` | Wheel by `dy`/`dx` over the page or over an element (a list, a map), or bring an element into view | `tab`, `dy`, `dx`, `x`, `y`, `ref`, `selector`, `text` |
| `page_eval` | Run JavaScript in the page as an async function body (use `return`) | `tab`, `script` |
| `page_screenshot` | JPEG of the page, in any tab; `marks` draws each element's box and ref on it | `tab`, `maxWidth`, `marks` |
| `page_find` | Find text and scroll to it | `tab`, `text` |
| `history_search` | Search Sill's history | `query`, `limit` |
| `page_do` | Many steps in one call (click, type, press, select, wait, …) | `steps`, `full` |
| `page_sign_in` | Sign in with the password saved in Sill for this site; the agent never sees it | `tab`, `user`, `submit` |
| `passwords_list` | Saved accounts for this site (names only) | `tab`, `host` |
| `passwords_save` | Keep a password; `generate` makes a strong one and fills the sign-up form | `tab`, `user`, `password`, `generate` |
| `page_drag` | Press, move, let go: to a target, or along a drawn path (`by`) | `fromRef`/`fromX`…, `toRef`/`toX`…, `by`, `steps` |
| `page_touch` | Tap, long press or swipe with a finger | `ref`/`x`,`y`, `kind`, `dx`, `dy` |
| `page_pinch` / `page_zoom` | Pinch to zoom; the page's zoom level | `scale` / `level` |
| `page_upload` | Files into a file field, also inside frames from other sites; the user is always asked | `ref`, `paths` |
| `wait_for_user` | Hand over for a CAPTCHA, a code or a passkey, and wait | `message`, `until`, `timeout` |
| `page_dialog` | Answer the page's alert, confirm or prompt (held while an agent works) | `accept`, `text` |
| `web_search` | Search the web in your browser (Google, else DuckDuckGo) | `query`, `count`, `engine` |
| `read_url` | Open, read and close a page in one step | `url`, `maxChars`, `keep_open` |

`tab` is an id from `tabs_list`. Leave it out to use your current tab: the last one
you opened or named (the tab in front only if you haven't opened one).

Fast by design: Sill acts in milliseconds; the time is the model's round trips. So:
1. `tabs_open` answers with the page's elements and their refs.
2. `page_do` runs a whole sequence in one call: type, pick a suggestion by its full name,
   pick a date, press Search. Text targets are waited for; a text matching several things
   is refused, and a partial match is flagged.
3. Every action answers with only what changed on the page (`page_snapshot` shows it all).
4. Actions finish when the page is quiet and its requests have come back, not after a
   fixed pause: suggestions and results are in the answer.

Trip.com, London → Paris one-way on a chosen date, ten steps: one `page_do` call, 7 s.

## The socket directly

One JSON object per line each way:

    → {"id": 1, "cmd": "tabs.open", "args": {"url": "example.com"}}
    ← {"id": 1, "ok": true, "result": {"id": "…", "url": "https://example.com/", …}}

Commands are the tool names with a dot, not an underscore (`tabs.open`, `page.snapshot`, …).

```sh
printf '{"id":1,"cmd":"tabs.list"}\n' | nc -U ~/Library/Application\ Support/Sill/agent.sock
```
