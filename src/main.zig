const std = @import("std");
const Context = @import("Context.zig").Context;
const Positions = @import("services/Positions.zig");

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

fn shortenHome(path: []const u8, home: ?[]const u8) []const u8 {
    const h = home orelse return path;
    if (std.mem.startsWith(u8, path, h) and path.len > h.len and path[h.len] == '/') {
        return path[h.len + 1 ..];
    }
    return path;
}

// Prints the recent-files list and reads a selection from stdin.
fn pickRecent(init: std.process.Init, stdout: *std.Io.Writer) !?[:0]const u8 {
    const arena = init.arena.allocator();
    const recents = Positions.listRecent(arena, init.io, init.environ_map);
    if (recents.len == 0) return null;

    const home = init.environ_map.get("HOME");
    const shown = @min(recents.len, 15);
    try stdout.writeAll("Recent:\n");
    for (recents[0..shown], 1..) |r, i| {
        const prefix: []const u8 = if (shortenHome(r.path, home).ptr != r.path.ptr) "~/" else "";
        try stdout.print("  {d:>2}. {s}{s}  (p.{d})\n", .{ i, prefix, shortenHome(r.path, home), r.page + 1 });
    }
    try stdout.print("open [1-{d}]: ", .{shown});
    try stdout.flush();

    var in_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &in_buf);
    const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch return null;
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    const choice: usize = if (trimmed.len == 0) 1 else std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (choice < 1 or choice > shown) return null;
    return try arena.dupeZ(u8, recents[choice - 1].path);
}

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

    if (args.len > 3 or (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))) {
        try stderr.writeAll("Usage: fancy-cat <path-to-pdf> <optional-page-number>\n       fancy-cat            (pick from recently opened)\n");
        try stderr.flush();
        return;
    }

    var path: [:0]const u8 = undefined;
    var initial_page: ?u16 = null;
    if (args.len == 1) {
        path = try pickRecent(init, stdout) orelse {
            try stderr.writeAll("Usage: fancy-cat <path-to-pdf> <optional-page-number>\n");
            try stderr.flush();
            return;
        };
    } else {
        path = args[1];
        if (args.len == 3) initial_page = try std.fmt.parseInt(u16, args[2], 10);
    }

    var app = try Context.init(init.gpa, init.io, init.environ_map, path, initial_page);
    defer app.deinit();

    try app.run();
}
