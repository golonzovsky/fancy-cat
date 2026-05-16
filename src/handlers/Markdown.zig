// Consumes structured page events from `fz_extract_pages_z` and emits markdown
// to an `std.Io.Writer`. All formatting heuristics live here.
const Self = @This();
const std = @import("std");

pub const Char = extern struct {
    codepoint: u32,
    bold: u8,
    italic: u8,
    mono: u8,
    _pad: u8,
    size: f32,
    origin_y: f32,
};

const event_page_start = 0;
const event_line = 1;
const event_block_end = 2;
const event_image = 3;
const event_page_end = 4;

allocator: std.mem.Allocator,
writer: *std.Io.Writer,
body_size: f32 = 0,
chars: std.ArrayList(Char) = .empty,
line_offsets: std.ArrayList(u32) = .empty, // offset into `chars` where each line begins
in_code_block: bool = false,
write_failed: bool = false,

pub fn init(allocator: std.mem.Allocator, writer: *std.Io.Writer) Self {
    return .{ .allocator = allocator, .writer = writer };
}

pub fn deinit(self: *Self) void {
    self.chars.deinit(self.allocator);
    self.line_offsets.deinit(self.allocator);
}

pub fn finalize(self: *Self) !void {
    self.closeCodeBlock();
}

pub fn eventCallback(ud: ?*anyopaque, kind: c_int, chars: ?[*]const Char, n: c_int, str: ?[*:0]const u8) callconv(.c) void {
    const self = @as(*Self, @ptrCast(@alignCast(ud.?)));
    self.handle(kind, chars, n, str) catch {
        self.write_failed = true;
    };
}

fn handle(self: *Self, kind: c_int, chars_ptr: ?[*]const Char, n: c_int, str: ?[*:0]const u8) !void {
    switch (kind) {
        event_page_start => if (chars_ptr) |p| {
            self.body_size = p[0].size;
        },
        event_line => if (chars_ptr) |p| {
            const slice = p[0..@intCast(n)];
            try self.line_offsets.append(self.allocator, @intCast(self.chars.items.len));
            try self.chars.appendSlice(self.allocator, slice);
        },
        event_block_end => try self.flushBlock(),
        event_image => if (str) |s| {
            self.closeCodeBlock();
            try self.writer.print("![]({s})\n\n", .{std.mem.span(s)});
        },
        event_page_end => {},
        else => {},
    }
}

fn flushBlock(self: *Self) !void {
    defer {
        self.chars.clearRetainingCapacity();
        self.line_offsets.clearRetainingCapacity();
    }
    if (self.line_offsets.items.len == 0) return;

    if (blockIsAllMono(self.chars.items)) {
        try self.openCodeBlock();
        try self.emitCode();
        return;
    }

    self.closeCodeBlock();

    const first_line = self.lineSlice(0);
    var max_size: f32 = 0;
    for (first_line) |ch| {
        if (ch.codepoint > 32 and ch.size > max_size) max_size = ch.size;
    }
    var body_start: usize = 0;
    if (self.body_size > 0 and max_size / self.body_size >= 1.2) {
        const ratio = max_size / self.body_size;
        const prefix: []const u8 = if (ratio >= 1.7) "# " else if (ratio >= 1.4) "## " else "### ";
        try self.writer.writeAll(prefix);
        try self.emitHeadingLine(first_line);
        try self.writer.writeAll("\n\n");
        body_start = 1;
        if (body_start >= self.line_offsets.items.len) return;
    }

    try self.emitParagraph(body_start);
}

fn lineSlice(self: *const Self, i: usize) []const Char {
    const start = self.line_offsets.items[i];
    const end: u32 = if (i + 1 < self.line_offsets.items.len) self.line_offsets.items[i + 1] else @intCast(self.chars.items.len);
    return self.chars.items[start..end];
}

fn blockIsAllMono(chars: []const Char) bool {
    var saw_any = false;
    for (chars) |ch| {
        if (ch.codepoint <= 32 or ch.codepoint == 0xFFFD or ch.codepoint == 0x00AD) continue;
        saw_any = true;
        if (ch.mono == 0) return false;
    }
    return saw_any;
}

fn openCodeBlock(self: *Self) !void {
    if (self.in_code_block) return;
    try self.writer.writeAll("```\n");
    self.in_code_block = true;
}

