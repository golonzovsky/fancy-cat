const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");

context: *Context,
cursor: usize,
top: usize,
draw_arena: std.heap.ArenaAllocator,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .cursor = 0,
        .top = 0,
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.draw_arena.deinit();
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    const ctx = self.context;
    const items = ctx.highlights.items;
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or
        key.matches(km.highlights_mode.codepoint, km.highlights_mode.mods) or
        items.len == 0)
    {
        ctx.changeMode(.view);
        return;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        if (self.cursor > 0) self.cursor -= 1;
        return;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        if (self.cursor + 1 < items.len) self.cursor += 1;
        return;
    }
    if (key.matches('g', .{})) {
        self.cursor = 0;
        return;
    }
    if (key.matches('G', .{})) {
        self.cursor = items.len - 1;
        return;
    }
    if (key.matches('d', .{})) {
        ctx.deleteHighlight(self.cursor);
        const new_len = ctx.highlights.items.len;
        if (new_len == 0) {
            ctx.changeMode(.view);
            return;
        }
        if (self.cursor >= new_len) self.cursor = new_len - 1;
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const idx = self.cursor;
        ctx.changeMode(.view);
        ctx.jumpToHighlight(idx);
        return;
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    if (mouse.type != .press) return;
    const len = self.context.highlights.items.len;
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
    const items = self.context.highlights.items;
    const row_count: u16 = @intCast(@min(@max(@as(usize, 3), items.len + 2), 1000));
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
    const mark_style = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 200, 110 } },
    };

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = max_h });
    popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = bg });

    _ = popup.print(
        &.{.{ .text = " Highlights (Enter: jump, d: delete, Esc: close) ", .style = bg }},
        .{ .row_offset = 0, .col_offset = 1 },
    );

    if (items.len == 0) {
        _ = popup.print(
            &.{.{ .text = " (no highlights — select text, then H) ", .style = dim }},
            .{ .row_offset = 1, .col_offset = 1 },
        );
        return;
    }

    const list_h: usize = if (max_h > 1) max_h - 1 else 0;
    if (list_h == 0) return;
    if (self.cursor < self.top) self.top = self.cursor;
    if (self.cursor >= self.top + list_h) self.top = self.cursor + 1 - list_h;

    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();

    var i: usize = 0;
    while (i < list_h and self.top + i < items.len) : (i += 1) {
        const idx = self.top + i;
        const h = items[idx];
        const row: u16 = @intCast(i + 1);
        const style = if (idx == self.cursor) sel else bg;

        const label = std.fmt.allocPrint(a, " p.{d:<4} ", .{h.page + 1}) catch continue;
        _ = popup.print(
            &.{.{ .text = label, .style = if (idx == self.cursor) sel else mark_style }},
            .{ .row_offset = row, .col_offset = 0 },
        );

        const text_col: u16 = @intCast(@min(label.len, w));
        const avail: usize = w -| text_col;
        if (avail == 0) continue;
        var text = std.mem.trim(u8, h.text, &std.ascii.whitespace);
        if (text.len > avail) text = text[0..avail];
        const flat = std.mem.join(a, " ", blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, text, "\r\n");
            while (it.next()) |t| parts.append(a, t) catch break;
            break :blk parts.items;
        }) catch text;
        _ = popup.print(
            &.{.{ .text = flat, .style = style }},
            .{ .row_offset = row, .col_offset = text_col },
        );
    }
}
