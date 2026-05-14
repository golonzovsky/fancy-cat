const std = @import("std");
const vaxis = @import("vaxis");
const ViewMode = @import("modes/ViewMode.zig");
const CommandMode = @import("modes/CommandMode.zig");
const HintMode = @import("modes/HintMode.zig");
const MarksMode = @import("modes/MarksMode.zig");
const fzwatch = @import("fzwatch");
const Config = @import("config/Config.zig");
const DocumentHandler = @import("handlers/DocumentHandler.zig");
const Cache = @import("./Cache.zig");
const ReloadIndicatorTimer = @import("services/ReloadIndicatorTimer.zig");
const History = @import("services/History.zig");
const Positions = @import("services/Positions.zig");

pub const panic = vaxis.panic_handler;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    file_changed,
    reload_done: usize,
};

pub const ModeType = enum { view, command, hint, marks };
pub const Mode = union(ModeType) { view: ViewMode, command: CommandMode, hint: HintMode, marks: MarksMode };
pub const ReloadIndicatorState = enum { idle, reload, watching };

pub const VisiblePage = struct {
    page_num: u16,
    vp_y_top: u32,
    vp_y_bot: u32,
    vp_x_left: u32,
    vp_x_right: u32,
    clip_x: u32,
    clip_y: u32,
    origin_x: f32,
    origin_y: f32,
};

pub const JumpPosition = struct {
    page: u16,
    scroll_y: i32,
    scroll_x: i32,
};

const max_jumps: usize = 100;

