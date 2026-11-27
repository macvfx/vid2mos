# Inspect Movies

[`inspect-movies.sh`](inspect-movies.sh) reads a text file of movie paths, shows a quick survey
of every entry, and saves diagnostic reports. A full run then optionally copies the movies,
checks decoding, generates previews with `vid2mos-hardened.sh`, and calculates SHA-256 hashes.

Use `--survey` for a quick overview of large files on a SAN. Use `--skipcopy` for full inspection
directly on the source files. Copying remains the default for a full run.

## Quick start

Run these commands from the folder containing `inspect-movies.sh`:

```bash
# Quick overview and metadata only: no copying, hashes, decoding, or previews.
./inspect-movies.sh --survey file.txt "/Volumes/Example_Archive/Inspection_Results"

# Full inspection of the originals, without copying them.
./inspect-movies.sh --skipcopy file.txt "/Volumes/Example_Archive/Inspection_Results"

# Full inspection with copies in the output location.
./inspect-movies.sh file.txt "/Volumes/Example_Archive/Inspection_Results"
```

The second argument determines where results and any movie copies are stored. It can be on
local storage or a SAN. Every invocation creates a new `movie-inspection.XXXXXX` subfolder
and prints its actual path. Existing runs are retained; there is no automatic cleanup or resume.

If the script is not executable, run `bash ./inspect-movies.sh` with the same arguments.

## File list format

Put one absolute path on each line of `file.txt`:

```text
/Volumes/Example_Media/Example_Project/clip_001.mov
/Volumes/Example_Media/Example_Project/clip with spaces.mxf
/Volumes/Example_Media/Example_Project/clip_003.mp4
```

Do not add shell quotes or escape spaces inside the text file. Blank lines are ignored.
Windows CRLF line endings and a final line without a newline are supported. Duplicate entries
are processed separately and receive separate numbered result folders. Comment lines and paths
containing embedded newlines are not supported.

Each entry that cannot be inspected fails with its own reason, in `reports/input-error.txt`
and on screen; the other entries continue:

| Reason | What it means |
| --- | --- |
| `Expected an absolute path` | The line does not start with `/` |
| `Broken symbolic link -> TARGET` | A link whose target is gone; `TARGET` is what it points to |
| `File not found` | Nothing at that path |
| `Is a folder, not a file` | The path names a folder |
| `Not a regular file (device, socket or pipe)` | Something other than a file |
| `Not readable by USER (permissions)` | A file the user running the script may not read |
| `Finder alias, not the movie` | A Finder alias: resolve it in Finder and list the original |

A symbolic link whose target exists is inspected, and the survey shows `Link: -> TARGET`.
Its size and type are the target's. Copy mode copies the target; with `--skipcopy`, the
preview script's own policy applies (`vid2mos-hardened.sh` 1.2.1 and later refuse links).

## What runs, and in what order

The script completes each survey pass across the entire list before starting intensive work.

| Pass | Work | Where it reads |
| --- | --- | --- |
| 1. Basic survey | Count, name, path, symbolic link target, size in bytes/GiB, `file` description, MIME type, `ls`, and `stat` | Original files in every mode |
| 2. Quick metadata | ExifTool JSON and ffprobe JSON; selected fields printed on screen | Original files in every mode |
| 3. Intensive checks | Copy unless skipped; video/audio decode; mosaic preview; SHA-256; optional MediaInfo, `mdls`, and `xattr` | Copies by default; originals with `--skipcopy` |

`--survey` stops after pass 2. Combining it with `--skipcopy` is allowed but does not change
the survey: it already makes no copies.

The metadata pass uses ExifTool `-fast2`, which can omit deeper metadata, and ffprobe
`-probesize 5000000 -analyzeduration 5000000`. Those ffprobe settings limit discovery budgets;
they are **not a five-second wall-clock timeout**. Slow storage or unusual containers can
still make metadata reads take time. Selected fields such as codec, resolution, frame rate,
and duration appear on screen when the tools return them; missing fields are not invented.

Full runs decode the first 30 seconds of video/audio by default. Preview generation can read
and decode much more of the movie, depending on the selected preview script. SHA-256 reads
the entire file, including with `--skipcopy`. It records a fingerprint; it does not compare
the source and copy or prove that all media is decodable. `--survey` omits hashing entirely;
there is no separate hash-skip option in a full run.

## Arguments and settings

```text
inspect-movies.sh [--survey] [--skipcopy] FILE_LIST TEMP_LOCATION [VID2MOS_SCRIPT]
```

| Argument or option | Meaning |
| --- | --- |
| `FILE_LIST` | Readable text file containing absolute movie paths |
| `TEMP_LOCATION` | Parent folder for the new run; created if needed |
| `VID2MOS_SCRIPT` | Optional explicit path to `vid2mos-hardened.sh` |
| `--survey` | Basic survey and quick metadata only |
| `--skipcopy` | Full inspection without movie copies; aliases: `--skip-copy`, `-skipcopy` |
| `--help`, `-h` | Print usage |
| `--` | End option parsing |

Options may appear before or after the positional arguments.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `DECODE_SECONDS` | `30` | Seconds to decode in full runs; `0` checks the entire video/audio timeline |
| `PROGRESS_INTERVAL` | `5` | Positive whole seconds between progress updates |
| `NO_COLOR` | Unset | Set to any value to disable terminal colors |

