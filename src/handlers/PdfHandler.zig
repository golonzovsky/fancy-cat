const Self = @This();
const std = @import("std");
const fastb64z = @import("fastb64z");
const vaxis = @import("vaxis");
const Config = @import("../config/Config.zig");
const types = @import("./types.zig");
const Utilities = @import("../utilities/Utilities.zig");
const Markdown = @import("./Markdown.zig");

const c = @cImport({
    @cInclude("fitz-z.h");
    @cInclude("mupdf/fitz.h");
    @cInclude("mupdf/pdf.h");
});

const time_compat = struct {
    pub const timespec = extern struct { tv_sec: c_long, tv_nsec: c_long };
    pub extern "c" fn clock_gettime(clk: c_int, ts: *timespec) c_int;
    pub extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;
    const CLOCK_MONOTONIC: c_int = 6;
    pub fn milliTimestamp() i64 {
        var ts: timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        return @as(i64, ts.tv_sec) * std.time.ms_per_s + @divTrunc(@as(i64, ts.tv_nsec), std.time.ns_per_ms);
    }
    pub fn sleep(ns: u64) void {
        var req = timespec{ .tv_sec = @intCast(ns / std.time.ns_per_s), .tv_nsec = @intCast(ns % std.time.ns_per_s) };
        _ = nanosleep(&req, null);
    }
};

