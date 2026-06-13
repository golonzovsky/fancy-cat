const Self = @This();
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");

context: *Context,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
    };
}

// Keymap field name → action, dispatched in order (first match wins).
const bindings = .{
    .{ "next", nextPage },
    .{ "prev", prevPage },
    .{ "zoom_in", zoomIn },
    .{ "zoom_out", zoomOut },
    .{ "width_mode", toggleWidthMode },
    .{ "crop_to_content", toggleCrop },
    .{ "toggle_spread", toggleSpread },
    .{ "full_screen", toggleStatusBar },
    .{ "scroll_up", scrollUp },
    .{ "scroll_down", scrollDown },
    .{ "scroll_left", scrollLeft },
    .{ "scroll_right", scrollRight },
    .{ "scroll_half_down", scrollHalfDown },
    .{ "scroll_half_up", scrollHalfUp },
    .{ "colorize", toggleInvert },
    .{ "enter_command_mode", enterCommand },
    .{ "hint_mode", enterHints },
    .{ "set_mark", startSetMark },
    .{ "jump_mark", startJumpMark },
    .{ "toc_mode", enterToc },
    .{ "marks_mode", enterMarks },
    .{ "jump_back", Context.jumpBack },
    .{ "jump_forward", Context.jumpForward },
    .{ "open_in_editor", openPageInEditor },
    .{ "open_chapter_in_editor", openChapterInEditor },
    .{ "show_help", showHelp },
    .{ "search", enterSearch },
    .{ "search_next", Context.searchNext },
    .{ "search_prev", Context.searchPrev },
    .{ "search_list", enterSearchList },
    .{ "add_highlight", Context.addHighlightFromSelection },
    .{ "highlights_mode", enterHighlights },
    .{ "exit_command_mode", Context.escapeClear },
};

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    const ctx = self.context;

    if (ctx.pending_op) |op| {
        ctx.pending_op = null;
        if (key.codepoint >= 'a' and key.codepoint <= 'z') {
            const letter: u8 = @intCast(key.codepoint);
            switch (op) {
                .set_mark => ctx.setMark(letter),
                .jump_mark => ctx.jumpToMark(letter),
            }
        }
        return;
    }

    inline for (bindings) |b| {
        const bind = @field(km, b[0]);
        if (key.matches(bind.codepoint, bind.mods)) return b[1](ctx);
    }
}

fn nextPage(ctx: *Context) void {
    if (ctx.document_handler.changePage(1)) ctx.resetCurrentPage();
}

fn prevPage(ctx: *Context) void {
    if (ctx.document_handler.changePage(-1)) ctx.resetCurrentPage();
}

fn zoomIn(ctx: *Context) void {
    ctx.document_handler.zoomIn();
    ctx.reload_page = true;
}

fn zoomOut(ctx: *Context) void {
    ctx.document_handler.zoomOut();
    ctx.reload_page = true;
}

fn toggleWidthMode(ctx: *Context) void {
    ctx.document_handler.toggleWidthMode();
    ctx.reload_page = true;
}

fn toggleCrop(ctx: *Context) void {
    ctx.document_handler.toggleCropToContent();
    ctx.reload_page = true;
}

fn toggleSpread(ctx: *Context) void {
    ctx.document_handler.toggleSpread();
    ctx.reload_page = true;
}

fn toggleStatusBar(ctx: *Context) void {
    ctx.toggleFullScreen();
    ctx.document_handler.resetDefaultZoom();
    ctx.reload_page = true;
}

fn toggleInvert(ctx: *Context) void {
    ctx.document_handler.toggleColor();
    ctx.reload_page = true;
}

fn scrollUp(ctx: *Context) void {
    ctx.document_handler.scrollY(ctx.config.general.scroll_step);
}

fn scrollDown(ctx: *Context) void {
    ctx.document_handler.scrollY(-ctx.config.general.scroll_step);
}

fn scrollHalfDown(ctx: *Context) void {
    ctx.smoothScrollHalf(true);
}

fn scrollHalfUp(ctx: *Context) void {
    ctx.smoothScrollHalf(false);
}

fn scrollLeft(ctx: *Context) void {
    ctx.document_handler.offsetScroll(-ctx.config.general.scroll_step, 0);
}

fn scrollRight(ctx: *Context) void {
    ctx.document_handler.offsetScroll(ctx.config.general.scroll_step, 0);
}

fn enterCommand(ctx: *Context) void {
    ctx.changeMode(.command);
}

fn enterHints(ctx: *Context) void {
    ctx.changeMode(.hint);
}

fn enterToc(ctx: *Context) void {
    ctx.changeMode(.toc);
}

fn enterMarks(ctx: *Context) void {
    ctx.changeMode(.marks);
}

fn showHelp(ctx: *Context) void {
    ctx.changeMode(.help);
}

fn enterSearch(ctx: *Context) void {
    ctx.changeMode(.search);
}

fn enterSearchList(ctx: *Context) void {
    ctx.changeMode(.search_list);
}

fn enterHighlights(ctx: *Context) void {
    ctx.changeMode(.highlights);
}

fn startSetMark(ctx: *Context) void {
    ctx.pending_op = .set_mark;
}

fn startJumpMark(ctx: *Context) void {
    ctx.pending_op = .jump_mark;
}

fn openPageInEditor(ctx: *Context) void {
    ctx.openCurrentPageInEditor() catch {};
}

fn openChapterInEditor(ctx: *Context) void {
    ctx.openCurrentChapterInEditor() catch {};
}