```bash
# More frequent progress, with a full decode rather than a 30-second sample.
PROGRESS_INTERVAL=2 DECODE_SECONDS=0 \
  ./inspect-movies.sh --skipcopy file.txt "/Volumes/Example_Archive/Inspection_Results"

# Save plain terminal output as well as the script's normal reports.
./inspect-movies.sh --survey file.txt /tmp/example-inspection > survey-terminal.txt 2>&1
```

## Tools and preview script selection

The script is compatible with macOS `/bin/bash` 3.2. Survey commands use `file`, `exiftool`,
and `ffprobe` from `PATH`, plus standard shell utilities. Full runs also use `ffmpeg` and
`shasum`. MediaInfo, `mdls`, and `xattr` are optional and run only in the intensive pass.
Missing required tools cause failures to be recorded; missing optional tools are skipped.

Without an explicit third argument, the preview script is selected in this order:

1. `/Library/Scripts/vid2mos-hardened.sh`
2. `vid2mos-hardened.sh` beside `inspect-movies.sh`

An installed script takes precedence over the copy beside the inspector. To test the latter
explicitly:

```bash
./inspect-movies.sh --skipcopy file.txt /tmp/example-inspection ./vid2mos-hardened.sh
```

The preview script chooses its own ffmpeg/ffprobe binaries, which can differ from the tools
on `PATH`. Compatible versions accept `VID2MOS_FFMPEG`, `VID2MOS_FFPROBE`, and
`VID2MOS_BIN_DIR`; their timeout settings also remain in effect. To use the binaries on `PATH`
for previews with a version supporting those overrides:

```bash
VID2MOS_FFMPEG="$(command -v ffmpeg)" VID2MOS_FFPROBE="$(command -v ffprobe)" \
  ./inspect-movies.sh --skipcopy file.txt /tmp/example-inspection ./vid2mos-hardened.sh
```

The inspector sets `VID2MOS_MODE=test`, redirects preview images and logs into the current
item's `output/` folder, and clears `VID2MOS_SHARED_DIR`. Versions supporting test mode stay
out of production logs. Older versions may still write to syslog. See the
[main README](README.md) for the preview script's settings and version-specific behavior.
Survey-only runs do not execute or require the preview script.

## Terminal progress and cancellation

Interactive terminal output uses cyan for active steps, green for successful completion,
yellow for skips, and red for failures. Redirected output is plain text. Colors are also
disabled when `TERM` is `dumb` or `NO_COLOR` is set.

Copy updates show percentage, destination bytes, GiB, average MiB/s, and elapsed time.
These estimates use the destination's reported file size, so preallocation, sparse files,
and filesystem behavior can make them approximate. Other commands show their name,
completion status, and periodic elapsed-time messages; hashing has no byte-percentage meter.
The script prints destination disk space but does not reserve capacity or enforce a free-space limit.

Press **Ctrl-C** to request cancellation of the active command and its children. Partial files
and reports are retained, and the run's `state` becomes `cancelled`. A storage operation blocked
in the operating system can take time to respond. A subsequent invocation starts a fresh run.

## Saved results

```text
movie-inspection.XXXXXX/
  files.txt                 Normalized snapshot of the input list
  survey.tsv                Basic survey for every entry
  summary.tsv               Required-check result and last completed pass per item
  environment.txt           Tool paths, versions, and selected settings
  state                     running, done, cancelled, or empty
  000001/
    source-path.txt         Original path
    reports/link-target.txt What a symbolic link points to, when the entry is one
    result                  OK or FAIL
    phase                   basics, metadata, or intensive
    reports/
      commands.tsv          Command label, required flag, exit code
      file.stdout.txt
      exiftool.stdout.txt   Quick ExifTool JSON
      ffprobe.stdout.txt    ffprobe JSON
      ...
    input/                  Movie copy; full copy mode only
    output/                 Preview JPEG and preview-script logs, when generated
  000002/
    ...
```

Captured commands normally have `<label>.command.txt`, `<label>.stdout.txt`, and
`<label>.stderr.txt`. Open the stderr file named in a failure message for details. Input and
preview validation failures also produce `input-error.txt` or `preview-error.txt`.

`survey.tsv` contains the item number, name, original path, byte size, file type, **basic
survey result**, and the symbolic link target (empty when the entry is not a link). Later metadata or decode failures appear in `summary.tsv`, rather than
changing the basic survey result. `summary.tsv` records each item's cumulative required-check
result and last completed pass. Optional command failures remain in `commands.tsv` and do
not mark an otherwise successful item as failed. `state=done` means processing finished;
check the summary to see whether it passed.

Columns labeled `shell_quoted` use Bash quoting to preserve spaces and special characters.
Treat them as text when opening the TSV files in a spreadsheet. Interrupted runs may have
incomplete summaries; consult individual command reports as well.

## Exit status and limits

| Exit status | Meaning |
| --- | --- |
| `0` | All required checks for the selected mode passed |
| `1` | At least one file, required command, or preview check failed |
| `2` | Invalid arguments, an empty list, or setup failure |
| `130` | Cancelled with Ctrl-C / SIGINT |
| `143` | Cancelled with SIGTERM |
| `129` | Cancelled with SIGHUP |

The inspector does not deliberately modify source movie contents. Survey passes read originals
even when copying is enabled, so metadata describes the source at survey time, not a separately
verified copy. Copy mode follows symbolic links when copying; with `--skipcopy`, the preview
script's own symbolic-link policy applies. Source files should remain stable during a run.
Reports contain full paths and extracted metadata; review them before sharing.
