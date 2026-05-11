#include "mupdf/fitz.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename);
int fz_count_pages_z(fz_context *ctx, fz_document *doc);
fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number);
fz_link *fz_load_links_z(fz_context *ctx, fz_page *page);
int fz_resolve_link_page_z(fz_context *ctx, fz_document *doc, const char *uri);
// Writes hex of the first /ID string into out (size out_size). Returns length on success, 0 on missing.
int fz_pdf_id_hex_z(fz_context *ctx, fz_document *doc, char *out, int out_size);
