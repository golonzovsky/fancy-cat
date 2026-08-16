const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");

pub const page_behind_text = true;

pub const Position = struct {
    cell_col: u16,
    cell_row: u16,
};

pub const Hint = struct {
    label: []u8,
    target: PdfHandler.LinkTarget,
    positions: std.ArrayList(Position),
};

context: *Context,
hints: std.ArrayList(Hint),
prefix: std.ArrayList(u8),

pub fn init(context: *Context) Self {
    var self = Self{
        .context = context,
        .hints = .empty,
        .prefix = .empty,
    };
    self.populate() catch {};
    return self;
}

pub fn deinit(self: *Self) void {
    const a = self.context.allocator;
    for (self.hints.items) |*h| {
        a.free(h.label);
        switch (h.target) {
            .uri => |u| a.free(u),
            .page => {},
        }
        h.positions.deinit(a);
    }
    self.hints.deinit(a);
    self.prefix.deinit(a);
}

fn targetsEqual(a: PdfHandler.LinkTarget, b: PdfHandler.LinkTarget) bool {
    return switch (a) {
        .page => |pa| switch (b) {
            .page => |pb| pa.num == pb.num and pa.y == pb.y,
            .uri => false,
        },
        .uri => |ua| switch (b) {
            .page => false,
            .uri => |ub| std.mem.eql(u8, ua, ub),
        },
    };
}

fn findGroup(self: *Self, target: PdfHandler.LinkTarget) ?usize {
    for (self.hints.items, 0..) |h, i| {
        if (targetsEqual(h.target, target)) return i;
    }
    return null;
}

fn populate(self: *Self) !void {
    const a = self.context.allocator;
    const visible = self.context.visible_pages[0..self.context.visible_pages_len];
    const zoom = self.context.document_handler.getActiveZoom();
    if (zoom == 0) return;

    for (visible) |p| {
        const links = self.context.document_handler.loadLinks(a, p.page_num) catch continue;
        defer a.free(links);
        for (links) |link| {
            const shift_pdf: f32 = if (p.page_num % 2 == 1)
                @floatFromInt(self.context.document_handler.getOddShiftX())
            else
                0;
            const px = p.vpX(link.rect.x0 + shift_pdf, zoom);
            const py = p.vpY(link.rect.y0, zoom);
            if (px < @as(f32, @floatFromInt(p.vp_x_left)) or px >= @as(f32, @floatFromInt(p.vp_x_right)) or
                py < @as(f32, @floatFromInt(p.vp_y_top)) or py >= @as(f32, @floatFromInt(p.vp_y_bot)))
            {
                if (link.target == .uri) a.free(link.target.uri);
                continue;
            }
            const cell_col: u16 = @intCast(@as(u32, @intFromFloat(px)) / @as(u32, self.context.last_pix_per_col));
            const cell_row: u16 = @intCast(@as(u32, @intFromFloat(py)) / @as(u32, self.context.last_pix_per_row));

            if (self.findGroup(link.target)) |idx| {
                try self.hints.items[idx].positions.append(a, .{ .cell_col = cell_col, .cell_row = cell_row });
                if (link.target == .uri) a.free(link.target.uri);
            } else {
                var positions: std.ArrayList(Position) = .empty;
                try positions.append(a, .{ .cell_col = cell_col, .cell_row = cell_row });
                try self.hints.append(a, .{
                    .label = "",
                    .target = link.target,
                    .positions = positions,
                });
            }
        }
    }

    const total = self.hints.items.len;
    if (total == 0) return;
    const label_len: usize = if (total <= 26) 1 else if (total <= 26 * 26) 2 else 3;
    for (self.hints.items, 0..) |*h, i| {
        const label = try a.alloc(u8, label_len);
        var n = i;
        var k: usize = label_len;
        while (k > 0) {
            k -= 1;
            label[k] = 'a' + @as(u8, @intCast(n % 26));
            n /= 26;
        }
        h.label = label;
    }
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
        self.context.changeMode(.view);
        return;
    }

    if (key.codepoint >= 'a' and key.codepoint <= 'z') {
        try self.prefix.append(self.context.allocator, @intCast(key.codepoint));
        const pfx = self.prefix.items;

        for (self.hints.items) |h| {
            if (std.mem.eql(u8, h.label, pfx)) {
                self.context.followLink(h.target);
                self.context.changeMode(.view);
                return;
            }
        }

        var any_match = false;
        for (self.hints.items) |h| {
            if (h.label.len >= pfx.len and std.mem.startsWith(u8, h.label, pfx)) {
                any_match = true;
                break;
            }
        }
        if (!any_match) self.context.changeMode(.view);
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const hint_color = vaxis.Cell.Style{
        .fg = .{ .rgb = .{ 220, 20, 60 } },
        .bold = true,
    };
    for (self.hints.items) |h| {
        var matched = true;
        if (self.prefix.items.len > 0) {
            if (h.label.len < self.prefix.items.len) matched = false;
            if (matched and !std.mem.startsWith(u8, h.label, self.prefix.items)) matched = false;
        }
        if (!matched) continue;
        for (h.positions.items) |pos| {
            if (pos.cell_row >= win.height or pos.cell_col >= win.width) continue;
            _ = win.print(
                &.{
                    .{ .text = "\u{2588}", .style = hint_color },
                    .{ .text = h.label, .style = hint_color },
                    .{ .text = "\u{2588}", .style = hint_color },
                },
                .{ .row_offset = pos.cell_row, .col_offset = pos.cell_col },
            );
        }
    }
}
