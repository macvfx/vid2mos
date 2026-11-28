# P5 Preview Monitor 0.3.1 (build 35), pre-release

Fixes from testing 0.3.0 on a production P5 site, and a Diagnostics log for troubleshooting.
Requirements and install are unchanged from `RELEASE-NOTES-0.3.0.md`.

Pre-release, provided as is, with no support.

## New

- **Help ▸ Diagnostics… (⌥⌘L):** what the app did and why: polls, log reads, REST calls, and each
  restore, retry and attach. Saved daily in `~/Library/Logs/P5 Preview Monitor/` for 14 days.
  File paths and names are removed, so an export can be shared.
- **Files P5 skipped for a missing source** ("No source file" in the server log) are now listed in
  Fix previews, with the same check, restore, retry and attach steps. P5 never sends these files to
  a client, so no client log had them.
- **Fix the N… on the Live tab:** under a finished batch that did not load everything, the server
  card says what failed on the preview clients and opens Fix previews for that batch only. When
  nothing can be fixed it says so and offers **Show them…** instead.
- **Settings ▸ Preview script ▸ "Media inside FCP libraries is always a symbolic link here"** (off
  by default): files inside FCP libraries then count as never previewed.

## Fixes

- **Read logs again** never found anything newer than the day the window opened. A "Last N days"
  range now moves with the clock.
- A week's range with thousands of server skips made Fix previews very slow. They are hidden in a
  range unless their filter is on, and the window only redraws when something changes.
- A list emptied by its filters said nothing. It now says how many files are hidden and why, with
  **Show them**.
- The Live card's numbers now match what Fix previews lists.
- ffmpeg's rc=183 is named "not a readable movie" (for example a render that was cut off), with a
  hint to compare the file's size with P5's before retrying.
