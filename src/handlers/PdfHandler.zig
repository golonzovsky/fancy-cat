const Self = @This();
const std = @import("std");
const fastb64z = @import("fastb64z");
const vaxis = @import("vaxis");
const Config = @import("../config/Config.zig");
const types = @import("./types.zig");
const Utilities = @import("../utilities/Utilities.zig");

const c = @cImport({
    @cInclude("fitz-z.h");
    @cInclude("mupdf/fitz.h");
    @cInclude("mupdf/pdf.h");
});

allocator: std.mem.Allocator,
ctx: [*c]c.fz_context,
doc: [*c]c.fz_document,
total_pages: u16,
path: []const u8,
active_zoom: f32,
default_zoom: f32,
width_mode: bool,
pix_scroll_x: i32,
pix_scroll_y: i32,
rendered_w: u32,
rendered_h: u32,
last_viewport_w: u32,
last_viewport_h: u32,
pending_snap: ?enum { top, bottom },
config: *Config,

pub fn init(
    allocator: std.mem.Allocator,
    path: []const u8,
    config: *Config,
) !Self {
    const ctx = c.fz_new_context(null, null, c.FZ_STORE_UNLIMITED) orelse {
        std.debug.print("Failed to create mupdf context\n", .{});
        return types.DocumentError.FailedToCreateContext;
    };
    errdefer c.fz_drop_context(ctx);

    c.fz_register_document_handlers(ctx);
    c.fz_set_error_callback(ctx, null, null);
    c.fz_set_warning_callback(ctx, null, null);

    const doc = c.fz_open_document_z(ctx, path.ptr) orelse {
        const err_msg = c.fz_caught_message(ctx);
        std.debug.print("Failed to open document: {s}\n", .{err_msg});
        return types.DocumentError.FailedToOpenDocument;
    };
    errdefer c.fz_drop_document(ctx, doc);

    const total_pages = @as(u16, @intCast(c.fz_count_pages(ctx, doc)));

    return .{
        .allocator = allocator,
        .ctx = ctx,
        .doc = doc,
        .total_pages = total_pages,
        .path = path,
        .active_zoom = 0,
        .default_zoom = 0,
        .width_mode = false,
        .pix_scroll_x = 0,
        .pix_scroll_y = 0,
        .rendered_w = 0,
        .rendered_h = 0,
        .last_viewport_w = 0,
        .last_viewport_h = 0,
        .pending_snap = null,
        .config = config,
    };
}

pub fn deinit(self: *Self) void {
    c.fz_drop_document(self.ctx, self.doc);
    c.fz_drop_context(self.ctx);
}

pub fn reloadDocument(self: *Self) !void {
    const retry_delay = @as(u64, @intFromFloat(self.config.general.retry_delay * @as(f64, std.time.ns_per_s)));
    const timeout = @as(i64, @intFromFloat(self.config.general.timeout * @as(f64, std.time.ms_per_s)));
    const start_time = std.time.milliTimestamp();

    while (true) {
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout) {
            std.debug.print("Failed to reload document\n", .{});
            return types.DocumentError.FailedToOpenDocument;
        }

        if (self.doc) |doc| {
            c.fz_drop_document(self.ctx, doc);
            self.doc = null;
        }

        const doc = c.fz_open_document_z(self.ctx, self.path.ptr) orelse {
            std.Thread.sleep(retry_delay);
            continue; // try again
        };
        self.doc = doc;

        const page_count = c.fz_count_pages_z(self.ctx, self.doc);
        if (page_count == 0) {
            std.Thread.sleep(retry_delay);
            continue; // try again
        }
        self.total_pages = @as(u16, @intCast(page_count));
        return;
    }
}

