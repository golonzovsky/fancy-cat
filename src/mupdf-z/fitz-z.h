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
// Extracts the text of a page via mupdf's stext device and writes it to `path`. Returns 1 on success.
// Diagrams alongside the markdown are rasterized at `scale` (pixels per PDF point) and tinted with
// the given black/white colors. Pass (0x000000, 0xffffff) for an identity tint.
int fz_write_page_text_z(fz_context *ctx, fz_document *doc, int page_num, const char *path, float scale, int black, int white);
// Same as fz_write_page_text_z but for an inclusive page range [start_page, end_page). Diagram
// numbering is global across the whole range. `on_progress` is invoked once per page (NULL to
// disable).
typedef void (*fz_progress_fn)(void *userdata, int current, int total);
int fz_write_pages_text_z(fz_context *ctx, fz_document *doc, int start_page, int end_page, const char *path, float scale, int black, int white, fz_progress_fn on_progress, void *progress_userdata);
