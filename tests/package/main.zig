const std = @import("std");
const ws = @import("ws");
const io = std.testing.io;
const a = std.testing.allocator;

fn expectClientFrame(reader: *std.Io.Reader, opcode: u8, bytes: []const u8) !void {
    try std.testing.expectEqual(0x80 | opcode, try reader.takeByte());
    try std.testing.expectEqual(0x80 | @as(u8, @intCast(bytes.len)), try reader.takeByte());
    const mask = (try reader.takeArray(4)).*;
    for (bytes, 0..) |byte, i|
        try std.testing.expectEqual(byte, try reader.takeByte() ^ mask[i % 4]);
}

fn upgrade(reader: *std.Io.Reader, writer: *std.Io.Writer, expected_host: []const u8, bad: bool, first_frame: []const u8) ![24]u8 {
    var headers: [2048]u8 = undefined;
    var used: usize = 0;
    while (used < headers.len) {
        headers[used] = try reader.takeByte();
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
    try writer.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{if (bad) "invalid" else accept});
    try writer.writeAll(first_frame);
    try writer.flush();
    return nonce;
}

fn peer(server: *std.Io.net.Server, expected_host: []const u8, bad: bool) ![24]u8 {
    const stream = try server.accept(io);
    defer stream.close(io);
    var rb: [2048]u8 = undefined;
    var reader = stream.reader(io, &rb);
    var wb: [512]u8 = undefined;
    var writer = stream.writer(io, &wb);
    const nonce = try upgrade(&reader.interface, &writer.interface, expected_host, bad, "\x01\x01\xe2\x89\x01?\x80\x02\x82\xac");
    if (!bad) {
        try expectClientFrame(&reader.interface, 10, "?");
        try expectClientFrame(&reader.interface, 2, "\x00\xff\x80");
        try writer.interface.writeAll("\x82\x03\x00\xff\x80\x88\x05\x03\xe8bye");
        try writer.interface.flush();
        try expectClientFrame(&reader.interface, 8, "\x03\xe8bye");
    }
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
        const text = try conn.receive(ws.default_timeout);
        defer text.deinit(a);
        try std.testing.expectEqualStrings("€", text.text);
        try conn.send(.binary, "\x00\xff\x80", ws.default_timeout);
        const binary = try conn.receive(ws.default_timeout);
        defer binary.deinit(a);
        try std.testing.expectEqualSlices(u8, "\x00\xff\x80", binary.binary);
        const close = try conn.receive(ws.default_timeout);
        defer close.deinit(a);
        try std.testing.expectEqual(@as(?u16, 1000), close.close.code);
        try std.testing.expectEqualStrings("bye", close.close.reason);
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
const initialize = "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"}}}";
const initialized = "{\"method\":\"initialized\"}";
const start = "{\"id\":\"turn\",\"method\":\"turn/start\",\"params\":{\"threadId\":\"test\",\"input\":[{\"type\":\"text\",\"text\":\"fixture\"}]}}";
const notice = "{\"method\":\"turn/started\",\"params\":{\"turn\":{\"id\":\"fixture-turn\"}}}";
const ack = "{\"id\":\"turn\",\"result\":{\"turn\":{\"id\":\"fixture-turn\"}}}";
const lookup = "{\"id\":3,\"method\":\"thread/read\",\"params\":{}}";
const lookup_reply = "{\"id\":3,\"result\":{}}";
const server_request = "{\"id\":3,\"method\":\"fixture/request\",\"params\":{}}";
const Scenario = enum { accepted, lost, reverse, overflow };

fn writeJson(w: *std.Io.Writer, json: []const u8) !void {
    try std.testing.expect(json.len < 126);
    try w.writeAll(&.{ 0x81, @intCast(json.len) });
    try w.writeAll(json);
    try w.flush();
}