allocator: std.mem.Allocator,
io: std.Io,
ctx: [*c]c.fz_context,
doc: [*c]c.fz_document,
total_pages: u16,
path: []const u8,
active_zoom: f32,
default_zoom: f32,
width_mode: bool,
crop_to_content: bool,
crop_margin: f32,
odd_shift_x: i32,
pending_scroll_pdf_y: ?f32,
pix_scroll_x: i32,
pix_scroll_y: i32,
rendered_w: u32,
rendered_h: u32,
last_viewport_w: u32,
last_viewport_h: u32,
config: *Config,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
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
        .io = io,
        .ctx = ctx,
        .doc = doc,
        .total_pages = total_pages,
        .path = path,
        .active_zoom = 0,
        .default_zoom = 0,
        .width_mode = false,
        .crop_to_content = false,
        .crop_margin = 4,
        .odd_shift_x = 0,
        .pending_scroll_pdf_y = null,
        .pix_scroll_x = 0,
        .pix_scroll_y = 0,
        .rendered_w = 0,
        .rendered_h = 0,
        .last_viewport_w = 0,
        .last_viewport_h = 0,
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
    const start_time = time_compat.milliTimestamp();

    while (true) {
        const now = time_compat.milliTimestamp();
        if (now - start_time > timeout) {
            std.debug.print("Failed to reload document\n", .{});
            return types.DocumentError.FailedToOpenDocument;
        }

        if (self.doc) |doc| {
            c.fz_drop_document(self.ctx, doc);
            self.doc = null;
        }

        const doc = c.fz_open_document_z(self.ctx, self.path.ptr) orelse {
            time_compat.sleep(retry_delay);
            continue; // try again
        };
        self.doc = doc;

        const page_count = c.fz_count_pages_z(self.ctx, self.doc);
        if (page_count == 0) {
            time_compat.sleep(retry_delay);
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
    const start_time = time_compat.milliTimestamp();

    while (true) {
        const now = time_compat.milliTimestamp();
        if (now - start_time > timeout) {
            std.debug.print("Failed to render page\n", .{});
            return types.DocumentError.FailedToRenderPage;
        }

        const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse {
            time_compat.sleep(retry_delay);
            continue;
        };
        defer c.fz_drop_page(self.ctx, page);
        const page_bound = c.fz_bound_page(self.ctx, page);

        var render_bound = page_bound;
        var origin_x: f32 = 0;
        var origin_y: f32 = 0;
        if (self.crop_to_content) {
            var content_bbox: c.fz_rect = undefined;
            if (c.fz_page_content_bbox_z(self.ctx, page, &content_bbox) != 0) {
                const m = self.crop_margin;
                content_bbox.x0 = @max(page_bound.x0, content_bbox.x0 - m);
                content_bbox.y0 = @max(page_bound.y0, content_bbox.y0 - m);
                content_bbox.x1 = @min(page_bound.x1, content_bbox.x1 + m);
                content_bbox.y1 = @min(page_bound.y1, content_bbox.y1 + m);
                if (content_bbox.x1 > content_bbox.x0 and content_bbox.y1 > content_bbox.y0) {
                    render_bound = content_bbox;
                    origin_x = content_bbox.x0;
                    origin_y = content_bbox.y0;
                }
            }
        }

        const render_w_pdf = render_bound.x1 - render_bound.x0;
        const render_h_pdf = render_bound.y1 - render_bound.y0;
        self.calculateZoomLevel(window_width, window_height, c.fz_make_rect(0, 0, render_w_pdf, render_h_pdf));

        const full_w = @max(1.0, self.active_zoom * render_w_pdf);
        const full_h = @max(1.0, self.active_zoom * render_h_pdf);

        const bbox = c.fz_make_irect(0, 0, @intFromFloat(full_w), @intFromFloat(full_h));
        const pix = c.fz_new_pixmap_with_bbox(self.ctx, c.fz_device_rgb(self.ctx), bbox, null, 0);
        defer c.fz_drop_pixmap(self.ctx, pix);
        c.fz_clear_pixmap_with_value(self.ctx, pix, 0xFF);

        var ctm = c.fz_scale(self.active_zoom, self.active_zoom);
        const shift_pdf: f32 = if (page_number % 2 == 1 and self.active_zoom > 0)
            @as(f32, @floatFromInt(self.odd_shift_x)) / self.active_zoom
        else
            0;
        ctm = c.fz_pre_translate(ctm, -origin_x + shift_pdf, -origin_y);

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

        return types.EncodedImage{
            .base64 = encoded,
            .width = @as(u16, @intCast(width)),
            .height = @as(u16, @intCast(height)),
            .origin_x = origin_x,
            .origin_y = origin_y,
        };
    }
}

pub fn toggleCropToContent(self: *Self) void {
    self.crop_to_content = !self.crop_to_content;
    self.default_zoom = 0;
    self.active_zoom = 0;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

fn maxScrollX(self: *const Self, viewport_w: u32) i32 {
    if (self.rendered_w > viewport_w) return @intCast(self.rendered_w - viewport_w);
    return 0;
}

fn maxScrollY(self: *const Self, viewport_h: u32) i32 {
    if (self.rendered_h > viewport_h) return @intCast(self.rendered_h - viewport_h);
    return 0;
}

pub fn clampScrollX(self: *Self, viewport_w: u32) void {
    self.pix_scroll_x = @max(0, @min(self.maxScrollX(viewport_w), self.pix_scroll_x));
}

pub fn currentMaxScrollY(self: *const Self, viewport_h: u32) i32 {
    return self.maxScrollY(viewport_h);
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
    self.clampScrollX(self.last_viewport_w);
}

pub fn offsetScroll(self: *Self, dx: f32, dy: f32) void {
    // dx > 0 reveals right; dy > 0 reveals top (pix_scroll_y decreases).
    self.pix_scroll_x += @intFromFloat(dx);
    self.pix_scroll_y -= @intFromFloat(dy);
    self.clampScrollX(self.last_viewport_w);
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

pub const PageTarget = struct { num: u16, y: f32 };

pub const LinkTarget = union(enum) {
    page: PageTarget,
    uri: []u8, // owned; caller frees with allocator passed to findLinkAtPoint
};

pub const PageLink = struct {
    rect: c.fz_rect,
    target: LinkTarget,
};

pub const OutlineEntry = struct {
    title: []u8,
    depth: u8,
    page: u16,
    y: f32,
};

const VisitData = struct {
    self: *Self,
    out: *std.ArrayList(OutlineEntry),
    allocator: std.mem.Allocator,
    failed: bool,
};

fn outlineVisitCb(userdata: ?*anyopaque, title: [*c]const u8, depth: c_int, uri: [*c]const u8) callconv(.c) void {
    const data = @as(*VisitData, @ptrCast(@alignCast(userdata.?)));
    if (data.failed) return;
    const title_len: usize = if (title != null) std.mem.len(title) else 0;
    const uri_len: usize = if (uri != null) std.mem.len(uri) else 0;

    var page: u16 = 0;
    var y: f32 = 0;
    if (uri != null and uri_len > 0) {
        const resolved = c.fz_resolve_link_target_z(data.self.ctx, data.self.doc, uri, &y);
        if (resolved >= 0 and resolved < data.self.total_pages) {
            page = @intCast(resolved);
        }
    }
    const title_src: []const u8 = if (title != null) title[0..title_len] else "";
    const title_dup = data.allocator.dupe(u8, title_src) catch {
        data.failed = true;
        return;
    };
    data.out.append(data.allocator, .{
        .title = title_dup,
        .depth = @intCast(@min(depth, 255)),
        .page = page,
        .y = y,
    }) catch {
        data.allocator.free(title_dup);
        data.failed = true;
    };
}

pub fn loadOutline(self: *Self, allocator: std.mem.Allocator) ![]OutlineEntry {
    var out: std.ArrayList(OutlineEntry) = .empty;
    errdefer {
        for (out.items) |e| allocator.free(e.title);
        out.deinit(allocator);
    }
    var data = VisitData{ .self = self, .out = &out, .allocator = allocator, .failed = false };
    c.fz_walk_outline_z(self.ctx, self.doc, &data, outlineVisitCb);
    if (data.failed) return error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

pub fn loadLinks(self: *Self, allocator: std.mem.Allocator, page_number: u16) ![]PageLink {
    var out: std.ArrayList(PageLink) = .empty;
    errdefer {
        for (out.items) |item| switch (item.target) {
            .uri => |u| allocator.free(u),
            .page => {},
        };
        out.deinit(allocator);
    }

    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse return out.toOwnedSlice(allocator);
    defer c.fz_drop_page(self.ctx, page);

    const links = c.fz_load_links_z(self.ctx, page) orelse return out.toOwnedSlice(allocator);
    defer c.fz_drop_link(self.ctx, links);

    var node: ?*c.fz_link = links;
    while (node) |link| : (node = link.next) {
        if (link.uri == null) continue;
        const uri_zlen = std.mem.len(link.uri);
        const uri_slice = link.uri[0..uri_zlen];

        var dest_y: f32 = 0;
        const target: LinkTarget = if (c.fz_is_external_link(self.ctx, link.uri) != 0) blk: {
            const owned = try allocator.dupe(u8, uri_slice);
            break :blk .{ .uri = owned };
        } else blk: {
            const resolved = c.fz_resolve_link_target_z(self.ctx, self.doc, link.uri, &dest_y);
            if (resolved < 0 or resolved >= self.total_pages) continue;
            break :blk .{ .page = .{ .num = @as(u16, @intCast(resolved)), .y = dest_y } };
        };

        try out.append(allocator, .{ .rect = link.rect, .target = target });
    }
    return out.toOwnedSlice(allocator);
}

pub fn getDocumentKey(self: *Self, allocator: std.mem.Allocator) ![]u8 {
    var id_buf: [256]u8 = undefined;
    const id_len = c.fz_pdf_id_hex_z(self.ctx, self.doc, &id_buf, id_buf.len);
    if (id_len > 0) {
        return std.fmt.allocPrint(allocator, "pdf-id:{s}", .{id_buf[0..@as(usize, @intCast(id_len))]});
    }

    if (std.Io.Dir.cwd().readFileAlloc(self.io, self.path, allocator, .limited(1024 * 1024))) |buf| {
        defer allocator.free(buf);
        if (buf.len > 0) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(buf[0..@min(buf.len, 1024 * 1024)], &digest, .{});
            var hex: [64]u8 = undefined;
            const hex_chars = "0123456789abcdef";
            for (digest, 0..) |b, i| {
                hex[2 * i] = hex_chars[b >> 4];
                hex[2 * i + 1] = hex_chars[b & 0xF];
            }
            return std.fmt.allocPrint(allocator, "sha256-1mb:{s}", .{hex});
        }
    } else |_| {}

    return std.fmt.allocPrint(allocator, "path:{s}", .{self.path});
}

pub fn findLinkAtPoint(
    self: *Self,
    allocator: std.mem.Allocator,
    page_number: u16,
    pdf_x: f32,
    pdf_y: f32,
) ?LinkTarget {
    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse return null;
    defer c.fz_drop_page(self.ctx, page);

    const links = c.fz_load_links_z(self.ctx, page) orelse return null;
    defer c.fz_drop_link(self.ctx, links);

    var node: ?*c.fz_link = links;
    while (node) |link| : (node = link.next) {
        const r = link.rect;
        if (pdf_x < r.x0 or pdf_x > r.x1 or pdf_y < r.y0 or pdf_y > r.y1) continue;
        if (link.uri == null) continue;
        const uri_zlen = std.mem.len(link.uri);
        const uri_slice = link.uri[0..uri_zlen];

        if (c.fz_is_external_link(self.ctx, link.uri) != 0) {
            const owned = allocator.dupe(u8, uri_slice) catch return null;
            return .{ .uri = owned };
        }
        var dest_y: f32 = 0;
        const resolved = c.fz_resolve_link_target_z(self.ctx, self.doc, link.uri, &dest_y);
        if (resolved < 0) continue;
        if (resolved >= self.total_pages) continue;
        return .{ .page = .{ .num = @as(u16, @intCast(resolved)), .y = dest_y } };
    }
    return null;
}

pub fn getWidthMode(self: *Self) bool {
    return self.width_mode;
}

fn extractEventBridge(ud: ?*anyopaque, kind: c_int, chars: [*c]const c.fz_char_z, n: c_int, str: [*c]const u8) callconv(.c) void {
    // Markdown.Char and fz_char_z have the same extern layout; pointer-cast across the FFI.
    const md_chars: ?[*]const Markdown.Char = if (chars != null) @ptrCast(chars) else null;
    const md_str: ?[*:0]const u8 = if (str != null) @ptrCast(str) else null;
    Markdown.eventCallback(ud, kind, md_chars, n, md_str);
}

pub fn writePageText(self: *Self, page_number: u16, path: [:0]const u8) !void {
    return self.writePagesText(page_number, page_number + 1, path, null, null);
}

pub fn writePagesText(
    self: *Self,
    start_page: u16,
    end_page: u16,
    path: [:0]const u8,
    on_progress: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void,
    progress_userdata: ?*anyopaque,
) !void {
    const black: c_int = if (self.config.general.colorize) @intCast(self.config.general.black) else 0x000000;
    const white: c_int = if (self.config.general.colorize) @intCast(self.config.general.white) else 0xffffff;
    const scale: f32 = if (self.active_zoom > 0) self.active_zoom else 4.0;

    var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
    defer file.close(self.io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(self.io, &buf);

    try fw.interface.writeAll("<!-- markdownlint-disable -->\n\n");

    var md = Markdown.init(self.allocator, &fw.interface);
    defer md.deinit();

    // Image dir = dirname(path).
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const image_dir = try self.allocator.dupeZ(u8, if (slash > 0) path[0..slash] else ".");
    defer self.allocator.free(image_dir);

    const rc = c.fz_extract_pages_z(
        self.ctx,
        self.doc,
        @as(c_int, @intCast(start_page)),
        @as(c_int, @intCast(end_page)),
        scale,
        black,
        white,
        image_dir.ptr,
        extractEventBridge,
        &md,
        on_progress,
        progress_userdata,
    );
    if (rc == 0) return types.DocumentError.FailedToRenderPage;
    try md.finalize();
    try fw.interface.flush();
    if (md.write_failed) return types.DocumentError.FailedToRenderPage;
}
