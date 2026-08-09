const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const PagePoint = @import("../Context.zig").PagePoint;
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");

const Side = enum { left, right, top, bottom };
const min_gap: f32 = 24; // pt kept between opposite crop lines

context: *Context,
left: f32,
right: f32,
top: f32,
bottom: f32,
prev: [4]f32, // L R T B at entry, restored on cancel
prev_auto: bool,
cleared: bool, // init un-cropped the document; deinit must undo that
applied: bool,
drag: ?Side,
drag_bound: PdfHandler.PageBound,

pub fn init(context: *Context) Self {
    const dh = &context.document_handler;
    var self = Self{
        .context = context,
        .left = 0,
        .right = 0,
        .top = 0,
        .bottom = 0,
        .prev = .{ dh.crop_left, dh.crop_right, dh.crop_top, dh.crop_bottom },
        .prev_auto = dh.getCropToContent(),
        .cleared = false,
        .applied = false,
        .drag = null,
        .drag_bound = undefined,
    };
    // Seed the lines from the effective crop (manual margins or the
    // content-crop equivalent), then display the full page while adjusting.
    if (dh.cropInfo()) |ci| {
        self.left = ci.left;
        self.right = ci.right;
        self.top = ci.top;
        self.bottom = ci.bottom;
    }
    self.cleared = self.prev_auto or self.left != 0 or self.right != 0 or self.top != 0 or self.bottom != 0;
    if (self.cleared) {
        if (self.prev_auto) dh.toggleCropToContent();
        dh.setMarginCrop(0, 0, 0, 0);
        context.clearCache();
        context.resetCurrentPage();
    }
    context.progress_text = " crop: drag lines · enter apply · esc cancel ";
    return self;
}

pub fn deinit(self: *Self) void {
    const dh = &self.context.document_handler;
    if (!self.applied and self.cleared) {
        dh.setMarginCrop(self.prev[0], self.prev[1], self.prev[2], self.prev[3]);
        if (self.prev_auto) dh.toggleCropToContent();
        self.context.clearCache();
        self.context.resetCurrentPage();
    }
    self.context.progress_text = null;
}

fn apply(self: *Self) void {
    const dh = &self.context.document_handler;
    self.applied = true;
    const unchanged = !self.prev_auto and self.left == self.prev[0] and self.right == self.prev[1] and
        self.top == self.prev[2] and self.bottom == self.prev[3];
    if (!unchanged or self.cleared) {
        dh.setMarginCrop(self.left, self.right, self.top, self.bottom);
        self.context.clearCache();
        self.context.resetCurrentPage();
    }
    self.context.changeMode(.view);
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
        self.context.changeMode(.view);
        return;
    }
    if (key.matches(km.execute_command.codepoint, km.execute_command.mods) or
        key.matches(km.crop_mode.codepoint, km.crop_mode.mods))
    {
        self.apply();
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    const ctx = self.context;
    switch (mouse.type) {
        .press => switch (mouse.button) {
            .wheel_up => ctx.document_handler.scrollY(ctx.config.general.scroll_step / 4.0),
            .wheel_down => ctx.document_handler.scrollY(-ctx.config.general.scroll_step / 4.0),
            .left => {
                const pt = ctx.pdfPointAt(mouse) orelse return;
                self.drag_bound = ctx.document_handler.getPageBound(pt.page);
                self.drag = self.nearestSide(pt);
                self.moveTo(pt);
            },
            else => {},
        },
        .drag => {
            if (mouse.button != .left or self.drag == null) return;
            const pt = ctx.pdfPointAt(mouse) orelse return;
            self.drag_bound = ctx.document_handler.getPageBound(pt.page);
            self.moveTo(pt);
        },
        .release => self.drag = null,
        else => {},
    }
}

fn nearestSide(self: *Self, pt: PagePoint) Side {
    const b = self.drag_bound;
    var side: Side = .left;
    var best = @abs(pt.x - (b.x0 + self.left));
    const dr = @abs((b.x1 - self.right) - pt.x);
    if (dr < best) {
        side = .right;
        best = dr;
    }
    const dt = @abs(pt.y - (b.y0 + self.top));
    if (dt < best) {
        side = .top;
        best = dt;
    }
    const db = @abs((b.y1 - self.bottom) - pt.y);
    if (db < best) side = .bottom;
    return side;
}