pub const Context = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    mouse: ?vaxis.Mouse,
    document_handler: DocumentHandler,
    page_info_text: []u8,
    current_page: ?vaxis.Image,
    watcher: ?fzwatch.Watcher,
    watcher_thread: ?std.Thread,
    config: *Config,
    current_mode: Mode,
    history: History,
    positions: Positions,
    doc_path: []const u8,
    doc_key: []u8,
    reload_page: bool,
    cache: Cache,
    reload_indicator_timer: ReloadIndicatorTimer,
    current_reload_indicator_state: ReloadIndicatorState,
    reload_indicator_active: bool,
    buf: []u8,
    visible_pages: [8]VisiblePage,
    visible_pages_len: usize,
    last_pix_per_col: u16,
    last_pix_per_row: u16,
    jump_back: std.ArrayList(JumpPosition),
    jump_forward: std.ArrayList(JumpPosition),
    lock_horizontal_scroll: bool,
    marks: std.ArrayList(Positions.Mark),
    pending_op: ?enum { set_mark, jump_mark },

    pub fn init(allocator: std.mem.Allocator, args: [][:0]u8) !Self {
        const path = args[1];
        const initial_page = if (args.len == 3)
            try std.fmt.parseInt(u16, args[2], 10)
        else
            null;

        const config = try allocator.create(Config);
        errdefer allocator.destroy(config);
        config.* = Config.init(allocator);
        errdefer config.deinit();

        var document_handler = try DocumentHandler.init(allocator, path, initial_page, config);
        errdefer document_handler.deinit();

        const doc_key = try document_handler.getDocumentKey(allocator);
        errdefer allocator.free(doc_key);

        var positions = Positions.init(allocator, config, doc_key);
        errdefer positions.deinit();
        if (initial_page == null) {
            if (positions.getSavedPosition()) |pos| {
                if (pos.page < document_handler.getTotalPages()) {
                    document_handler.setCurrentPage(pos.page);
                    document_handler.setScrollX(pos.scroll_x);
                    document_handler.setScrollY(pos.scroll_y);
                    if (pos.zoom > 0) document_handler.setActiveZoom(pos.zoom);
                    document_handler.setOddShiftX(pos.odd_shift_x);
                    config.general.colorize = pos.colorize;
                    if (pos.crop != document_handler.getCropToContent()) {
                        document_handler.toggleCropToContent();
                    }
                }
            }
        }
        const restored_hlock: bool = if (positions.getSavedPosition()) |p| p.hlock else false;
        var marks = positions.loadMarks(allocator);
        errdefer marks.deinit(allocator);

        var watcher: ?fzwatch.Watcher = null;
        if (config.file_monitor.enabled) {
            watcher = try fzwatch.Watcher.init(allocator);
            if (watcher) |*w| try w.addFile(path);
        }

        const vx = try vaxis.init(allocator, .{});
        const buf = try allocator.alloc(u8, 4096);
        const tty = try vaxis.Tty.init(buf);
        const reload_indicator_timer = ReloadIndicatorTimer.init(config);
        const history = History.init(allocator, config);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .should_quit = false,
            .tty = tty,
            .vx = vx,
            .document_handler = document_handler,
            .page_info_text = &[_]u8{},
            .current_page = null,
            .watcher = watcher,
            .mouse = null,
            .watcher_thread = null,
            .config = config,
            .current_mode = undefined,
            .history = history,
            .positions = positions,
            .doc_path = path,
            .doc_key = doc_key,
            .reload_page = true,
            .cache = Cache.init(allocator, config, vx, &tty),
            .reload_indicator_timer = reload_indicator_timer,
            .current_reload_indicator_state = .idle,
            .reload_indicator_active = false,
            .buf = buf,
            .visible_pages = undefined,
            .visible_pages_len = 0,
            .last_pix_per_col = 1,
            .last_pix_per_row = 1,
            .jump_back = .{},
            .jump_forward = .{},
            .lock_horizontal_scroll = restored_hlock,
            .marks = marks,
            .pending_op = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.positions.save(.{
            .page = self.document_handler.getCurrentPageNumber(),
            .scroll_x = self.document_handler.getScrollX(),
            .scroll_y = self.document_handler.getScrollY(),
            .zoom = self.document_handler.getActiveZoom(),
            .odd_shift_x = self.document_handler.getOddShiftX(),
            .colorize = self.config.general.colorize,
            .crop = self.document_handler.getCropToContent(),
            .hlock = self.lock_horizontal_scroll,
        }, self.marks.items);
        for (self.marks.items) |m| {
            if (m.comment.len > 0) self.allocator.free(m.comment);
        }
        self.marks.deinit(self.allocator);
        self.positions.deinit();
        self.allocator.free(self.doc_key);
        self.jump_back.deinit(self.allocator);
        self.jump_forward.deinit(self.allocator);
        switch (self.current_mode) {
            .command => |*state| state.deinit(),
            .hint => |*state| state.deinit(),
            .marks => |*state| state.deinit(),
            .view => {},
        }
        if (self.watcher) |*w| {
            w.stop();
            if (self.watcher_thread) |thread| thread.join();
            w.deinit();
        }

        if (self.page_info_text.len > 0) self.allocator.free(self.page_info_text);

        self.reload_indicator_timer.deinit();
        self.history.deinit();
        self.cache.deinit();
        self.document_handler.deinit();
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
        self.config.deinit();
        self.allocator.destroy(self.config);
        self.arena.deinit();
        self.allocator.free(self.buf);
    }

    fn callback(context: ?*anyopaque, event: fzwatch.Event) void {
        switch (event) {
            .modified => {
                const loop = @as(*vaxis.Loop(Event), @ptrCast(@alignCast(context.?)));
                loop.postEvent(Event.file_changed);
            },
        }
    }

    fn watcherWorker(self: *Self, watcher: *fzwatch.Watcher) !void {
        try watcher.start(.{ .latency = self.config.file_monitor.latency });
    }

    pub fn run(self: *Self) !void {
        self.current_mode = .{ .view = ViewMode.init(self) };

        var loop: vaxis.Loop(Event) = .{
            .tty = &self.tty,
            .vaxis = &self.vx,
        };

        try loop.init();
        try loop.start();
        defer loop.stop();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(self.tty.writer(), true);

        if (self.config.file_monitor.enabled) {
            if (self.watcher) |*w| {
                w.setCallback(callback, &loop);
                self.watcher_thread = try std.Thread.spawn(.{}, watcherWorker, .{ self, w });
                self.current_reload_indicator_state = .watching;
                if (self.config.status_bar.enabled and self.config.file_monitor.reload_indicator_duration > 0) {
                    for (self.config.status_bar.items) |item| {
                        if (item == .reload_aware) {
                            try self.reload_indicator_timer.start(&loop);
                            self.reload_indicator_active = true;
                            break;
                        }
                    }
                }
            }
        }

        while (!self.should_quit) {
            loop.pollEvent();

            while (loop.tryEvent()) |event| {
                try self.update(event);
            }

            try self.draw();

            var buffered = self.tty.writer();
            try self.vx.render(buffered);
            try buffered.flush();
        }
    }

    pub fn changeMode(self: *Self, new_state: ModeType) void {
        switch (self.current_mode) {
            .command => |*state| state.deinit(),
            .hint => |*state| state.deinit(),
            .marks => |*state| state.deinit(),
            .view => {},
        }

        switch (new_state) {
            .view => self.current_mode = .{ .view = ViewMode.init(self) },
            .command => self.current_mode = .{ .command = CommandMode.init(self) },
            .hint => self.current_mode = .{ .hint = HintMode.init(self) },
            .marks => self.current_mode = .{ .marks = MarksMode.init(self) },
        }
    }

    pub fn resetCurrentPage(self: *Self) void {
        self.reload_page = true;
    }

    pub fn handleKeyStroke(self: *Self, key: vaxis.Key) !void {
        const km = self.config.key_map;

        // Global keybindings
        if (key.matches(km.quit.codepoint, km.quit.mods)) {
            self.should_quit = true;
            return;
        }

        try switch (self.current_mode) {
            .view => |*state| state.handleKeyStroke(key, km),
            .command => |*state| state.handleKeyStroke(key, km),
            .hint => |*state| state.handleKeyStroke(key, km),
            .marks => |*state| state.handleKeyStroke(key, km),
        };
    }

    pub fn update(self: *Self, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKeyStroke(key),
            .mouse => |mouse| {
                self.mouse = mouse;
                if (self.current_mode == .view and mouse.type == .press) {
                    const step = self.config.general.scroll_step / 4.0;
                    const zoom_mod = mouse.mods.ctrl or mouse.mods.alt;
                    switch (mouse.button) {
                        .wheel_up => {
                            if (zoom_mod) {
                                self.document_handler.zoomIn();
                                self.reload_page = true;
                            } else if (mouse.mods.shift) {
                                self.document_handler.offsetScroll(step, 0);
                            } else {
                                self.document_handler.scrollY(step);
                            }
                        },
                        .wheel_down => {
                            if (zoom_mod) {
                                self.document_handler.zoomOut();
                                self.reload_page = true;
                            } else if (mouse.mods.shift) {
                                self.document_handler.offsetScroll(-step, 0);
                            } else {
                                self.document_handler.scrollY(-step);
                            }
                        },
                        .wheel_left => {
                            if (!self.lock_horizontal_scroll) self.document_handler.offsetScroll(step, 0);
                        },
                        .wheel_right => {
                            if (!self.lock_horizontal_scroll) self.document_handler.offsetScroll(-step, 0);
                        },
                        .left => {
                            try self.handleLeftClick(mouse);
                        },
                        else => {},
                    }
                }
            },
            .winsize => |ws| {
                try self.vx.resize(self.allocator, self.tty.writer(), ws);
                self.cache.clear();
                self.reload_page = true;
            },
            .file_changed => {
                try self.document_handler.reloadDocument();
                self.cache.clear();
                self.reload_page = true;
                if (self.reload_indicator_active) {
                    self.current_reload_indicator_state = .reload;
                    self.reload_indicator_timer.notifyChange();
                }
            },
            .reload_done => {
                self.current_reload_indicator_state = .watching;
            },
        }
    }

    pub fn getPage(
        self: *Self,
        page_number: u16,
        window_width: u32,
        window_height: u32,
    ) !Cache.CachedImage {
        const cache_key = Cache.Key{
            .colorize = self.config.general.colorize,
            .page = page_number,
            .width_mode = self.document_handler.getWidthMode(),
            .zoom = @as(u32, @intFromFloat(self.document_handler.getActiveZoom() * 1000.0)),
            .crop = self.document_handler.getCropToContent(),
            .shift_x = if (page_number % 2 == 1) self.document_handler.getOddShiftX() else 0,
        };

        if (self.config.cache.enabled) {
            if (self.cache.get(cache_key)) |cached| return cached;
        }

        const encoded_image = try self.document_handler.renderPage(
            page_number,
            window_width,
            window_height,
        );
        defer self.allocator.free(encoded_image.base64);

        const image = try self.vx.transmitPreEncodedImage(
            self.tty.writer(),
            encoded_image.base64,
            encoded_image.width,
            encoded_image.height,
            .rgb,
        );

        const cached = Cache.CachedImage{
            .image = image,
            .origin_x = encoded_image.origin_x,
            .origin_y = encoded_image.origin_y,
        };
        if (self.config.cache.enabled) _ = try self.cache.put(cache_key, cached);
        return cached;
    }

    pub fn drawCurrentPage(self: *Self, win: vaxis.Window) !void {
        const pix_per_col = try std.math.divCeil(u16, win.screen.width_pix, win.screen.width);
        const pix_per_row = try std.math.divCeil(u16, win.screen.height_pix, win.screen.height);
        self.last_pix_per_col = pix_per_col;
        self.last_pix_per_row = pix_per_row;
        self.visible_pages_len = 0;

        var viewport_rows: u16 = win.height;
        if (self.config.status_bar.enabled or self.current_mode == .command) viewport_rows -|= 1;
        const viewport_w_pix: u32 = @as(u32, win.width) * @as(u32, pix_per_col);
        const viewport_h_pix: u32 = @as(u32, viewport_rows) * @as(u32, pix_per_row);

        if (self.current_mode == .marks) return;

        var page_num = self.document_handler.getCurrentPageNumber();
        const total_pages = self.document_handler.getTotalPages();
        var cur = try self.getPage(page_num, viewport_w_pix, viewport_h_pix);

        if (self.document_handler.takePendingScrollPdfY()) |pdf_y| {
            if (!std.math.isNan(pdf_y)) {
                const zoom = self.document_handler.getActiveZoom();
                if (zoom > 0) {
                    const context_px: i32 = @intCast(@as(u32, pix_per_row) * 3);
                    const target_y: i32 = @intFromFloat((pdf_y - cur.origin_y) * zoom);
                    self.document_handler.setScrollY(@max(0, target_y - context_px));
                }
            }
        }

        var scroll_y: i32 = self.document_handler.getScrollY();

        while (scroll_y < 0 and page_num > 0) {
            const prev = try self.getPage(page_num - 1, viewport_w_pix, viewport_h_pix);
            scroll_y += @as(i32, @intCast(prev.image.height));
            page_num -= 1;
            cur = prev;
        }

        while (page_num + 1 < total_pages and scroll_y >= @as(i32, @intCast(cur.image.height))) {
            scroll_y -= @as(i32, @intCast(cur.image.height));
            page_num += 1;
            cur = try self.getPage(page_num, viewport_w_pix, viewport_h_pix);
        }

        if (page_num == 0 and scroll_y < 0) scroll_y = 0;
        if (page_num + 1 == total_pages) {
            const max_y = @max(0, @as(i32, @intCast(cur.image.height)) - @as(i32, @intCast(viewport_h_pix)));
            if (scroll_y > max_y) scroll_y = max_y;
        }

        self.document_handler.setCurrentPage(page_num);
        self.document_handler.setScrollY(scroll_y);
        self.document_handler.clampScrollX(viewport_w_pix);
        self.current_page = cur.image;
        self.reload_page = false;

        const scroll_x = self.document_handler.getScrollX();
        const ppr_i: i32 = @intCast(pix_per_row);
        const ppc_i: i32 = @intCast(pix_per_col);
        const display_scroll_y: i32 = @divFloor(scroll_y, ppr_i) * ppr_i;
        const display_scroll_x: i32 = @divFloor(scroll_x, ppc_i) * ppc_i;
        var y_pix_used: u32 = 0;
        var draw_page = page_num;
        var first_top: i32 = display_scroll_y;

        while (y_pix_used < viewport_h_pix and draw_page < total_pages) {
            const entry = try self.getPage(draw_page, viewport_w_pix, viewport_h_pix);
            const img = entry.image;
            const clip_top: u32 = @intCast(@max(0, first_top));
            const img_h: u32 = img.height;
            if (clip_top >= img_h) {
                draw_page += 1;
                first_top = 0;
                continue;
            }
            const remaining_vp = viewport_h_pix - y_pix_used;
            const visible_h: u32 = @min(remaining_vp, img_h - clip_top);
            if (visible_h == 0) {
                draw_page += 1;
                first_top = 0;
                continue;
            }

            const img_w: u32 = img.width;
            const need_clip_x = img_w > viewport_w_pix;
            const clip_w: u32 = if (need_clip_x) viewport_w_pix else img_w;
            const clip_x: u32 = if (need_clip_x) @intCast(@max(0, display_scroll_x)) else 0;

            const dest_cols: u16 = @intCast(@max(1, std.math.divCeil(u32, clip_w, pix_per_col) catch 1));
            const dest_rows: u16 = @intCast(@max(1, std.math.divCeil(u32, visible_h, pix_per_row) catch 1));
            const x_off: u16 = if (win.width > dest_cols) (win.width - dest_cols) / 2 else 0;
            const y_off: u16 = @intCast(y_pix_used / pix_per_row);
            const clip_x_eff: u32 = clip_x;
            const clip_w_eff: u32 = clip_w;

            const child = win.child(.{
                .x_off = x_off,
                .y_off = y_off,
                .width = dest_cols,
                .height = dest_rows,
            });
            try img.draw(child, .{
                .clip_region = .{
                    .x = @intCast(clip_x_eff),
                    .y = @intCast(clip_top),
                    .width = @intCast(clip_w_eff),
                    .height = @intCast(visible_h),
                },
                .size = .{ .cols = dest_cols, .rows = dest_rows },
                .z_index = if (self.current_mode == .hint or self.current_mode == .marks) -1 else null,
            });

            if (self.visible_pages_len < self.visible_pages.len) {
                const vp_x_left: u32 = @as(u32, x_off) * @as(u32, pix_per_col);
                self.visible_pages[self.visible_pages_len] = .{
                    .page_num = draw_page,
                    .vp_y_top = y_pix_used,
                    .vp_y_bot = y_pix_used + visible_h,
                    .vp_x_left = vp_x_left,
                    .vp_x_right = vp_x_left + clip_w_eff,
                    .clip_x = clip_x_eff,
                    .clip_y = clip_top,
                    .origin_x = entry.origin_x,
                    .origin_y = entry.origin_y,
                };
                self.visible_pages_len += 1;
            }

            y_pix_used += @as(u32, dest_rows) * @as(u32, pix_per_row);
            first_top = 0;
            draw_page += 1;
        }
    }

    pub fn handleLeftClick(self: *Self, mouse: vaxis.Mouse) !void {
        const click_pix_x: u32 = @as(u32, mouse.col) * @as(u32, self.last_pix_per_col) + mouse.xoffset;
        const click_pix_y: u32 = @as(u32, mouse.row) * @as(u32, self.last_pix_per_row) + mouse.yoffset;
        const zoom = self.document_handler.getActiveZoom();
        if (zoom == 0) return;

        for (self.visible_pages[0..self.visible_pages_len]) |p| {
            if (click_pix_y < p.vp_y_top or click_pix_y >= p.vp_y_bot) continue;
            if (click_pix_x < p.vp_x_left or click_pix_x >= p.vp_x_right) continue;

            const bitmap_x: f32 = @floatFromInt(p.clip_x + (click_pix_x - p.vp_x_left));
            const bitmap_y: f32 = @floatFromInt(p.clip_y + (click_pix_y - p.vp_y_top));
            const pdf_x = bitmap_x / zoom + p.origin_x;
            const pdf_y = bitmap_y / zoom + p.origin_y;

            const target = self.document_handler.findLinkAtPoint(self.allocator, p.page_num, pdf_x, pdf_y) orelse return;
            try self.followLink(target);
            return;
        }
    }

    fn followLink(self: *Self, target: @import("./handlers/PdfHandler.zig").LinkTarget) !void {
        switch (target) {
            .page => |dest| {
                self.pushJump();
                _ = self.document_handler.goToPage(dest.num + 1);
                self.document_handler.setScrollY(0);
                self.document_handler.setPendingScrollPdfY(dest.y);
                self.resetCurrentPage();
            },
            .uri => |uri| {
                defer self.allocator.free(uri);
                var child = std.process.Child.init(&.{ "open", uri }, self.allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;
                _ = child.spawn() catch {};
            },
        }
    }

    fn currentPosition(self: *Self) JumpPosition {
        return .{
            .page = self.document_handler.getCurrentPageNumber(),
            .scroll_y = self.document_handler.getScrollY(),
            .scroll_x = self.document_handler.getScrollX(),
        };
    }

    pub fn pushJump(self: *Self) void {
        const pos = self.currentPosition();
        self.jump_back.append(self.allocator, pos) catch return;
        if (self.jump_back.items.len > max_jumps) _ = self.jump_back.orderedRemove(0);
        self.jump_forward.clearRetainingCapacity();
    }

    pub fn jumpBack(self: *Self) void {
        if (self.jump_back.items.len == 0) return;
        const target = self.jump_back.pop() orelse return;
        const here = self.currentPosition();
        self.jump_forward.append(self.allocator, here) catch {};
        self.restorePosition(target);
    }

    pub fn jumpForward(self: *Self) void {
        if (self.jump_forward.items.len == 0) return;
        const target = self.jump_forward.pop() orelse return;
        const here = self.currentPosition();
        self.jump_back.append(self.allocator, here) catch {};
        self.restorePosition(target);
    }

    fn restorePosition(self: *Self, pos: JumpPosition) void {
        self.document_handler.setCurrentPage(pos.page);
        self.document_handler.setScrollY(pos.scroll_y);
        self.document_handler.setScrollX(pos.scroll_x);
        self.resetCurrentPage();
    }

    pub fn setMark(self: *Self, letter: u8) void {
        const page = self.document_handler.getCurrentPageNumber();
        const sx = self.document_handler.getScrollX();
        const sy = self.document_handler.getScrollY();
        for (self.marks.items) |*m| {
            if (m.letter == letter) {
                m.page = page;
                m.scroll_x = sx;
                m.scroll_y = sy;
                return;
            }
        }
        self.marks.append(self.allocator, .{
            .letter = letter,
            .page = page,
            .scroll_x = sx,
            .scroll_y = sy,
        }) catch {};
    }

    pub fn jumpToMark(self: *Self, letter: u8) void {
        for (self.marks.items) |m| {
            if (m.letter == letter) {
                if (m.page < self.document_handler.getTotalPages()) {
                    self.pushJump();
                    self.document_handler.setCurrentPage(m.page);
                    self.document_handler.setScrollX(m.scroll_x);
                    self.document_handler.setScrollY(m.scroll_y);
                    self.resetCurrentPage();
                }
                return;
            }
        }
    }

    pub fn deleteMark(self: *Self, letter: u8) void {
        for (self.marks.items, 0..) |m, i| {
            if (m.letter == letter) {
                if (m.comment.len > 0) self.allocator.free(m.comment);
                _ = self.marks.orderedRemove(i);
                return;
            }
        }
    }

    pub fn setMarkComment(self: *Self, letter: u8, comment: []const u8) !void {
        for (self.marks.items) |*m| {
            if (m.letter == letter) {
                if (m.comment.len > 0) self.allocator.free(m.comment);
                m.comment = try self.allocator.dupe(u8, comment);
                return;
            }
        }
    }

    pub fn drawStatusBar(self: *Self, win: vaxis.Window) !void {
        const arena = self.arena.allocator();
        defer _ = self.arena.reset(.retain_capacity);

        const status_bar = win.child(.{
            .x_off = 0,
            .y_off = win.height -| 1,
            .width = win.width,
            .height = 1,
        });

        // Expand all items into styled sub-items
        var expanded_items = std.array_list.Managed(Config.StatusBar.StyledItem).init(arena);
        defer expanded_items.deinit();

        for (self.config.status_bar.items) |item| {
            switch (item) {
                .styled => |styled| {
                    try expandPlaceholders(&expanded_items, styled);
                },
                .mode_aware => |mode_aware| {
                    switch (self.current_mode) {
                        .view, .hint, .marks => try expandPlaceholders(&expanded_items, mode_aware.view),
                        .command => try expandPlaceholders(&expanded_items, mode_aware.command),
                    }
                },
                .reload_aware => |reload_aware| {
                    switch (self.current_reload_indicator_state) {
                        .idle => try expandPlaceholders(&expanded_items, reload_aware.idle),
                        .reload => try expandPlaceholders(&expanded_items, reload_aware.reload),
                        .watching => try expandPlaceholders(&expanded_items, reload_aware.watching),
                    }
                },
            }
        }

        const items = expanded_items.items;

        // Find the separator
        var separator_index: usize = items.len;
        for (items, 0..) |item, i| {
            if (std.mem.eql(u8, item.text, Config.StatusBar.SEPARATOR)) {
                separator_index = i;
                break;
            }
        }

        if (separator_index < items.len) {
            status_bar.fill(vaxis.Cell{ .style = items[separator_index].style });
        } else {
            status_bar.fill(vaxis.Cell{ .style = self.config.status_bar.style });
        }

        // Left side
        var left_col: usize = 0;
        for (0..separator_index) |i| {
            try self.drawStatusText(status_bar, items[i], &left_col, true, arena);
        }

        // Right side
        if (separator_index < items.len - 1) {
            var right_col: usize = win.width;
            for (0..(items.len - separator_index - 1)) |j| {
                try self.drawStatusText(status_bar, items[items.len - 1 - j], &right_col, false, arena);
            }
        }
    }

    fn expandPlaceholders(list: *std.array_list.Managed(Config.StatusBar.StyledItem), styled_text: Config.StatusBar.StyledItem) !void {
        const text = styled_text.text;
        var last_index: usize = 0;

        while (last_index < text.len) {
            const open = std.mem.indexOfScalarPos(u8, text, last_index, '<') orelse {
                if (last_index < text.len) {
                    try list.append(.{ .text = text[last_index..], .style = styled_text.style });
                }
                break;
            };

            if (open > last_index) {
                try list.append(.{ .text = text[last_index..open], .style = styled_text.style });
            }

            const close = std.mem.indexOfScalarPos(u8, text, open, '>') orelse {
                try list.append(.{ .text = text[open..], .style = styled_text.style });
                break;
            };

            try list.append(.{ .text = text[open .. close + 1], .style = styled_text.style });

            last_index = close + 1;
        }
    }

    fn drawStatusText(self: *Self, status_bar: vaxis.Window, item: Config.StatusBar.StyledItem, col_offset: *usize, left_aligned: bool, allocator: std.mem.Allocator) !void {
        var text = item.text;

        if (std.mem.eql(u8, text, Config.StatusBar.PATH)) {
            const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
            defer allocator.free(cwd);

            const full_path = try std.fs.cwd().realpathAlloc(allocator, self.document_handler.getPath());
            defer allocator.free(full_path);

            if (std.mem.startsWith(u8, full_path, cwd)) {
                var path = full_path[cwd.len..];
                if (path.len > 0 and path[0] == '/') path = path[1..];
                text = try std.fmt.allocPrint(allocator, "{s}", .{path}); // trim cwd
            } else if (std.posix.getenv("HOME")) |home| {
                if (std.mem.startsWith(u8, full_path, home)) {
                    var path = full_path[home.len..];
                    if (path.len > 0 and path[0] == '/') path = path[1..];
                    text = try std.fmt.allocPrint(allocator, "~/{s}", .{path});
                } else {
                    text = try std.fmt.allocPrint(allocator, "{s}", .{full_path});
                }
            } else {
                text = try std.fmt.allocPrint(allocator, "{s}", .{full_path});
            }
        } else if (std.mem.eql(u8, text, Config.StatusBar.PAGE)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.document_handler.getCurrentPageNumber() + 1});
        } else if (std.mem.eql(u8, text, Config.StatusBar.TOTAL_PAGES)) {
            text = try std.fmt.allocPrint(allocator, "{}", .{self.document_handler.getTotalPages()});
        } else if (std.mem.eql(u8, text, Config.StatusBar.SEPARATOR)) {
            text = "";
        } else if (std.mem.eql(u8, text, Config.StatusBar.HLOCK)) {
            text = if (self.lock_horizontal_scroll) " HLOCK " else "";
        }

        const width = vaxis.gwidth.gwidth(text, .wcwidth);

        if (!left_aligned) col_offset.* -= width;

        _ = status_bar.print(
            &.{.{ .text = text, .style = item.style }},
            .{ .col_offset = @intCast(col_offset.*) },
        );

        if (left_aligned) col_offset.* += width;
    }

    pub fn draw(self: *Self) !void {
        const win = self.vx.window();
        win.clear();

        try self.drawCurrentPage(win);

        if (self.current_mode == .command) {
            self.current_mode.command.drawCommandBar(win);
        } else if (self.config.status_bar.enabled) {
            try self.drawStatusBar(win);
        }
        if (self.current_mode == .hint) self.current_mode.hint.drawHints(win);
        if (self.current_mode == .marks) self.current_mode.marks.draw(win);
    }

    pub fn toggleFullScreen(self: *Self) void {
        self.config.status_bar.enabled = !self.config.status_bar.enabled;
    }
};
