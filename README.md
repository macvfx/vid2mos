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
- **Unique output names** (a short hash of the input path), so same-named files in different
  folders do not overwrite each other.

The contract with P5 is unchanged: argument = path of the video; stdout = only the path of the
JPEG, on success; stderr empty; exit 0 or 1.

## Files

| File | Purpose |
|---|---|
| `vid2mos-hardened.sh` | The preview script (drop-in replacement for `vid2mos.sh`) |
| `test-vid2mos.sh` | 47 checks on synthetic media. `--compare <original>` also shows what the original does on the same inputs |
| `batch-vid2mos.sh` | Runs the script over a folder of real media with a per-file report |
| `vid2mos-log-summary.sh` | Summarises the daily logs: totals per host, runs per minute, unfinished runs, latest failures |
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
`VID2MOS_PROBE_TIMEOUT`.

## Use with Archiware P5

Install it under a new name and leave the original in place:

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

Read the logs with:

```bash
sudo ./vid2mos-log-summary.sh                      # every vid2mos log in /var/log and /tmp
sudo ./vid2mos-log-summary.sh --since "2026-11-22 09:00"
```

## Tested

- 47 checks on synthetic media with P5's bundled ffmpeg 7.1 and macOS's stock `/bin/bash` 3.2.
- A real Archive job on P5 8.0.6 (macOS): previews created, no warnings in the server log.
- A P5 preview client with a read-only source mounted: all runs logged OK and the previews
  appeared in the P5 web interface.

Not tested at large scale (hundreds of files) or with a missing script on a client.

## Credit and licence

Derived from the `vid2mos.sh` script in Archiware's blog post linked above. Archiware P5 is a
product of Archiware GmbH; this project is independent and not affiliated with or supported by
Archiware. Provided as is, without warranty: test it on copies before relying on it.