fn moveTo(self: *Self, pt: PagePoint) void {
    const b = self.drag_bound;
    const w = b.x1 - b.x0;
    const h = b.y1 - b.y0;
    switch (self.drag orelse return) {
        .left => self.left = std.math.clamp(pt.x - b.x0, 0, @max(0, w - self.right - min_gap)),
        .right => self.right = std.math.clamp(b.x1 - pt.x, 0, @max(0, w - self.left - min_gap)),
        .top => self.top = std.math.clamp(pt.y - b.y0, 0, @max(0, h - self.bottom - min_gap)),
        .bottom => self.bottom = std.math.clamp(b.y1 - pt.y, 0, @max(0, h - self.top - min_gap)),
    }
    self.context.progress_text = std.fmt.bufPrint(
        &self.context.progress_buf,
        " crop {d:.0} {d:.0} {d:.0} {d:.0} (TRBL) · enter apply · esc cancel ",
        .{ self.top, self.right, self.bottom, self.left },
    ) catch null;
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const ctx = self.context;
    const dh = &ctx.document_handler;
    const zoom = dh.getActiveZoom();
    if (zoom == 0) return;
    const ppc: f32 = @floatFromInt(ctx.last_pix_per_col);
    const ppr: f32 = @floatFromInt(ctx.last_pix_per_row);

    const dim: vaxis.Cell = .{ .char = .{ .grapheme = "░", .width = 1 }, .style = .{ .fg = .{ .index = 8 } } };
    const line_style: vaxis.Cell.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    const drag_style: vaxis.Cell.Style = .{ .fg = .{ .index = 11 }, .bold = true };

    for (ctx.visible_pages[0..ctx.visible_pages_len]) |p| {
        const b = dh.getPageBound(p.page_num);
        if (b.x1 <= b.x0 or b.y1 <= b.y0) continue;
        const shift: f32 = if (p.page_num % 2 == 1) @floatFromInt(dh.getOddShiftX()) else 0;

        // Crop-line positions in viewport pixels (may fall outside this segment).
        const vx0: f32 = @floatFromInt(p.vp_x_left);
        const vy0: f32 = @floatFromInt(p.vp_y_top);
        const lx = vx0 + ((b.x0 + self.left + shift) - p.origin_x) * zoom - @as(f32, @floatFromInt(p.clip_x));
        const rx = vx0 + ((b.x1 - self.right + shift) - p.origin_x) * zoom - @as(f32, @floatFromInt(p.clip_x));
        const ty = vy0 + ((b.y0 + self.top) - p.origin_y) * zoom - @as(f32, @floatFromInt(p.clip_y));
        const by = vy0 + ((b.y1 - self.bottom) - p.origin_y) * zoom - @as(f32, @floatFromInt(p.clip_y));

        // Right/bottom use the last pixel inside the crop, so a zero margin
        // lands on the page's edge cell instead of one past it.
        const col_l: i32 = @intFromFloat(@floor(lx / ppc));
        const col_r: i32 = @intFromFloat(@floor((rx - 1) / ppc));
        const row_t: i32 = @intFromFloat(@floor(ty / ppr));
        const row_b: i32 = @intFromFloat(@floor((by - 1) / ppr));

        const c0: i32 = @intCast(p.vp_x_left / ctx.last_pix_per_col);
        const c1: i32 = @intCast((p.vp_x_right - 1) / ctx.last_pix_per_col);
        const r0: i32 = @intCast(p.vp_y_top / ctx.last_pix_per_row);
        const r1: i32 = @intCast((p.vp_y_bot - 1) / ctx.last_pix_per_row);

        var row: i32 = r0;
        while (row <= r1) : (row += 1) {
            var col: i32 = c0;
            while (col <= c1) : (col += 1) {
                const on_h = (row == row_t or row == row_b) and col >= col_l and col <= col_r;
                const on_v = (col == col_l or col == col_r) and row >= row_t and row <= row_b;
                var cell: ?vaxis.Cell = null;
                if (on_h or on_v) {
                    const g: []const u8 = if (on_h and on_v)
                        (if (row == row_t)
                            (if (col == col_l) "┌" else "┐")
                        else
                            (if (col == col_l) "└" else "┘"))
                    else if (on_h) "─" else "│";
                    var st = line_style;
                    if (self.drag) |d| {
                        const active = switch (d) {
                            .top => on_h and row == row_t,
                            .bottom => on_h and row == row_b,
                            .left => on_v and col == col_l,
                            .right => on_v and col == col_r,
                        };
                        if (active) st = drag_style;
                    }
                    cell = .{ .char = .{ .grapheme = g, .width = 1 }, .style = st };
                } else if (col < col_l or col > col_r or row < row_t or row > row_b) {
                    cell = dim;
                }
                if (cell) |cl| {
                    if (row >= 0 and col >= 0 and row < win.height and col < win.width) {
                        const ucol: u16 = @intCast(col);
                        const urow: u16 = @intCast(row);
                        var out = cl;
                        // The kitty placement lives in one anchor cell (the
                        // page's top-left); overwriting it would hide the page.
                        if (win.readCell(ucol, urow)) |existing| out.image = existing.image;
                        win.writeCell(ucol, urow, out);
                    }
                }
            }
        }
    }
}
