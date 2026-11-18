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
pub const Kind = enum(u8) { text = 1, binary = 2 };
pub const Close = struct { code: ?u16, reason: []u8 };
pub const Message = union(enum) {
    text: []u8,
    binary: []u8,
    close: Close,

    /// Release the owned payload with the connection's receiving allocator.
    pub fn deinit(message: Message, allocator: Allocator) void {
        switch (message) {
            .text, .binary => |bytes| allocator.free(bytes),
            .close => |value| allocator.free(value.reason),
        }
    }
};

pub fn send(self: *Connection, kind: Kind, bytes: []const u8, timeout: Io.Timeout) !void {
    var written: usize = 0;
    try self.sendTracked(kind, bytes, timeout, &written);
}

/// On failure, written counts frame bytes already accepted by the stream.
pub fn sendTracked(self: *Connection, kind: Kind, bytes: []const u8, timeout: Io.Timeout, written: *usize) !void {
    written.* = 0;
    if (self.closed or self.sent_close) return error.ConnectionClosed;
    if (bytes.len > self.max_message_bytes) return error.MessageTooLarge;
    if (kind == .text and !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    errdefer self.deinit();
    try self.writeFrame(@backingInt(kind), bytes, timeout.toDeadline(self.io), written);
}

fn writeFrame(self: *Connection, opcode: u8, bytes: []const u8, deadline: Io.Timeout, written: *usize) !void {
    var buf: [4096]u8 = undefined;
    buf[0] = 0x80 | opcode;
    var prefix: usize = 2;
    if (bytes.len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(bytes.len));
    } else if (bytes.len <= 0xffff) {
        buf[1] = 0xfe;
        std.mem.writeInt(u16, buf[2..4], @intCast(bytes.len), .big);
        prefix += 2;
    } else {
        buf[1] = 0xff;
        std.mem.writeInt(u64, buf[2..10], bytes.len, .big);
        prefix += 8;
    }
    var mask: [4]u8 = undefined;
    try self.io.randomSecure(&mask);
    @memcpy(buf[prefix..][0..4], &mask);
    prefix += 4;
    var offset: usize = 0;
    while (true) {
        const n = @min(bytes.len - offset, buf.len - prefix);
        for (buf[prefix..][0..n], bytes[offset..][0..n], 0..) |*dest, byte, i|
            dest.* = byte ^ mask[(offset + i) % 4];
        try self.writeAll(buf[0 .. prefix + n], deadline, written);
        offset += n;
        if (offset == bytes.len) return;
        prefix = 0;
    }
}

fn control(self: *Connection, opcode: u8, bytes: []const u8, deadline: Io.Timeout) !void {
    var written: usize = 0;
    try self.writeFrame(opcode, bytes, deadline, &written);
}

const Header = struct { final: bool, opcode: u8, len: usize };

fn readHeader(self: *Connection, deadline: Io.Timeout) !Header {
    var head: [2]u8 = undefined;
    try self.readExact(&head, deadline);
    if (head[0] & 0x70 != 0 or head[1] & 0x80 != 0) return error.InvalidWebSocketFrame;
    const op = head[0] & 0xf;
    const final = head[0] & 0x80 != 0;
    var len: usize = head[1];
    if (op >= 8 and (!final or len > 125)) return error.InvalidWebSocketFrame;
    switch (len) {
        126 => {
            var size: [2]u8 = undefined;
            try self.readExact(&size, deadline);
            len = std.mem.readInt(u16, &size, .big);
            if (len < 126) return error.InvalidWebSocketFrame;
        },
        127 => {
            var size: [8]u8 = undefined;
            try self.readExact(&size, deadline);
            const wide = std.mem.readInt(u64, &size, .big);
            if (size[0] & 0x80 != 0 or wide < 65536) return error.InvalidWebSocketFrame;
            len = std.math.cast(usize, wide) orelse return error.MessageTooLarge;
        },
        else => {},
    }
    return .{ .final = final, .opcode = op, .len = len };
}

