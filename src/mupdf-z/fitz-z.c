#include "fitz-z.h"
#include "mupdf/pdf.h"
#include <string.h>

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

static void walk_outline(fz_outline *node, int depth, void *userdata, fz_outline_visit_fn cb) {
  fz_outline *o = node;
  while (o) {
    cb(userdata, o->title ? o->title : "", depth, o->uri ? o->uri : "");
    if (o->down && depth < 32) walk_outline(o->down, depth + 1, userdata, cb);
    o = o->next;
  }
}

void fz_walk_outline_z(fz_context *ctx, fz_document *doc, void *userdata, fz_outline_visit_fn cb) {
  fz_outline *root = NULL;
  fz_try(ctx) { root = fz_load_outline(ctx, doc); }
  fz_catch(ctx) { return; }
  if (!root) return;
  walk_outline(root, 0, userdata, cb);
  fz_drop_outline(ctx, root);
}

#define MD_MAX_TEXT_BBOXES 128

typedef struct {
  fz_output *out;
  fz_page *page;
  const char *base_path; // path to .md without the extension
  fz_rect mediabox;
  fz_rect pending_rect;
  fz_rect text_bboxes[MD_MAX_TEXT_BBOXES];
  int text_bbox_count;
  float body_size;
  int pending_active;
  int image_counter;
  float scale;
  int black;
  int white;
  int in_bold;
  int in_italic;
  int in_mono;
  int last_was_space;
} md_state;

static float md_rect_area(fz_rect r) {
  float w = r.x1 - r.x0;
  float h = r.y1 - r.y0;
  return (w > 0 && h > 0) ? w * h : 0;
}

static float md_intersect_area(fz_rect a, fz_rect b) {
  float x0 = a.x0 > b.x0 ? a.x0 : b.x0;
  float y0 = a.y0 > b.y0 ? a.y0 : b.y0;
  float x1 = a.x1 < b.x1 ? a.x1 : b.x1;
  float y1 = a.y1 < b.y1 ? a.y1 : b.y1;
  if (x1 <= x0 || y1 <= y0) return 0;
  return (x1 - x0) * (y1 - y0);
}

// Fraction of `region` covered by collected text bboxes. Used to decide whether
// a vector region is "text-heavy" (a decorative box around a paragraph — skip
// the raster, keep the text) or sparse (a real diagram with at most a few
// labels — render the raster).
static float md_text_coverage(md_state *st, fz_rect region) {
  float region_area = md_rect_area(region);
  if (region_area <= 0) return 0;
  float covered = 0;
  for (int i = 0; i < st->text_bbox_count; i++) {
    covered += md_intersect_area(st->text_bboxes[i], region);
  }
  return covered / region_area;
}

static void md_collect_text_bboxes(fz_stext_block *blocks, fz_rect *out, int *count, int cap) {
  for (fz_stext_block *b = blocks; b; b = b->next) {
    if (b->type == FZ_STEXT_BLOCK_TEXT) {
      if (*count < cap) out[(*count)++] = b->bbox;
    } else if (b->type == FZ_STEXT_BLOCK_STRUCT && b->u.s.down) {
      md_collect_text_bboxes(b->u.s.down->first_block, out, count, cap);
    }
  }
}

static int md_is_bold(fz_context *ctx, fz_stext_char *c) {
  if (c->flags & FZ_STEXT_BOLD) return 1;
  return c->font && fz_font_is_bold(ctx, c->font);
}
static int md_is_italic(fz_context *ctx, fz_stext_char *c) {
  return c->font && fz_font_is_italic(ctx, c->font);
}
static int md_name_contains_ci(const char *name, const char *needle) {
  if (!name || !needle) return 0;
  size_t nl = strlen(needle);
  for (const char *p = name; *p; p++) {
    size_t i = 0;
    while (i < nl && p[i]) {
      char a = p[i], b = needle[i];
      if (a >= 'A' && a <= 'Z') a += 32;
      if (b >= 'A' && b <= 'Z') b += 32;
      if (a != b) break;
      i++;
    }
    if (i == nl) return 1;
  }
  return 0;
}

