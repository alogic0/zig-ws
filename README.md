# zig-ws

`zig-ws` is a WebSocket client library for Linux and Zig **0.17.0**. Its
`ws` module sends and receives text and binary messages over `ws://` TCP
connections and Unix domain sockets. A connection can stay open across
requests and receive messages whenever the peer sends them.

## Add the library to your project

From the directory containing your application's `build.zig.zon`, fetch the
0.1.0 package. Commit the updated manifest to pin the revision and package
hash.

```sh
zig fetch --save=zig_ws 'git+https://github.com/alogic0/zig-ws.git#deb93db8db3a93b557f1a77325f7aa6237da9fa7'
```

In `build.zig`, add the import to the module that will use `@import("ws")`.
For an executable, add these lines after creating `exe` with `b.addExecutable`.

```zig
const dep = b.dependency("zig_ws", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ws", dep.module("ws"));
```

## Exchange a message

This `src/main.zig` sends `hello` to an echo server, prints the first message
it receives, and completes the close handshake. Pass your echo server's URL
to the `run` step from `zig init`, for example
`zig build run -- ws://127.0.0.1:9000/echo`.

```zig
const std = @import("std");
const ws = @import("ws");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const url = args.next() orelse return error.MissingWebSocketUrl;

    const allocator = init.gpa;
    const deadline = ws.default_timeout.toDeadline(init.io);
    var conn = try ws.Connection.connect(allocator, init.io, .{ .tcp = url }, .{
        .timeout = deadline,
    });
    defer conn.deinit();

    try conn.send(.text, "hello", deadline);
    const message = try conn.receive(deadline);
    defer message.deinit(allocator);
    switch (message) {
        .text => |bytes| std.debug.print("{s}\n", .{bytes}),
        .binary => |bytes| std.debug.print("Received {d} binary bytes\n", .{bytes.len}),
        .close => |peer| {
            std.debug.print("Peer closed ({?d}) {s}\n", .{ peer.code, peer.reason });
            return;
        },
    }

    const peer = try conn.close(1000, "", deadline);
    defer allocator.free(peer.reason);
}
```

For a Unix socket, pass the following `ws.Endpoint` as the third argument to
`connect`. The filesystem path selects the socket. The HTTP request target
and `Host` header default to `/` and `localhost` and can be set separately.

```zig
const endpoint: ws.Endpoint = .{ .unix = .{
    .path = "run/echo.sock",
    .target = "/echo",
    .host = "echo.local",
} };
```

## Work with an open connection

- **Messages.** Use `send(.text, bytes, timeout)` for UTF-8 and
  `send(.binary, bytes, timeout)` for arbitrary bytes. Call `receive` for
  each incoming message, including unsolicited ones. It reassembles fragments
  and answers pings while reading. Serialize reads and writes on each
  connection.
- **Ownership.** The caller owns the bytes passed to `send`. Each successful
  `receive` returns an owned `ws.Message`. Call `message.deinit(allocator)`
  after handling it, including a peer-initiated `.close`. To close gracefully,
  call `conn.close` and free the returned `reason`. `conn.deinit()` releases
  the socket immediately and is safe after a graceful close or terminal error.
- **Timeouts and size.** The default opening timeout is 30 seconds.
  `send`, `receive`, and `close` each take a `std.Io.Timeout`. The example
  shares a single deadline across the exchange. Pass `ws.default_timeout` on
  each call for a fresh 30-second budget, or use `receive(.none)` to wait
  indefinitely for an incoming message. The default message limit is 64 MiB
  in each direction. Set `.max_message_bytes` in the options passed to
  `connect` to change it. Oversized messages produce
  `error.MessageTooLarge`. A timeout or cancellation during a receive closes
  the connection and discards any partial message.

If your application polls the socket, check `conn.hasBufferedInput()`
before waiting for readability. To measure write progress, call
`conn.sendTracked(kind, bytes, timeout, &written)`. The `written` count
includes all frame bytes the local stream accepted, even on a partial write.

## Match JSON requests and replies

Use `ws.Rpc` when your peer returns JSON replies with an integer or string
`id`. It borrows an open connection and can track several outstanding
requests. When `conn` is connected to Chrome's browser WebSocket, use this
in place of the echo exchange to print the version reply and any events
queued while waiting for it.

```zig
var rpc = ws.Rpc.init(&conn, .{});
defer rpc.deinit();

try rpc.submit("{\"id\":1,\"method\":\"Browser.getVersion\"}", deadline);
const reply = try rpc.wait(.{ .integer = 1 }, deadline);
defer allocator.free(reply);
std.debug.print("{s}\n", .{reply});

while (rpc.takeEvent()) |event| {
    defer allocator.free(event);
    std.debug.print("{s}\n", .{event});
}
```

`wait` returns the entire reply envelope for the requested ID, even when
replies arrive out of order. `takeEvent()` returns the oldest queued
notification or incoming request, or `null` when the queue is empty.
`nextEvent(timeout)` also reads from the connection to wait for an event.
Free each returned byte slice with the connection's allocator. Use the RPC
helper for reads while requests are outstanding.

`ws.Rpc.Limits` defaults to 32 pending requests, 128 queued events, and
4 MiB of queued reply and event bytes. Pass overrides to `Rpc.init`.
`submit` reports `error.PendingLimitReached` before sending a new request.
An incoming message that exceeds the queue limits ends the connection with
`error.QueueLimitReached`.

If `submit` fails after a partial write, it returns `error.DeliveryUnknown`.
`wait` returns the same error if the peer disconnects or the receive deadline
expires before its reply arrives. The peer may already have acted on the
request. The caller decides whether to retry. Failures before any request
bytes were sent retain their original errors.

An independent package exercises both transports and out-of-order replies.
[Consumer example](tests/package/main.zig)

For command-line examples and release checks, see the
[project plan](https://github.com/alogic0/zig-ws/blob/main/PLAN.md#command-line-client).
The library uses the [MIT license](LICENSE).
