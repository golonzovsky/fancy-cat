const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");

pub const Position = struct {
    page: u16 = 0,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    zoom: f32 = 0,
    odd_shift_x: i32 = 0,
    colorize: bool = false,
    crop: bool = false,
    hlock: bool = false,
    spread: bool = false,
    // For the recent-files list; not restored as view state.
    path: []const u8 = "",
    last_opened: i64 = 0,
};

pub const Mark = struct {
    letter: u8,
    page: u16,
    scroll_x: i32,
    scroll_y: i32,
    comment: []const u8 = "",
};

allocator: std.mem.Allocator,
io: std.Io,
config: *Config,
doc_path: []const u8,
file_path: []u8,
all: std.json.Parsed(std.json.Value),
have_data: bool,

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config: *Config, doc_path: []const u8) Self {
    var self = Self{
        .allocator = allocator,
        .io = io,
        .config = config,
        .doc_path = doc_path,
        .file_path = "",
        .all = undefined,
        .have_data = false,
    };

    self.file_path = statePath(allocator, env) orelse return self;

    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, self.file_path, allocator, .limited(1024 * 1024)) catch return self;
    defer allocator.free(content);

    self.all = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return self;
    if (self.all.value != .object) {
        self.all.deinit();
        return self;
    }
    self.have_data = true;
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.have_data) self.all.deinit();
    if (self.file_path.len > 0) self.allocator.free(self.file_path);
}

fn statePath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    if (env.get("XDG_STATE_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/fancy-cat/positions.json", .{x}) catch null;
    }
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/.local/state/fancy-cat/positions.json", .{home}) catch null;
}

pub const RecentEntry = struct {
    path: []const u8,
    page: u16,
    last_opened: i64,
};

// Entries from positions.json that carry a path, newest first, deduped by path.
pub fn listRecent(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) []RecentEntry {
    const path = statePath(allocator, env) orelse return &.{};
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return &.{};
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .object) return &.{};

    var out: std.ArrayList(RecentEntry) = .empty;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const obj = kv.value_ptr.object;
        const doc_path = jsonGet([]const u8, obj, "path", "");
        if (doc_path.len == 0) continue;
        const entry = RecentEntry{
            .path = allocator.dupe(u8, doc_path) catch continue,
            .page = jsonGet(u16, obj, "page", 0),
            .last_opened = jsonGet(i64, obj, "last_opened", 0),
        };
        var merged = false;
        for (out.items) |*e| {
            if (std.mem.eql(u8, e.path, entry.path)) {
                merged = true;
                if (entry.last_opened > e.last_opened) {
                    allocator.free(e.path);
                    e.* = entry;
                } else {
                    allocator.free(entry.path);
                }
                break;
            }
        }
        if (!merged) out.append(allocator, entry) catch {
            allocator.free(entry.path);
            break;
        };
    }

    std.sort.pdq(RecentEntry, out.items, {}, struct {
        fn newerFirst(_: void, a: RecentEntry, b: RecentEntry) bool {
            return a.last_opened > b.last_opened;
        }
    }.newerFirst);
    return out.toOwnedSlice(allocator) catch &.{};
}

pub fn getSavedPosition(self: *Self) ?Position {
    return self.lookupKey(self.doc_path);
}

// Tries the canonical doc key first, then an alternate (e.g. the document's
// raw path) — heals positions saved by an older version that keyed by path
// before PDF-id keying existed. The next save rewrites under the canonical key.
pub fn getSavedPositionForKey(self: *Self, alt_key: []const u8) ?Position {
    return self.lookupKey(self.doc_path) orelse self.lookupKey(alt_key);
}

// Reads one struct field's value out of a JSON object, keeping `fallback` on
// miss or type mismatch. Strings are slices into the parsed JSON tree.
fn jsonGet(comptime T: type, obj: std.json.ObjectMap, name: []const u8, fallback: T) T {
    const v = obj.get(name) orelse return fallback;
    return switch (@typeInfo(T)) {
        .int => if (v == .integer) (std.math.cast(T, v.integer) orelse fallback) else fallback,
        .float => switch (v) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => fallback,
        },
        .bool => if (v == .bool) v.bool else fallback,
        .pointer => if (v == .string) v.string else fallback,
        else => @compileError("unsupported field type for jsonGet"),
    };
}

