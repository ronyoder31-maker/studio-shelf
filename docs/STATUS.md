# Status (stage 1, 2026-10-25)

Levels: implemented → compiled → simulator-tested → physical-iPad-tested.

| Area | Level reached |
|---|---|
| Library folder (On My iPad › StudioShelf or a chosen folder), list/grid, search by name/folder/tag | compiled; screens seen in simulator |
| Rename, move, new folder/text, import (copies), share, tags, favorites, Library Trash with safe restore | simulator-tested (unit tests) |
| Path safety: traversal, symlink escape, missing child under linked folder, collisions, Unicode | simulator-tested |
| Damaged / newer metadata never overwritten | simulator-tested |
| Browser (WKWebView), ordinary downloads into Downloads, "Save this file" for PDFs/media | compiled only |
| YouTube link checks (single video only; playlists/channels refused) | simulator-tested |
| MP3 encoding with LAME on device: real MPEG Layer III, 128/192/256/320 kbps, mono/stereo, 22.05–96 kHz input, UTF-16 titles, cancel/corrupt input leave no partial file, renamed AAC rejected | simulator-tested |
| YouTube audio retrieval (YouTubeKit, `.local` only) | compiled; live test **blocked** on GitHub's servers: YouTube answered "Sign in to confirm you're not a bot" (datacenter address). Needs the iPad test. |
| Offline player (resume, speed, repeat, background audio), PDF view + highlight saved as a separate copy, UTF-8 text editor with change detection, Word preview | compiled only |
| Unsigned build for a real iPad | compiled |
| Anything on your physical iPad | **not yet tested** |

## The acceptance test only you can do
1. Install (START-HERE.md). Turn the Mac off.
2. On iPad Wi-Fi, open a normal public YouTube video in Browser, tap MP3, keep the app open until "Saved".
3. Open Downloads › Audio, play it. Turn on Airplane Mode, force-quit, reopen, play again.
4. AirDrop or Finder-copy a movie in, Airplane Mode on, play it.
Tell me exactly what each step showed.

## Known limits
- Conversion needs the app open (iPadOS may pause it in the background).
- YouTube can change or block access at any time; the app then shows a plain error rather than a fake file.
- No Mac companion yet; no automatic sync.
