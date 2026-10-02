# WebSocket Smart Reloads: Design Document

> Server-side view diffing over WebSockets, the Phoenix LiveView model adapted for Blimp's actor system.

## Problem

Every user interaction in the current web server (`web/server.blimp`) causes a full page reload:

1. User clicks a button
2. JS creates a hidden form and POSTs `msg=<atom>`
3. Server receives POST, updates state, sends HTTP 302 redirect
4. Browser follows redirect, GETs the page
5. Server re-renders the entire view tree, sends full HTML

This is slow (3 round trips), destroys client-side state (scroll position, focus, animations), and cannot support real-time updates (server push).

## Solution: WebSocket Smart Reloads

Replace the POST/redirect/GET cycle with a persistent WebSocket connection:

1. Initial page load: full HTML render (same as now)
2. Client JS opens a WebSocket to `/ws`
3. User interacts: JS sends `{"event": "increment"}` over WebSocket
4. Server receives event, updates actor state, re-renders view tree
5. Server diffs old view tree vs new view tree
6. Server sends `[{op: "replace", path: "1.0", html: "5"}]` over WebSocket
7. Client JS applies patches to the DOM -- no reload

## Architecture

```
Browser                          Server (Blimp)
  |                                  |
  |--- GET / ----------------------->|  Full HTML page + blimp.js
  |<-- 200 OK + HTML ---------------|
  |                                  |
  |--- WS Upgrade /ws ------------->|  HTTP 101 Switching Protocols
  |<-- 101 + Sec-WebSocket-Accept --|
  |                                  |
  |    [WebSocket connection open]   |
  |                                  |
  |--- {"event":"increment"} ------>|  Server: handle_event -> re-render
  |<-- [{"op":"text","p":"1.0",     |  Server: diff old vs new view tree
  |      "v":"5"}] ----------------|  Send minimal patches
  |                                  |
  |    [Client applies DOM patches]  |
```

## Phase 1: WebSocket Protocol (Zig Builtins)

### The Handshake

WebSocket upgrade is an HTTP request with specific headers:

```
GET /ws HTTP/1.1
Host: localhost:8080
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

Server must:
1. Concatenate the client key with the magic GUID: `"258EAFA5-E914-47DA-95CA-5AB9DC80CB65"`
2. SHA-1 hash the result
3. Base64 encode the hash
4. Send back `101 Switching Protocols` with `Sec-WebSocket-Accept: <result>`

### New Builtins

```zig
// ws_accept_key(client_key: String) -> String
// Computes SHA-1(key + magic_guid) then Base64-encodes it
fn builtinWsAcceptKey(allocator, args) -> Value.string

// ws_read_frame(fd: Int) -> String
// Reads one WebSocket text frame, handles masking, returns payload
fn builtinWsReadFrame(allocator, args) -> Value.string

// ws_write_frame(fd: Int, data: String) -> nil
// Writes a WebSocket text frame (server-to-client, unmasked)
fn builtinWsWriteFrame(allocator, args) -> Value.nil
```

### Frame Format (Text Frames Only)

Server-to-client (unmasked):
```
Byte 0: 0x81 (FIN=1, opcode=0x1 text)
Byte 1: payload length
  - if len < 126: byte 1 IS the length
  - if len == 126: next 2 bytes are length (big-endian u16)
  - if len == 127: next 8 bytes are length (big-endian u64)
Bytes N..: payload data (UTF-8 text)
```

Client-to-server (masked):
```
Byte 0: 0x81 (FIN=1, opcode=0x1 text)
Byte 1: 0x80 | payload length (high bit = masked)
  - length encoding same as above
4 bytes: masking key
Bytes N..: masked payload (XOR each byte with mask[i % 4])
```

### Opcodes We Handle

| Opcode | Name | Action |
|--------|------|--------|
| 0x1 | Text | Decode and return payload |
| 0x8 | Close | Return nil (connection closed) |
| 0x9 | Ping | Auto-respond with Pong, then read next frame |
| 0xA | Pong | Ignore, read next frame |

Binary frames (0x2) are not supported initially.

## Phase 2: View Tree Diffing

### The Diff Algorithm

Compare two ViewNode trees and produce a list of patch operations. The path is a dot-separated index into the tree (e.g., "1.0" means child 1, then child 0 of that).

```
diff(old_tree, new_tree) -> [Patch]

