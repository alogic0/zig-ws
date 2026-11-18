const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zig_ws", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ws", .module = dep.module("ws") }},
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Exercise the public ws module").dependOn(&b.addRunArtifact(tests).step);
}
