const std = @import("std");

pub fn build(b: *std.Build) void {
    const version = std.mem.trim(u8, @embedFile(".zigversion"), " \t\r\n");
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, version))
        @panic("use the Zig compiler pinned in .zigversion");
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .linux) @panic("zig-ws currently supports Linux");
    const optimize = b.standardOptimizeOption(.{});
    const ws = b.addModule("ws", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = ws });
    b.step("test", "Run WebSocket protocol fixtures").dependOn(&b.addRunArtifact(tests).step);
}
