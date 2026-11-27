# Changelog

Earlier versions (1.0.0, 1.1.0) are described in the git history and the README.

## 1.3.0

### Changes
- **The ffmpeg limit grows with the file.** It was a flat 120 s, which no large file can meet: the
  mosaic decodes the whole file, and six 46-63 GB ProRes files that had timed out in a real P5 job
  each needed 176-303 s when retried. The limit is now 120 s plus 1 s per 100 MB, at most 3600 s
  (`VID2MOS_TIMEOUT_BASE`, `VID2MOS_TIMEOUT_RATE`, `VID2MOS_TIMEOUT_MAX`). 100 MB/s is about half
  the slowest rate measured, leaving room for several clients reading the share at once; the hour
  ceiling keeps a stuck read from holding a P5 preview slot for longer. `VID2MOS_TIMEOUT` still
  sets one fixed limit, so the test runner's `--timeout` is unchanged.
- **A timeout is not tried again without the seek.** The second pass exists for short clips and
  stills; after a timeout it only read the whole file again and doubled the time lost.
- The timeout reason now says how the limit was set, e.g.
  `ffmpeg TIMED OUT after 720s and was killed (limit for 62.7 GB, rc=143)`, the `OK` line carries
  `limit=Ns`, and `--selftest` prints `ffmpeg_timeout=`.

## Tools added after 1.2.1

### Features
- **`inspect-movies.sh`** ([guide](INSPECT-MOVIES-README.md)): reads a text list of movie paths,
  surveys every entry first (name, path, size, `file` type, ExifTool and ffprobe metadata), then,
  unless `--survey`, copies each one (or reads it in place with `--skipcopy`), decodes the first
  30 s (`DECODE_SECONDS`, `0` = all of it), makes a preview with the script in test mode and
  hashes it. Every command's output and exit code is kept per file in a new
  `movie-inspection.XXXXXX` folder; nothing is deleted. macOS `/bin/bash` 3.2 compatible.
  The README linked it from 1.3.0 before the files were committed.
  - Fix before its first commit: `DECODE_SECONDS=0` stopped the whole run at the first file under
    macOS bash 3.2 (`decode_args[@]: unbound variable`), because `set -u` treats an empty array
    as unset there; the run's `state` was left at `running`. Expanded with the 3.2-safe
    `${decode_args[@]+"${decode_args[@]}"}`.
- **`vid2mos-test-runner.sh`**: runs the preview script over a list of files with one or more
  labelled ffmpeg + ffprobe builds (`--mode script|fallback|matrix`), a chosen limit
  (`--timeout S|none`), previews kept in the run folder or a review folder. Writes
  `results.tsv` (one row per file per build, with size, codec, dimensions, duration and the
  failure reason), `state`, the run's own test-mode log and each failure's ffmpeg log. Stops after
  the current file with `DIR/stop`, or at once on TERM, killing the ffmpeg it started. Started
  detached by P5 Preview Monitor 0.3.0 build 18 ("Retry failed files"). Results are TSV, not the
  JSON Lines the client-tests plan named: simpler to write safely from a shell.
- **`size-survey.sh`**: sizes every video file under a folder and summarises them, with the read
  time each needs at a given speed and how many exceed the timeout. Symbolic links are counted
  apart.

### Finding
- The preview decodes the whole file from the seek point, so its time grows with the file's
  length; with files of hundreds of gigabytes the 120 s default cannot be enough. A timeout also
  costs about twice the limit, because the script retries once without the seek. Both are
  changed in 1.3.0.

## 1.2.1

### Changes
- **Symbolic links are not previewed.** A source that is a symbolic link fails at once, without
  running ffprobe or ffmpeg, with the reason `source is a symbolic link, not previewed`. P5 archives
  a link as a link, so a preview of what it points to would not belong to the entry; and the links
  inside Final Cut Pro libraries (`Original Media`) were among the files failing with
  `ffmpeg failed (rc=234)` on a real job. P5 still gets "no preview" (exit 1), but the log now says
  why, and P5 Preview Monitor 0.3.0 build 15 keeps these out of redo lists. Real files inside a
  library are not links and are previewed as before. `VID2MOS_FOLLOW_SYMLINKS=1` restores the old
  behaviour for manual tests (P5 itself cannot pass it).

### Fixes
- **A busy day's log lost lines.** At 5 MB the log moved to `.1` with `mv -f`, so a second
  rotation the same day overwrote the first, with every START and FAIL line in it (and with them
  the full paths of failed previews). A multi-terabyte job can pass 5 MB in a day. Rotation now
  happens at 20 MB (`VID2MOS_LOG_MAX_BYTES`) to the next free `.1`, `.2`, ... and never replaces
  one. P5 Preview Monitor 0.3.0 build 13 reads these rotations.

## 1.2.0

### Features
- **Test mode.** `--test` or `VID2MOS_MODE=test` makes the same preview with the same output
  contract, but logs only to `VID2MOS_LOG` (else a `vid2mos-test-YYYY-MM-DD.log` in the output
  folder), never to the daily log folder, the shared folder or the system log, and writes to
  `/tmp/vid2mos-test-<user>` by default. Every line carries `mode=test` before `pid=`, so readers
  that expect `user=U pid=N` (P5 Preview Monitor 0.3.0, `vid2mos-log-summary.sh`) do not take it
  for a P5 run.
- **Separate ffmpeg and ffprobe.** `VID2MOS_FFMPEG` and `VID2MOS_FFPROBE` name each tool and
  override `VID2MOS_BIN_DIR`, so another ffmpeg can be tried with P5's own ffprobe.
- The START line names the exact `ffmpeg=` and `ffprobe=` used (after `bin=`, which is kept), and
  `--selftest` prints `mode=`, both paths and the first line of each tool's `-version`.
- Leading options can come in any order (`--test -v <file>`).
- `batch-vid2mos.sh`: `--bin-dir`, `--ffmpeg`, `--ffprobe`; prints the script version and tools.

### Fixes
- **`batch-vid2mos.sh` wrote its test runs into the daily log P5's runs use**, so P5 Preview
  Monitor and the log summary counted them as P5 previews. Cause: it only redirected the log when
  `VID2MOS_LOG` was already set, otherwise it used the same daily default as P5's runs. It now
  runs the script in test mode, logs to `<report>.log`, and switches off the shared folder; with a
  1.1.0 script (no test mode) the log is still redirected, so the daily log stays clean either way.
- `vid2mos-log-summary.sh` skips `mode=test` lines.
- **`prepare-client.sh` printed `FIX` for a copy it was about to replace**, so an upgrade looked like
  a problem even though the next line said it was installed. Cause: the version check reported
  through the same "needs fixing" message in both modes. A normal run now says "replacing installed
  copy (1.1.0) with 1.2.0"; `FIX` appears only with `--check`, or when the install itself fails
  (which now also counts as a problem and exits 1, where before it was only a note).
