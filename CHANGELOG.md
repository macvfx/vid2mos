# Changelog

Earlier versions (1.0.0, 1.1.0) are described in the git history and the README.

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
