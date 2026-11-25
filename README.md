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
- **Watchdogs** on ffprobe (30 s) and ffmpeg (120 s), and every tool reads stdin from `/dev/null`,
  so an offline or slow source cannot hang the run or hold P5's pipes open.
- **Short clips and stills** retry without a seek instead of producing nothing.
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
| `test-vid2mos.sh` | 75 checks on synthetic media. `--compare <original>` also shows what the original does on the same inputs |
| `batch-vid2mos.sh` | Runs the script over a folder of real media with a per-file report |
| `vid2mos-log-summary.sh` | Summarises the daily logs: totals per host, runs per minute, unfinished runs, latest failures |
| `prepare-client.sh` | One command to get a Mac ready: installs the script to `/Library/Scripts`, checks ffmpeg and Remote Login, runs `--selftest`. `--check` changes nothing |
| `TESTING.md` | How to test the scripts, what to record, and findings so far |

## Standalone use

```bash
./vid2mos-hardened.sh -v /path/to/video.mov     # -v echoes the log line to stderr
```

It needs `ffmpeg` and `ffprobe`. By default they are taken from `/usr/local/aw/bin` (the P5
install), or from `$AWPST_SRV_HOME/bin` when P5 sets it. For any other install, point
`VID2MOS_BIN_DIR` at the folder that holds them.

Optional environment variables: `VID2MOS_BIN_DIR`, `VID2MOS_TMP` (output folder, default `/tmp`),
`VID2MOS_LOG_DIR`, `VID2MOS_KEEP_DAYS`, `VID2MOS_LOG` (one fixed file), `VID2MOS_TIMEOUT`,
`VID2MOS_PROBE_TIMEOUT`, `VID2MOS_SHARED_DIR`.

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

## Credit and licence

Derived from the `vid2mos.sh` script in Archiware's blog post linked above. Archiware P5 is a
product of Archiware GmbH; this project is independent and not affiliated with or supported by
Archiware. Provided as is, without warranty: test it on copies before relying on it.
