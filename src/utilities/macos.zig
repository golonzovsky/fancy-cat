// CoreGraphics can't be @cImport'ed: the SDK umbrella contains Objective-C
// block syntax that Zig's translate-c rejects (CGBitmapContext.h callbacks).
// Declare the three calls we need instead; the framework is linked in build.zig.
const CGDirectDisplayID = u32;
const CGSize = extern struct { width: f64, height: f64 };
extern "c" fn CGMainDisplayID() CGDirectDisplayID;
extern "c" fn CGDisplayScreenSize(display: CGDirectDisplayID) CGSize;
extern "c" fn CGDisplayPixelsWide(display: CGDirectDisplayID) usize;

pub fn getDPI() ?f32 {
    const display = CGMainDisplayID();
    const size_mm = CGDisplayScreenSize(display);
    const width_px = CGDisplayPixelsWide(display);
    if (size_mm.width <= 0 or width_px == 0) return null;
    return @floatCast(@as(f64, @floatFromInt(width_px)) / size_mm.width * 25.4);
}