fn calculateZoomLevel(self: *Self, window_width: u32, window_height: u32, bound: c.fz_rect) void {
    var scale: f32 = 0;
    if (self.width_mode) {
        scale = @as(f32, @floatFromInt(window_width)) / bound.x1;
    } else {
        scale = @min(
            @as(f32, @floatFromInt(window_width)) / bound.x1,
            @as(f32, @floatFromInt(window_height)) / bound.y1,
        );
    }

    // initial zoom
    if (self.default_zoom == 0) {
        self.default_zoom = scale * self.config.general.size;
    }

    if (self.active_zoom == 0) {
        self.active_zoom = self.default_zoom;
    }

    self.active_zoom = @max(self.active_zoom, self.config.general.zoom_min);
}

pub fn renderPage(
    self: *Self,
    page_number: u16,
    window_width: u32,
    window_height: u32,
) !types.EncodedImage {
    const retry_delay = @as(u64, @intFromFloat(self.config.general.retry_delay * @as(f64, std.time.ns_per_s)));
    const timeout = @as(i64, @intFromFloat(self.config.general.timeout * @as(f64, std.time.ms_per_s)));
    const start_time = std.time.milliTimestamp();

    while (true) {
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout) {
            std.debug.print("Failed to render page\n", .{});
            return types.DocumentError.FailedToRenderPage;
        }

        const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse {
            std.Thread.sleep(retry_delay);
            continue;
        };
        defer c.fz_drop_page(self.ctx, page);
        const bound = c.fz_bound_page(self.ctx, page);

        self.calculateZoomLevel(window_width, window_height, bound);

        const full_w = @max(1.0, self.active_zoom * bound.x1);
        const full_h = @max(1.0, self.active_zoom * bound.y1);

        const bbox = c.fz_make_irect(0, 0, @intFromFloat(full_w), @intFromFloat(full_h));
        const pix = c.fz_new_pixmap_with_bbox(self.ctx, c.fz_device_rgb(self.ctx), bbox, null, 0);
        defer c.fz_drop_pixmap(self.ctx, pix);
        c.fz_clear_pixmap_with_value(self.ctx, pix, 0xFF);

        const ctm = c.fz_scale(self.active_zoom, self.active_zoom);

        const dev = c.fz_new_draw_device(self.ctx, ctm, pix);
        defer c.fz_drop_device(self.ctx, dev);
        c.fz_run_page(self.ctx, page, dev, c.fz_identity, null);
        c.fz_close_device(self.ctx, dev);

        if (self.config.general.colorize) {
            c.fz_tint_pixmap(self.ctx, pix, self.config.general.black, self.config.general.white);
        }

        const width = @as(usize, @intCast(@abs(bbox.x1)));
        const height = @as(usize, @intCast(@abs(bbox.y1)));
        const samples = c.fz_pixmap_samples(self.ctx, pix);

        const base64Encoder = fastb64z.standard.Encoder;
        const sample_count = width * height * 3;

        const b64_buf = try self.allocator.alloc(u8, base64Encoder.calcSize(sample_count));
        const encoded = base64Encoder.encode(b64_buf, samples[0..sample_count]);

        self.rendered_w = @intCast(width);
        self.rendered_h = @intCast(height);
        self.last_viewport_w = window_width;
        self.last_viewport_h = window_height;
        self.applyPendingSnap();
        self.clampScroll(window_width, window_height);

        return types.EncodedImage{
            .base64 = encoded,
            .width = @as(u16, @intCast(width)),
            .height = @as(u16, @intCast(height)),
        };
    }
}

fn maxScrollX(self: *const Self, viewport_w: u32) i32 {
    if (self.rendered_w > viewport_w) return @intCast(self.rendered_w - viewport_w);
    return 0;
}

fn maxScrollY(self: *const Self, viewport_h: u32) i32 {
    if (self.rendered_h > viewport_h) return @intCast(self.rendered_h - viewport_h);
    return 0;
}

pub fn clampScroll(self: *Self, viewport_w: u32, viewport_h: u32) void {
    self.pix_scroll_x = @max(0, @min(self.maxScrollX(viewport_w), self.pix_scroll_x));
    self.pix_scroll_y = @max(0, @min(self.maxScrollY(viewport_h), self.pix_scroll_y));
}

