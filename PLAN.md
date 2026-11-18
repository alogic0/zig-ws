# zig-ws implementation and release plan

The first release targets Linux and Zig 0.17.0. The `zig-ws` CLI and
`zig-cdp` share the `ws` module. The client connects to Chrome DevTools over
TCP and to the Codex app server over a Unix domain socket.
Library integration and usage are in the [README](README.md).

## 1. Extract the transport

At revision `e7dd49e`, `zig-cdp` already handled masked client writes,
partial reads, fragmented text, ping/pong, deadlines, and a bounded queue.
Its Chrome connector used a fixed example handshake key and its reader
handled text messages. These were the starting points for the extraction.

- [x] Start from `WsSession` and `CdpClient.connectWs` in `zig-cdp` at
  revision `e7dd49e`. Preserve the MIT notice with the reused code.
  [Source](../zig-cdp/src/cdp.zig) · [License](../zig-cdp/LICENSE)
- [x] Put the TCP and Unix socket upgrades, text and binary framing,
  fragmentation, ping/pong, and close handling in `ws`. Generate a fresh
  handshake key for each connection. Accept the caller's allocator and I/O
  context, document who frees received messages, and enforce byte limits,
  cancellation, and a deadline across the whole operation.
- [x] Export `ws` from `build.zig` with `b.addModule`. Build the CLI against
  that module. Keep JSON parsing and request matching above the transport.

## 2. Verify the package before adoption

- [x] Import `ws` from a small external Zig package. Exchange messages with a
  local peer over TCP and a Unix socket using only the public API.
- [x] Run the protocol and CLI fixtures in Debug and ReleaseFast. Check that
  each stage meets the acceptance criteria below.
