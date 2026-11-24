# Testing vid2mos-hardened

How to check the script on a machine, and what has been learned so far. Tested with Archiware P5
8.0.6 on macOS.

## 1. Quick checks (no P5 needed)

```bash
./test-vid2mos.sh                              # 63 checks on synthetic media
./test-vid2mos.sh --compare /path/to/original-vid2mos.sh   # also shows what the original does
sudo ./batch-vid2mos.sh /path/to/copies-of-real-media      # per-file report, optional --original
```

`test-vid2mos.sh` uses `/usr/local/aw/bin` for ffmpeg unless you pass `--bin-dir`. Test on
**copies** of media. Run the batch as root to match how P5 runs the script. Each machine has its
own ffmpeg build, so repeat on every machine that may generate previews.

Include in the media: several clips under 10 s, one MXF or TS file (no frame count), one still
image, one name with spaces.

## 2. Test through P5

1. Install under a new name and leave the original alone (commands in the README), then point
   P5's preview script setting at it.
2. Archive a small folder of copies to a disk pool, with a plan that keeps the source.
3. Watch the log during the job: `tail -f /var/log/vid2mos-$(date +%Y-%m-%d).log`. One `START`
   then one `OK` or `FAIL` per file. **An empty log means P5 never called the script.**
4. Afterwards check that previews exist in P5 and the job finished, and run
   `sudo ./vid2mos-log-summary.sh`.
5. For a before/after comparison, repeat with the original script (or a wrapper that logs each
   call and then runs it).

If preview clients are enabled, run steps 1 to 4 against a job that uses one, and read the
client's log too.

## 3. What to record

- P5 version, macOS version, which machine ran the job, which script (original or hardened).
- Job result and whether the preview counter finished.
- The vid2mos logs from **every** machine involved. The `host=` values show who ran previews.
- If a job hangs: `pgrep -lP <nsd pid>`, then `sudo sample <nsd pid> 10`, before cancelling.

## 4. Findings so far

- **Short clips:** the original uses `-ss 10`. On a clip shorter than 10 s ffmpeg writes nothing,
  but the script prints the path and exits 0. With the original, 1 of 7 real short clips got a
  preview; with this version, 7 of 7.
- **P5 copes with missing previews:** with the original script, a job over short clips finished
  normally; P5 loaded the previews that existed and skipped the rest. So the silent-success bug
  costs previews but did not stall P5 in that test.
- **Preview clients do the work:** with a preview client enabled, the server ran none of the
  previews; every run was in the client's log. A client that lacks the script at the configured
  path produces `couldn't execute ... no such file or directory` warnings in the server log, with
  no host named.
- **Read-only source is fine:** a client generated previews from read-only mounted storage.
- **Retries are normal:** for clips under 10 s the first ffmpeg call exits non-zero and the log
  shows `retry without seek`, then `OK`.
- **Timeouts:** the log says `TIMED OUT` only when the watchdog fired; a corrupt file is reported
  as an ffmpeg failure.

## 5. Not yet tested

- A job with hundreds of files, many of them short clips.
- A missing script path on a preview client (does the server wait forever?).
- A preview client dropping off the network mid-job.

## 6. Cleanup

```bash
rm -f /tmp/*-????????.jpg /var/log/vid2mos-*.log     # test logs and leftover previews
sudo rm -f /Library/Scripts/vid2mos-hardened.sh      # only if abandoning the test install
```
