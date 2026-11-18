//! Optional, serialized JSON request/reply matching over a borrowed connection.
const std = @import("std");
const Connection = @import("Connection.zig");
const Rpc = @This();
const A = std.mem.Allocator;
const Timeout = std.Io.Timeout;

pub const Limits = struct {
    pending: usize = 32,
    events: usize = 128,
    queued_bytes: usize = 4 * 1024 * 1024,
};
pub const Id = union(enum) {
    integer: i64,
    string: []const u8,

    fn parse(value: std.json.Value) !Id {
        return switch (value) {
            .integer => |n| .{ .integer = n },
            .string => |s| .{ .string = s },
            else => error.InvalidEnvelope,
        };
    }
    fn eql(left: Id, right: Id) bool {
        return switch (left) {
            .integer => |n| right == .integer and n == right.integer,
            .string => |s| right == .string and std.mem.eql(u8, s, right.string),
        };
    }
    fn copy(id: Id, a: A) !Id {
        return if (id == .string) .{ .string = try a.dupe(u8, id.string) } else id;
    }
    fn deinit(id: Id, a: A) void {
        if (id == .string) a.free(id.string);
    }
};
const Pending = struct { id: Id, reply: ?[]u8 = null };

connection: *Connection,
allocator: A,
limits: Limits,
pending: std.ArrayList(Pending) = .empty,
events: std.ArrayList([]u8) = .empty,
queued_bytes: usize = 0,
ended: bool = false,

pub fn init(connection: *Connection, limits: Limits) Rpc {
    return .{ .connection = connection, .allocator = connection.allocator, .limits = limits };
}

pub fn deinit(self: *Rpc) void {
    for (self.pending.items) |p| {
        p.id.deinit(self.allocator);
        if (p.reply) |raw| self.allocator.free(raw);
    }
    self.pending.deinit(self.allocator);
    for (self.events.items) |raw| self.allocator.free(raw);
    self.events.deinit(self.allocator);
}

fn indexOf(self: *Rpc, id: Id) ?usize {
    for (self.pending.items, 0..) |p, i| if (p.id.eql(id)) return i;
    return null;
}

fn envelope(self: *Rpc, raw: []const u8) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEnvelope;
    return parsed;
}

/// Register and send exactly once. The caller keeps ownership of request.
/// A partial write yields DeliveryUnknown. Validation and pre-write failures
/// return their original error.
pub fn submit(self: *Rpc, request: []const u8, timeout: Timeout) !void {
    if (self.ended or self.connection.closed) return error.ConnectionClosed;
    if (request.len > self.connection.max_message_bytes) return error.MessageTooLarge;
    if (self.pending.items.len >= self.limits.pending) return error.PendingLimitReached;
    const deadline = timeout.toDeadline(self.connection.io);
    const parsed = try self.envelope(request);
    defer parsed.deinit();
    const obj = parsed.value.object;
    const method = obj.get("method") orelse return error.InvalidEnvelope;
    if (method != .string) return error.InvalidEnvelope;
    const id = try Id.parse(obj.get("id") orelse return error.InvalidEnvelope);
    if (self.indexOf(id) != null) return error.DuplicateId;
    const owned = try id.copy(self.allocator);
    errdefer owned.deinit(self.allocator);
    try self.pending.append(self.allocator, .{ .id = owned });
    errdefer _ = self.pending.pop();
    var written: usize = 0;
    self.connection.sendTracked(.text, request, deadline, &written) catch |err| {
        if (written != 0) return error.DeliveryUnknown;
        return err;
    };
}

/// Return a queued notification or incoming request. Caller frees the bytes.
pub fn takeEvent(self: *Rpc) ?[]u8 {
    if (self.events.items.len == 0) return null;
    const event = self.events.orderedRemove(0);
    self.queued_bytes -= event.len;
    return event;
}

/// Wait for a notification or incoming request, retaining replies for wait().
pub fn nextEvent(self: *Rpc, timeout: Timeout) ![]u8 {
    const deadline = timeout.toDeadline(self.connection.io);
    while (true) {
        if (self.takeEvent()) |event| return event;
        try self.pump(deadline);
    }
}

/// Wait for a submitted ID. Caller frees the entire JSON reply envelope.
/// A disconnected peer leaves outstanding requests with unknown delivery.
pub fn wait(self: *Rpc, id: Id, timeout: Timeout) ![]u8 {
    const i = self.indexOf(id) orelse return error.UnknownId;
    const deadline = timeout.toDeadline(self.connection.io);
    while (self.pending.items[i].reply == null) {
        self.pump(deadline) catch |err| {
            if (err != error.ConnectionLost) return err;
            const entry = self.pending.swapRemove(i);
            entry.id.deinit(self.allocator);
            return error.DeliveryUnknown;
        };
    }
    const entry = self.pending.swapRemove(i);
    entry.id.deinit(self.allocator);
    const reply = entry.reply.?;
    self.queued_bytes -= reply.len;
    return reply;
}

fn pump(self: *Rpc, deadline: Timeout) !void {
    if (self.ended) return error.ConnectionLost;
    errdefer {
        self.ended = true;
        self.connection.deinit();
    }
    const msg = self.connection.receive(deadline) catch |err| switch (err) {
        error.ConnectionClosed, error.ConnectionResetByPeer, error.SocketUnconnected, error.ConnectionTimedOut, error.Timeout => return error.ConnectionLost,
        else => return err,
    };
    errdefer msg.deinit(self.allocator);
    if (msg == .close) return error.ConnectionLost;
    if (msg != .text) return error.InvalidEnvelope;
    const raw = msg.text;
    const parsed = try self.envelope(raw);
    defer parsed.deinit();
    const obj = parsed.value.object;
    if (raw.len > self.limits.queued_bytes - self.queued_bytes) return error.QueueLimitReached;
    if (obj.get("method")) |method| {
        if (method != .string) return error.InvalidEnvelope;
        if (self.events.items.len >= self.limits.events) return error.QueueLimitReached;
        try self.events.append(self.allocator, raw);
    } else {
        const id = try Id.parse(obj.get("id") orelse return error.InvalidEnvelope);
        if (obj.contains("result") == obj.contains("error")) return error.InvalidEnvelope;
        const i = self.indexOf(id) orelse return error.UnexpectedReply;
        if (self.pending.items[i].reply != null) return error.UnexpectedReply;
        self.pending.items[i].reply = raw;
    }
    self.queued_bytes += raw.len;
}
