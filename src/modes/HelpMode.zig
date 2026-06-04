const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");

context: *Context,
draw_arena: std.heap.ArenaAllocator,

const Line = struct {
    header: bool = false,
    keys: []const u8 = "",
    label: []const u8 = "",
};

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.draw_arena.deinit();
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    _ = key;
    _ = km;
    self.context.changeMode(.view);
}

fn fmtKey(a: std.mem.Allocator, key: vaxis.Key) []const u8 {
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    const put = struct {
        fn f(b: []u8, idx: usize, s: []const u8) usize {
            const n = @min(s.len, b.len - idx);
            @memcpy(b[idx .. idx + n], s[0..n]);
            return idx + n;
        }
    }.f;
    if (key.mods.ctrl) i = put(&buf, i, "C-");
    if (key.mods.alt) i = put(&buf, i, "M-");
    if (key.mods.super) i = put(&buf, i, "D-");

    const named: ?[]const u8 = switch (key.codepoint) {
        vaxis.Key.tab => "Tab",
        vaxis.Key.enter => "Enter",
        vaxis.Key.escape => "Esc",
        vaxis.Key.space => "Space",
        vaxis.Key.backspace => "Bksp",
        vaxis.Key.up => "Up",
        vaxis.Key.down => "Down",
        vaxis.Key.left => "Left",
        vaxis.Key.right => "Right",
        else => null,
    };
    if (named) |n| {
        i = put(&buf, i, n);
    } else {
        var cp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(key.codepoint, &cp) catch 0;
        i = put(&buf, i, cp[0..len]);
    }
    return a.dupe(u8, buf[0..i]) catch buf[0..i];
}

fn buildLines(self: *Self, a: std.mem.Allocator) []const Line {
    const km = self.context.config.key_map;
    const lines = a.alloc(Line, 24) catch return &.{};
    var n: usize = 0;
    const add = struct {
        fn f(buf: []Line, idx: *usize, line: Line) void {
            if (idx.* < buf.len) {
                buf[idx.*] = line;
                idx.* += 1;
            }
        }
    }.f;
    const two = struct {
        fn f(alloc: std.mem.Allocator, x: []const u8, y: []const u8) []const u8 {
            return std.fmt.allocPrint(alloc, "{s} {s}", .{ x, y }) catch x;
        }
    }.f;

    add(lines, &n, .{ .header = true, .label = "Navigation" });
    add(lines, &n, .{ .keys = two(a, fmtKey(a, km.prev), fmtKey(a, km.next)), .label = "prev / next page" });
    add(lines, &n, .{ .keys = std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ fmtKey(a, km.scroll_left), fmtKey(a, km.scroll_down), fmtKey(a, km.scroll_up), fmtKey(a, km.scroll_right) }) catch "", .label = "scroll left/down/up/right" });
    add(lines, &n, .{ .keys = two(a, fmtKey(a, km.jump_back), fmtKey(a, km.jump_forward)), .label = "jump back / forward" });

    add(lines, &n, .{ .header = true, .label = "View" });
    add(lines, &n, .{ .keys = two(a, fmtKey(a, km.zoom_in), fmtKey(a, km.zoom_out)), .label = "zoom in / out" });
    add(lines, &n, .{ .keys = fmtKey(a, km.width_mode), .label = "fit width" });
    add(lines, &n, .{ .keys = fmtKey(a, km.crop_to_content), .label = "crop to content" });
    add(lines, &n, .{ .keys = fmtKey(a, km.full_screen), .label = "toggle status bar" });
    add(lines, &n, .{ .keys = fmtKey(a, km.colorize), .label = "toggle invert" });

    add(lines, &n, .{ .header = true, .label = "Marks & contents" });
    add(lines, &n, .{ .keys = fmtKey(a, km.set_mark), .label = "set mark (then a-z)" });
    add(lines, &n, .{ .keys = fmtKey(a, km.jump_mark), .label = "jump to mark (then a-z)" });
    add(lines, &n, .{ .keys = fmtKey(a, km.marks_mode), .label = "marks list" });
    add(lines, &n, .{ .keys = fmtKey(a, km.toc_mode), .label = "table of contents" });

    add(lines, &n, .{ .header = true, .label = "Editor & links" });
    add(lines, &n, .{ .keys = fmtKey(a, km.open_in_editor), .label = "page text in $EDITOR" });
    add(lines, &n, .{ .keys = fmtKey(a, km.open_chapter_in_editor), .label = "chapter text in $EDITOR" });
    add(lines, &n, .{ .keys = fmtKey(a, km.hint_mode), .label = "follow link (hints)" });

    add(lines, &n, .{ .header = true, .label = "General" });
    add(lines, &n, .{ .keys = fmtKey(a, km.enter_command_mode), .label = "command mode" });
    add(lines, &n, .{ .keys = fmtKey(a, km.show_help), .label = "this help" });
    add(lines, &n, .{ .keys = fmtKey(a, km.quit), .label = "quit" });

    return lines[0..n];
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();
    const lines = self.buildLines(a);

    const key_col: u16 = 12;
    const w: u16 = @min(@as(u16, win.width -| 4), 52);
    const content_h: u16 = @intCast(lines.len + 2);
    const max_h: u16 = @min(content_h, @as(u16, @intCast(@as(usize, win.height) -| 2)));
    const x_off = (win.width -| w) / 2;
    const y_off = (win.height -| max_h) / 2;

    const bg = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 230, 230 } },
    };
    const head = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 130, 170, 255 } },
        .bold = true,
    };
    const key_style = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 200, 110 } },
        .bold = true,
    };

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = max_h });
    popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = bg });

    _ = popup.print(
        &.{.{ .text = " Keymap (any key to close) ", .style = head }},
        .{ .row_offset = 0, .col_offset = 1 },
    );

    for (lines, 0..) |line, i| {
        const row: u16 = @intCast(i + 2);
        if (row >= max_h) break;
        if (line.header) {
            _ = popup.print(&.{.{ .text = line.label, .style = head }}, .{ .row_offset = row, .col_offset = 1 });
        } else {
            _ = popup.print(&.{.{ .text = line.keys, .style = key_style }}, .{ .row_offset = row, .col_offset = 2 });
            _ = popup.print(&.{.{ .text = line.label, .style = bg }}, .{ .row_offset = row, .col_offset = key_col });
        }
    }
}
