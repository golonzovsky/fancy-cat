<h1>
<p align="center">
  📑
  <br>fancy-cat
</h1>
  <p align="center">
    PDF viewer for terminals using the Kitty image protocol
    <br />
  </p>
</p>

![demo](https://github.com/user-attachments/assets/b1edc9d2-3b1f-437d-9b48-c196d22fcbbd)

## Fork notes

This is a fork of [freref/fancy-cat](https://github.com/freref/fancy-cat) with the following changes on top of upstream:

- **Continuous scroll across pages** — scroll past a page boundary and the next page is rendered in the same viewport; no per-page snap.
- **Smooth in-page scrolling via kitty `clip_region`** — each page is rasterized once at the current zoom and transmitted to the terminal once, then scrolling just updates the placement's source rect (~50 bytes/event) instead of re-rendering. Adjacent pages are stacked with cell-aligned placements; sub-cell page-bottom remainders are scaled to fill (`r=/c=`) so nothing is lost at page boundaries.
- **Mouse / trackpad support** — wheel up/down/left/right scrolls; `Shift+wheel` scrolls horizontally; `Ctrl`/`Alt`+wheel zooms; left-click follows PDF links (internal → goToPage with destination y, URI → `open <uri>`). `:hlock` disables horizontal wheel for reading-mode trackpad use.
- **Full-text search** (`/`, then `N`/`P` for next/prev match, Esc clears) — scans the whole document via mupdf and highlights hits by inverting their rects in the rendered page. `S` opens a search finder: type a query, get the full match list with the containing text line per hit; `Enter` jumps, the needle is emphasized in each row.
- **Mouse text selection → clipboard** — drag with the left button; endpoints map to PDF space and snap to characters via mupdf's structured text, so the selection follows real text lines rather than terminal cells. On release the text is copied to the system clipboard (OSC 52). Esc clears the selection.
- **Highlights** (`H` / `V`) — `H` persists the current selection as a highlight, rendered as a yellow blend baked into the page raster (legible in colorize mode too). Overlapping highlights merge into one by re-selecting the union span, so the stored text stays exact. `V` opens a navigator listing each highlight with its text (`Enter` jumps, `d` deletes). Highlights live in `positions.json` — the PDF file is never modified.
- **Two-column spread** (`d` or `:spread`) — continuous flow for wide monitors: the page strip fills the left column and continues into the right, half pages allowed, so tall pages stay readable without shrinking.
- **Auto-crop margins** (`t`) — computes a document-stable text bounding box (samples ~48 pages, trims outliers per edge) so every page shares one crop box; pages without text fall back to the drawn-content bbox.
- **Manual margin crop** (`:crop T R B L`) — trims margins in PDF points with CSS-shorthand value rules (1/2/3/4 values); applied after the odd-page offset; current values shown in the status bar; bare `:crop` resets.
- **Odd-page horizontal alignment** (`:oddx N`) — for books with asymmetric inner margins. Shift is baked into the mupdf CTM during render, so no display gap appears.
- **Background prerendering** — a worker thread renders the adjacent pages ahead of time so page crossings hit the cache instead of stalling on a render.
- **Fast image transfer** — pages are encoded as PNG (10–40× smaller than raw RGB) and handed to the terminal as a temp file via the kitty graphics `t=t` medium, so only a file path crosses the tty; falls back to streamed base64 PNG over SSH.
- **Link hint mode** (`;`) — vim-style overlay labels on every visible link; type the letter(s) to follow. Duplicate links (same target) share a label.
- **Table of contents** (`T` to toggle, or `:toc`) — popup tree of mupdf's outline. Defaults to collapsed-with-current-page-ancestry-expanded, so you see chapters with the section you're in opened. `l`/`h` (or `→`/`←`) expand/collapse; Space toggles; Enter jumps; mouse wheel and `j`/`k` navigate; `g`/`G` for top/bottom.
- **Marks** (vim-style) — `m<letter>` sets a mark at the current page+scroll, `'<letter>` jumps to it. `M` (or `:marks`) opens a popup listing marks alongside the TOC section title for each. `Enter` jumps, `r` renames (opens command line pre-filled with `mark <letter> <current comment>`), `d` deletes; mouse wheel and `j`/`k` navigate. `:mark a some comment` sets a mark with a comment; `:delmark a` removes one. Persisted per document.
- **Link navigation history** — vim-style `Ctrl+O` (back) / `Tab` (forward) jump list. Only link follows and mark jumps push to the list; manual nav doesn't.
- **Per-document position persistence** — page, scroll, zoom, oddx, colorize, crop (including manual margins), spread, hlock, marks, and highlights are saved continuously and restored on next open. Stored at `${XDG_STATE_HOME:-~/.local/state}/fancy-cat/positions.json`, keyed by PDF `/ID` (or SHA-256 of first 1MB, or path) so files survive being moved. Opening with an explicit page argument overrides only the position, not the view settings.
- **Recent-files picker** — running `fancy-cat` with no arguments opens the recently-read list in `fzf` (numbered-prompt fallback when fzf is missing) and restores your exact position.
- **Chapter & progress in the status bar** — `<chapter>` (deepest outline section at the current page) and `<percent>` placeholders, alongside the existing page/zoom items.
- **Help popup** (`?` or `:help`) — keybinding chips are rendered from the live keymap (so rebinds show correctly) and the `:` command column is generated from the command dispatch table, so the help can't go stale.
- **Open page / chapter in `$EDITOR`** (`e` / `E`, or `:edit` / `:edit c`) — extracts as markdown with bold/italic/mono spans, headings, and inline diagram PNGs (pairs well with [image.nvim](https://github.com/3rd/image.nvim)).
- **Status / command bar share a row** — image no longer overlaps the status row; in command mode, status is hidden in favor of the command bar.
- **Build artifacts moved out of the submodule** — mupdf installs to `mupdf-out/` at the project root (gitignored) instead of dirtying `deps/mupdf/local/`.
- **Migrated to Zig 0.16.**

Misc smaller fixes: `f` (full screen) preserves active zoom and scroll instead of resetting; horizontal scroll preserved across page transitions; cache always consulted (the old `should_check_cache` one-shot gate is gone).

## Usage

```sh
fancy-cat <path-to-pdf> <optional-page-number>
```

### Commands

fancy-cat uses a modal interface similar to Neovim. There are two modes: view mode and command mode. To enter command mode you type `:` by default (this can be changed in the config file).

Documentation on the available commands can be found [here](./docs/commands.md).

### Configuration

fancy-cat can be configured through a JSON configuration file located in one of several locations (primary `$XDG_CONFIG_HOME/fancy-cat/config.json`, fallback `$HOME/.config/fancy-cat/config.json`, legacy `$HOME/.fancy-cat`). An empty configuration file is automatically created in the primary or fallback location on the first run.

An example `config.json` and documentation can be found [here](./docs/config.md).

## Installation

`fancy-cat` is available in the following repositories:

[![Packaging status](https://repology.org/badge/vertical-allrepos/fancy-cat.svg?columns=3&header=fancy-cat)](https://repology.org/project/fancy-cat/versions)

## Build Instructions

### Requirements

- Zig version `0.16.0` (matches `build.zig.zon`'s `minimum_zig_version`)
- Terminal emulator with the Kitty image protocol (e.g. Kitty, Ghostty, WezTerm, etc.)

### Build

1. Fetch submodules:

```
git submodule update --init --recursive
```

2. Build the project:

```sh
zig build --release=small
```

> [!NOTE]
> There is a [known issue](https://github.com/freref/fancy-cat/issues/18) with some processors; if the build fails on step 7/10 with the error `LLVM ERROR: Do not know how to expand the result of this operator!` then try the command below instead:
>
> ```sh
> zig build -Dcpu="skylake" --release=small
> ```

3. Install:

```sh
# Add to your PATH
# Linux
mv zig-out/bin/fancy-cat ~/.local/bin/

# macOS
mv zig-out/bin/fancy-cat /usr/local/bin/
```

### Run

```sh
zig build run -- <path-to-pdf> <optional-page-number>
```

## Features

- ✅ Filewatch (hot-reload)
- ✅ Runtime config
- ✅ Custom keymappings
- ✅ Modal interface
- ✅ Commands
- ✅ Colorize mode (dark-mode)
- ✅ Status bar
- ✅ Page navigation (zoom, prev, next, etc.)
- ✅ Full-text search with match finder
- ✅ Text selection → clipboard
- ✅ Persistent highlights
- ✅ Two-column spread
- ✅ Background prerendering

## License

[AGPL-3.0-or-later](https://spdx.org/licenses/AGPL-3.0-or-later.html)

## Contributing

Contributions are welcome.
