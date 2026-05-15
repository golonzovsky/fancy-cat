# Commands

These are the commands that can be executed:

- `:q` — quit
- `:edit` — extract current page as markdown and open in `$EDITOR` (or `$VISUAL`, fallback `vim`)
- `:edit chapter` (or `:edit c`) — same, but the current chapter (range from TOC)
- `:<number>%` — set zoom level
- `:<number>` — go to page number
- `:x+<number>` / `:x-<number>` — scroll right (`+`) or left (`-`) by the given amount (e.g. `:x+10.5`)
- `:y+<number>` / `:y-<number>` — scroll up (`+`) or down (`-`) by the given amount (e.g. `:y-3.1`)
