//! A single-owner client connection. Serialize all operations on a connection.
const std = @import("std");
const Connection = @This();
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

pub const Endpoint = union(enum) {
    tcp: []const u8,
    unix: struct { path: []const u8, target: []const u8 = "/", host: []const u8 = "localhost" },
};
pub const default_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } };
pub const Options = struct {
    timeout: Io.Timeout = default_timeout,
    max_message_bytes: usize = 64 * 1024 * 1024,
};

io: Io,
allocator: Allocator,
stream: net.Stream,
max_message_bytes: usize,
closed: bool = false,
sent_close: bool = false,
input: [8192]u8 = undefined,
start: usize = 0,
end: usize = 0,

pub fn connect(a: Allocator, io: Io, endpoint: Endpoint, options: Options) !Connection {
    const deadline = options.timeout.toDeadline(io);
    try checkDeadline(io, deadline);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temp = scratch.allocator();
    var target: []const u8 = undefined;
    var host: []const u8 = undefined;
    const address: Address = switch (endpoint) {
        .unix => |u| blk: {
            target = u.target;
            host = u.host;
            if (u.path.len == 0 or std.mem.indexOfScalar(u8, u.path, 0) != null) return error.InvalidEndpoint;
            break :blk .{ .unix = try net.UnixAddress.init(u.path) };
        },
        .tcp => |url| blk: {
            const uri = std.Uri.parse(url) catch return error.InvalidEndpoint;
            if (!std.ascii.eqlIgnoreCase(uri.scheme, "ws") or uri.user != null or uri.password != null or uri.fragment != null)
                return error.InvalidEndpoint;
            const name = (uri.host orelse return error.InvalidEndpoint).percent_encoded;
            const port = uri.port orelse 80;
            host = if (uri.port != null) try temp.print("{s}:{d}", .{ name, port }) else name;
            const path = if (uri.path.isEmpty()) "/" else uri.path.percent_encoded;
            target = if (uri.query) |q| try temp.print("{s}?{s}", .{ path, q.percent_encoded }) else path;
            const literal = if (name[0] == '[' and name[name.len - 1] == ']') name[1 .. name.len - 1] else name;
            if (net.IpAddress.parse(literal, port)) |ip| break :blk .{ .ip = ip } else |_| {}
            break :blk .{ .dns = .{ .name = net.HostName.init(name) catch return error.InvalidEndpoint, .port = port } };
        },
    };
    try validateTarget(target, host);
    const stream = try dial(io, address, deadline);
    var conn: Connection = .{ .io = io, .allocator = a, .stream = stream, .max_message_bytes = options.max_message_bytes };
    errdefer conn.deinit();
    if (endpoint == .tcp) {
        const enabled: i32 = 1;
        try std.posix.setsockopt(stream.socket.handle, std.os.linux.IPPROTO.TCP, std.os.linux.TCP.NODELAY, std.mem.asBytes(&enabled));
    }
    try conn.upgrade(temp, target, host, deadline);
    return conn;
}

const Address = union(enum) {
    ip: net.IpAddress,
    dns: struct { name: net.HostName, port: u16 },
    unix: net.UnixAddress,

    fn open(address: Address, io: Io) anyerror!net.Stream {
        return switch (address) {
            .ip => |ip| ip.connect(io, .{ .mode = .stream }),
            .dns => |dns| dns.name.connect(io, dns.port, .{ .mode = .stream }),
            .unix => |unix| unix.connect(io),
        };
    }
};

// Include DNS and the Unix connect syscall in the opening deadline.
fn dial(io: Io, address: Address, deadline: Io.Timeout) !net.Stream {
    if (deadline == .none) return address.open(io);
    const Event = union(enum) { stream: anyerror!net.Stream, timer: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select = Io.Select(Event).init(io, &events);
    defer while (select.cancel()) |event| switch (event) {
        .stream => |result| if (result) |stream| stream.close(io) else |_| {},
        .timer => {},
    };
    try select.concurrent(.stream, Address.open, .{ address, io });
    try select.concurrent(.timer, Io.Timeout.sleep, .{ deadline, io });
    return switch (try select.await()) {
        .stream => |result| result,
        .timer => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
    };
}

fn validateTarget(target: []const u8, host: []const u8) !void {
    if (host.len == 0 or target.len == 0 or target[0] != '/' or std.mem.indexOfScalar(u8, target, '#') != null) return error.InvalidEndpoint;
    for ([_][]const u8{ target, host }) |field| {
        for (field) |c| if (c <= ' ' or c >= 0x7f) return error.InvalidEndpoint;
    }
    if (std.mem.indexOfAny(u8, host, "/?#@") != null) return error.InvalidEndpoint;
}

fn acceptKey(key: []const u8) [28]u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(key);
    hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    hash.final(&digest);
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &digest);
    return result;
}

