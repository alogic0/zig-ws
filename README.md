# zig-ws

A Zig WebSocket client library and CLI for long-lived connections over TCP
and Unix sockets. Both use the same `ws` module. The Linux release targets
Zig 0.17.0 and supports text, binary data, and unsolicited messages. The first tested
peers are Chrome DevTools and the Codex app server.

## Build and use the client

Run `zig build` with the compiler in `.zigversion`. The executable is
`zig-out/bin/zig-ws`. The default mode sends one JSON value per input line
and prints incoming values as compact JSON lines, including notifications.
After input EOF it keeps receiving until the peer closes or `--receive N`
messages have arrived. The default operation and idle timeout is 30 seconds.
Use `--help` for text mode, file input and size limits.

```sh
printf '%s\n' '{"id":1,"method":"Browser.getVersion"}' |
  zig-out/bin/zig-ws --receive 1 "$CHROME_WS_URL" | jqz '.result.product'
zig-out/bin/zig-ws --unix "$SOCKET" --target / --host localhost --binary --input sample.bin > reply.bin
```

Import the public module with `b.dependency("zig_ws", options).module("ws")`.
`ws.Connection.connect(allocator, io, endpoint, options)` returns a connection
owned by the caller. Serialize its operations and call `deinit()` when done.
`send`, `receive` and `close` accept a `std.Io.Timeout` for the entire
operation. Pass the same absolute deadline to share a budget across calls.
Release each received message with `message.deinit(allocator)`. A successful
`close` returns the peer's code and a reason to free with the same allocator.
[Independent package example](tests/package/main.zig)

For JSON protocols, `ws.Rpc.init(&connection, limits)` matches integer or
string IDs. Call `submit` to send a request and `wait` to collect its reply.
`takeEvent` drains queued notifications and server requests. `nextEvent`
also reads from the connection. Free returned bytes with the allocator passed
to `connect` and call `rpc.deinit()` before releasing the connection. Queue
and pending limits surface as errors. If a submitted request loses its
reply, `wait` returns `error.DeliveryUnknown`. The caller decides whether to
retry. Connection failures before submission retain their original errors.

Run `zig build test test-cli` and run `zig build test` in `tests/package`.
The CLI fixtures use Python's standard library for the independent peer and
`jqz` to verify stdout. Repeat with `-Doptimize=ReleaseFast`.

## Start with the existing Zig code

At revision `e7dd49e`, `zig-cdp` already has masked client writes, partial
reads, text-message reassembly, ping/pong handling, deadlines and a bounded
queue. Read `WsSession` and `CdpClient.connectWs` before choosing what to
extract. Two details need particular attention. The Chrome connector uses a
fixed example handshake key, and its reader handles text messages. The new
client needs a fresh handshake key per connection and binary message support.
Keep Chrome discovery, session routing and its loopback policy in the consumer.
Preserve the MIT notice for reused code. [Existing implementation](../zig-cdp/src/cdp.zig)
· [Consumer API](../zig-cdp/docs/library.md) · [License](../zig-cdp/LICENSE)

## Implementation order

| Stage | Deliverable | Check before moving on |
| --- | --- | --- |
| 1. Connect and upgrade | Accept a TCP WebSocket URL or a Unix socket path. For Unix sockets, take the HTTP request target and Host separately from the filesystem path. Validate the HTTP 101 response, upgrade tokens and accept value for the generated key. | A local peer completes the upgrade over both transports. A bad accept value fails. A first frame arriving in the same read as the response headers is preserved. |
| 2. Exchange messages | Send and receive text and binary messages. Handle partial I/O, fragmentation, client masking, UTF-8 text, ping/pong, and the close handshake with its code and reason. | Split one text character across fragments, interleave a ping, then finish the message. The peer receives the pong and the caller receives one intact message. Round-trip arbitrary binary bytes. |
| 3. Bound resource use | Accept the caller's allocator and I/O context. Document who owns received bytes. Enforce message and queue byte limits, cancellation and a deadline for the whole operation. | Test an oversized fragmented message, a slow peer sending fragments before each individual read times out, and cancellation during a partial read. Release buffers and the socket on each terminal path. |
| 4. Expose the CLI | Accept messages from stdin or a file. Keep the connection open across requests. In JSON-lines mode, send one JSON value per line and write one received value per line to stdout. Send diagnostics to stderr. Provide a byte-preserving mode for a single binary message. | Pipe received JSON into `jqz`. Verify stdout, stderr and exit status for success, failed upgrade, timeout and peer close. |
| 5. Add optional request/reply handling | Match replies to pending request IDs. Deliver notifications and incoming requests to the caller. Bound pending requests and queued events, and tell the caller when a limit is reached. | With two requests outstanding, have the peer send a notification and reply in reverse order. Both callers receive the right reply and the notification remains observable. |

Use the WebSocket specification for wire behavior, including length encoding,
mask direction and control frames. Keep JSON parsing and application method
names above the transport so callers can also exchange arbitrary bytes.
[Opening handshake](https://www.rfc-editor.org/rfc/rfc6455.html#section-4.1)
· [Framing and control messages](https://www.rfc-editor.org/rfc/rfc6455.html#section-5)

## The decisive handoff test

Use a local fixture that speaks the Codex message sequence. Open one Unix
socket connection, send `initialize`, wait for its matching reply, send
`initialized`, and issue one `turn/start`. Have the fixture send a notification
before acknowledging the request. The caller must receive the notification
and the matching turn ID. The ID confirms that the server accepted the turn.
Its eventual completion is a separate event. [App-server protocol](../codex/codex-rs/app-server/README.md)

Repeat with the fixture recording the request and disconnecting before its
reply. The caller must receive **delivery unknown**, and the fixture must count
exactly one request. A failed connection before any request bytes were sent
has a distinct outcome. Leave any retry of a potentially delivered request to
the caller.

## First release

Run the protocol and CLI fixtures in Debug and ReleaseFast. Exercise the
library from a small external Zig package. Then try a read-only Chrome command
over TCP and a read-only app-server request over the Unix socket. Use fixtures
for the task-start and lost-reply cases so the checks can run repeatedly.
Once these pass, qualify the installed CLI against the same examples and
evaluate adopting the library in `zig-cdp` as a separate consumer change.

For day-to-day searches, JSON inspection and qualification of installed tools,
follow the [shared jqz and zigrep workflow](../docs/jqz-and-zigrep-workflow.md).
