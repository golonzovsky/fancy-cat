const std = @import("std");
const vaxis = @import("vaxis");
const ViewMode = @import("modes/ViewMode.zig");
const CommandMode = @import("modes/CommandMode.zig");
const HintMode = @import("modes/HintMode.zig");
const MarksMode = @import("modes/MarksMode.zig");
const TocMode = @import("modes/TocMode.zig");
const HelpMode = @import("modes/HelpMode.zig");
const fzwatch = @import("fzwatch");
const Config = @import("config/Config.zig");
const PdfHandler = @import("handlers/PdfHandler.zig");
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

pub const ModeType = enum { view, command, hint, marks, toc, help };
pub const Mode = union(ModeType) { view: ViewMode, command: CommandMode, hint: HintMode, marks: MarksMode, toc: TocMode, help: HelpMode };
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
    io: std.Io,
    env: *std.process.Environ.Map,
    arena: std.heap.ArenaAllocator,
    should_quit: bool,
    tty: vaxis.Tty,
    vx: vaxis.Vaxis,
    document_handler: PdfHandler,
    page_info_text: []u8,
    current_page: ?vaxis.Image,
    watcher: ?fzwatch.Watcher,
    watcher_thread: ?std.Thread,
    config: *Config,
    loop: ?*vaxis.Loop(Event),
    current_mode: Mode,
    history: History,
    positions: Positions,
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
    progress_text: ?[]const u8,
    progress_buf: [128]u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, args: []const [:0]const u8) !Self {
        const path = args[1];
        const initial_page = if (args.len == 3)
            try std.fmt.parseInt(u16, args[2], 10)
        else
            null;

        const config = try allocator.create(Config);
        errdefer allocator.destroy(config);
        config.* = Config.init(allocator, io, env);
        errdefer config.deinit();

        var document_handler = try PdfHandler.init(allocator, io, path, initial_page, config);
        errdefer document_handler.deinit();

        const doc_key = try document_handler.getDocumentKey(allocator);
        errdefer allocator.free(doc_key);

        var positions = Positions.init(allocator, io, env, config, doc_key);
        errdefer positions.deinit();
        if (initial_page == null) {
            if (positions.getSavedPositionForKey(document_handler.getPath())) |pos| {
                if (pos.page < document_handler.getTotalPages()) {
                    document_handler.setCurrentPage(pos.page);
                    config.general.colorize = pos.colorize;
                    // Crop first: toggleCropToContent resets zoom/scroll, so it must
                    // run before we restore them or it wipes the restored values.
                    if (pos.crop != document_handler.getCropToContent()) {
                        document_handler.toggleCropToContent();
                    }
                    document_handler.setScrollX(pos.scroll_x);
                    document_handler.setScrollY(pos.scroll_y);
                    if (pos.zoom > 0) document_handler.setActiveZoom(pos.zoom);
                    document_handler.setOddShiftX(pos.odd_shift_x);
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

        const vx = try vaxis.init(io, allocator, env, .{});
        const buf = try allocator.alloc(u8, 4096);
        const tty = try vaxis.Tty.init(io, buf);
        const reload_indicator_timer = ReloadIndicatorTimer.init(config);
        const history = History.init(allocator, io, env, config);

        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .should_quit = false,
            .tty = tty,
            .vx = vx,
            .document_handler = document_handler,
            .page_info_text = &[_]u8{},
            .current_page = null,
            .watcher = watcher,
            .watcher_thread = null,
            .config = config,
            .loop = null,
            .current_mode = undefined,
            .history = history,
            .positions = positions,
            .doc_key = doc_key,
            .reload_page = true,
            .cache = Cache.init(allocator, config.cache.lru_size),
            .reload_indicator_timer = reload_indicator_timer,
            .current_reload_indicator_state = .idle,
            .reload_indicator_active = false,
            .buf = buf,
            .visible_pages = undefined,
            .visible_pages_len = 0,
            .last_pix_per_col = 1,
            .last_pix_per_row = 1,
            .jump_back = .empty,
            .jump_forward = .empty,
            .lock_horizontal_scroll = restored_hlock,
            .marks = marks,
            .pending_op = null,
            .progress_text = null,
            .progress_buf = undefined,
        };
    }

    pub fn saveState(self: *Self) void {
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
    }

    pub fn deinit(self: *Self) void {
        self.saveState();
        for (self.marks.items) |m| {
            if (m.comment.len > 0) self.allocator.free(m.comment);
        }
        self.marks.deinit(self.allocator);
        self.positions.deinit();
        self.allocator.free(self.doc_key);
        self.jump_back.deinit(self.allocator);
        self.jump_forward.deinit(self.allocator);
        self.deinitCurrentMode();
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
                loop.postEvent(Event.file_changed) catch {};
            },
        }
    }

    fn watcherWorker(self: *Self, watcher: *fzwatch.Watcher) !void {
        try watcher.start(.{ .latency = self.config.file_monitor.latency });
    }

    pub fn run(self: *Self) !void {
        self.current_mode = .{ .view = ViewMode.init(self) };

        var loop: vaxis.Loop(Event) = .init(self.io, &self.tty, &self.vx);
        self.loop = &loop;
        defer self.loop = null;

        try loop.start();
        defer loop.stop();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), std.Io.Duration.fromSeconds(1));
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
            try loop.pollEvent();

            var had_event = false;
            while (try loop.tryEvent()) |event| {
                try self.update(event);
                had_event = true;
            }

            try self.draw();

            var buffered = self.tty.writer();
            try self.vx.render(buffered);
            try buffered.flush();

            // Persist position/zoom after any state-changing batch — draw() above
            // has already finalized active_zoom — so it survives a non-clean exit
            // (terminal closed, killed) without waiting for deinit on quit.
            if (had_event) self.saveState();
        }
    }

    fn deinitCurrentMode(self: *Self) void {
        switch (self.current_mode) {
            .view => {},
            inline else => |*state| state.deinit(),
        }
    }

    pub fn changeMode(self: *Self, new_state: ModeType) void {
        self.deinitCurrentMode();
        switch (new_state) {
            inline else => |tag| {
                self.current_mode = @unionInit(Mode, @tagName(tag), @FieldType(Mode, @tagName(tag)).init(self));
            },
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
            inline else => |*state| state.handleKeyStroke(key, km),
        };
    }

    pub fn update(self: *Self, event: Event) !void {
        switch (event) {
            .key_press => |key| try self.handleKeyStroke(key),
            .mouse => |mouse| {
                if (self.current_mode == .toc) {
                    self.current_mode.toc.handleMouse(mouse);
                    return;
                }
                if (self.current_mode == .marks) {
                    self.current_mode.marks.handleMouse(mouse);
                    return;
                }
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

        if (self.current_mode == .marks or self.current_mode == .toc or self.current_mode == .help) return;

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

            const child = win.child(.{
                .x_off = x_off,
                .y_off = y_off,
                .width = dest_cols,
                .height = dest_rows,
            });
            try img.draw(child, .{
                .clip_region = .{
                    .x = @intCast(clip_x),
                    .y = @intCast(clip_top),
                    .width = @intCast(clip_w),
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
                    .vp_x_right = vp_x_left + clip_w,
                    .clip_x = clip_x,
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
        if (mouse.col < 0 or mouse.row < 0) return;
        const click_pix_x: u32 = @as(u32, @intCast(mouse.col)) * @as(u32, self.last_pix_per_col) + mouse.xoffset;
        const click_pix_y: u32 = @as(u32, @intCast(mouse.row)) * @as(u32, self.last_pix_per_row) + mouse.yoffset;
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
            defer if (target == .uri) self.allocator.free(target.uri);
            self.followLink(target);
            return;
        }
    }

    // Does not take ownership of a .uri target; the caller frees it.
    pub fn followLink(self: *Self, target: PdfHandler.LinkTarget) void {
        switch (target) {
            .page => |dest| {
                self.pushJump();
                _ = self.document_handler.goToPage(dest.num + 1);
                self.document_handler.setScrollY(0);
                self.document_handler.setPendingScrollPdfY(dest.y);
                self.resetCurrentPage();
            },
            .uri => |uri| {
                _ = std.process.spawn(self.io, .{
                    .argv = &.{ "open", uri },
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                }) catch {};
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
        const target = self.jump_back.pop() orelse return;
        const here = self.currentPosition();
        self.jump_forward.append(self.allocator, here) catch {};
        self.restorePosition(target);
    }

    pub fn jumpForward(self: *Self) void {
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
                if (m.comment.len > 0) {
                    self.allocator.free(m.comment);
                    m.comment = "";
                }
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

    pub fn openCurrentPageInEditor(self: *Self) !void {
        const page = self.document_handler.getCurrentPageNumber();
        const pid = std.c.getpid();
        const dir = try std.fmt.allocPrint(self.allocator, "/tmp/fancy-cat-{d}-page{d}", .{ pid, page + 1 });
        defer self.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/page{d}.md", .{ dir, page + 1 }, 0);
        defer self.allocator.free(path);

        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch {};
        try self.document_handler.writePageText(page, path);
        try self.spawnEditorAndWait(path, dir, null);
    }

    fn currentChapterRange(self: *Self, current_page: u16) struct { start: u16, end: u16 } {
        const total = self.document_handler.getTotalPages();
        const entries = self.document_handler.loadOutline(self.allocator) catch return .{ .start = current_page, .end = current_page + 1 };
        defer {
            for (entries) |e| self.allocator.free(e.title);
            self.allocator.free(entries);
        }
        if (entries.len == 0) return .{ .start = current_page, .end = current_page + 1 };

        var min_depth: u8 = 255;
        for (entries) |e| {
            if (e.depth < min_depth) min_depth = e.depth;
        }

        var start: u16 = 0;
        var end: u16 = total;
        var found = false;
        for (entries, 0..) |e, i| {
            if (e.depth != min_depth) continue;
            if (e.page <= current_page) {
                start = e.page;
                found = true;
                end = total;
                for (entries[i + 1 ..]) |next_e| {
                    if (next_e.depth == min_depth) {
                        end = next_e.page;
                        break;
                    }
                }
            } else break;
        }
        if (!found) return .{ .start = current_page, .end = current_page + 1 };
        return .{ .start = start, .end = end };
    }

    fn progressCallback(ud: ?*anyopaque, current: c_int, total: c_int) callconv(.c) void {
        const self = @as(*Self, @ptrCast(@alignCast(ud.?)));
        const msg = std.fmt.bufPrint(&self.progress_buf, " Rendering chapter {d}/{d} ", .{ current, total }) catch return;
        self.progress_text = msg;
        const win = self.vx.window();
        self.drawStatusBar(win) catch return;
        var w = self.tty.writer();
        self.vx.render(w) catch return;
        w.flush() catch return;
    }

    fn extractRangeToEditor(self: *Self, dir: []const u8, name: []const u8, start: u16, end: u16) !void {
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ dir, name }, 0);
        defer self.allocator.free(path);

        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch {};
        try self.document_handler.writePagesText(start, end, path, progressCallback, self);
        self.progress_text = null;
        try self.spawnEditorAndWait(path, dir, null);
    }

    pub fn openCurrentChapterInEditor(self: *Self) !void {
        const page = self.document_handler.getCurrentPageNumber();
        const range = self.currentChapterRange(page);
        const pid = std.c.getpid();
        const dir = try std.fmt.allocPrint(self.allocator, "/tmp/fancy-cat-{d}-chap-{d}-{d}", .{ pid, range.start + 1, range.end });
        defer self.allocator.free(dir);
        const name = try std.fmt.allocPrint(self.allocator, "chap-{d}-{d}.md", .{ range.start + 1, range.end });
        defer self.allocator.free(name);

        try self.extractRangeToEditor(dir, name, range.start, range.end);
    }

    pub fn openOutlineInEditor(self: *Self, selected_index: ?usize) !void {
        const entries = self.document_handler.loadOutline(self.allocator) catch return;
        defer {
            for (entries) |e| self.allocator.free(e.title);
            self.allocator.free(entries);
        }
        if (entries.len == 0) return;

        const pid = std.c.getpid();
        const dir = try std.fmt.allocPrint(self.allocator, "/tmp/fancy-cat-{d}-toc", .{pid});
        defer self.allocator.free(dir);
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/toc.md", .{dir}, 0);
        defer self.allocator.free(path);

        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch {};
        {
            var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
            defer file.close(self.io);
            var buf: [4096]u8 = undefined;
            var fw = file.writer(self.io, &buf);
            const w = &fw.interface;
            try w.writeAll("# Table of Contents\n\n");
            for (entries) |e| {
                var k: usize = 0;
                while (k < @as(usize, e.depth) * 2) : (k += 1) try w.writeByte(' ');
                try w.print("- {s}  (p.{d})\n", .{ e.title, e.page + 1 });
            }
            try w.flush();
        }
        const line: ?usize = if (selected_index) |i| i + 3 else null; // header is 2 lines; entries start at line 3
        try self.spawnEditorAndWait(path, dir, line);
    }

    fn spawnEditorAndWait(self: *Self, path: [:0]const u8, dir: []const u8, line: ?usize) !void {
        var writer = self.tty.writer();
        try self.vx.setMouseMode(writer, false);
        try self.vx.exitAltScreen(writer);
        try writer.flush();

        // Release the tty so the editor can read stdin — otherwise the vaxis
        // input thread keeps consuming keystrokes from underneath the editor.
        if (self.loop) |loop| loop.stop();

        const editor_raw = self.env.get("EDITOR") orelse self.env.get("VISUAL") orelse "vim";
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        var it = std.mem.tokenizeAny(u8, editor_raw, &std.ascii.whitespace);
        while (it.next()) |tok| try argv.append(self.allocator, tok);

        // Jump vim-family editors to a specific line (e.g. the TOC's selected
        // chapter). `+N` is understood by vi/vim/nvim/nano/emacs; skip it for
        // others (e.g. `code` would treat `+N` as a filename).
        var line_buf: ?[]u8 = null;
        defer if (line_buf) |lb| self.allocator.free(lb);
        if (line) |n| {
            if (argv.items.len > 0) {
                const base = std.fs.path.basename(argv.items[0]);
                const is_vi = std.mem.eql(u8, base, "vim") or std.mem.eql(u8, base, "nvim") or
                    std.mem.eql(u8, base, "vi") or std.mem.eql(u8, base, "nano") or
                    std.mem.eql(u8, base, "emacs") or std.mem.eql(u8, base, "emacsclient");
                if (is_vi) {
                    line_buf = try std.fmt.allocPrint(self.allocator, "+{d}", .{n});
                    try argv.append(self.allocator, line_buf.?);
                }
            }
        }
        try argv.append(self.allocator, path);

        var child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .environ_map = self.env,
        });
        _ = child.wait(self.io) catch {};

        // Clean up the per-extract directory and everything inside it.
        const last_slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse 0;
        const parent = dir[0..last_slash];
        const leaf = dir[last_slash + 1 ..];
        if (std.Io.Dir.openDirAbsolute(self.io, parent, .{})) |opened_parent| {
            var parent_dir = opened_parent;
            defer parent_dir.close(self.io);
            parent_dir.deleteTree(self.io, leaf) catch {};
        } else |_| {}

        if (self.loop) |loop| try loop.start();

        try self.vx.enterAltScreen(writer);
        try self.vx.setMouseMode(writer, true);
        try writer.flush();
        self.cache.clear();
        self.reload_page = true;
    }

    pub fn enterCommandWithText(self: *Self, text: []const u8) void {
        self.changeMode(.command);
        self.current_mode.command.text_input.insertSliceAtCursor(text) catch {};
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

        if (self.progress_text) |text| {
            status_bar.fill(vaxis.Cell{ .style = self.config.status_bar.style });
            _ = status_bar.print(&.{.{ .text = text, .style = self.config.status_bar.style }}, .{ .col_offset = 0 });
            return;
        }

        // Expand all items into styled sub-items
        var expanded_items: std.ArrayList(Config.StatusBar.StyledItem) = .empty;

        for (self.config.status_bar.items) |item| {
            const styled = switch (item) {
                .styled => |styled| styled,
                .mode_aware => |mode_aware| switch (self.current_mode) {
                    .command => mode_aware.command,
                    else => mode_aware.view,
                },
                .reload_aware => |reload_aware| switch (self.current_reload_indicator_state) {
                    .idle => reload_aware.idle,
                    .reload => reload_aware.reload,
                    .watching => reload_aware.watching,
                },
            };
            try expandPlaceholders(arena, &expanded_items, styled);
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

    fn expandPlaceholders(arena: std.mem.Allocator, list: *std.ArrayList(Config.StatusBar.StyledItem), styled_text: Config.StatusBar.StyledItem) !void {
        const text = styled_text.text;
        var last_index: usize = 0;

        while (last_index < text.len) {
            const open = std.mem.indexOfScalarPos(u8, text, last_index, '<') orelse {
                if (last_index < text.len) {
                    try list.append(arena, .{ .text = text[last_index..], .style = styled_text.style });
                }
                break;
            };

            if (open > last_index) {
                try list.append(arena, .{ .text = text[last_index..open], .style = styled_text.style });
            }

            const close = std.mem.indexOfScalarPos(u8, text, open, '>') orelse {
                try list.append(arena, .{ .text = text[open..], .style = styled_text.style });
                break;
            };

            try list.append(arena, .{ .text = text[open .. close + 1], .style = styled_text.style });

            last_index = close + 1;
        }
    }

    fn stripDirPrefix(path: []const u8, dir: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, path, dir)) return null;
        var rel = path[dir.len..];
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        return rel;
    }

    fn drawStatusText(self: *Self, status_bar: vaxis.Window, item: Config.StatusBar.StyledItem, col_offset: *usize, left_aligned: bool, allocator: std.mem.Allocator) !void {
        var text = item.text;

        if (std.mem.eql(u8, text, Config.StatusBar.PATH)) {
            const cwd_dir = std.Io.Dir.cwd();
            const cwd = try cwd_dir.realPathFileAlloc(self.io, ".", allocator);
            defer allocator.free(cwd);

            const full_path = try cwd_dir.realPathFileAlloc(self.io, self.document_handler.getPath(), allocator);
            defer allocator.free(full_path);

            if (stripDirPrefix(full_path, cwd)) |rel| {
                text = try allocator.dupe(u8, rel);
            } else if (self.env.get("HOME")) |home| {
                if (stripDirPrefix(full_path, home)) |rel| {
                    text = try std.fmt.allocPrint(allocator, "~/{s}", .{rel});
                } else {
                    text = try allocator.dupe(u8, full_path);
                }
            } else {
                text = try allocator.dupe(u8, full_path);
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
        if (self.current_mode == .toc) self.current_mode.toc.draw(win);
        if (self.current_mode == .help) self.current_mode.help.draw(win);
    }

    pub fn toggleFullScreen(self: *Self) void {
        self.config.status_bar.enabled = !self.config.status_bar.enabled;
    }
};
