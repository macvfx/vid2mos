# Checking whether a video file is real

When a preview fails, a decode errors or a restore looks wrong, the question is usually: is this
a real, complete movie, or something else wearing a movie's name? This guide covers the checks,
cheapest first, using tools already on a Mac (`ls`, `stat`, `file`, `xxd`, `mdls`, `xattr`) plus
`ffprobe` and `ffmpeg`.

Every check here only reads the file. Run them on the original or on a restored copy, and quote
paths, because media paths often contain spaces:

```bash
f="/Volumes/Share/Project/Renders/clip.mov"
```

To survey many files at once, `inspect-movies.sh` in this repository runs most of these checks
over a list of paths (see `INSPECT-MOVIES-README.md`).

## Quick triage

Run these four in order. Most broken files show themselves by the second or third.

```bash
ls -lO@ "$f"                                   # size, link, flags, extended attributes
file "$f"                                      # what the content looks like
xxd -l 64 "$f"                                 # the first 64 bytes
ffprobe -v error -show_format -show_streams "$f"
```

| What you see | Likely meaning |
|---|---|
| Size 0 | Empty file: a placeholder, or a copy that never started |
| A round size: 4096, 65536, 1048576 (1 MB), 2147483648 (2 GB), 4294967296 (4 GB) | A write that stopped at a buffer or chunk boundary, or a file-system limit |
| `->` after the name | A symbolic link, not the file itself (see "Links and aliases") |
| `dataless` in the flags | A cloud placeholder: the data is not on this disk |
| `file` says `data` | The start of the file is not any known format: zeros, garbage or encrypted |
| `file` says `AppleDouble encoded Macintosh file` | A `._` sidecar file, not a movie |
| `file` says `MacOS Alias file` | A Finder alias, not the movie |
| `ffprobe` says `moov atom not found` | An unfinished QuickTime or MP4 (see "QuickTime and MP4") |
| `ffprobe` says `Invalid data found when processing input` | Not a container ffmpeg recognises |

## 1. Size

```bash
ls -l "$f"
stat -f '%z bytes, %b blocks of 512' "$f"
```

- **Compare with the size the file should have:** the size in the archive index, on the
  original drive, or in the delivery notes. A restore that came back smaller than the archived
  size is a restore problem. A file that was archived at the wrong size has been broken since
  before it was archived.
- **Round numbers are a warning sign.** Real movies almost never end exactly on a power of two.
  1,048,576 bytes is a common size for a render or copy that was stopped after its first write.
- **Sparse or preallocated files:** if blocks × 512 is far smaller than the size, most of the
  file was never written. Network volumes (SMB, NFS) do not always report blocks correctly, so
  only trust this check on a local disk.
- **Bitrate sanity check.** Once `ffprobe` gives a duration, size × 8 ÷ duration is the average
  bitrate. A 1080p ProRes file at a few hundred kbit/s, or an H.264 proxy at 2 Gbit/s, is wrong.

## 2. What kind of file it is

```bash
file "$f"
file -b --mime-type "$f"
mdls -name kMDItemContentType -name kMDItemDurationSeconds -name kMDItemCodecs "$f"
```

`file` reads the content, not the extension. A `.mov` that `file` calls `data`, `empty`,
`ASCII text` or `HTML document` is not a movie. A text or HTML "movie" is often an error page
saved by a download or a web transfer.

`mdls` returns what Spotlight knows. It returns `(null)` on volumes Spotlight does not index,
which is common for network shares, so a null there proves nothing.

## 3. The first bytes

```bash
xxd -l 64 "$f"
```

Container formats start with a known signature:

| Format | What to look for |
|---|---|
| QuickTime `.mov`, MP4 `.mp4` `.m4v` | Bytes 4–7 are `ftyp`. Older QuickTime files may start with `moov`, `mdat`, `wide`, `free`, `skip` or `pnot` |
| MXF `.mxf` | `06 0e 2b 34` |
| Matroska `.mkv`, WebM `.webm` | `1a 45 df a3` |
| AVI `.avi` | `RIFF`, then `AVI ` at bytes 8–11 |
| MPEG program stream `.mpg` `.vob` | `00 00 01 ba` |
| MPEG transport stream `.ts` `.m2ts` | `47` at byte 0 and again every 188 bytes (`.m2ts`: every 192 bytes, starting at byte 4) |
| AppleDouble `._name` | `00 05 16 07`: metadata, not the movie |

