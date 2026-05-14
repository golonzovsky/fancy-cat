const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");

context: *Context,
cursor: usize,

pub fn init(context: *Context) Self {
    return .{ .context = context, .cursor = 0 };
}

pub fn deinit(_: *Self) void {}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    const marks = self.context.marks.items;
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
        self.context.changeMode(.view);
        return;
    }
    if (marks.len == 0) {
        self.context.changeMode(.view);
        return;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        if (self.cursor > 0) self.cursor -= 1;
        return;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        if (self.cursor + 1 < marks.len) self.cursor += 1;
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const m = marks[self.cursor];
        self.context.changeMode(.view);
        self.context.jumpToMark(m.letter);
        return;
    }
    if (key.matches('d', .{})) {
        const m = marks[self.cursor];
        self.context.deleteMark(m.letter);
        const new_len = self.context.marks.items.len;
        if (new_len == 0) {
            self.context.changeMode(.view);
            return;
        }
        if (self.cursor >= new_len) self.cursor = new_len - 1;
        return;
    }
    if (key.codepoint >= 'a' and key.codepoint <= 'z') {
        const letter: u8 = @intCast(key.codepoint);
        for (marks) |m| {
            if (m.letter == letter) {
                self.context.changeMode(.view);
                self.context.jumpToMark(letter);
                return;
            }
        }
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const marks = self.context.marks.items;
    const row_count: u16 = @intCast(@max(@as(usize, 3), marks.len + 2));
    const max_h: u16 = @min(row_count, @as(u16, @intCast(@as(usize, win.height) -| 2)));
    const w: u16 = @min(@as(u16, 60), win.width -| 4);
    const x_off = (win.width -| w) / 2;
    const y_off = (win.height -| max_h) / 2;

    const bg = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 230, 230 } },
    };
    const sel = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 220, 20, 60 } },
        .fg = .{ .rgb = .{ 255, 255, 255 } },
        .bold = true,
    };

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = max_h });
    popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = bg });

    _ = popup.print(
        &.{.{ .text = " Marks (Enter: jump, d: delete, Esc: close) ", .style = bg }},
        .{ .row_offset = 0, .col_offset = 1 },
    );

    var arena = std.heap.ArenaAllocator.init(self.context.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (marks, 0..) |m, i| {
        const row: u16 = @intCast(i + 1);
        if (row >= max_h - 0) break;
        const style = if (i == self.cursor) sel else bg;
        const letter_str = a.alloc(u8, 1) catch continue;
        letter_str[0] = m.letter;
        const line = std.fmt.allocPrint(a, " {s}  p.{d}  {s}", .{ letter_str, m.page + 1, m.comment }) catch continue;
        _ = popup.print(
            &.{.{ .text = line, .style = style }},
            .{ .row_offset = row, .col_offset = 0 },
        );
    }
}