Patch = {
  op: "replace" | "text" | "remove" | "insert" | "attrs",
  path: String,       // e.g. "0.1.2"
  value: String       // HTML fragment or text content
}
```

### Diff Rules

1. **Same tag, same children count**: recurse into children, diff attributes
2. **Same tag, different children count**: replace the entire subtree
3. **Different tag**: replace the entire subtree
4. **Text node changed**: emit `{op: "text", path, value: new_text}`
5. **Attributes changed**: emit `{op: "attrs", path, attrs: {key: val}}`

### Implementation Strategy

Start simple: compare `to_html(old)` vs `to_html(new)`. If different, send full replacement. This is the "v0" diff -- works but sends too much data.

Then upgrade to structural diffing:

```zig
fn diffViewTrees(alloc, old: *const Value, new: *const Value, path: []const u8) ![]Patch {
    // Both view_nodes?
    if (old.* == .view_node and new.* == .view_node) {
        const o = old.view_node;
        const n = new.view_node;

        // Different tags -> full replace
        if (!mem.eql(u8, o.tag, n.tag)) return [replace(path, to_html(new))];

        // Same tag, diff attrs
        var patches = diffAttrs(o.attrs, n.attrs, path);

        // Diff children recursively
        const min_len = @min(o.children.len, n.children.len);
        for (0..min_len) |i| {
            const child_path = fmt("{s}.{d}", .{path, i});
            patches ++= diffViewTrees(alloc, o.children[i], n.children[i], child_path);
        }

        // Extra children in new -> insert
        // Missing children in new -> remove

        return patches;
    }

    // Text nodes: compare string content
    if (old.* == .string and new.* == .string) {
        if (!mem.eql(u8, old.string, new.string)) {
            return [text(path, new.string)];
        }
        return &.{};
    }

    // Type mismatch -> full replace
    return [replace(path, to_html(new))];
}
```

### Builtin

```
view_diff(old_tree, new_tree) -> List
```

Returns a list of maps: `[%{op: "text", path: "1.0", value: "5"}, ...]`

Exposed to Blimp code so `server.blimp` can call it directly.

## Phase 3: Client-Side JavaScript

Replace the current `blimp_script()` (form POST hack) with a WebSocket client:

```javascript
(function() {
  var ws = null;
  var reconnectDelay = 1000;

  function connect() {
    ws = new WebSocket('ws://' + location.host + '/ws');

    ws.onopen = function() {
      reconnectDelay = 1000;
      // Request initial state
      ws.send(JSON.stringify({type: 'mount'}));
    };

    ws.onmessage = function(e) {
      var msg = JSON.parse(e.data);
      if (msg.type === 'patches') {
        msg.patches.forEach(applyPatch);
      } else if (msg.type === 'full') {
        document.querySelector('.page').innerHTML = msg.html;
      }
    };

    ws.onclose = function() {
      setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    };
  }

  function applyPatch(patch) {
    var el = navigatePath(document.querySelector('.page'), patch.path);
    if (!el) return;

    switch (patch.op) {
      case 'replace':
        el.outerHTML = patch.value;
        break;
      case 'text':
        el.textContent = patch.value;
        break;
      case 'remove':
        el.remove();
        break;
      case 'insert':
        el.insertAdjacentHTML('beforeend', patch.value);
        break;
      case 'attrs':
        Object.keys(patch.value).forEach(function(k) {
          el.setAttribute(k, patch.value[k]);
        });
        break;
    }
  }

  function navigatePath(root, path) {
    if (!path || path === '') return root;
    var indices = path.split('.').map(Number);
    var node = root;
    for (var i = 0; i < indices.length; i++) {
      if (!node || !node.children) return null;
      node = node.children[indices[i]];
    }
    return node;
  }

  // Event handling: buttons with data-sends
  document.addEventListener('click', function(e) {
    var btn = e.target.closest('[data-sends]');
    if (btn && ws && ws.readyState === 1) {
      e.preventDefault();
      ws.send(JSON.stringify({
        type: 'event',
        msg: btn.getAttribute('data-sends')
      }));
    }
  });

  // Input handling: inputs with data-name
  document.addEventListener('change', function(e) {
    var input = e.target.closest('[data-name]');
    if (input && ws && ws.readyState === 1) {
      ws.send(JSON.stringify({
        type: 'input',
        name: input.getAttribute('data-name'),
        value: input.value
      }));
    }
  });

  // Form handling
  document.addEventListener('submit', function(e) {
    var form = e.target.closest('form');
    if (form && ws && ws.readyState === 1) {
      e.preventDefault();
      var data = {};
      new FormData(form).forEach(function(v, k) { data[k] = v; });
      ws.send(JSON.stringify({
        type: 'form',
        data: data
      }));
    }
  });

  connect();
})();
```

### Key Design Points

- **Reconnection with backoff**: If the WS drops, auto-reconnect with exponential backoff (1s, 2s, 4s, ... up to 30s).
- **Event delegation**: Instead of `onclick` on each button, use event delegation on `document`. This survives DOM patches.
- **`mount` message**: On connect, client sends `{type: "mount"}` so the server knows to send the initial full render.
- **Two message types from server**: `{type: "full", html: "..."}` for initial render / fallback, and `{type: "patches", patches: [...]}` for incremental updates.

## Phase 4: Server-Side WebSocket Handler

### Upgrade Detection in server.blimp

```blimp
on :accept do
  client_fd = tcp_accept(fd)
  raw = tcp_read(client_fd)

  first_line = head(split(raw, "\r\n"))
  req = parse_request_line(first_line)
  method = lookup(req, "method")

  case is_ws_upgrade(raw) do
    true -> handle_ws(client_fd, raw)
    _    ->
      # existing HTTP handling
      session_id = "1"
      existing = Sessions <- :get(session_id)
      data = existing orelse initial_state()
      response = dispatch(method, raw, session_id, data)
      tcp_write(client_fd, response)
      tcp_close(client_fd)
  end

  HTTPServer <- :accept