A first line of only `0000 0000 …` means the file starts with zeros.

**Is the whole file zeros?** This counts the bytes that are not zero. A result of 0 means no
data was ever written:

```bash
LC_ALL=C tr -d '\000' < "$f" | wc -c
```

**Does it end in zeros?** A file preallocated to its full size and then abandoned often has real
data at the start and zeros after that. This counts the non-zero bytes in the last 64 KB:

```bash
tail -c 65536 "$f" | LC_ALL=C tr -d '\000' | wc -c
```

## 4. QuickTime and MP4: the moov atom

A QuickTime or MP4 file is a list of boxes ("atoms"). The media is in `mdat`, and the index
that says where every frame is lives in `moov`. Many apps write `moov` last, when the render or
recording finishes. If the app crashes, is stopped, or the copy is cut short, the file has media
but no index, and no player can find its frames: ffprobe reports `moov atom not found`.

List the top-level atoms:

```bash
ffprobe -v trace "$f" 2>&1 | grep "parent:'root'"
```

A healthy file shows `ftyp`, then `moov` and `mdat` in either order, each with a plausible
size. Atom sizes that add up to more than the file's size mean the file is truncated.

A quick check for the index, which can occasionally give a false hit inside compressed media
but is reliable when it says 0:

```bash
LC_ALL=C grep -c moov "$f"
```

A file without `moov` cannot be fixed by retrying. Tools such as `untrunc` can sometimes rebuild
the index from a working file made by the same app with the same codec and settings. That is
only worth trying when the content matters and no other copy exists.

## 5. What ffprobe says

```bash
ffprobe -v error -show_entries format=format_name,duration,size,bit_rate:stream=index,codec_type,codec_name,width,height,r_frame_rate,duration -of default=noprint_wrappers=1 "$f"
```

| Message or result | Meaning |
|---|---|
| Clean output with streams, codecs, size and duration | The container is readable. The media can still be damaged further in, so decode it to be sure (step 6) |
| `moov atom not found`, then `Invalid data found when processing input` | For a `.mov` or `.mp4` name: no index. Either an unfinished file (step 4), or a file of zeros or garbage, since ffmpeg picks the QuickTime reader from the name. The zero count in step 3 tells them apart |
| `Invalid data found when processing input` alone | Not a recognised container: zeros, garbage, a text file, or an unknown format |
| `No such file or directory` | Wrong path, an unmounted volume or a broken link |
| `Permission denied` | The account running the check cannot read the file |
| `Operation timed out`, or a long hang | The volume is slow or offline. The file itself may be fine |
| `partial file` or `stream … offset … partial file` | The container says there is more data than the file holds: truncated |
| `could not find codec parameters` | The stream is damaged, or ffmpeg cannot read its codec |
| `no decoder`, `unknown codec`, or `codec_name=unknown` | This ffmpeg build cannot decode the codec. The file may be fine: try another build (vid2mos 1.4.0 falls back to `/usr/local/bin/ffmpeg`) |
| `duration=N/A` | There is no index or timestamps. Common in raw streams and truncated files |
| Duration far shorter than expected | Truncated, or only the first segment of a spanned recording |

The exit status says whether the file could be opened at all. `ffprobe` exits 1 for any failure.
`ffmpeg` exits with the low byte of its error code, which is what preview logs record:

| ffmpeg exit | Meaning |
|---|---|
| 183 | Invalid data: not a movie ffmpeg can read (the `rc=183` in vid2mos logs) |
| 254 | No such file or directory |
| 1 | Most other failures; the message says which |

