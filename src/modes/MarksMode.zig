const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");

context: *Context,
cursor: usize,
outline: []const PdfHandler.OutlineEntry,
draw_arena: std.heap.ArenaAllocator,

pub fn init(context: *Context) Self {
    const outline: []const PdfHandler.OutlineEntry =
        context.document_handler.loadOutline(context.allocator) catch &.{};
    return .{
        .context = context,
        .cursor = 0,
        .outline = outline,
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.draw_arena.deinit();
    if (self.outline.len > 0) {
        for (self.outline) |e| self.context.allocator.free(e.title);
        self.context.allocator.free(self.outline);
    }
}

fn sectionFor(self: *const Self, page: u16) []const u8 {
    var title: []const u8 = "";
    for (self.outline) |e| {
        if (e.page > page) break;
        title = e.title;
    }
    return title;
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    const marks = self.context.marks.items;
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or
        key.matches(km.marks_mode.codepoint, km.marks_mode.mods))
    {
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
    if (key.matches('r', .{})) {
        const m = marks[self.cursor];
        var buf: [256]u8 = undefined;
        const prefilled = std.fmt.bufPrint(&buf, "mark {c} {s}", .{ m.letter, m.comment }) catch return;
        self.context.enterCommandWithText(prefilled);
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

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    if (mouse.type != .press) return;
    const len = self.context.marks.items.len;
    if (len == 0) return;
    switch (mouse.button) {
        .wheel_up => if (self.cursor > 0) {
            self.cursor -= 1;
        },
        .wheel_down => if (self.cursor + 1 < len) {
            self.cursor += 1;
        },
        else => {},
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const marks = self.context.marks.items;
    const row_count: u16 = @intCast(@max(@as(usize, 3), marks.len + 2));
    const max_h: u16 = @min(row_count, @as(u16, @intCast(@as(usize, win.height) -| 2)));
    const w: u16 = @min(@as(u16, win.width -| 4), 120);
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
    const dim = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 150, 150, 160 } },
    };

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = max_h });
    popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = bg });

    _ = popup.print(
        &.{.{ .text = " Marks (Enter: jump, r: rename, d: delete, Esc: close) ", .style = bg }},
        .{ .row_offset = 0, .col_offset = 1 },
    );

    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();

    for (marks, 0..) |m, i| {
        const row: u16 = @intCast(i + 1);
        if (row >= max_h) break;
        const style = if (i == self.cursor) sel else bg;
        const section = self.sectionFor(m.page);
        const label = std.fmt.allocPrint(a, " {c}  p.{d:<4}  ", .{ m.letter, m.page + 1 }) catch continue;
        _ = popup.print(
            &.{.{ .text = label, .style = style }},
            .{ .row_offset = row, .col_offset = 0 },
        );

        const main_col: u16 = @intCast(@min(label.len, w));
        if (m.comment.len > 0) {
            _ = popup.print(
                &.{.{ .text = m.comment, .style = style }},
                .{ .row_offset = row, .col_offset = main_col },
            );
            if (section.len > 0) {
                const sep = std.fmt.allocPrint(a, "  - {s}", .{section}) catch section;
                _ = popup.print(
                    &.{.{ .text = sep, .style = if (i == self.cursor) sel else dim }},
                    .{ .row_offset = row, .col_offset = @intCast(@min(@as(usize, main_col) + m.comment.len, w)) },
                );
            }
        } else if (section.len > 0) {
            _ = popup.print(
                &.{.{ .text = section, .style = if (i == self.cursor) sel else dim }},
                .{ .row_offset = row, .col_offset = main_col },
            );
        }
    }
}
