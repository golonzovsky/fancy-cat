const Self = @This();
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const CommandMode = @import("./CommandMode.zig");
const Config = @import("../config/Config.zig");

context: *Context,

pub const KeyAction = struct {
    codepoint: u21,
    mods: vaxis.Key.Modifiers,
    handler: *const fn (*Context) void,
};

pub fn init(context: *Context) Self {
    return .{
        .context = context,
    };
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (self.context.pending_op) |op| {
        self.context.pending_op = null;
        if (key.codepoint >= 'a' and key.codepoint <= 'z') {
            const letter: u8 = @intCast(key.codepoint);
            switch (op) {
                .set_mark => self.context.setMark(letter),
                .jump_mark => self.context.jumpToMark(letter),
            }
        }
        return;
    }

    const key_actions = &[_]KeyAction{
        .{
            .codepoint = km.next.codepoint,
            .mods = km.next.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    if (s.document_handler.changePage(1)) {
                        s.resetCurrentPage();
                    }
                }
            }.action,
        },
        .{
            .codepoint = km.prev.codepoint,
            .mods = km.prev.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    if (s.document_handler.changePage(-1)) {
                        s.resetCurrentPage();
                    }
                }
            }.action,
        },
        .{
            .codepoint = km.zoom_in.codepoint,
            .mods = km.zoom_in.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.zoomIn();
                    s.reload_page = true;
                }
            }.action,
        },
        .{
            .codepoint = km.zoom_out.codepoint,
            .mods = km.zoom_out.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.zoomOut();
                    s.reload_page = true;
                }
            }.action,
        },
        .{
            .codepoint = km.width_mode.codepoint,
            .mods = km.width_mode.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.toggleWidthMode();
                    s.reload_page = true;
                }
            }.action,
        },
        .{
            .codepoint = km.crop_to_content.codepoint,
            .mods = km.crop_to_content.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.toggleCropToContent();
                    s.reload_page = true;
                }
            }.action,
        },
        .{
            .codepoint = km.full_screen.codepoint,
            .mods = km.full_screen.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.toggleFullScreen();
                    s.document_handler.resetDefaultZoom();
                    s.reload_page = true;
                }
            }.action,
        },
        .{
            .codepoint = km.scroll_up.codepoint,
            .mods = km.scroll_up.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.scrollY(s.config.general.scroll_step);
                }
            }.action,
        },
        .{
            .codepoint = km.scroll_down.codepoint,
            .mods = km.scroll_down.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.scrollY(-s.config.general.scroll_step);
                }
            }.action,
        },
        .{
            .codepoint = km.scroll_left.codepoint,
            .mods = km.scroll_left.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.scroll(.Left);
                }
            }.action,
        },
        .{
            .codepoint = km.scroll_right.codepoint,
            .mods = km.scroll_right.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.scroll(.Right);
                }
            }.action,
        },
        .{
            .codepoint = km.colorize.codepoint,
            .mods = km.colorize.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.document_handler.toggleColor();
                    s.reload_page = true;
                }
            }.action,
        },
        .{
            .codepoint = km.enter_command_mode.codepoint,
            .mods = km.enter_command_mode.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.changeMode(.command);
                }
            }.action,
        },
        .{
            .codepoint = km.hint_mode.codepoint,
            .mods = km.hint_mode.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.changeMode(.hint);
                }
            }.action,
        },
        .{
            .codepoint = km.set_mark.codepoint,
            .mods = km.set_mark.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.pending_op = .set_mark;
                }
            }.action,
        },
        .{
            .codepoint = km.jump_mark.codepoint,
            .mods = km.jump_mark.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.pending_op = .jump_mark;
                }
            }.action,
        },
        .{
            .codepoint = km.toc_mode.codepoint,
            .mods = km.toc_mode.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.changeMode(.toc);
                }
            }.action,
        },
        .{
            .codepoint = km.marks_mode.codepoint,
            .mods = km.marks_mode.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.changeMode(.marks);
                }
            }.action,
        },
        .{
            .codepoint = km.jump_back.codepoint,
            .mods = km.jump_back.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.jumpBack();
                }
            }.action,
        },
        .{
            .codepoint = km.jump_forward.codepoint,
            .mods = km.jump_forward.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.jumpForward();
                }
            }.action,
        },
        .{
            .codepoint = km.open_in_editor.codepoint,
            .mods = km.open_in_editor.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.openCurrentPageInEditor() catch {};
                }
            }.action,
        },
        .{
            .codepoint = km.open_chapter_in_editor.codepoint,
            .mods = km.open_chapter_in_editor.mods,
            .handler = struct {
                fn action(s: *Context) void {
                    s.openCurrentChapterInEditor() catch {};
                }
            }.action,
        },
    };

    for (key_actions) |action| {
        if (key.matches(action.codepoint, action.mods)) {
            action.handler(self.context);
            return;
        }
    }
}