fn closeCodeBlock(self: *Self) void {
    if (!self.in_code_block) return;
    self.writer.writeAll("```\n\n") catch {};
    self.in_code_block = false;
}

fn emitCode(self: *Self) !void {
    var i: usize = 0;
    while (i < self.line_offsets.items.len) : (i += 1) {
        for (self.lineSlice(i)) |ch| {
            if (ch.codepoint == 0xFFFD or ch.codepoint == 0x00AD) continue;
            if (ch.codepoint <= 32) {
                try self.writer.writeByte(' ');
                continue;
            }
            try writeRune(self.writer, ch.codepoint);
        }
        try self.writer.writeByte('\n');
    }
}

fn emitHeadingLine(self: *Self, chars: []const Char) !void {
    var last_was_space = true; // suppress leading space
    for (chars) |ch| {
        if (ch.codepoint == 0xFFFD or ch.codepoint == 0x00AD) continue;
        if (ch.codepoint <= 32) {
            if (!last_was_space) {
                try self.writer.writeByte(' ');
                last_was_space = true;
            }
            continue;
        }
        try writeRune(self.writer, ch.codepoint);
        last_was_space = false;
    }
}

fn emitParagraph(self: *Self, start_line: usize) !void {
    var pp = ParaState{};
    var li = start_line;
    while (li < self.line_offsets.items.len) : (li += 1) {
        const line = self.lineSlice(li);
        try self.emitParaLine(&pp, line);
        if (li + 1 < self.line_offsets.items.len and !pp.last_was_space) pp.pending_space = true;
    }
    self.closeStyles(&pp);
    try self.writer.writeAll("\n\n");
}

const ParaState = struct {
    in_bold: bool = false,
    in_italic: bool = false,
    in_mono: bool = false,
    last_was_space: bool = true,
    pending_space: bool = false,
};

fn emitParaLine(self: *Self, p: *ParaState, chars: []const Char) !void {
    var i: usize = 0;
    while (i < chars.len) : (i += 1) {
        const ch = chars[i];
        if (ch.codepoint == 0xFFFD or ch.codepoint == 0x00AD) continue;
        if (ch.codepoint <= 32) {
            if (!p.last_was_space) p.pending_space = true;
            continue;
        }

        // Superscript run: scan ahead for the run's end. If every char maps to a
        // Unicode superscript glyph, emit each translated. Otherwise wrap the
        // run in <sup>...</sup> so renderers can still surface it.
        if (isSuper(chars, i)) {
            var j = i;
            while (j < chars.len and isSuper(chars, j) and chars[j].codepoint > 32) : (j += 1) {}
            const run = chars[i..j];
            var all_translatable = true;
            for (run) |sch| {
                if (asSuperscript(sch.codepoint) == null) {
                    all_translatable = false;
                    break;
                }
            }

            // Close emph before the pending space if the run's first char ends a styled run.
            if (p.pending_space) {
                if (p.in_mono and run[0].mono == 0) { try self.writer.writeByte('`'); p.in_mono = false; }
                if (p.in_italic and run[0].italic == 0) { try self.writer.writeByte('*'); p.in_italic = false; }
                if (p.in_bold and run[0].bold == 0) { try self.writer.writeAll("**"); p.in_bold = false; }
                try self.writer.writeByte(' ');
                p.last_was_space = true;
                p.pending_space = false;
            }
            // Close any open mono span around <sup> — markdown ignores tags inside `code`.
            if (!all_translatable and p.in_mono) {
                try self.writer.writeByte('`');
                p.in_mono = false;
            }

            if (all_translatable) {
                for (run) |sch| try writeRune(self.writer, asSuperscript(sch.codepoint).?);
            } else {
                try self.writer.writeAll("<sup>");
                for (run) |sch| try writeRune(self.writer, sch.codepoint);
                try self.writer.writeAll("</sup>");
            }
            p.last_was_space = false;
            i = j - 1; // outer while increments
            continue;
        }

        // Normalize TeX-style double quotes (`` and '' → ").
        if ((ch.codepoint == '`' or ch.codepoint == '\'') and i + 1 < chars.len and chars[i + 1].codepoint == ch.codepoint) {
            try self.emitPendingSpace(p);
            if (p.in_mono) {
                try self.writer.writeByte('`');
                p.in_mono = false;
            }
            try self.writer.writeByte('"');
            p.last_was_space = false;
            i += 1;
            continue;
        }
        var rune: u32 = ch.codepoint;
        if (rune == '`') rune = '\''; // lone backtick → apostrophe

        const bold = ch.bold != 0;
        const italic = ch.italic != 0;
        const mono = ch.mono != 0;

        if (p.pending_space) {
            // Close emph BEFORE the space so the closing marker isn't preceded by whitespace.
            if (p.in_mono and !mono) {
                try self.writer.writeByte('`');
                p.in_mono = false;
            }
            if (p.in_italic and !italic) {
                try self.writer.writeByte('*');
                p.in_italic = false;
            }
            if (p.in_bold and !bold) {
                try self.writer.writeAll("**");
                p.in_bold = false;
            }
            try self.writer.writeByte(' ');
            p.last_was_space = true;
            p.pending_space = false;
        }

        try self.syncStyles(p, bold, italic, mono);
        try writeRune(self.writer, rune);
        p.last_was_space = false;
    }
}

