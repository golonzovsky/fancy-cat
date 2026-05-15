const std = @import("std");
const Context = @import("Context.zig").Context;

// Types for build.zig.zon
// For now metadata is only used in main.zig, but can move it to types.zig if needed eleswhere
// This wont be necessary once https://github.com/ziglang/zig/pull/22907 is merged

const PackageName = enum { fancy_cat };

const DependencyType = struct {
    url: []const u8,
    hash: []const u8,
};

const DependenciesType = struct {
    vaxis: DependencyType,
    fastb64z: DependencyType,
    fzwatch: DependencyType,
};

const MetadataType = struct {
    name: PackageName,
    fingerprint: u64,
    version: []const u8,
    minimum_zig_version: []const u8,
    dependencies: DependenciesType,
    paths: []const []const u8,
};

const metadata: MetadataType = @import("metadata");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))) {
        try stdout.print("fancy-cat version {s}\n", .{metadata.version});
        try stdout.flush();
        return;
    }

    if (args.len < 2 or args.len > 3 or (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try stderr.writeAll("Usage: fancy-cat <path-to-pdf> <optional-page-number>\n");
        try stderr.flush();
        return;
    }

    var app = try Context.init(init.gpa, init.io, init.environ_map, args);
    defer app.deinit();

    try app.run();
}
