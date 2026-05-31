const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");
const PdfHandler = @import("./PdfHandler.zig");
const types = @import("./types.zig");

pub const FileFormat = enum {
    pdf,

    pub fn fromPath(path: []const u8) !FileFormat {
        if (std.mem.endsWith(u8, path, ".pdf")) {
            return .pdf;
        }
        return types.DocumentError.UnsupportedFileFormat;
    }
};

pdf_handler: PdfHandler,
current_page_number: u16,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    initial_page: ?u16,
    config: *Config,
) !Self {
    _ = try FileFormat.fromPath(path); // validate extension; only PDF supported

    var pdf_handler = try PdfHandler.init(allocator, io, path, config);
    errdefer pdf_handler.deinit();

    const current_page_number = if (initial_page) |page| blk: {
        if (page < 1 or page > pdf_handler.total_pages) {
            return types.DocumentError.InvalidPageNumber;
        }
        break :blk page - 1;
    } else 0;

    return .{
        .pdf_handler = pdf_handler,
        .current_page_number = current_page_number,
    };
}

pub fn deinit(self: *Self) void {
    self.pdf_handler.deinit();
}

pub fn reloadDocument(self: *Self) !void {
    try self.pdf_handler.reloadDocument();
    if (self.current_page_number >= self.pdf_handler.total_pages) {
        self.current_page_number = self.pdf_handler.total_pages - 1;
    }
}

pub fn renderPage(
    self: *Self,
    page_number: u16,
    window_width: u32,
    window_height: u32,
) !types.EncodedImage {
    return try self.pdf_handler.renderPage(page_number, window_width, window_height);
}

pub fn zoomIn(self: *Self) void {
    self.pdf_handler.zoomIn();
}

pub fn zoomOut(self: *Self) void {
    self.pdf_handler.zoomOut();
}

pub fn setZoom(self: *Self, percent: f32) void {
    self.pdf_handler.setZoom(percent);
}

pub fn toggleColor(self: *Self) void {
    self.pdf_handler.toggleColor();
}

pub fn scroll(self: *Self, direction: types.ScrollDirection) void {
    self.pdf_handler.scroll(direction);
}

pub fn offsetScroll(self: *Self, dx: f32, dy: f32) void {
    self.pdf_handler.offsetScroll(dx, dy);
}

pub fn scrollY(self: *Self, dy: f32) void {
    self.pdf_handler.pix_scroll_y -= @intFromFloat(dy);
}

pub fn clampScrollX(self: *Self, viewport_w: u32) void {
    self.pdf_handler.clampScrollX(viewport_w);
}

pub fn setScrollY(self: *Self, y: i32) void {
    self.pdf_handler.pix_scroll_y = y;
}

pub fn setScrollX(self: *Self, x: i32) void {
    self.pdf_handler.pix_scroll_x = x;
}

pub fn setActiveZoom(self: *Self, zoom: f32) void {
    self.pdf_handler.active_zoom = zoom;
}

pub fn setPendingScrollPdfY(self: *Self, y: f32) void {
    self.pdf_handler.pending_scroll_pdf_y = y;
}

pub fn takePendingScrollPdfY(self: *Self) ?f32 {
    const y = self.pdf_handler.pending_scroll_pdf_y;
    self.pdf_handler.pending_scroll_pdf_y = null;
    return y;
}

pub fn setOddShiftX(self: *Self, x: i32) void {
    self.pdf_handler.odd_shift_x = x;
}

pub fn getOddShiftX(self: *Self) i32 {
    return self.pdf_handler.odd_shift_x;
}

pub fn setCurrentPage(self: *Self, page: u16) void {
    self.current_page_number = page;
}

pub fn findLinkAtPoint(
    self: *Self,
    allocator: std.mem.Allocator,
    page_number: u16,
    pdf_x: f32,
    pdf_y: f32,
) ?PdfHandler.LinkTarget {
    return self.pdf_handler.findLinkAtPoint(allocator, page_number, pdf_x, pdf_y);
}

pub fn getDocumentKey(self: *Self, allocator: std.mem.Allocator) ![]u8 {
    return self.pdf_handler.getDocumentKey(allocator);
}

pub fn loadLinks(self: *Self, allocator: std.mem.Allocator, page_number: u16) ![]PdfHandler.PageLink {
    return self.pdf_handler.loadLinks(allocator, page_number);
}

pub fn loadOutline(self: *Self, allocator: std.mem.Allocator) ![]PdfHandler.OutlineEntry {
    return self.pdf_handler.loadOutline(allocator);
}

pub fn writePageText(self: *Self, page_number: u16, path: [:0]const u8) !void {
    return self.pdf_handler.writePageText(page_number, path);
}

pub fn writePagesText(
    self: *Self,
    start_page: u16,
    end_page: u16,
    path: [:0]const u8,
    on_progress: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void,
    progress_userdata: ?*anyopaque,
) !void {
    return self.pdf_handler.writePagesText(start_page, end_page, path, on_progress, progress_userdata);
}

pub fn resetDefaultZoom(self: *Self) void {
    self.pdf_handler.resetDefaultZoom();
}

pub fn toggleWidthMode(self: *Self) void {
    self.pdf_handler.toggleWidthMode();
}

pub fn toggleCropToContent(self: *Self) void {
    self.pdf_handler.toggleCropToContent();
}

pub fn getCropToContent(self: *Self) bool {
    return self.pdf_handler.crop_to_content;
}

pub fn goToPage(self: *Self, page_num: u16) bool {
    if (page_num >= 1 and page_num <= self.getTotalPages() and page_num != self.current_page_number + 1) {
        self.current_page_number = @as(u16, @intCast(page_num)) - 1;
        return true;
    }
    return false;
}

pub fn changePage(self: *Self, delta: i32) bool {
    const new_page = @as(i32, @intCast(self.current_page_number)) + delta;

    if (new_page >= 0 and new_page < self.getTotalPages()) {
        self.current_page_number = @as(u16, @intCast(new_page));
        return true;
    }
    return false;
}

// getters

pub fn getWidthMode(self: *Self) bool {
    return self.pdf_handler.getWidthMode();
}

pub fn getCurrentPageNumber(self: *Self) u16 {
    return self.current_page_number;
}

pub fn getPath(self: *Self) []const u8 {
    return self.pdf_handler.path;
}

pub fn getTotalPages(self: *Self) u16 {
    return self.pdf_handler.total_pages;
}

pub fn getActiveZoom(self: *Self) f32 {
    return self.pdf_handler.active_zoom;
}

pub fn getScrollX(self: *Self) i32 {
    return self.pdf_handler.pix_scroll_x;
}

pub fn getScrollY(self: *Self) i32 {
    return self.pdf_handler.pix_scroll_y;
}
