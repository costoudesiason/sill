# Driving Sill from an agent

Sill can be driven by AI agents and scripts on the same Mac: Claude Code, Codex, Cursor,
Devin's local runner, or anything that speaks MCP or a line of JSON.

## Turn it on

Sill › Settings › **Agents** › **Allow agents to control Sill**. Off by default.

Sill then listens on a Unix socket:

    ~/Library/Application Support/Sill/agent.sock

- The folder is yours alone (0700), the socket 0600, and every connection's other end is
  checked to be the same user before anything is read. Nothing listens on the network.
- Private windows are never visible. Password fields never give up their values.
- Only `http` and `https` addresses can be opened. Tabs an agent opens are marked
  `openedByAgent`.

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
| `tabs_open` | Open an address in a new tab, waiting for it to load | `url`, `background`, `wait`, `timeout` |
| `tabs_select` | Bring a tab to the front | `tab` |
| `tabs_close` | Close a tab | `tab` |
| `page_navigate` | Load an address in a tab | `tab`, `url`, `wait`, `timeout` |
| `page_back` / `page_forward` / `page_reload` | History and reload, waiting for the page | `tab` |
| `page_wait` | Wait for load, a CSS selector, or some text | `tab`, `selector`, `text`, `timeout` |
| `page_text` | Visible text, url and title | `tab`, `maxChars` |
| `page_snapshot` | Interactive elements with refs (`e12`), role, name, value, href, box | `tab`, `all` |
| `page_click` | Click by ref, selector or visible text (a real click on the tab in front) | `tab`, `ref`, `selector`, `text`, `double` |
| `page_type` | Type into a field or contenteditable, optionally pressing Enter | `tab`, `ref`, `selector`, `label`, `text`, `clear`, `submit` |
| `page_select` | Choose a `<select>` option by value or label | `tab`, `ref`, `selector`, `text`, `value` |
| `page_press` | Press Enter, Tab, Escape, Backspace, Delete, Space, arrows, PageUp/Down, Home, End | `tab`, `key` |
| `page_scroll` | Scroll by `dy` pixels, or scroll an element into view | `tab`, `dy`, `ref`, `selector`, `text` |
| `page_eval` | Run JavaScript in the page as an async function body (use `return`) | `tab`, `script` |
| `page_screenshot` | PNG of the page | `tab`, `maxWidth` |
| `page_find` | Find text and scroll to it | `tab`, `text` |
| `history_search` | Search Sill's history | `query`, `limit` |

`tab` is an id from `tabs_list`. Leave it out to use the tab in front.

A typical loop:
1. `tabs_open` to open a page.
2. `page_snapshot` to get the element refs.
3. `page_click` or `page_type` with a ref.
4. `page_wait`, then `page_snapshot` again.

## The socket directly

One JSON object per line each way:

    → {"id": 1, "cmd": "tabs.open", "args": {"url": "example.com"}}
    ← {"id": 1, "ok": true, "result": {"id": "…", "url": "https://example.com/", …}}

Commands are the tool names with a dot, not an underscore (`tabs.open`, `page.snapshot`, …).

```sh
printf '{"id":1,"cmd":"tabs.list"}\n' | nc -U ~/Library/Application\ Support/Sill/agent.sock
```
