# Share the WebSocket transport with zig-cdp

Make `zig-ws` an independent Zig package that exports the `ws` module. The
`zig-ws` CLI and `zig-cdp` will both import that module. Target Linux and
Zig 0.17.0 for the first release.

## 1. Extract the transport

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
  an upgrade preserves a first frame received with the headers, a ping between
  text fragments gets a pong, and binary bytes round-trip intact. Check the
  CLI's JSON-lines output with `jqz`.
- [x] Run the Codex handoff fixture. Observe both the notification and matching
  turn ID. When the peer records `turn/start` and disconnects before replying,
  require `delivery unknown` and exactly one recorded request. Qualify the
  installed CLI and run the read-only Chrome and app-server checks in the
  [first-release guide](README.md#first-release).

## 3. Switch zig-cdp to the package

- [ ] Make adoption a separate change in `../zig-cdp`. For the first local
  build, add `.zig_ws = .{ .path = "../zig-ws" }` to its manifest dependencies.
  Import the dependency's `ws` module into both the public `cdp` module and
  the native test module that compiles `cdp.zig` directly.
  [Consumer build](../zig-cdp/build.zig)
- [ ] Have `CdpClient.connectWs` apply Chrome's loopback and port checks
  before delegating the upgrade to `ws`. Replace the framing inside
  `WsSession` with calls to `ws`. Keep discovery, request IDs, `sessionId`
  routing, and queued CDP events in `zig-cdp`. Verify that existing callers
  can still use `call`, `callSession`, and `takeEvent` with their documented
  ownership rules. [Public API](../zig-cdp/docs/library.md)
- [ ] Once the tested `zig-ws` revision is available from its Git remote,
  replace the local path with the full Git commit and Zig package hash.
  Follow the existing `zig-process` dependency. From a clean `zig-cdp`
  checkout, run the library, CLI, and external package checks in Debug and
  ReleaseSafe using the committed pin. [Consumer manifest](../zig-cdp/build.zig.zon)

For subsequent changes across both checkouts, run
`zig build test --fork=../zig-ws` from `../zig-cdp` to test local edits.
Run `zig build test` there to test the committed dependency.