static int md_is_mono(fz_context *ctx, fz_stext_char *c) {
  if (!c->font) return 0;
  if (fz_font_is_monospaced(ctx, c->font)) return 1;
  // PDF embedding often strips the monospaced flag; fall back to font-name match.
  const char *name = fz_font_name(ctx, c->font);
  return md_name_contains_ci(name, "mono") ||
         md_name_contains_ci(name, "courier") ||
         md_name_contains_ci(name, "consolas") ||
         md_name_contains_ci(name, "menlo") ||
         md_name_contains_ci(name, "lettergothic") ||
         md_name_contains_ci(name, "typewriter") ||
         md_name_contains_ci(name, "cmtt");
}

static void md_collect_sizes(fz_stext_block *blocks, int counts[], int cap) {
  for (fz_stext_block *b = blocks; b; b = b->next) {
    if (b->type == FZ_STEXT_BLOCK_TEXT) {
      for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
        for (fz_stext_char *c = l->first_char; c; c = c->next) {
          if (c->c <= 32) continue;
          int idx = (int)(c->size + 0.5f);
          if (idx >= 0 && idx < cap) counts[idx]++;
        }
      }
    } else if (b->type == FZ_STEXT_BLOCK_STRUCT && b->u.s.down) {
      md_collect_sizes(b->u.s.down->first_block, counts, cap);
    }
  }
}

static float md_body_size(fz_stext_page *page) {
  int counts[200] = {0};
  md_collect_sizes(page->first_block, counts, 200);
  int best_idx = 10, best = 0;
  for (int i = 4; i < 200; i++) {
    if (counts[i] > best) { best = counts[i]; best_idx = i; }
  }
  return (float)best_idx;
}

static void md_emit_space(fz_context *ctx, md_state *st) {
  if (st->last_was_space) return;
  fz_write_byte(ctx, st->out, ' ');
  st->last_was_space = 1;
}

static void md_close_styles(fz_context *ctx, md_state *st) {
  if (st->in_mono) { fz_write_byte(ctx, st->out, '`'); st->in_mono = 0; }
  if (st->in_italic) { fz_write_byte(ctx, st->out, '*'); st->in_italic = 0; }
  if (st->in_bold) { fz_write_string(ctx, st->out, "**"); st->in_bold = 0; }
}

static void md_sync_styles(fz_context *ctx, md_state *st, int bold, int italic, int mono) {
  // Close inner-first if turning off; open outer-first when turning on.
  if (st->in_mono && !mono) { fz_write_byte(ctx, st->out, '`'); st->in_mono = 0; }
  if (st->in_italic && !italic) { fz_write_byte(ctx, st->out, '*'); st->in_italic = 0; }
  if (st->in_bold && !bold) { fz_write_string(ctx, st->out, "**"); st->in_bold = 0; }
  if (!st->in_bold && bold) { fz_write_string(ctx, st->out, "**"); st->in_bold = 1; }
  if (!st->in_italic && italic) { fz_write_byte(ctx, st->out, '*'); st->in_italic = 1; }
  if (!st->in_mono && mono) { fz_write_byte(ctx, st->out, '`'); st->in_mono = 1; }
}

