const std = @import("std");
const ws = @import("ws");
const io = std.testing.io;
const a = std.testing.allocator;

fn peer(server: *std.Io.net.Server, expected_host: []const u8, bad: bool) ![24]u8 {
    const stream = try server.accept(io);
    defer stream.close(io);
    var rb: [2048]u8 = undefined;
    var reader = stream.reader(io, &rb);
    var headers: [2048]u8 = undefined;
    var used: usize = 0;
    while (used < headers.len) {
        headers[used] = try reader.interface.takeByte();
        used += 1;
        if (std.mem.endsWith(u8, headers[0..used], "\r\n\r\n")) break;
    }
    var lines = std.mem.splitSequence(u8, headers[0..used], "\r\n");
    try std.testing.expectEqualStrings("GET /session?q=a%20b HTTP/1.1", lines.first());
    var key: ?[24]u8 = null;
    var host = false;
    while (lines.next()) |line| {
        if (std.mem.cutPrefix(u8, line, "Host: ")) |value| host = std.mem.eql(u8, value, expected_host);
        if (std.mem.cutPrefix(u8, line, "Sec-WebSocket-Key: ")) |value| {
            if (value.len != 24) return error.BadKey;
            key = value[0..24].*;
        }
    }
    try std.testing.expect(host);
    const nonce = key orelse return error.BadKey;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(&nonce);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var encoded: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&encoded, &digest);
    var wb: [512]u8 = undefined;
    var writer = stream.writer(io, &wb);
    try writer.interface.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{if (bad) "invalid" else accept});
    try writer.interface.writeAll("\x81\x02ok");
    try writer.interface.flush();
    return nonce;
}

fn exchange(server: *std.Io.net.Server, endpoint: ws.Endpoint, host: []const u8, bad: bool) ![24]u8 {
    var serving = try io.concurrent(peer, .{ server, host, bad });
    defer _ = serving.cancel(io) catch {};
    if (bad) {
        try std.testing.expectError(error.WebSocketUpgradeFailed, ws.Connection.connect(a, io, endpoint, .{}));
    } else {
        var conn = try ws.Connection.connect(a, io, endpoint, .{});
        defer conn.deinit();
    }
    return serving.await(io);
}

test "public package upgrades TCP and Unix sockets with independent keys" {
    var tcp = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
    defer tcp.deinit(io);
    const host = try a.print("127.0.0.1:{d}", .{tcp.socket.address.getPort()});
    defer a.free(host);
    const url = try a.print("ws://{s}/session?q=a%20b", .{host});
    defer a.free(url);
    const key1 = try exchange(&tcp, .{ .tcp = url }, host, false);
    _ = try exchange(&tcp, .{ .tcp = url }, host, true);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try a.print("{s}/peer.sock", .{dir});
    defer a.free(path);
    var unix = try (try std.Io.net.UnixAddress.init(path)).listen(io, .{});
    defer unix.deinit(io);
    const key2 = try exchange(&unix, .{ .unix = .{ .path = path, .target = "/session?q=a%20b", .host = "fixture.local" } }, "fixture.local", false);
    try std.testing.expect(!std.mem.eql(u8, &key1, &key2));
}
