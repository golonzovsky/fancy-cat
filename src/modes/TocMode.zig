const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");

context: *Context,
entries: []PdfHandler.OutlineEntry,
cursor: usize,
top: usize,
draw_arena: std.heap.ArenaAllocator,

pub fn init(context: *Context) Self {
    const empty = &[_]PdfHandler.OutlineEntry{};
    var entries: []PdfHandler.OutlineEntry = @constCast(empty);
    if (context.document_handler.loadOutline(context.allocator)) |loaded| {
        entries = loaded;
    } else |_| {}

    var cursor: usize = 0;
    const cur_page = context.document_handler.getCurrentPageNumber();
    for (entries, 0..) |e, i| {
        if (e.page > cur_page) break;
        cursor = i;
    }
    return .{
        .context = context,
        .entries = entries,
        .cursor = cursor,
        .top = 0,
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.draw_arena.deinit();
    const a = self.context.allocator;
    if (self.entries.len > 0) {
        for (self.entries) |e| a.free(e.title);
        a.free(self.entries);
    }
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
        self.context.changeMode(.view);
        return;
    }
    if (self.entries.len == 0) {
        self.context.changeMode(.view);
        return;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        if (self.cursor > 0) self.cursor -= 1;
        return;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        if (self.cursor + 1 < self.entries.len) self.cursor += 1;
        return;
    }
    if (key.matches('g', .{})) {
        self.cursor = 0;
        return;
    }
    if (key.matches('G', .{})) {
        self.cursor = self.entries.len - 1;
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const e = self.entries[self.cursor];
        self.context.changeMode(.view);
        self.context.pushJump();
        _ = self.context.document_handler.goToPage(e.page + 1);
        self.context.document_handler.setScrollY(0);
        if (!std.math.isNan(e.y)) self.context.document_handler.setPendingScrollPdfY(e.y);
        self.context.resetCurrentPage();
        return;
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const title_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 100, 200, 255 } }, .bold = true };
    const row_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 230, 230, 230 } } };
    const sel_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 255, 215, 0 } }, .bold = true };

    const w: u16 = if (win.width > 8) win.width - 4 else win.width;
    const h: u16 = if (win.height > 4) win.height - 2 else win.height;
    const x_off: u16 = (win.width -| w) / 2;
    const y_off: u16 = (win.height -| h) / 2;

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = h });

    _ = popup.print(
        &.{.{ .text = " Table of Contents (Enter: jump, Esc: close) ", .style = title_style }},
        .{ .row_offset = 0, .col_offset = 0 },
    );

    if (self.entries.len == 0) {
        _ = popup.print(
            &.{.{ .text = " (no outline in this document) ", .style = row_style }},
            .{ .row_offset = 2, .col_offset = 0 },
        );
        return;
    }

    const list_h: usize = if (h > 2) @intCast(h - 2) else 0;
    if (list_h == 0) return;

    if (self.cursor < self.top) self.top = self.cursor;
    if (self.cursor >= self.top + list_h) self.top = self.cursor + 1 - list_h;

    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();

    var i: usize = 0;
    while (i < list_h and self.top + i < self.entries.len) : (i += 1) {
        const idx = self.top + i;
        const e = self.entries[idx];
        const style = if (idx == self.cursor) sel_style else row_style;
        const prefix_n: usize = @as(usize, e.depth) * 2;
        const prefix = a.alloc(u8, prefix_n) catch continue;
        @memset(prefix, ' ');
        const line = std.fmt.allocPrint(a, "{s}{s}  (p.{d})", .{ prefix, e.title, e.page + 1 }) catch continue;
        const row: u16 = @intCast(2 + i);
        _ = popup.print(
            &.{.{ .text = line, .style = style }},
            .{ .row_offset = row, .col_offset = 1 },
        );
    }
}
