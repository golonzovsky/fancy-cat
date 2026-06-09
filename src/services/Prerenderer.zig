//! Background page prerenderer. A single worker thread renders neighbor pages
//! (mupdf + base64 — the expensive part) so page crossings hit the cache.
//! The kitty transmit must stay on the main thread: finished results are
//! parked here and the main loop claims them on the `prerender_ready` event.
const Self = @This();
const std = @import("std");
const Cache = @import("../Cache.zig");
const types = @import("../handlers/types.zig");
const Context = @import("../Context.zig").Context;

pub const Result = struct {
    key: Cache.Key,
    image: types.EncodedImage,
};

context: *Context,
thread: ?std.Thread,
mutex: std.Io.Mutex,
cond: std.Io.Condition,
quit: bool,
req_pages: [2]?u16,
req_w: u32,
req_h: u32,
has_req: bool,
results: [2]?*Result,

pub fn init() Self {
    return .{
        .context = undefined,
        .thread = null,
        .mutex = .init,
        .cond = .init,
        .quit = false,
        .req_pages = .{ null, null },
        .req_w = 0,
        .req_h = 0,
        .has_req = false,
        .results = .{ null, null },
    };
}

pub fn start(self: *Self) !void {
    if (self.thread != null) return;
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn stop(self: *Self) void {
    if (self.thread == null) return;
    const io = self.context.io;
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.quit = true;
        self.cond.signal(io);
    }
    self.thread.?.join();
    self.thread = null;
}

pub fn deinit(self: *Self) void {
    self.stop();
    for (&self.results) |*slot| {
        if (slot.*) |r| {
            self.freeResult(r);
            slot.* = null;
        }
    }
}

fn freeResult(self: *Self, r: *Result) void {
    const a = self.context.allocator;
    a.free(r.image.base64);
    a.destroy(r);
}

// Latest request wins; pending older requests are coalesced away.
pub fn request(self: *Self, pages: [2]?u16, w: u32, h: u32) void {
    if (self.thread == null) return;
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.req_pages = pages;
    self.req_w = w;
    self.req_h = h;
    self.has_req = true;
    self.cond.signal(io);
}

// Hands finished renders to the caller, which takes ownership.
pub fn claim(self: *Self) [2]?*Result {
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const out = self.results;
    self.results = .{ null, null };
    return out;
}

fn run(self: *Self) void {
    const io = self.context.io;
    while (true) {
        self.mutex.lockUncancelable(io);
        while (!self.quit and !self.has_req) self.cond.waitUncancelable(io, &self.mutex);
        if (self.quit) {
            self.mutex.unlock(io);
            return;
        }
        const pages = self.req_pages;
        const w = self.req_w;
        const h = self.req_h;
        self.has_req = false;
        self.mutex.unlock(io);

        for (pages) |maybe_page| {
            const page = maybe_page orelse continue;
            const encoded = self.context.document_handler.renderPage(page, w, h) catch continue;
            const key = self.context.cacheKeyFor(page);
            const result = self.context.allocator.create(Result) catch {
                self.context.allocator.free(encoded.base64);
                continue;
            };
            result.* = .{ .key = key, .image = encoded };

            self.mutex.lockUncancelable(io);
            if (self.quit) {
                self.mutex.unlock(io);
                self.freeResult(result);
                return;
            }
            if (self.results[0] == null) {
                self.results[0] = result;
            } else if (self.results[1] == null) {
                self.results[1] = result;
            } else {
                self.freeResult(self.results[0].?);
                self.results[0] = result;
            }
            self.mutex.unlock(io);

            if (self.context.loop) |loop| loop.postEvent(.prerender_ready) catch {};
        }
    }
}