static void md_emit_text_block(fz_context *ctx, md_state *st, fz_stext_block *b) {
  if (!b->u.t.first_line) return;

  float max_size = 0;
  for (fz_stext_char *c = b->u.t.first_line->first_char; c; c = c->next) {
    if (c->c > 32 && c->size > max_size) max_size = c->size;
  }
  if (st->body_size > 0) {
    float r = max_size / st->body_size;
    if (r >= 1.7f) fz_write_string(ctx, st->out, "# ");
    else if (r >= 1.4f) fz_write_string(ctx, st->out, "## ");
    else if (r >= 1.2f) fz_write_string(ctx, st->out, "### ");
  }

  st->last_was_space = 1; // suppress leading/duplicate spaces
  for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
    for (fz_stext_char *c = l->first_char; c; c = c->next) {
      if (c->c == 0xFFFD || c->c == 0x00AD) continue; // replacement char + soft hyphen
      if (c->c <= 32) {
        md_close_styles(ctx, st);
        md_emit_space(ctx, st);
        continue;
      }
      md_sync_styles(ctx, st, md_is_bold(ctx, c), md_is_italic(ctx, c), md_is_mono(ctx, c));
      fz_write_rune(ctx, st->out, c->c);
      st->last_was_space = 0;
    }
    md_close_styles(ctx, st);
    if (l->next) md_emit_space(ctx, st);
  }
  fz_write_string(ctx, st->out, "\n\n");
  st->last_was_space = 1;
}

static void md_flush_pending(fz_context *ctx, md_state *st) {
  if (!st->pending_active) return;
  fz_rect r = st->pending_rect;
  st->pending_active = 0;
  st->pending_rect = fz_empty_rect;

  float w = r.x1 - r.x0;
  float h = r.y1 - r.y0;
  // Filter junk: too small (single rule/glyph trace) or essentially the whole page (background tints).
  if (w < 30 || h < 30) return;
  float page_w = st->mediabox.x1 - st->mediabox.x0;
  float page_h = st->mediabox.y1 - st->mediabox.y0;
  if (page_w > 0 && page_h > 0 && w > 0.95f * page_w && h > 0.95f * page_h) return;
  // If the region is mostly text (a decorative box around a paragraph) keep the
  // copyable text and skip the raster — point of the editor flow is to copy
  // text. Pure diagrams with sparse labels (< 25% text coverage) still render.
  if (md_text_coverage(st, r) > 0.25f) return;

  st->image_counter++;
  char img_path[1024];
  snprintf(img_path, sizeof(img_path), "%s/img%d.png", st->base_path, st->image_counter);

  fz_pixmap *pix = NULL;
  fz_device *dev = NULL;
  fz_try(ctx) {
    float scale = st->scale > 0 ? st->scale : 4.0f;
    fz_matrix ctm = fz_pre_translate(fz_scale(scale, scale), -r.x0, -r.y0);
    fz_irect ibox = fz_make_irect(0, 0, (int)(w * scale + 0.5f), (int)(h * scale + 0.5f));
    pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), ibox, NULL, 0);
    fz_clear_pixmap_with_value(ctx, pix, 0xff);
    dev = fz_new_draw_device(ctx, ctm, pix);
    fz_run_page(ctx, st->page, dev, fz_identity, NULL);
    fz_close_device(ctx, dev);
    fz_tint_pixmap(ctx, pix, st->black, st->white);
    fz_save_pixmap_as_png(ctx, pix, img_path);
    // Emit a relative reference so the md is self-contained inside its dir.
    fz_write_printf(ctx, st->out, "![](img%d.png)\n\n", st->image_counter);
  }
  fz_always(ctx) {
    if (dev) fz_drop_device(ctx, dev);
    if (pix) fz_drop_pixmap(ctx, pix);
  }
  fz_catch(ctx) {
    // best-effort; on failure just drop the reference
    st->image_counter--;
  }
}

