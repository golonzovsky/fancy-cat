#ifndef DPI_Z_H
#define DPI_Z_H

// Returns the active display's horizontal DPI as a float, or 0 if it could not
// be determined. Implemented in dpi-z.c using CoreGraphics directly so we never
// route the Apple SDK headers (which contain Objective-C blocks) through Zig's
// translate-c.
float fzc_get_display_dpi(void);

#endif
