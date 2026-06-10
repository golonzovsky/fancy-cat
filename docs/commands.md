# Commands

Press `:` to enter command mode. (The in-app help — `?` or `:help` — always shows the
current list; it is generated from the same table that dispatches these commands.)

- `:<number>` — go to page number
- `:<number>%` — set zoom level
- `:y+<number>` / `:y-<number>` — scroll up (`+`) or down (`-`) by the given amount (e.g. `:y-3.1`)
- `:x+<number>` / `:x-<number>` — scroll right (`+`) or left (`-`) by the given amount (e.g. `:x+10.5`)
- `:toc` — table of contents popup
- `:marks` — marks list popup
- `:mark <a-z> <comment>` — set a mark with a comment
- `:delmark <a-z>` — delete a mark
- `:edit` — extract current page as markdown and open in `$EDITOR` (or `$VISUAL`, fallback `vim`)
- `:edit chapter` (or `:edit c`) — same, but the current chapter (range from TOC)
- `:oddx <number>` — shift odd pages horizontally by N PDF points (for asymmetric inner margins)
- `:hlock` — toggle horizontal scroll lock (trackpad reading mode)
- `:spread` — toggle the two-column continuous spread
- `:crop [T [R [B [L]]]]` — trim margins in PDF points, CSS-shorthand value rules;
  bare `:crop` resets the trim
- `:help` — help popup
- `:q` — quit

## Key-driven features (not commands)

See the in-app help (`?`) for the full, rebind-aware key list. Highlights of the
non-obvious ones:

- `/` search, then `N`/`P` for next/prev match; `S` opens the search finder with
  the full match list; Esc clears highlights
- mouse drag selects text and copies it on release (OSC 52); `H` persists the
  selection as a highlight; `V` opens the highlights navigator
- `t` auto-crop, `d` spread, `T` table of contents, `M` marks, `;` link hints,
  `m<a-z>`/`'<a-z>` set/jump mark, `Ctrl+O`/`Tab` jump back/forward,
  `e`/`E` page/chapter in `$EDITOR`
