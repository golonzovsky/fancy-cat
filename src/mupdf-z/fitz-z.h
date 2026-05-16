#include "mupdf/fitz.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename);
int fz_count_pages_z(fz_context *ctx, fz_document *doc);
fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number);
fz_link *fz_load_links_z(fz_context *ctx, fz_page *page);
int fz_resolve_link_page_z(fz_context *ctx, fz_document *doc, const char *uri);
// Like fz_resolve_link_page_z but also outputs the destination y in PDF units (0 if unknown).
int fz_resolve_link_target_z(fz_context *ctx, fz_document *doc, const char *uri, float *yp);
// Walks the document outline, invoking cb for each entry in pre-order.
typedef void (*fz_outline_visit_fn)(void *userdata, const char *title, int depth, const char *uri);
void fz_walk_outline_z(fz_context *ctx, fz_document *doc, void *userdata, fz_outline_visit_fn cb);
// Writes hex of the first /ID string into out (size out_size). Returns length on success, 0 on missing.
int fz_pdf_id_hex_z(fz_context *ctx, fz_document *doc, char *out, int out_size);
// Computes the tight bounding box of all drawn content on a page. Returns 1 on success.
int fz_page_content_bbox_z(fz_context *ctx, fz_page *page, fz_rect *out);
// Streaming-style page extractor. The C side walks mupdf's stext, filters footers and
// diagram-vs-text regions, rasterizes vector diagrams to PNG, and surfaces structured events
// to the Zig caller, which is responsible for all markdown formatting.

typedef struct {
    unsigned int codepoint;
    unsigned char bold;
    unsigned char italic;
    unsigned char mono;
    unsigned char _pad;
    float size;
    float origin_y; // baseline y in PDF coords (caller uses this for superscript detection)
} fz_char_z;

// Event kinds delivered to fz_extract_event_fn. The `chars`/`n` payload is non-NULL for LINE
// only; the `str` payload is non-NULL for IMAGE (relative filename of the rendered PNG).
enum {
    FZ_EXTRACT_EVENT_PAGE_START = 0, // chars[0].size carries the body-font size for this page
    FZ_EXTRACT_EVENT_LINE = 1,       // one text line; chars[0..n] is the line content
    FZ_EXTRACT_EVENT_BLOCK_END = 2,  // paragraph boundary
    FZ_EXTRACT_EVENT_IMAGE = 3,      // a diagram PNG was written; str is its basename
    FZ_EXTRACT_EVENT_PAGE_END = 4,
};

typedef void (*fz_extract_event_fn)(void *userdata, int kind, const fz_char_z *chars, int n, const char *str);
typedef void (*fz_progress_fn)(void *userdata, int current, int total);

// Walks pages [start_page, end_page). For each text line emits FZ_EXTRACT_EVENT_LINE; between
// blocks emits BLOCK_END; for non-text regions worth rendering, writes `<image_dir_abs>/img<N>.png`
// and emits IMAGE with the basename `img<N>.png`. `scale` is pixels-per-PDF-point for diagrams.
// `(black, white)` tints diagrams; pass (0x000000, 0xffffff) for identity. `on_progress` may be NULL.
int fz_extract_pages_z(
    fz_context *ctx, fz_document *doc, int start_page, int end_page,
    float scale, int black, int white,
    const char *image_dir_abs,
    fz_extract_event_fn on_event, void *event_userdata,
    fz_progress_fn on_progress, void *progress_userdata);
