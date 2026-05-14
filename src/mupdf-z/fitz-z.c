#include "fitz-z.h"
#include "mupdf/pdf.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename) {
  fz_document *doc = NULL;
  fz_try(ctx) { doc = fz_open_document(ctx, filename); }
  fz_catch(ctx) {}
  return doc;
}

int fz_count_pages_z(fz_context *ctx, fz_document *doc) {
  int count = 0;
  fz_try(ctx) { count = fz_count_pages(ctx, doc); }
  fz_catch(ctx) {}
  return count;
}

fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number) {
  fz_page *page = NULL;
  fz_try(ctx) { page = fz_load_page(ctx, doc, page_number); }
  fz_catch(ctx) {}
  return page;
}

fz_link *fz_load_links_z(fz_context *ctx, fz_page *page) {
  fz_link *links = NULL;
  fz_try(ctx) { links = fz_load_links(ctx, page); }
  fz_catch(ctx) {}
  return links;
}

int fz_resolve_link_page_z(fz_context *ctx, fz_document *doc, const char *uri) {
  int page = -1;
  fz_try(ctx) {
    fz_location loc = fz_resolve_link(ctx, doc, uri, NULL, NULL);
    page = fz_page_number_from_location(ctx, doc, loc);
  }
  fz_catch(ctx) {}
  return page;
}

int fz_resolve_link_target_z(fz_context *ctx, fz_document *doc, const char *uri, float *yp) {
  int page = -1;
  float x = 0, y = 0;
  fz_try(ctx) {
    fz_location loc = fz_resolve_link(ctx, doc, uri, &x, &y);
    page = fz_page_number_from_location(ctx, doc, loc);
  }
  fz_catch(ctx) {}
  if (yp) *yp = y;
  return page;
}

int fz_page_content_bbox_z(fz_context *ctx, fz_page *page, fz_rect *out) {
  int ok = 0;
  fz_device *dev = NULL;
  fz_rect bbox = fz_empty_rect;
  fz_try(ctx) {
    dev = fz_new_bbox_device(ctx, &bbox);
    fz_run_page(ctx, page, dev, fz_identity, NULL);
    fz_close_device(ctx, dev);
    *out = bbox;
    ok = 1;
  }
  fz_always(ctx) { if (dev) fz_drop_device(ctx, dev); }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

int fz_pdf_id_hex_z(fz_context *ctx, fz_document *doc, char *out, int out_size) {
  int written = 0;
  fz_try(ctx) {
    pdf_document *pdoc = pdf_specifics(ctx, doc);
    if (!pdoc) fz_throw(ctx, FZ_ERROR_GENERIC, "not a pdf");
    pdf_obj *trailer = pdf_trailer(ctx, pdoc);
    if (!trailer) fz_throw(ctx, FZ_ERROR_GENERIC, "no trailer");
    pdf_obj *id_array = pdf_dict_gets(ctx, trailer, "ID");
    if (!id_array) fz_throw(ctx, FZ_ERROR_GENERIC, "no /ID");
    pdf_obj *first = pdf_array_get(ctx, id_array, 0);
    if (!first) fz_throw(ctx, FZ_ERROR_GENERIC, "no /ID[0]");
    size_t len = 0;
    const char *bytes = pdf_to_string(ctx, first, &len);
    if (!bytes || len == 0) fz_throw(ctx, FZ_ERROR_GENERIC, "empty /ID");
    int need = (int)(len * 2);
    if (need + 1 > out_size) fz_throw(ctx, FZ_ERROR_GENERIC, "buf too small");
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
      out[2 * i] = hex[(unsigned char)bytes[i] >> 4];
      out[2 * i + 1] = hex[(unsigned char)bytes[i] & 0xF];
    }
    out[need] = 0;
    written = need;
  }
  fz_catch(ctx) { written = 0; }
  return written;
}