```bash
ffprobe -v error "$f"; echo "ffprobe exit $?"
ffmpeg -v error -i "$f" -t 1 -f null -; echo "ffmpeg exit $?"
```

## 6. Decode it

A readable header does not mean every frame decodes. This reads and decodes the whole file
without writing anything, and prints only errors:

```bash
ffmpeg -v error -i "$f" -f null - 2>&1 | head -20
```

- Silence and exit 0 means every frame decoded.
- Errors near the end only: the file is truncated, but most of it plays.
- Errors throughout: the media is damaged, or this ffmpeg build decodes the codec badly.

On a large file this reads every byte, which takes as long as a full copy. Decode only the first
30 seconds to test quickly:

```bash
ffmpeg -v error -t 30 -i "$f" -f null -
```

To check a single frame, the way a preview does:

```bash
ffmpeg -v error -ss 10 -i "$f" -frames:v 1 -f image2 /tmp/frame-check.jpg && open /tmp/frame-check.jpg
```

A black or green frame, or a picture smeared with blocks, means the codec is damaged or
misread even though nothing errored.

## 7. Links and aliases

```bash
ls -l "$f"                       # a link shows: name -> target
readlink "$f"                    # where it points
[ -L "$f" ] && echo "link"; [ -e "$f" ] || echo "target missing"
file "$f"                        # "MacOS Alias file" for a Finder alias
```

- **Symbolic link:** a path that points elsewhere. Archives and preview tools may store the link
  rather than the movie, so the archive has nothing to preview. Media inside Final Cut Pro
  libraries is often linked this way. `vid2mos-hardened.sh` skips links unless
  `VID2MOS_FOLLOW_SYMLINKS=1`.
- **Broken link:** `[ -L ]` is true and `[ -e ]` is false. The target is missing or on a volume
  that is not mounted.
- **Finder alias:** a small file holding a bookmark. Command-line tools do not follow it.

## 8. macOS metadata, placeholders and sidecars

```bash
ls -lO@ "$f"
xattr -l "$f"
```

- **`dataless`** in the flags: a cloud placeholder (iCloud Drive, a File Provider). Reading it
  starts a download, or fails offline.
- **`._name` files:** AppleDouble sidecars that macOS writes on SMB and other non-Mac volumes to
  hold metadata. They are usually 4096 bytes and are never movies, even with a `.mov` name. Skip
  them.
- **`com.apple.quarantine`:** a file downloaded from the internet. It does not affect reading.

## 9. The volume, not the file

When a check hangs or a read is slow, test the storage before the file:

```bash
df -h "$f"                                    # which volume, and is it mounted
time head -c 1073741824 "$f" > /dev/null      # read speed of the first 1 GB
```

A file on an offline or very slow volume can time out in a preview or decode and still be
perfectly good.

## 10. Compare two copies

When a restored copy and an original (or two archive copies) disagree:

```bash
stat -f '%z  %N' "$a" "$b"
shasum -a 256 "$a" "$b"
cmp "$a" "$b" | head -1          # the first byte where they differ
```

Matching sizes with a different checksum means corruption inside the file. A copy that matches
the original up to a point and then ends means a truncated copy: `cmp` says `EOF on` the shorter
one.

## Worked example: an After Effects render that never finished

Two `.mov` renders failed their previews on every machine with `ffmpeg failed (rc=183)`. The
checks showed:

1. `ls -l`: both were exactly 1,048,576 bytes. That round size was the first warning.
2. `ffprobe`: `moov atom not found`. The files had no index, so no player could find their
   frames.
3. The archived size was the same 1 MB, so the restore was not at fault.

These were renders that stopped after the first megabyte, broken since they were made. No retry
or other ffmpeg build can preview them. The right action is to mark them as not fixable, not to
retry them.

## When to stop retrying

Retrying a preview helps only when the cause is outside the file: a timeout, a slow volume, a
missing decoder in one ffmpeg build, or a source that was offline. If the file is empty, all
zeros, truncated, has no `moov`, is a link or sidecar, or does not match its archived size,
retrying will fail the same way. Fix or replace the file, or set it aside.
