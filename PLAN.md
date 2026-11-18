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

## Qualification results

The package revision is `deb93db8db3a93b557f1a77325f7aa6237da9fa7`.
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
