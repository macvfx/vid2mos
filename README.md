# vid2mos

A hardened video-to-mosaic thumbnail generator: one JPEG containing a 4 x 3 grid of 12 frames
sampled across a video. It runs standalone from a shell, and it was tested as the preview
(thumbnail) script in the post-archive step of **Archiware P5 8.0.6**.

It is a hardened rewrite of the `vid2mos.sh` script described in Archiware's blog post
[Generate mosaic-style video previews in P5 Archive](https://www.archiware.com/blog/generate-mosaic-style-video-previews-in-p5-archive/).
The idea and the output format come from that post. This version fixes the logging and
troubleshooting problems I ran into with the original.

## Why

With the original script, a failed preview left almost no trail, and some inputs failed
silently:

- On clips shorter than the 10 s seek point, ffmpeg writes no file, yet the script still printed
  the output path and exited 0. In a test on 7 real camera clips (3.7 s to 10.7 s) the original
  produced a preview for 1 of 7; this version produced 7 of 7.
- When the script could not run, the P5 server log said only that it could not execute the script,
  with no host and no reason, so there was no way to tell which machine ran it.
- A missing frame count (MXF, MPEG-TS, still images) caused a division error and no preview.

## What is different

- **Every run is logged**: host, user, pid, input, result and seconds, to one file per day,
  `vid2mos-YYYY-MM-DD.log`, in `/var/log` when writable (P5 runs the script as root), otherwise
  `/tmp`. Old days are pruned after 30 days. Each run also goes to the system log through `logger`.
- A `START` line is written first, so a run with no later `OK` or `FAIL` is one that hung or was
  killed.
- **Honest results**: no JPEG means exit 1 and nothing on stdout. A timeout is logged as a timeout
  only when the watchdog really fired.
- **Watchdogs** on ffprobe (30 s) and ffmpeg, and every tool reads stdin from `/dev/null`,
  so an offline or slow source cannot hang the run or hold P5's pipes open.
- **A limit that fits the file** (1.3.0): ffmpeg gets 120 s plus 1 s per 100 MB of file, at most
  1 hour. A 1 GB file gets 130 s, a 60 GB file 12 minutes, files from about 350 GB up the full
  hour. See "Retrying failed files, and sizing the timeout" below for the numbers behind it.
- **Short clips and stills** retry without a seek instead of producing nothing.
- **A second ffmpeg for codecs P5's cannot read** (1.4.0): Archiware's bundled ffmpeg 7.1 is built
  without some decoders, PNG among them, so PNG-codec movies (common from After Effects) always
  failed with `ffmpeg failed (rc=234)`. When ffmpeg says it has no decoder for the file, the run is
  tried once more with `/usr/local/bin/ffmpeg` and `ffprobe` if both are installed, and the `OK`
  line ends `fallback="/usr/local/bin/ffmpeg" codec=png`. Without one, the reason names the codec:
  `ffmpeg has no decoder for png (rc=234), no fallback ffmpeg in /usr/local/bin`. No other failure
  triggers it. `VID2MOS_FALLBACK_BIN_DIR` picks another folder, or turns it off when set empty;
  `--selftest` prints `fallback_ffmpeg=`.
- **Frame count fallback**: `nb_frames`, then duration x frame rate, then the first frames.
- **Optional shared copy of the log**: set `VID2MOS_SHARED_DIR` and every log line is also written to
  `vid2mos-<host>-YYYY-MM-DD.log` there, so one monitor can read every machine's runs from one place.
  The copy is written in the background and can never delay or fail a run, even if the share is
  stale or unmounted. Lines can land slightly out of order, so pair START with OK/FAIL by host and pid.
- **Pre-flight checks**: `--version`, and `--selftest [path]`, which checks ffmpeg, ffprobe, the temp
  and log folders, the shared folder and (optionally) that a source path is readable. It prints
  `key=value` lines and ends with `result=PASS` or `result=FAIL`.
- **Unique output names** (a short hash of the input path), so same-named files in different
  folders do not overwrite each other.

The contract with P5 is unchanged: argument = path of the video; stdout = only the path of the
JPEG, on success; stderr empty; exit 0 or 1.

## Files

| File | Purpose |
|---|---|
| `vid2mos-hardened.sh` | The preview script (drop-in replacement for `vid2mos.sh`) |
| `test-vid2mos.sh` | 127 checks on synthetic media. `--compare <original>` also shows what the original does on the same inputs |
| `batch-vid2mos.sh` | Runs the script over a folder of real media with a per-file report |
| `vid2mos-test-runner.sh` | Runs the script over a list of files with one or more ffmpeg builds and a chosen time limit, one result row per file per build, previews kept. What P5 Preview Monitor's "Retry failed files" starts on a client |
| `size-survey.sh` | Sizes every video file under a folder (count, min, median, mean, percentiles, max, size bands, per extension) and estimates the read time against the timeout |
| [`inspect-movies.sh`](INSPECT-MOVIES-README.md) | Surveys a text list of movie paths, then optionally copies, decodes, previews, and hashes them; `--survey` gives a quick overview and `--skipcopy` inspects originals |
| `vid2mos-log-summary.sh` | Summarises the daily logs: totals per host, runs per minute, unfinished runs, latest failures |
| `prepare-client.sh` | One command to get a Mac ready: installs the script to `/Library/Scripts`, checks ffmpeg and Remote Login, runs `--selftest`. `--check` changes nothing |
| `TESTING.md` | How to test the scripts, what to record, and findings so far |

## Standalone use

```bash
./vid2mos-hardened.sh -v /path/to/video.mov     # -v echoes the log line to stderr
```

It needs `ffmpeg` and `ffprobe`. By default they are taken from `/usr/local/aw/bin` (the P5
install), or from `$AWPST_SRV_HOME/bin` when P5 sets it. For any other install, point
`VID2MOS_BIN_DIR` at the folder that holds them, or name each one with `VID2MOS_FFMPEG` and
`VID2MOS_FFPROBE` (1.2.0), for example to try another ffmpeg with P5's own ffprobe.

Optional environment variables: `VID2MOS_BIN_DIR`, `VID2MOS_FFMPEG`, `VID2MOS_FFPROBE`,
`VID2MOS_TMP` (output folder, default `/tmp`), `VID2MOS_LOG_DIR`, `VID2MOS_KEEP_DAYS`, `VID2MOS_LOG_MAX_BYTES` (rotate at, default 20 MB),
`VID2MOS_LOG` (one fixed file), `VID2MOS_TIMEOUT` (one fixed ffmpeg limit, replacing the scaled
one), `VID2MOS_TIMEOUT_BASE` / `VID2MOS_TIMEOUT_RATE` / `VID2MOS_TIMEOUT_MAX` (the scaled limit:
120 s, 100 MB per second, 3600 s), `VID2MOS_PROBE_TIMEOUT`, `VID2MOS_SHARED_DIR`,
`VID2MOS_FALLBACK_BIN_DIR` (1.4.0: second ffmpeg folder, default `/usr/local/bin`, empty = off),
`VID2MOS_MODE` (`test`, as `--test`), `VID2MOS_FOLLOW_SYMLINKS` (`1` = preview what a symbolic
link points to; by default, since 1.2.1, a link is logged as "source is a symbolic link, not previewed").

### Test mode (1.2.0)

Testing on a machine that also makes P5's previews should not add runs to P5's log, which is
what P5 Preview Monitor and `vid2mos-log-summary.sh` read. `--test` (or `VID2MOS_MODE=test`)
makes the same preview with the same output, but:

- logs to `VID2MOS_LOG`, else `vid2mos-test-YYYY-MM-DD.log` in the output folder; never the daily
  log folder, the shared folder or the system log
- writes previews to `/tmp/vid2mos-test-<user>` unless `VID2MOS_TMP` is set
- tags every line `mode=test`, which readers skip

```bash
./vid2mos-hardened.sh --test -v /path/to/video.mov
VID2MOS_FFMPEG=/usr/local/bin/ffmpeg ./vid2mos-hardened.sh --test -v /path/to/video.mov
```

`batch-vid2mos.sh` always runs the script in test mode and logs next to its report.
`--bin-dir`, `--ffmpeg` and `--ffprobe` choose the tools to test:

```bash
sudo ./batch-vid2mos.sh /Volumes/Share/folder --ffmpeg /usr/local/bin/ffmpeg --report /tmp/local-ffmpeg.tsv
```

### Retrying failed files, and sizing the timeout

The mosaic is made with ffmpeg's `select` + `tile` filters, which decode every frame from the seek
point to the end of the file. A preview therefore costs at least one full read of the file, and a
file whose read alone takes longer than the limit can never get one. Up to 1.2.1 the limit was a
flat 120 s, and a timeout was tried once more without the seek, costing twice the limit.

Measured on a P5 server over 10GbE, one file at a time, with Archiware's ffmpeg: six 1080p ProRes
files of 46-63 GB (50-67 minutes each) that had all timed out at 120 s made their previews in
176-303 s, 175-333 MB/s. So 1.3.0 scales the limit with the file: 120 s plus 1 s per 100 MB
(half the slowest rate measured, for a real job where several clients read the share at once),
capped at 1 hour so a stuck read still ends, and a timeout is no longer tried again. P5 passes
the script no environment, so to change these numbers for P5 runs edit the defaults near
`TIMEOUT_BASE` at the top of the script. `--selftest` prints the limit in use.

To see how many of a share's files are at risk:

```bash
./size-survey.sh /Volumes/Share/project --rate 400 --timeout 120 --report /tmp/sizes.tsv
```

`--rate` is the read speed to assume in MB/s (400 is a busy 10GbE share). `--probe` adds duration
and codec per file (slower). To retry a list of files with a longer limit and a second ffmpeg,
keeping the previews:

```bash
./vid2mos-test-runner.sh --run-dir /tmp/retry-1 --list /tmp/failed.txt --mode fallback \
    --toolchain Archiware=/usr/local/aw/bin/ffmpeg:/usr/local/aw/bin/ffprobe \
    --toolchain Local=/usr/local/bin/ffmpeg:/usr/local/bin/ffprobe \
    --timeout 1800 --jpeg-dir /Volumes/Share/preview-review
```

Results are in `/tmp/retry-1/results.tsv`, the script's log for the run in `run.log`, and
ffmpeg's error output for each failure in `ffmpeg/`. Both tools run in test mode: the daily log
and P5 are never touched.

## Use with Archiware P5

The quickest way, on each machine that may generate previews:

```bash
sudo ./prepare-client.sh                       # install, then self-test
./prepare-client.sh --check                    # report only, change nothing
sudo ./prepare-client.sh --source /path/to/a/video.mov    # also check a source can be read
```

It installs the copy beside it to `/Library/Scripts/vid2mos-hardened.sh` (owner root, mode 755, no
quarantine flags), keeps any different earlier copy as `.previous`, checks ffmpeg and ffprobe, runs the
script's `--selftest` and, as root, reports whether Remote Login is on. It never changes P5's settings,
turns on Remote Login or touches SSH keys: it prints those as next steps.

To do it by hand, install it under a new name and leave the original in place:

```bash
sudo cp vid2mos-hardened.sh /Library/Scripts/vid2mos-hardened.sh
sudo xattr -c /Library/Scripts/vid2mos-hardened.sh
sudo chmod 755 /Library/Scripts/vid2mos-hardened.sh
```

Then point P5's preview script setting at that path.

**Install it on every machine that may generate previews.** In my tests, when a P5 client was
enabled for preview generation, the server ran none of the previews itself; all runs were in the
client's log. A client that lacks the script, or cannot read the source path, produces the
"couldn't execute" warnings. The `host=` field in each log line shows which machine ran each
preview.

Check a machine before a job (no preview is made and no log line is written):

```bash
/Library/Scripts/vid2mos-hardened.sh --selftest /path/to/a/source/file
```

Read the logs with:

```bash
sudo ./vid2mos-log-summary.sh                      # every vid2mos log in /var/log and /tmp
sudo ./vid2mos-log-summary.sh --since "2026-11-22 09:00"
```

## Tested

- 75 checks on synthetic media with P5's bundled ffmpeg 7.1 and macOS's stock `/bin/bash` 3.2.
- A real Archive job on P5 8.0.6 (macOS): previews created, no warnings in the server log.
- A P5 preview client with a read-only source mounted: all runs logged OK and the previews
  appeared in the P5 web interface.

- At scale: a real job of 2,640 files across three preview clients ran to the end. P5 loaded 2,254
  and skipped 386; the clients' failed counts matched the server's warnings, and every failure was
  logged with its reason.
- A script P5 cannot start on a client (a missing script path gives `couldn't execute`, as the
  earlier test showed): on a real server P5 logged that warning for each file and carried on.
  Batches with hundreds of those warnings (up to 1,909 in one batch) finished and skipped the
  previews, so the server does not wait forever. The cause of each of those was not checked. One
  batch with 257 such warnings never logged a finish and the reason is unknown.

Not tested: a preview client dropping off the network in the middle of a job.

## P5 Preview Monitor (Mac desktop app)

A macOS app that watches preview generation on the P5 server and every client by reading this
script's logs, and repairs failed previews: it finds each file in P5, restores it if the source is
gone, makes the preview again on a client and attaches it to the archive entry. Its releases are
published here, as pre-releases; see `p5-preview-monitor/RELEASE-NOTES-0.3.1.md` (latest) and
`p5-preview-monitor/RELEASE-NOTES-0.3.0.md`.

## Credit and licence

Derived from the `vid2mos.sh` script in Archiware's blog post linked above. Archiware P5 is a
product of Archiware GmbH; this project is independent and not affiliated with or supported by
Archiware. Provided as is, without warranty: test it on copies before relying on it.