fn jsonValue(comptime T: type, v: T) std.json.Value {
    return switch (@typeInfo(T)) {
        .int => .{ .integer = @as(i64, v) },
        .float => .{ .float = v },
        .bool => .{ .bool = v },
        .pointer => .{ .string = v },
        else => @compileError("unsupported field type for jsonValue"),
    };
}

fn lookupKey(self: *Self, key: []const u8) ?Position {
    if (!self.have_data) return null;
    const entry = self.all.value.object.get(key) orelse return null;
    if (entry != .object) return null;

    var pos = Position{};
    inline for (std.meta.fields(Position)) |f| {
        @field(pos, f.name) = jsonGet(f.type, entry.object, f.name, @field(pos, f.name));
    }
    return pos;
}

pub fn loadMarks(self: *Self, allocator: std.mem.Allocator) std.ArrayList(Mark) {
    var out: std.ArrayList(Mark) = .empty;
    if (!self.have_data) return out;
    const entry = self.all.value.object.get(self.doc_path) orelse return out;
    if (entry != .object) return out;
    const arr = entry.object.get("marks") orelse return out;
    if (arr != .array) return out;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const letter_str = jsonGet([]const u8, item.object, "letter", "");
        if (letter_str.len == 0) continue;
        out.append(allocator, .{
            .letter = letter_str[0],
            .page = jsonGet(u16, item.object, "page", 0),
            .scroll_x = jsonGet(i32, item.object, "scroll_x", 0),
            .scroll_y = jsonGet(i32, item.object, "scroll_y", 0),
            .comment = allocator.dupe(u8, jsonGet([]const u8, item.object, "comment", "")) catch "",
        }) catch break;
    }
    return out;
}

pub fn save(self: *Self, pos: Position, marks: []const Mark) void {
    if (self.file_path.len == 0) return;

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(self.file_path)) |dir| cwd.createDirPath(self.io, dir) catch {};

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.ObjectMap.empty;
    if (self.have_data) {
        var it = self.all.value.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, self.doc_path)) continue;
            root.put(a, kv.key_ptr.*, kv.value_ptr.*) catch return;
        }
    }

    var entry = std.json.ObjectMap.empty;
    inline for (std.meta.fields(Position)) |f| {
        entry.put(a, f.name, jsonValue(f.type, @field(pos, f.name))) catch return;
    }

    if (marks.len > 0) {
        var arr = std.json.Array.init(a);
        for (marks) |m| {
            var obj = std.json.ObjectMap.empty;
            const letter_str = a.alloc(u8, 1) catch return;
            letter_str[0] = m.letter;
            obj.put(a, "letter", .{ .string = letter_str }) catch return;
            obj.put(a, "page", .{ .integer = @as(i64, m.page) }) catch return;
            obj.put(a, "scroll_x", .{ .integer = @as(i64, m.scroll_x) }) catch return;
            obj.put(a, "scroll_y", .{ .integer = @as(i64, m.scroll_y) }) catch return;
            obj.put(a, "comment", .{ .string = m.comment }) catch return;
            arr.append(.{ .object = obj }) catch return;
        }
        entry.put(a, "marks", .{ .array = arr }) catch return;
    }

    root.put(a, self.doc_path, .{ .object = entry }) catch return;

    const json_str = std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }) catch return;

    // Write to a temp file then atomically rename, so a kill mid-write (or a
    // frequent in-loop save) can never leave a truncated positions.json.
    const tmp_path = std.fmt.allocPrint(a, "{s}.tmp", .{self.file_path}) catch return;
    {
        var file = cwd.createFile(self.io, tmp_path, .{}) catch return;
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        fw.interface.writeAll(json_str) catch return;
        fw.interface.flush() catch return;
    }
    std.Io.Dir.renameAbsolute(tmp_path, self.file_path, self.io) catch return;
}