- [x] Run the Codex handoff fixture, qualify the installed CLI, and run the
  read-only Chrome and app-server checks. [First release](#first-release)

### Implementation order

| Stage | Deliverable | Acceptance check |
| --- | --- | --- |
| 1. Connect and upgrade | Accept a TCP WebSocket URL or a Unix socket path with a separate HTTP target and Host. Validate the HTTP 101 response, upgrade tokens, and accept value for a fresh key. | Complete an upgrade on both transports. Reject a bad accept value. Preserve a first frame arriving in the same read as the response headers. |
| 2. Exchange messages | Support partial I/O, masked client frames, UTF-8 text, binary messages, fragmentation, ping/pong, and close codes and reasons. | Split a UTF-8 character across fragments with an intervening ping. The peer receives a pong and the caller receives the intact message. Round-trip arbitrary binary bytes. |
| 3. Bound resource use | Accept the caller's allocator and I/O context. Define ownership and enforce message and queue limits, cancellation, and a deadline across the whole operation. | Exercise oversized fragmented messages, fragments arriving slowly enough to exceed the total deadline, and cancellation during a partial read. Check buffer and socket cleanup. |
| 4. Expose the CLI | Keep one connection open across messages from stdin or a file. Support JSON lines and a byte-preserving single binary exchange. Send diagnostics to stderr. | Pipe JSON output to `jqz`. Verify stdout, stderr, and exit status for success, failed upgrade, timeout, and peer close. |
| 5. Match requests and replies | Bound pending request IDs and queued events, surface limit errors, and deliver notifications and incoming requests. | Send a notification and reply to two outstanding requests in reverse order. Match both IDs and retain the notification. |

The wire implementation follows RFC 6455 for length encoding, mask direction,
control frames, and the opening handshake.
[Opening handshake](https://www.rfc-editor.org/rfc/rfc6455.html#section-4.1) · [Framing and control messages](https://www.rfc-editor.org/rfc/rfc6455.html#section-5)

### Codex handoff fixture

Open one Unix socket connection, send `initialize`, wait for its matching
reply, send `initialized`, and issue one `turn/start`. Have the fixture send a
notification before acknowledging the request. The caller must receive the
notification and the matching turn ID. The ID confirms acceptance of the
turn. Completion arrives as a separate event.

Repeat with the fixture recording `turn/start` and disconnecting before its
reply. The caller must receive `error.DeliveryUnknown` and the fixture must
count exactly one request. A connection failure before submission must
retain its original error. Leave any retry to the caller.
[Fixture](tests/package/main.zig) · [App-server protocol](../codex/codex-rs/app-server/README.md)

## 3. Switch zig-cdp to the package

- [x] Make adoption a separate change in `../zig-cdp`. For the first local
  build, add `.zig_ws = .{ .path = "../zig-ws" }` to its manifest dependencies.
  Import the dependency's `ws` module into both the public `cdp` module and
  the native test module that compiles `cdp.zig` directly.
  [Consumer build](../zig-cdp/build.zig)
- [x] Have `CdpClient.connectWs` apply Chrome's loopback and port checks
  before delegating the upgrade to `ws`. Replace the framing inside
  `WsSession` with calls to `ws`. Keep discovery, request IDs, `sessionId`
  routing, and queued CDP events in `zig-cdp`. Verify that existing callers
  can still use `call`, `callSession`, and `takeEvent` with their documented
  ownership rules. [Public API](../zig-cdp/docs/library.md)
- [x] Once the tested `zig-ws` revision is available from its Git remote,
  replace the local path with the full Git commit and Zig package hash.
  Follow the existing `zig-process` dependency. From a clean `zig-cdp`
  checkout, run the library, CLI, and external package checks in Debug and
  ReleaseSafe using the committed pin. [Consumer manifest](../zig-cdp/build.zig.zon)

For subsequent changes across both checkouts, run
`zig build test --fork=../zig-ws` from `../zig-cdp` to test local edits.
Run `zig build test` there to test the committed dependency.

## Command-line client

Run `zig build` with the compiler in `.zigversion`. The executable is
`zig-out/bin/zig-ws`. Its default JSON-lines mode sends one JSON value per
input line and prints incoming values as compact JSON lines, including
notifications. After input EOF it keeps receiving until the peer closes or
`--receive N` messages have arrived. The default operation and idle timeout
is 30 seconds. Run `zig-out/bin/zig-ws --help` for text mode, file input,
timeouts, and size limits.

Set `CHROME_WS_URL` to the browser's DevTools WebSocket URL to read its
version. For the binary example, set `SOCKET` to the path of a Unix socket
whose peer accepts binary messages.

```sh
printf '%s\n' '{"id":1,"method":"Browser.getVersion"}' |
  zig-out/bin/zig-ws --receive 1 "$CHROME_WS_URL" | jqz '.result.product'
zig-out/bin/zig-ws --unix "$SOCKET" --target / --host localhost --binary --input sample.bin > reply.bin
```

## First release

Use Python's standard library for the independent CLI peer and `jqz` to
check stdout. Run the protocol, CLI, and external package fixtures from the
`zig-ws` checkout in both profiles.

```sh
zig build test test-cli
zig build test test-cli -Doptimize=ReleaseFast
(cd tests/package && zig build test)
(cd tests/package && zig build test -Doptimize=ReleaseFast)
```

Run the installed CLI against the same fixtures. Follow with a read-only
Chrome command over TCP and a read-only app-server request over the Unix
socket. Use the local fixture for task-start and lost-reply checks so they
can run repeatedly. Adopt the qualified package in a separate `zig-cdp` change.

For day-to-day searches, JSON inspection, and qualification of installed
tools, follow the [shared jqz and zigrep workflow](../docs/jqz-and-zigrep-workflow.md).

## Qualification results

The first release was qualified at `deb93db8db3a93b557f1a77325f7aa6237da9fa7`.
The `zig-cdp` 0.5.2 adoption commit is `9d9782ad4aab0f80852852e58dbede908345bc96`.
Its manifest records the Git URL and the Zig package hash.
[Consumer manifest](../zig-cdp/build.zig.zon)

| Check | Profiles | Result |
| --- | --- | --- |
| WebSocket protocol and CLI fixtures | Debug, ReleaseFast | Framing, cancellation, deadlines, JSON-lines output, binary exchange, and exit status passed. |
| External Zig package | Debug, ReleaseFast | Both transports, notification and reply routing, queue limits, and the lost-reply fixture passed. |
| Installed CLI at `~/bin/zig-ws` | ReleaseFast | `Browser.getVersion` returned Chrome 157.0.8103.38. The Unix app server accepted initialization and returned the matching `thread/loaded/list` reply. |
| Clean `zig-cdp` checkouts | Debug, ReleaseSafe | All 18 library and observer tests, 14 CLI scenario groups, the external consumer, the example, and the headed Chrome check passed in each profile. |

The installed CLI matched the ReleaseFast build byte for byte. Its SHA-256 is
`2bb2854c3c67a28b0915534d9f7e89dd5da4c7218b2afd788c136e871bcf2a67`.