fn emitPendingSpace(self: *Self, p: *ParaState) !void {
    if (!p.pending_space) return;
    try self.writer.writeByte(' ');
    p.pending_space = false;
    p.last_was_space = true;
}

fn syncStyles(self: *Self, p: *ParaState, bold: bool, italic: bool, mono: bool) !void {
    if (p.in_mono and !mono) {
        try self.writer.writeByte('`');
        p.in_mono = false;
    }
    if (p.in_italic and !italic) {
        try self.writer.writeByte('*');
        p.in_italic = false;
    }
    if (p.in_bold and !bold) {
        try self.writer.writeAll("**");
        p.in_bold = false;
    }
    if (!p.in_bold and bold) {
        try self.writer.writeAll("**");
        p.in_bold = true;
    }
    if (!p.in_italic and italic) {
        try self.writer.writeByte('*');
        p.in_italic = true;
    }
    if (!p.in_mono and mono) {
        try self.writer.writeByte('`');
        p.in_mono = true;
    }
}

fn closeStyles(self: *Self, p: *ParaState) void {
    if (p.in_mono) {
        self.writer.writeByte('`') catch {};
        p.in_mono = false;
    }
    if (p.in_italic) {
        self.writer.writeByte('*') catch {};
        p.in_italic = false;
    }
    if (p.in_bold) {
        self.writer.writeAll("**") catch {};
        p.in_bold = false;
    }
}

// A char is superscript if it's smaller than the line's dominant font AND its
// baseline is raised above that of the dominant chars. Inline small monospace
// (e.g. `gridDim.x`) sits on the baseline so it's not flagged.
fn isSuper(chars: []const Char, idx: usize) bool {
    const ch = chars[idx];
    if (ch.codepoint <= 32) return false;
    var max_size: f32 = 0;
    for (chars) |c| {
        if (c.codepoint > 32 and c.size > max_size) max_size = c.size;
    }
    if (max_size <= 0 or ch.size >= max_size * 0.85) return false;
    var baseline: f32 = 0;
    var n: f32 = 0;
    for (chars) |c| {
        if (c.codepoint > 32 and c.size >= max_size * 0.95) {
            baseline += c.origin_y;
            n += 1;
        }
    }
    if (n == 0) return false;
    return ch.origin_y < baseline / n - 1.0;
}

fn asSuperscript(cp: u32) ?u32 {
    return switch (cp) {
        '0' => 0x2070,
        '1' => 0x00B9,
        '2' => 0x00B2,
        '3' => 0x00B3,
        '4' => 0x2074,
        '5' => 0x2075,
        '6' => 0x2076,
        '7' => 0x2077,
        '8' => 0x2078,
        '9' => 0x2079,
        '+' => 0x207A,
        '-' => 0x207B,
        '=' => 0x207C,
        '(' => 0x207D,
        ')' => 0x207E,
        'n' => 0x207F,
        'i' => 0x2071,
        else => null,
    };
}

fn writeRune(w: *std.Io.Writer, rune: u32) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(@intCast(rune), &buf);
    try w.writeAll(buf[0..len]);
}