fn applyPendingSnap(self: *Self) void {
    if (self.pending_snap) |snap| {
        switch (snap) {
            .top => self.pix_scroll_y = 0,
            .bottom => self.pix_scroll_y = self.maxScrollY(self.last_viewport_h),
        }
        self.pending_snap = null;
    }
}

pub fn zoomIn(self: *Self) void {
    const old_zoom = self.active_zoom;
    self.active_zoom *= self.config.general.zoom_step;
    self.rescaleScroll(old_zoom);
}

pub fn zoomOut(self: *Self) void {
    const old_zoom = self.active_zoom;
    self.active_zoom /= self.config.general.zoom_step;
    self.rescaleScroll(old_zoom);
}

fn rescaleScroll(self: *Self, old_zoom: f32) void {
    if (old_zoom == 0 or self.active_zoom == 0) return;
    const ratio = self.active_zoom / old_zoom;
    self.pix_scroll_x = @intFromFloat(@as(f32, @floatFromInt(self.pix_scroll_x)) * ratio);
    self.pix_scroll_y = @intFromFloat(@as(f32, @floatFromInt(self.pix_scroll_y)) * ratio);
}

pub fn setZoom(self: *Self, percent: f32) void {
    var dpi = self.config.general.dpi;
    if (self.config.general.detect_dpi) dpi = Utilities.getDPI() orelse dpi;

    self.active_zoom = @max(percent * dpi / 7200.0, self.config.general.zoom_min);
}

pub fn toggleColor(self: *Self) void {
    self.config.general.colorize = !self.config.general.colorize;
}

pub fn scroll(self: *Self, direction: types.ScrollDirection) void {
    const step: i32 = @intFromFloat(self.config.general.scroll_step);
    switch (direction) {
        .Up => self.pix_scroll_y -= step,
        .Down => self.pix_scroll_y += step,
        .Left => self.pix_scroll_x -= step,
        .Right => self.pix_scroll_x += step,
    }
    self.clampScroll(self.last_viewport_w, self.last_viewport_h);
}

pub fn offsetScroll(self: *Self, dx: f32, dy: f32) void {
    // dx > 0 reveals right (scrolls viewport right). dy > 0 reveals top (scrolls viewport up).
    self.pix_scroll_x += @intFromFloat(dx);
    self.pix_scroll_y -= @intFromFloat(dy);
    self.clampScroll(self.last_viewport_w, self.last_viewport_h);
}

pub const VerticalScrollResult = enum { scrolled, hit_top, hit_bottom };

pub fn tryScrollY(self: *Self, dy: f32) VerticalScrollResult {
    // dy > 0: viewport moves up (reveals top); dy < 0: viewport moves down (reveals bottom).
    if (self.rendered_h == 0) {
        self.pix_scroll_y -= @intFromFloat(dy);
        return .scrolled;
    }
    const max_y = self.maxScrollY(self.last_viewport_h);
    if (dy < 0 and self.pix_scroll_y >= max_y) return .hit_bottom;
    if (dy > 0 and self.pix_scroll_y <= 0) return .hit_top;
    self.pix_scroll_y -= @intFromFloat(dy);
    self.pix_scroll_y = @max(0, @min(max_y, self.pix_scroll_y));
    return .scrolled;
}

pub fn snapToTop(self: *Self) void {
    self.pending_snap = .top;
    self.pix_scroll_y = 0;
}

pub fn snapToBottom(self: *Self) void {
    self.pending_snap = .bottom;
}

pub fn resetDefaultZoom(self: *Self) void {
    self.default_zoom = 0;
}

pub fn resetZoomAndScroll(self: *Self) void {
    self.active_zoom = self.default_zoom;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

pub fn toggleWidthMode(self: *Self) void {
    self.default_zoom = 0;
    self.active_zoom = 0;
    self.width_mode = !self.width_mode;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

pub fn getWidthMode(self: *Self) bool {
    return self.width_mode;
}
