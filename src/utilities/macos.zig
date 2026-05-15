const std = @import("std");

// DPI is fetched via a C helper (`src/mupdf-z/dpi-z.c`) that calls CoreGraphics
// directly. We can't @cImport CoreGraphics under Zig 0.16 because the macOS SDK
// headers use Objective-C block syntax that translate-c can't parse; the C
// compiler handles it fine, so the wrapper exposes a single plain-C function.
const c = @cImport({
    @cInclude("dpi-z.h");
});

pub fn getDPI() ?f32 {
    const dpi = c.fzc_get_display_dpi();
    if (dpi <= 0) return null;
    return dpi;
}
