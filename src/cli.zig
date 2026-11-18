const std = @import("std");
const ws = @import("ws");
const Io = std.Io;
const A = std.mem.Allocator;
const eql = std.mem.eql;

const usage =
    \\Usage: zig-ws [OPTIONS] ws://HOST[:PORT]/PATH
    \\       zig-ws [OPTIONS] --unix SOCKET [--target PATH] [--host HOST]
    \\
    \\  --jsonl           One JSON value per input and output line (default)
    \\  --text            One text message per input line
    \\  --binary          Send one binary message from all input and receive one
    \\  --input FILE      Read messages from a file (default: stdin)
    \\  --receive COUNT   Finish after this many incoming messages
    \\  --timeout-ms N    Opening, message and idle timeout (default: 30000)
    \\  --max-bytes N     Maximum bytes per message (default: 67108864)
    \\
    \\After input EOF, continue receiving until the count or peer close.
    \\
;

const Mode = enum { jsonl, text, binary };
const Config = struct {
    endpoint: ws.Endpoint,
    mode: Mode = .jsonl,
    path: ?[]const u8 = null,
    count: ?usize = null,
    max: usize = 64 * 1024 * 1024,
    timeout: Io.Timeout = ws.default_timeout,
};

pub fn main(init: std.process.Init) u8 {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const config = parse(&args) catch |err| {
        if (err == error.Help) {
            Io.File.stdout().writeStreamingAll(init.io, usage) catch return 1;
            return 0;
        }
        std.debug.print("zig-ws: {s}\n{s}", .{ @errorName(err), usage });
        return 2;
    };
    run(init.gpa, init.io, config) catch |err| {
        std.debug.print("zig-ws: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn number(comptime T: type, raw: ?[]const u8) !T {
    const n = std.fmt.parseInt(T, raw orelse return error.MissingArgument, 10) catch return error.InvalidNumber;
    if (n == 0) return error.InvalidNumber;
    return n;
}

fn parse(args: *std.process.Args.Iterator) !Config {
    var config: Config = .{ .endpoint = undefined };
    var url: ?[]const u8 = null;
    var unix: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var mode: ?Mode = null;
    while (args.next()) |arg| {
        if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) return error.Help;
        if (eql(u8, arg, "--unix")) {
            unix = args.next() orelse return error.MissingArgument;
        } else if (eql(u8, arg, "--target")) {
            target = args.next() orelse return error.MissingArgument;
        } else if (eql(u8, arg, "--host")) {
            host = args.next() orelse return error.MissingArgument;
        } else if (eql(u8, arg, "--input")) {
            config.path = args.next() orelse return error.MissingArgument;
        } else if (eql(u8, arg, "--receive")) {
            config.count = try number(usize, args.next());
        } else if (eql(u8, arg, "--max-bytes")) {
            config.max = try number(usize, args.next());
        } else if (eql(u8, arg, "--timeout-ms")) {
            config.timeout = .{ .duration = .{ .raw = .fromMilliseconds(try number(u32, args.next())), .clock = .awake } };
        } else if (eql(u8, arg, "--jsonl") or eql(u8, arg, "--text") or eql(u8, arg, "--binary")) {
            if (mode != null) return error.ConflictingModes;
            mode = std.meta.stringToEnum(Mode, arg[2..]).?;
        } else if (arg.len != 0 and arg[0] != '-' and url == null) {
            url = arg;
        } else return error.InvalidArgument;
    }
    config.mode = mode orelse .jsonl;
    if (config.mode == .binary) {
        if (config.count != null and config.count.? != 1) return error.InvalidCount;
        config.count = 1;
    }
    if (unix) |path| {
        if (url != null) return error.ConflictingEndpoints;
        config.endpoint = .{ .unix = .{ .path = path, .host = host orelse "localhost", .target = target orelse "/" } };
    } else {
        if (host != null or target != null) return error.UnexpectedUnixOption;
        config.endpoint = .{ .tcp = url orelse return error.MissingEndpoint };
    }
    return config;
}

const Input = struct {
    bytes: std.ArrayList(u8) = .empty,
    done: bool = false,

    fn append(self: *Input, a: A, chunk: []const u8, limit: usize) !void {
        if (chunk.len > limit - self.bytes.items.len) return error.MessageTooLarge;
        try self.bytes.appendSlice(a, chunk);
    }

    fn sendLine(self: *Input, conn: *ws.Connection, c: Config, deadline: Io.Timeout) !void {
        const line = std.mem.trimEnd(u8, self.bytes.items, "\r");
        if (c.mode == .jsonl and !try std.json.validate(conn.allocator, line)) return error.InvalidJson;
        try conn.send(.text, line, deadline);
        self.bytes.clearRetainingCapacity();
    }

    fn read(self: *Input, file: Io.File, conn: *ws.Connection, c: Config, deadline: Io.Timeout) !void {
        var buf: [8192]u8 = undefined;
        const n = file.readStreaming(conn.io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) {
            self.done = true;
            if (c.mode == .binary) {
                try conn.send(.binary, self.bytes.items, deadline);
            } else if (self.bytes.items.len != 0) try self.sendLine(conn, c, deadline);
            return;
        }
        if (c.mode == .binary) return self.append(conn.allocator, buf[0..n], c.max);
        var rest = buf[0..n];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |end| {
            try self.append(conn.allocator, rest[0..end], c.max);
            try self.sendLine(conn, c, deadline);
            rest = rest[end + 1 ..];
        }
        try self.append(conn.allocator, rest, c.max);
    }
};

// Compact in place while preserving numeric lexemes, escaped strings and object order.
fn jsonLine(a: A, bytes: []u8) ![]const u8 {
    if (!try std.json.validate(a, bytes)) return error.InvalidJson;
    var quoted = false;
    var escaped = false;
    var out: usize = 0;
    for (bytes) |c| {
        if (!quoted and std.ascii.isWhitespace(c)) continue;
        bytes[out] = c;
        out += 1;
        if (escaped) {
            escaped = false;
        } else if (quoted and c == '\\') {
            escaped = true;
        } else if (c == '"') quoted = !quoted;
    }
    return bytes[0..out];
}

fn output(io: Io, a: A, mode: Mode, message: ws.Message) !void {
    const out = Io.File.stdout();
    if (mode == .binary) {
        if (message != .binary) return error.ExpectedBinary;
        return out.writeStreamingAll(io, message.binary);
    }
    if (message != .text) return error.ExpectedText;
    const bytes = if (mode == .jsonl) try jsonLine(a, message.text) else message.text;
    try out.writeStreamingAll(io, bytes);
    try out.writeStreamingAll(io, "\n");
}

fn run(a: A, io: Io, c: Config) !void {
    const file = if (c.path) |path| try Io.Dir.cwd().openFile(io, path, .{}) else Io.File.stdin();
    defer if (c.path != null) file.close(io);
    var conn = try ws.Connection.connect(a, io, c.endpoint, .{ .timeout = c.timeout, .max_message_bytes = c.max });
    defer conn.deinit();
    var input: Input = .{};
    defer input.bytes.deinit(a);
    var received: usize = 0;
    var deadline = c.timeout.toDeadline(io);
    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = if (input.done) -1 else file.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = conn.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ns = deadline.deadline.durationFromNow(io).raw.nanoseconds;
        if (ns <= 0) return error.Timeout;
        const wait: i32 = if (conn.hasBufferedInput()) 0 else @intCast(@min(@divTrunc(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
        _ = try std.posix.poll(&fds, wait);
        if (fds[0].revents != 0) {
            try input.read(file, &conn, c, deadline);
            deadline = c.timeout.toDeadline(io);
        }
        if (conn.hasBufferedInput() or fds[1].revents != 0) {
            const message = try conn.receive(deadline);
            defer message.deinit(a);
            if (message == .close) {
                if ((message.close.code orelse 1000) != 1000 or (c.count != null and received < c.count.?)) {
                    std.debug.print("peer close {d} {s}\n", .{ message.close.code orelse 1005, message.close.reason });
                    return error.PeerClosed;
                }
                return;
            }
            try output(io, a, c.mode, message);
            received += 1;
            deadline = c.timeout.toDeadline(io);
        }
        if (c.count == received and (c.mode != .binary or input.done)) {
            const reply = try conn.close(1000, "", deadline);
            defer a.free(reply.reason);
            if ((reply.code orelse 1000) != 1000) return error.PeerClosed;
            return;
        }
    }
}
