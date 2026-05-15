#include "dpi-z.h"

#ifdef __APPLE__
#include <CoreGraphics/CoreGraphics.h>

float fzc_get_display_dpi(void) {
  CGDirectDisplayID display = CGMainDisplayID();
  CGSize size_mm = CGDisplayScreenSize(display);
  size_t width_px = CGDisplayPixelsWide(display);
  if (size_mm.width <= 0.0 || width_px == 0) return 0.0f;
  return (float)((double)width_px / (double)size_mm.width * 25.4);
}
#else
float fzc_get_display_dpi(void) { return 0.0f; }
#endif