fn upgrade(self: *Connection, a: Allocator, target: []const u8, host: []const u8, deadline: Io.Timeout) !void {
    var nonce: [16]u8 = undefined;
    try self.io.randomSecure(&nonce);
    var encoded: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&encoded, &nonce);
    const request = try a.print("GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ target, host, key });
    var written: usize = 0;
    try self.writeAll(request, deadline, &written);
    while (self.end < self.input.len) {
        const previous = self.end;
        self.end += try self.readSome(self.input[self.end..], deadline);
        if (std.mem.indexOfPos(u8, self.input[0..self.end], previous -| 3, "\r\n\r\n")) |end| {
            try validateResponse(self.input[0..end], &acceptKey(key));
            self.start = end + 4;
            return;
        }
    }
    return error.WebSocketUpgradeFailed;
}

fn hasToken(value: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.tokenizeScalar(u8, value, ',');
    while (tokens.next()) |token| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, token, " \t"), wanted)) return true;
    return false;
}

fn validateResponse(headers: []const u8, expected: []const u8) !void {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    var status = std.mem.tokenizeScalar(u8, lines.first(), ' ');
    if (!std.mem.eql(u8, status.next() orelse "", "HTTP/1.1") or !std.mem.eql(u8, status.next() orelse "", "101")) return error.WebSocketUpgradeFailed;
    var upgrade_token = false;
    var connection_token = false;
    var accepted = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.WebSocketUpgradeFailed;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Upgrade")) upgrade_token = upgrade_token or hasToken(value, "websocket");
        if (std.ascii.eqlIgnoreCase(name, "Connection")) connection_token = connection_token or hasToken(value, "upgrade");
        if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) {
            if (accepted or !std.mem.eql(u8, value, expected)) return error.WebSocketUpgradeFailed;
            accepted = true;
        }
        if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Extensions") or std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Protocol"))
            return error.WebSocketUpgradeFailed;
    }
    if (!upgrade_token or !connection_token or !accepted) return error.WebSocketUpgradeFailed;
}

fn checkDeadline(io: Io, deadline: Io.Timeout) !void {
    if (deadline == .deadline and deadline.deadline.durationFromNow(io).raw.nanoseconds <= 0) return error.Timeout;
}

fn operate(self: *Connection, operation: Io.Operation, deadline: Io.Timeout) !Io.Operation.Result {
    while (true) {
        try checkDeadline(self.io, deadline);
        return self.io.operateTimeout(operation, deadline) catch |err| {
            if (err == error.Timeout and deadline == .deadline) continue;
            return err;
        };
    }
}

fn readSome(self: *Connection, bytes: []u8, deadline: Io.Timeout) !usize {
    var buffers = [_][]u8{bytes};
    const result = try self.operate(.{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = &buffers } }, deadline);
    const n = (try result.net_read).data_len;
    if (n == 0) return error.ConnectionClosed;
    return n;
}

fn readExact(self: *Connection, bytes: []u8, deadline: Io.Timeout) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkDeadline(self.io, deadline);
        if (self.start == self.end) {
            if (bytes.len - offset >= self.input.len) {
                offset += try self.readSome(bytes[offset..], deadline);
                continue;
            }
            self.start = 0;
            self.end = try self.readSome(&self.input, deadline);
        }
        const n = @min(bytes.len - offset, self.end - self.start);
        @memcpy(bytes[offset..][0..n], self.input[self.start..][0..n]);
        self.start += n;
        offset += n;
    }
}

fn writeAll(self: *Connection, bytes: []const u8, deadline: Io.Timeout, written: *usize) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = offset + @min(bytes.len - offset, 4096);
        const result = try self.operate(.{ .net_write = .{ .socket_handle = self.stream.socket.handle, .data = &.{bytes[offset..end]} } }, deadline);
        const n = try result.net_write;
        if (n == 0) return error.ConnectionClosed;
        offset += n;
        written.* += n;
    }
}

pub fn hasBufferedInput(self: *const Connection) bool {
    return self.start < self.end;
}

/// Release the socket immediately. Safe after a peer close or any terminal error.
pub fn deinit(self: *Connection) void {
    if (!self.closed) self.stream.close(self.io);
    self.closed = true;
}

test "strict upgrade tokens and per-key accept" {
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
    const good = "HTTP/1.1 101 Switching Protocols\r\nupgrade: WebSocket\r\nConnection: keep-alive, UpGrAdE\r\nSec-WebSocket-Accept: ok";
    try validateResponse(good, "ok");
    try std.testing.expectError(error.WebSocketUpgradeFailed, validateResponse(good, "bad"));
    try std.testing.expectError(error.WebSocketUpgradeFailed, validateResponse(good ++ "\r\nSec-WebSocket-Accept: ok", "ok"));
    try std.testing.expectError(error.WebSocketUpgradeFailed, validateResponse("HTTP/1.1 101\r\nSec-WebSocket-Accept: ok", "ok"));
    try std.testing.expectError(error.InvalidEndpoint, validateTarget("/ok\r\nBad: header", "localhost"));
}
