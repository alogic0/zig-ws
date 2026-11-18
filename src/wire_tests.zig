const std = @import("std");
const Connection = @import("Connection.zig");
const Io = std.Io;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const Peer = struct {
    input: []const u8,
    output: std.ArrayList(u8) = .empty,
    read: usize = 0,
    closed: usize = 0,
    ms: i64 = 0,
    early_timeout: bool = false,
    cancel_at: ?usize = null,

    fn connection(p: *Peer, vtable: *Io.VTable) Connection {
        vtable.* = std.testing.io.vtable.*;
        vtable.operate = operate;
        vtable.batchAwaitConcurrent = awaitBatch;
        vtable.now = now;
        vtable.netClose = close;
        vtable.randomSecure = entropy;
        return .{ .allocator = std.testing.allocator, .io = .{ .userdata = p, .vtable = vtable }, .stream = .{ .socket = .{ .handle = -1, .address = .{ .ip4 = .loopback(0) } } }, .max_message_bytes = 128 * 1024 };
    }
    fn cast(ctx: ?*anyopaque) *Peer {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn entropy(_: ?*anyopaque, dest: []u8) Io.RandomSecureError!void {
        for (dest, 0..) |*byte, i| byte.* = @intCast(i + 1);
    }
    fn close(ctx: ?*anyopaque, _: []const Io.net.Socket) void {
        cast(ctx).closed += 1;
    }
    fn now(ctx: ?*anyopaque, _: Io.Clock) Io.Timestamp {
        return .{ .nanoseconds = @as(i96, cast(ctx).ms) * std.time.ns_per_ms };
    }
    fn operate(ctx: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const p = cast(ctx);
        p.ms += 1;
        switch (op) {
            .net_read => |r| {
                if (p.cancel_at == p.read) return error.Canceled;
                const n = @min(1, r.data[0].len, p.input.len - p.read);
                @memcpy(r.data[0][0..n], p.input[p.read..][0..n]);
                p.read += n;
                return .{ .net_read = .{ .data_len = n } };
            },
            .net_write => |w| {
                const bytes = w.data[0][0..@min(w.data[0].len, 113)];
                p.output.appendSlice(std.testing.allocator, bytes) catch return .{ .net_write = error.SystemResources };
                return .{ .net_write = bytes.len };
            },
            else => unreachable,
        }
    }
    fn awaitBatch(ctx: ?*anyopaque, batch: *Io.Batch, _: Io.Timeout) Io.Batch.AwaitConcurrentError!void {
        if (cast(ctx).early_timeout) {
            cast(ctx).early_timeout = false;
            return error.Timeout;
        }
        const index = batch.submitted.head;
        const slot = &batch.storage[index.toIndex()];
        const result = try operate(ctx, slot.submission.operation);
        slot.* = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
        batch.submitted = .{ .head = .none, .tail = .none };
        batch.completed = .{ .head = index, .tail = index };
    }
};

test "fragment limits, reserved frames, UTF-8 and control payloads fail closed" {
    const Case = struct { input: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .input = "\x01\x02ab\x80\x02cd", .err = error.MessageTooLarge },
        .{ .input = "\x81\x80", .err = error.InvalidWebSocketFrame },
        .{ .input = "\x80\x00", .err = error.InvalidWebSocketFrame },
        .{ .input = "\x09\x00", .err = error.InvalidWebSocketFrame },
        .{ .input = "\x82\x7e\x00\x02", .err = error.InvalidWebSocketFrame },
        .{ .input = "\xc1\x00", .err = error.InvalidWebSocketFrame },
        .{ .input = "\x81\x01\xff", .err = error.InvalidUtf8 },
        .{ .input = "\x88\x02\x03\xed", .err = error.InvalidWebSocketFrame },
        .{ .input = "\x88\x03\x03\xe8\xfe", .err = error.InvalidUtf8 },
    };
    for (cases) |item| {
        var peer: Peer = .{ .input = item.input };
        defer peer.output.deinit(std.testing.allocator);
        var table: Io.VTable = undefined;
        var conn = peer.connection(&table);
        conn.max_message_bytes = 3;
        try expectError(item.err, conn.receive(.none));
        try expect(peer.output.items[0] == 0x88);
        conn.deinit();
        try expect(peer.closed == 1);
    }
}

test "a deadline spans slow fragments and early polls, cancellation seals a partial read" {
    var peer: Peer = .{ .input = "\x01\x02ab\x80\x02cd", .early_timeout = true };
    defer peer.output.deinit(std.testing.allocator);
    var table: Io.VTable = undefined;
    var conn = peer.connection(&table);
    const timeout: Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(6) } };
    try expectError(error.Timeout, conn.receive(timeout));
    try expect(peer.ms == 6 and peer.read == 6 and peer.closed == 1);
    peer.read = 0;
    peer.cancel_at = 3;
    conn = peer.connection(&table);
    try expectError(error.Canceled, conn.receive(.none));
    try expect(peer.read == 3 and peer.closed == 2);
}

test "client length encoding, mask offsets and bounded writes survive partial I/O" {
    const a = std.testing.allocator;
    for ([_]usize{ 0, 125, 126, 65535, 65536 }) |len| {
        var peer: Peer = .{ .input = "" };
        defer peer.output.deinit(a);
        var table: Io.VTable = undefined;
        var conn = peer.connection(&table);
        defer conn.deinit();
        const data = try a.alloc(u8, len);
        defer a.free(data);
        for (data, 0..) |*byte, i| byte.* = @truncate(i);
        try conn.send(.binary, data, .none);
        const wire = peer.output.items;
        try expect(wire[0] == 0x82);
        const offset: usize = if (len < 126) 2 else if (len < 65536) 4 else 10;
        const size: u8 = if (len < 126) @intCast(len) else if (len < 65536) 126 else 127;
        try expect(wire[1] == 0x80 | size);
        if (offset == 4) try expect(std.mem.readInt(u16, wire[2..4], .big) == len);
        if (offset == 10) try expect(std.mem.readInt(u64, wire[2..10], .big) == len);
        const mask = wire[offset..][0..4];
        for (data, wire[offset + 4 ..], 0..) |byte, masked, i| try expect((byte ^ mask[i % 4]) == masked);
    }
}