fn codexPeer(server: *std.Io.net.Server, scenario: Scenario) !usize {
    const stream = try server.accept(io);
    defer stream.close(io);
    var rb: [1024]u8 = undefined;
    var wb: [1024]u8 = undefined;
    var reader = stream.reader(io, &rb);
    var writer = stream.writer(io, &wb);
    const r = &reader.interface;
    const w = &writer.interface;
    _ = try upgrade(r, w, "app.local", false, "");
    try expectClientFrame(r, 1, initialize);
    try writeJson(w, "{\"id\":1,\"result\":{}}");
    try expectClientFrame(r, 1, initialized);
    var turns: usize = 0;
    try expectClientFrame(r, 1, start);
    turns += 1;
    if (scenario == .lost) return turns;
    try writeJson(w, notice);
    if (scenario == .reverse or scenario == .overflow) {
        try expectClientFrame(r, 1, lookup);
        try writeJson(w, server_request);
        if (scenario == .overflow) return turns;
        try writeJson(w, lookup_reply);
    }
    try writeJson(w, ack);
    // A replay on this connection would appear where the close frame is expected.
    try expectClientFrame(r, 8, "\x03\xe8");
    try w.writeAll("\x88\x02\x03\xe8");
    try w.flush();
    return turns;
}

test "Codex handoff preserves notifications, reverse replies, incoming requests and delivery uncertainty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(directory);
    const path = try a.print("{s}/codex.sock", .{directory});
    defer a.free(path);
    const endpoint: ws.Endpoint = .{ .unix = .{ .path = path, .host = "app.local", .target = "/session?q=a%20b" } };
    try std.testing.expectError(error.FileNotFound, ws.Connection.connect(a, io, endpoint, .{}));
    var server = try (try std.Io.net.UnixAddress.init(path)).listen(io, .{});
    defer server.deinit(io);
    for ([_]Scenario{ .accepted, .lost, .reverse, .overflow }) |scenario| {
        var fixture = try io.concurrent(codexPeer, .{ &server, scenario });
        defer _ = fixture.cancel(io) catch {};
        var conn = try ws.Connection.connect(a, io, endpoint, .{});
        defer conn.deinit();
        var rpc = ws.Rpc.init(&conn, .{ .pending = 2, .events = if (scenario == .overflow) 1 else 4 });
        defer rpc.deinit();
        const deadline = ws.default_timeout.toDeadline(io);
        try rpc.submit(initialize, deadline);
        const ready = try rpc.wait(.{ .integer = 1 }, deadline);
        a.free(ready);
        try conn.send(.text, initialized, deadline);
        try rpc.submit(start, deadline);
        if (scenario == .lost) {
            try std.testing.expectError(error.DeliveryUnknown, rpc.wait(.{ .string = "turn" }, deadline));
        } else {
            if (scenario == .reverse or scenario == .overflow) {
                try rpc.submit(lookup, deadline);
                try std.testing.expectError(error.PendingLimitReached, rpc.submit(lookup, deadline));
            }
            if (scenario == .overflow) {
                try std.testing.expectError(error.QueueLimitReached, rpc.wait(.{ .string = "turn" }, deadline));
                try std.testing.expectError(error.DeliveryUnknown, rpc.wait(.{ .integer = 3 }, deadline));
            } else {
                const reply = try rpc.wait(.{ .string = "turn" }, deadline);
                defer a.free(reply);
                try std.testing.expectEqualStrings(ack, reply);
            }
            const event = rpc.takeEvent() orelse return error.MissingEvent;
            defer a.free(event);
            try std.testing.expectEqualStrings(notice, event);
            if (scenario == .reverse) {
                const reply = try rpc.wait(.{ .integer = 3 }, deadline);
                defer a.free(reply);
                try std.testing.expectEqualStrings(lookup_reply, reply);
                const incoming = try rpc.nextEvent(deadline);
                defer a.free(incoming);
                try std.testing.expectEqualStrings(server_request, incoming);
            }
            if (scenario != .overflow) {
                const closed = try conn.close(1000, "", deadline);
                a.free(closed.reason);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), try fixture.await(io));
    }
}
