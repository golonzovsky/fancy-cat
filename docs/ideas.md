# fancy-cat — feature ideas / roadmap

Living list of candidate features, scored for **this** use case (deep single-book
reading in a terminal: spread + crop + invert at high zoom, vim-style power user).
Effort/value are rough. "Unlocked by speed" = newly practical because rendering is
now cheap (PNG + kitty `t=t` temp-file transfer, off-thread prerender, ReleaseSafe,
clip-region-only scroll redraws).

## Unlocked by the speed work

| Feature | Value | Effort | Why now possible |
|---|---|---|---|
| **Figure-preview "portals"** — pop a small second kitty image of a referenced figure/table/equation in place while reading | high | high | second-image cropped render + placement used to stall; now cheap. `fz_extract_pages_z` already crops/rasterizes diagram regions; marks already store page+scroll+comment |
| **Reading guide / ruler** — translucent band over the current line, advances with j/k | med | med | was a re-render per line move; now a clip update or one-pass blend (`tintRects`). `fz_line_text_at_z` gives the line bbox |
| **Pixel-smooth sub-cell scroll + inertia** — scroll by pixels with momentum, not cell-quantized steps | med | high | ❌ tried & removed: sub-cell clip distorts on Ghostty (scales the partial top cell), and cell-stepped momentum wasn't worth it. Would need fixing kitty-graphics clip scaling upstream |
| **Thumbnail page-grid jump** — contact-sheet of pages to scan + jump | med | med | vaxis downscales cached pages ~free; low-zoom renders fast now. Reuses `gotoHit`/`pushJump` |
| ~~**Wider render-ahead (±3)**~~ ✅ done — prerender a deeper window so fast flipping stays warm | med | low | 6-slot prerenderer, ±3 forward-biased window, cache bumped to 14 pages |
| **Live search-as-you-type preview** | med | high | per-keystroke page preview is now cheap — BUT `runSearch` is a synchronous full-doc scan; still needs debounce + cancellable background search |

## Cheap, high-value wins (finish the reading workflow)

- **Export highlights + notes** (`:notes`) — open all highlights for the doc in `$EDITOR` as markdown grouped by chapter with page numbers; OSC52 copy variant. Highlights are write-only today. *(value high, effort low)*
- **Typed note on a highlight** — attach free text (mirrors `Mark.comment`), shown in the `V` navigator + exports. *(high / low)*
- **Page labels** — `:goto 42` lands on *printed* p.42, not physical page 42 (roman front matter). ~10-line wrapper around mupdf `pdf_page_label`. *(high / low)*
- **TOC fuzzy filter** — type-to-filter the outline; lift the `SearchListMode` text-input pattern into `TocMode`. *(high / low)*
- **Quote/citation export** — on a selection, copy as `> quote (p.N)`; small delta on `finishSelection`. *(high / low)*
- **`:pipe <cmd>`** — pipe selection text to a shell command stdin (LLM "explain", dictionary, translate), flash stdout. `fzfPick` shows the pipe wiring. *(high / med)*
- **Highlight colors / categories** — tag highlights, filter in navigator; `tintRects` needs per-quad color threaded through. *(high / med)*

## Smaller nice-to-haves

- Reading progress / time-left ETA + per-chapter progress in the status bar (`currentChapterRange` exists).
- ~~Fit-width lock~~ ✅ done (`W` / `:fit`): zoom locked to cropped page width (or 2-page in spread), tracks resize. Other fit modes (fit-page) still possible.
- Command palette over the `CommandMode.commands` table.
- Page rotation (`fz_pre_rotate` + swap w/h) for fold-out tables.
- Low-res first-paint then full-res swap (only helps cold misses; prerender covers neighbors).
- Sepia / extra color schemes (different `fz_tint_pixmap` pair).

## Skip (poor fit here)

- Cross-document highlight/mark review — needs re-init of the single-doc Context.
- Regex / whole-document search — mupdf search is literal-only, 128-quad/page cap.
- Animated continuous zoom — zoom is a cache key, so every level re-renders.
- Animated page-turn slide — duplicates the continuous-scroll feel.
- N-up beyond two columns — unreadably small.
- EPUB/CBZ/XPS — reflowable layout breaks the fixed-page model crop/spread/page-labels assume.
- SyncTeX, presenter mode, TTS — off-mission for a single-pane deep reader.
- Bookmarks bar — redundant with jump history (Ctrl-O/Tab) + named marks.

## Status

- [ ] Momentum / smooth in-page scroll — **tried, removed**. Sub-cell (pixel-exact)
  positioning distorts on Ghostty (clipping at a non-cell pixel makes it scale the
  partial top cell); without it, momentum was only cell-stepped and not worth the
  complexity. Scroll is plain/instant. `Ctrl+D`/`Ctrl+U` half-page animation is kept.
- [x] Wider render-ahead (±3) — **done**