fn validCode(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1014, 3000...4999 => true,
        else => false,
    };
}

fn parseClose(payload: []const u8) !?u16 {
    if (payload.len == 0) return null;
    if (payload.len < 2) return error.InvalidWebSocketFrame;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    if (!validCode(code)) return error.InvalidWebSocketFrame;
    if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidUtf8;
    return code;
}

/// Return an owned complete message, including the peer's closing code and reason.
/// A partial message is discarded on timeout, cancellation or protocol failure.
pub fn receive(self: *Connection, timeout: Io.Timeout) !Message {
    if (self.closed) return error.ConnectionClosed;
    const deadline = timeout.toDeadline(self.io);
    return self.readMessage(deadline) catch |err| {
        const code: ?u16 = switch (err) {
            error.InvalidWebSocketFrame => 1002,
            error.InvalidUtf8 => 1007,
            error.MessageTooLarge => 1009,
            else => null,
        };
        if (code) |value| if (!self.sent_close) {
            var payload: [2]u8 = undefined;
            std.mem.writeInt(u16, &payload, value, .big);
            self.control(8, &payload, deadline) catch {};
        };
        self.deinit();
        return err;
    };
}

fn readMessage(self: *Connection, deadline: Io.Timeout) !Message {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(self.allocator);
    var kind: ?Kind = null;
    while (true) {
        const header = try self.readHeader(deadline);
        switch (header.opcode) {
            0 => if (kind == null) return error.InvalidWebSocketFrame,
            1, 2 => {
                if (kind != null) return error.InvalidWebSocketFrame;
                kind = @fromBackingInt(@intCast(header.opcode));
            },
            8, 9, 10 => {
                var storage: [125]u8 = undefined;
                const payload = storage[0..header.len];
                try self.readExact(payload, deadline);
                switch (header.opcode) {
                    8 => {
                        const code = try parseClose(payload);
                        if (!self.sent_close) try self.control(8, payload, deadline);
                        self.deinit();
                        return .{ .close = .{ .code = code, .reason = try self.allocator.dupe(u8, if (code != null) payload[2..] else "") } };
                    },
                    9 => try self.control(10, payload, deadline),
                    else => {},
                }
                continue;
            },
            else => return error.InvalidWebSocketFrame,
        }
        if (header.len > self.max_message_bytes - bytes.items.len) return error.MessageTooLarge;
        const old = bytes.items.len;
        try bytes.resize(self.allocator, old + header.len);
        try self.readExact(bytes.items[old..], deadline);
        if (!header.final) continue;
        if (kind.? == .text and !std.unicode.utf8ValidateSlice(bytes.items)) return error.InvalidUtf8;
        const result = try bytes.toOwnedSlice(self.allocator);
        return if (kind.? == .text) .{ .text = result } else .{ .binary = result };
    }
}

/// Send a close frame and wait for the peer's close under one deadline.
/// The caller owns the returned reason and frees it with the receiving allocator.
pub fn close(self: *Connection, code: ?u16, reason: []const u8, timeout: Io.Timeout) !Close {
    if (self.closed or self.sent_close) return error.ConnectionClosed;
    if (reason.len > 123 or (code == null and reason.len != 0)) return error.InvalidClose;
    if (code) |value| if (!validCode(value)) return error.InvalidClose;
    if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;
    const deadline = timeout.toDeadline(self.io);
    errdefer self.deinit();
    var payload: [125]u8 = undefined;
    if (code) |value| {
        std.mem.writeInt(u16, payload[0..2], value, .big);
        @memcpy(payload[2..][0..reason.len], reason);
    }
    try self.control(8, payload[0..if (code != null) 2 + reason.len else 0], deadline);
    self.sent_close = true;
    while (true) {
        const message = try self.receive(deadline);
        if (message == .close) return message.close;
        message.deinit(self.allocator);
    }
}