static void md_walk(fz_context *ctx, md_state *st, fz_stext_block *blocks) {
  float page_h = st->mediabox.y1 - st->mediabox.y0;
  float footer_y = (page_h > 0) ? st->mediabox.y1 - 0.05f * page_h : 0;
  for (fz_stext_block *b = blocks; b; b = b->next) {
    if (b->type == FZ_STEXT_BLOCK_TEXT) {
      if (page_h > 0 && b->bbox.y0 >= footer_y) continue;
      md_flush_pending(ctx, st);
      md_emit_text_block(ctx, st, b);
    } else if (b->type == FZ_STEXT_BLOCK_STRUCT && b->u.s.down) {
      md_walk(ctx, st, b->u.s.down->first_block);
    } else if (b->type == FZ_STEXT_BLOCK_IMAGE || b->type == FZ_STEXT_BLOCK_VECTOR) {
      if (page_h > 0 && b->bbox.y0 >= footer_y) continue;
      if (!st->pending_active) {
        st->pending_rect = b->bbox;
        st->pending_active = 1;
      } else {
        st->pending_rect = fz_union_rect(st->pending_rect, b->bbox);
      }
    }
  }
  md_flush_pending(ctx, st);
}

static void md_print_page(fz_context *ctx, fz_output *out, fz_page *page, fz_stext_page *stext, const char *base_path, float scale, int black, int white) {
  md_state st = {
    .out = out,
    .page = page,
    .base_path = base_path,
    .mediabox = stext->mediabox,
    .body_size = md_body_size(stext),
    .scale = scale,
    .black = black,
    .white = white,
  };
  md_walk(ctx, &st, stext->first_block);
}

int fz_write_pages_text_z(fz_context *ctx, fz_document *doc, int start_page, int end_page, const char *path, float scale, int black, int white, fz_progress_fn on_progress, void *progress_userdata) {
  int ok = 0;
  fz_output *out = NULL;

  // base = dirname(path). Images go next to the .md in the same directory.
  char base[1024];
  size_t plen = strlen(path);
  if (plen >= sizeof(base)) plen = sizeof(base) - 1;
  memcpy(base, path, plen);
  base[plen] = 0;
  char *slash = strrchr(base, '/');
  if (slash) *slash = 0;
  else base[0] = '.', base[1] = 0;

  md_state st = {
    .base_path = base,
    .scale = scale,
    .black = black,
    .white = white,
  };

  fz_stext_options opts = { .flags = FZ_STEXT_PRESERVE_IMAGES | FZ_STEXT_COLLECT_VECTORS | FZ_STEXT_DEHYPHENATE };
  fz_try(ctx) {
    out = fz_new_output_with_path(ctx, path, 0);
    fz_write_string(ctx, out, "<!-- markdownlint-disable -->\n\n");
    st.out = out;

    int total = end_page - start_page;
    for (int p = start_page; p < end_page; p++) {
      if (on_progress) on_progress(progress_userdata, p - start_page, total);
      fz_page *page = NULL;
      fz_stext_page *stext = NULL;
      fz_try(ctx) {
        page = fz_load_page(ctx, doc, p);
        stext = fz_new_stext_page_from_page(ctx, page, &opts);
        st.page = page;
        st.mediabox = stext->mediabox;
        st.body_size = md_body_size(stext);
        st.in_bold = 0;
        st.in_italic = 0;
        st.in_mono = 0;
        st.pending_active = 0;
        st.text_bbox_count = 0;
        md_collect_text_bboxes(stext->first_block, st.text_bboxes, &st.text_bbox_count, MD_MAX_TEXT_BBOXES);
        md_walk(ctx, &st, stext->first_block);
      }
      fz_always(ctx) {
        if (stext) fz_drop_stext_page(ctx, stext);
        if (page) fz_drop_page(ctx, page);
      }
      fz_catch(ctx) {
        // Skip this page on error, keep going.
      }
    }

    if (on_progress) on_progress(progress_userdata, total, total);
    fz_close_output(ctx, out);
    ok = 1;
  }
  fz_always(ctx) {
    if (out) fz_drop_output(ctx, out);
  }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

int fz_write_page_text_z(fz_context *ctx, fz_document *doc, int page_num, const char *path, float scale, int black, int white) {
  return fz_write_pages_text_z(ctx, doc, page_num, page_num + 1, path, scale, black, white, NULL, NULL);
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
