const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");

pub const Position = struct {
    page: u16 = 0,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    zoom: f32 = 0,
    odd_shift_x: i32 = 0,
};

allocator: std.mem.Allocator,
config: *Config,
doc_path: []const u8,
file_path: []u8,
all: std.json.Parsed(std.json.Value),
have_data: bool,

pub fn init(allocator: std.mem.Allocator, config: *Config, doc_path: []const u8) Self {
    var self = Self{
        .allocator = allocator,
        .config = config,
        .doc_path = doc_path,
        .file_path = "",
        .all = undefined,
        .have_data = false,
    };

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return self;
    defer allocator.free(home);

    if (!config.legacy_path) {
        const xdg_state_home = std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME") catch null;
        if (xdg_state_home) |x| {
            self.file_path = std.fmt.allocPrint(allocator, "{s}/fancy-cat/positions.json", .{x}) catch return self;
            allocator.free(x);
        } else self.file_path = std.fmt.allocPrint(allocator, "{s}/.local/state/fancy-cat/positions.json", .{home}) catch return self;
    } else self.file_path = std.fmt.allocPrint(allocator, "{s}/.fancy-cat_positions", .{home}) catch return self;

    const content = std.fs.cwd().readFileAlloc(allocator, self.file_path, 1024 * 1024) catch return self;
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

pub fn getSavedPosition(self: *Self) ?Position {
    if (!self.have_data) return null;
    const entry = self.all.value.object.get(self.doc_path) orelse return null;
    if (entry != .object) return null;

    var pos = Position{};
    if (entry.object.get("page")) |v| if (v == .integer) {
        pos.page = std.math.cast(u16, v.integer) orelse 0;
    };
    if (entry.object.get("scroll_x")) |v| if (v == .integer) {
        pos.scroll_x = std.math.cast(i32, v.integer) orelse 0;
    };
    if (entry.object.get("scroll_y")) |v| if (v == .integer) {
        pos.scroll_y = std.math.cast(i32, v.integer) orelse 0;
    };
    if (entry.object.get("zoom")) |v| switch (v) {
        .float => |f| pos.zoom = @floatCast(f),
        .integer => |i| pos.zoom = @floatFromInt(i),
        else => {},
    };
    if (entry.object.get("odd_shift_x")) |v| if (v == .integer) {
        pos.odd_shift_x = std.math.cast(i32, v.integer) orelse 0;
    };
    return pos;
}

pub fn save(self: *Self, pos: Position) void {
    if (self.file_path.len == 0) return;

    if (std.fs.path.dirname(self.file_path)) |dir| std.fs.cwd().makePath(dir) catch {};

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.ObjectMap.init(a);
    if (self.have_data) {
        var it = self.all.value.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, self.doc_path)) continue;
            root.put(kv.key_ptr.*, kv.value_ptr.*) catch return;
        }
    }

    var entry = std.json.ObjectMap.init(a);
    entry.put("page", .{ .integer = @as(i64, pos.page) }) catch return;
    entry.put("scroll_x", .{ .integer = @as(i64, pos.scroll_x) }) catch return;
    entry.put("scroll_y", .{ .integer = @as(i64, pos.scroll_y) }) catch return;
    entry.put("zoom", .{ .float = pos.zoom }) catch return;
    entry.put("odd_shift_x", .{ .integer = @as(i64, pos.odd_shift_x) }) catch return;
    root.put(self.doc_path, .{ .object = entry }) catch return;

    const json_str = std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }) catch return;
    const file = std.fs.createFileAbsolute(self.file_path, .{}) catch return;
    defer file.close();
    file.writeAll(json_str) catch return;
}