end
```

### WebSocket Upgrade Response

```blimp
def is_ws_upgrade(raw: String) -> Bool do
  contains(raw, "Upgrade: websocket")
end

def parse_ws_key(raw: String) -> String do
  lines = split(raw, "\r\n")
  find_header(lines, "Sec-WebSocket-Key: ")
end

def find_header(lines: List, prefix: String) -> String do
  case empty?(lines) do
    true -> ""
    _ ->
      line = head(lines)
      case contains(line, prefix) do
        true ->
          parts = split(line, prefix)
          head(tail(parts))
        _ -> find_header(tail(lines), prefix)
      end
  end
end

def handle_ws(client_fd: Int, raw: String) do
  key = parse_ws_key(raw)
  accept = ws_accept_key(key)

  response = concat(
    "HTTP/1.1 101 Switching Protocols\r\n",
    concat("Upgrade: websocket\r\n",
    concat("Connection: Upgrade\r\n",
    concat("Sec-WebSocket-Accept: ", concat(accept, "\r\n\r\n"))))
  )
  tcp_write(client_fd, response)

  # Enter WebSocket loop with initial state
  data = initial_state()
  old_view = render_app(data)

  # Send initial full render
  html = to_html(old_view)
  ws_write_frame(client_fd, concat("{\"type\":\"full\",\"html\":\"", concat(escape_json(html), "\"}")))

  ws_loop(client_fd, data, old_view)
end

def ws_loop(fd: Int, data: Map, old_view: ViewNode) do
  frame = ws_read_frame(fd)
  case frame do
    nil -> tcp_close(fd)  # Connection closed
    _ ->
      msg = parse_ws_event(frame)
      new_data = handle_event(data, msg)
      new_view = render_app(new_data)
      patches = view_diff(old_view, new_view)
      response = to_json_patches(patches)
      ws_write_frame(fd, response)
      ws_loop(fd, new_data, new_view)
  end
end
```

### Session Integration

When cookies/sessions are implemented (by another agent), the WS handler should:
1. Parse cookies from the initial HTTP upgrade request
2. Look up session data from the Sessions actor
3. Use that session's state for the WS connection
4. On disconnect, persist state back to Sessions

## Interaction with Other Agents' Work

### Agent 1: Input Fields and Forms
- WS needs to handle `{type: "input", name, value}` and `{type: "form", data}` messages
- The client JS already includes handlers for these (event delegation on `change` and `submit`)
- Server needs `handle_input(data, name, value)` alongside `handle_event(data, msg)`

### Agent 2: Session Identity (Cookies)
- WS upgrade request includes cookies -- parse them from the HTTP headers
- Each WS connection should be associated with a session
- On reconnect, client should send session ID so server restores state

### Agent 3: Multi-Actor View Composition (mount())
- `mount(Counter)` in a view embeds a child actor's rendered output
- WS diffing must handle mounted actors: when a child actor's state changes, diff its subtree independently
- Each mounted actor could have its own WS "channel" within the connection

### Agent 5: Concurrent Connections
- WS connections are long-lived -- the server MUST handle multiple concurrent connections
- The current single-threaded accept loop blocks on `ws_loop()`
- Until concurrent connections exist, WS blocks all other requests
- Short-term: accept one WS connection at a time
- Long-term: actor scheduler handles concurrent WS connections as separate actors

## Open Questions

1. **JSON in Blimp**: We need `to_json(value)` and `parse_json(string)` builtins. The WS protocol is JSON-framed. Alternative: use a simpler wire format (pipe-separated, length-prefixed).

2. **Blocking read**: `ws_read_frame()` blocks the entire runtime. With a single-threaded evaluator, this means no other actors can process messages while waiting for WS input. The actor scheduler (when built) should make WS reads non-blocking.

3. **Binary efficiency**: JSON patches are human-readable but verbose. A binary patch format would be more efficient. Not worth optimizing yet.

4. **View tree identity**: Without stable keys on list items, the differ can't distinguish "item moved" from "item changed". The `key:` attribute from `view-dsl.md` would help but isn't implemented yet.

5. **Error recovery**: What happens if `ws_read_frame` gets a malformed frame? Currently returns nil (treated as close). Should probably send a WS close frame with error code.

## Implementation Order

1. Design doc (this file)
2. `ws_accept_key` builtin (SHA-1 + Base64) -- smallest unit, fully testable
3. `ws_write_frame` builtin -- simple encoding
4. `ws_read_frame` builtin -- frame parsing with mask decode
5. `view_diff` builtin -- structural tree diffing
6. Client JS -- replace `blimp_script()` with WS client
7. `server.blimp` -- upgrade detection + WS loop
8. Integration test -- click a button, verify diff arrives over WS
