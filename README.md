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
- **Mouse / trackpad support** — wheel up/down/left/right scrolls; `Shift+wheel` scrolls horizontally; `Ctrl`/`Alt`+wheel zooms; left-click follows PDF links (internal → goToPage, URI → `open <uri>`).
- **Auto-crop margins** (`t`) — uses mupdf's bbox device to render only the page's content rect; odd/even pages with different margins are independently cropped.
- **Odd-page horizontal alignment** (`:oddx N`) — for books with asymmetric inner margins. Shift is baked into the mupdf CTM during render, so no display gap appears.
- **Link navigation history** — vim-style `Ctrl+O` (back) / `Tab` (forward) jump list. Only link follows push to the list; manual nav doesn't.
- **Per-document position persistence** — page, scroll, zoom, oddx, colorize, and crop state are saved on quit and restored on next open. Stored at `${XDG_STATE_HOME:-~/.local/state}/fancy-cat/positions.json`, keyed by PDF `/ID` (or SHA-256 of first 1MB, or path) so files survive being moved.
- **Status / command bar share a row** — image no longer overlaps the status row; in command mode, status is hidden in favor of the command bar.
- **Build artifacts moved out of the submodule** — mupdf installs to `mupdf-out/` at the project root (gitignored) instead of dirtying `deps/mupdf/local/`.
- **macOS 26 (Tahoe) build** — Zig 0.15.2's bundled LLD can't parse the macOS 26 SDK's `libSystem.tbd`. Workaround is an `xcrun` shim that reports a 15.x SDK path; see commit log if you hit linker errors about `_malloc`, `_getcwd`, etc.

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

- Zig version `0.15.2`
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

## License

[AGPL-3.0-or-later](https://spdx.org/licenses/AGPL-3.0-or-later.html)

## Contributing

Contributions are welcome.
