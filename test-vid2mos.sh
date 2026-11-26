#!/bin/bash
# test-vid2mos.sh - test vid2mos-hardened.sh against synthetic media.
#
# Usage:
#   ./test-vid2mos.sh [--script PATH] [--bin-dir DIR] [--compare ORIGINAL_SCRIPT]
#
#   --script   script under test           (default: vid2mos-hardened.sh beside this file)
#   --bin-dir  folder with ffmpeg+ffprobe  (default: /usr/local/aw/bin, P5's own build)
#   --compare  also run the ORIGINAL script on every case and print what it does
#              (informational only, never counts as pass/fail)
#
# Everything runs in a private temp folder; nothing in /Library or the real /tmp
# preview area is touched. Exit status is 0 only if every check passes.

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/vid2mos-hardened.sh"
BIN_DIR="/usr/local/aw/bin"
ORIGINAL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --script)  SCRIPT="$2"; shift 2;;
        --bin-dir) BIN_DIR="$2"; shift 2;;
        --compare) ORIGINAL="$2"; shift 2;;
        *) echo "unknown option: $1"; exit 2;;
    esac
done

FFMPEG="$BIN_DIR/ffmpeg"
[ -x "$SCRIPT" ] || { echo "script not executable: $SCRIPT"; exit 2; }
[ -x "$FFMPEG" ] || { echo "ffmpeg not found at $FFMPEG (use --bin-dir)"; exit 2; }

WORK="$(mktemp -d /tmp/vid2mos-test.XXXXXX)" || exit 2
trap 'rm -rf "$WORK"' EXIT
MEDIA="$WORK/media"; OUT="$WORK/out"; mkdir -p "$MEDIA" "$OUT"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Run the script under test. Sets: OUTTXT ERRTXT RC SECS. Extra env can be put before the call.
run() {
    local start=$SECONDS
    OUTTXT=$("$SCRIPT" "$@" 2> "$WORK/stderr.txt" < /dev/null)
    RC=$?
    SECS=$(( SECONDS - start ))
    ERRTXT=$(cat "$WORK/stderr.txt")
}
export VID2MOS_BIN_DIR="$BIN_DIR" VID2MOS_TMP="$OUT" VID2MOS_LOG="$WORK/vid2mos.log"

is_one_line()  { [ "$(printf '%s\n' "$OUTTXT" | grep -c .)" -eq 1 ]; }
is_jpeg()      { [ -s "$1" ] && [ "$(head -c 2 "$1" | xxd -p)" = "ffd8" ]; }

gen() {  # gen <file> <ffmpeg args...>   quiet synthetic media
    local f="$1"; shift
    "$FFMPEG" -nostdin -hide_banner -loglevel error -y "$@" "$f" || { echo "could not create $f"; exit 2; }
}

echo "Script under test : $SCRIPT"
echo "ffmpeg            : $($FFMPEG -version 2>&1 | head -1)"
echo "Working folder    : $WORK"
echo

# ----------------------------------------------------------------- media set
gen "$MEDIA/normal.mp4"      -f lavfi -i "testsrc=duration=30:size=640x360:rate=25" -c:v mpeg4 -pix_fmt yuv420p
gen "$MEDIA/short3s.mp4"     -f lavfi -i "testsrc=duration=3:size=640x360:rate=25"  -c:v mpeg4 -pix_fmt yuv420p
gen "$MEDIA/five-frames.mp4" -f lavfi -i "testsrc=duration=0.2:size=320x180:rate=25" -c:v mpeg4 -pix_fmt yuv420p
gen "$MEDIA/nocount.ts"      -f lavfi -i "testsrc=duration=20:size=640x360:rate=25" -c:v mpeg4 -pix_fmt yuv420p -f mpegts
gen "$MEDIA/still.jpg"       -f lavfi -i "testsrc=size=320x240" -frames:v 1
gen "$MEDIA/with space & ünï.mp4" -f lavfi -i "testsrc=duration=12:size=320x180:rate=25" -c:v mpeg4 -pix_fmt yuv420p
mkdir -p "$MEDIA/a" "$MEDIA/b"
gen "$MEDIA/a/clip.mp4" -f lavfi -i "testsrc=duration=12:size=320x180:rate=25" -c:v mpeg4 -pix_fmt yuv420p
gen "$MEDIA/b/clip.mp4" -f lavfi -i "smptebars=duration=12:size=320x180:rate=25" -c:v mpeg4 -pix_fmt yuv420p
echo "this is not a video" > "$MEDIA/notes.mp4"
: > "$MEDIA/empty.mov"

# --------------------------------------------------------------------- tests
echo "1. Normal video"
run "$MEDIA/normal.mp4"
check "exit 0"                        '[ $RC -eq 0 ]'
check "stdout is exactly one path"    'is_one_line'
check "output is a real JPEG"         'is_jpeg "$OUTTXT"'
check "stderr is empty"               '[ -z "$ERRTXT" ]'
check "finished quickly (< 20 s)"     '[ $SECS -lt 20 ]'

echo "2. Clip shorter than the 10 s seek point (3 s)"
run "$MEDIA/short3s.mp4"
check "exit 0 and JPEG produced"      '[ $RC -eq 0 ] && is_jpeg "$OUTTXT"'
check "stderr is empty"               '[ -z "$ERRTXT" ]'

echo "3. Very short clip (5 frames, fewer than the 12 tiles)"
run "$MEDIA/five-frames.mp4"
check "exit 0 and JPEG produced"      '[ $RC -eq 0 ] && is_jpeg "$OUTTXT"'

echo "4. Container without a frame count (MPEG-TS)"
run "$MEDIA/nocount.ts"
check "exit 0 and JPEG produced"      '[ $RC -eq 0 ] && is_jpeg "$OUTTXT"'
check "stderr is empty"               '[ -z "$ERRTXT" ]'

echo "5. Still image"
run "$MEDIA/still.jpg"
check "exit 0 and JPEG produced"      '[ $RC -eq 0 ] && is_jpeg "$OUTTXT"'

echo "6. Name with spaces, ampersand and non-ASCII characters"
run "$MEDIA/with space & ünï.mp4"
check "exit 0 and JPEG produced"      '[ $RC -eq 0 ] && is_jpeg "$OUTTXT"'

echo "7. Same file name in two folders must not collide"
run "$MEDIA/a/clip.mp4"; first="$OUTTXT"; rc1=$RC
run "$MEDIA/b/clip.mp4"; second="$OUTTXT"; rc2=$RC
check "both succeed"                  '[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]'
check "output paths differ"           '[ -n "$first" ] && [ "$first" != "$second" ]'

echo "8. Missing file"
run "$MEDIA/does-not-exist.mp4"
check "exit 1"                        '[ $RC -eq 1 ]'
check "stdout empty"                  '[ -z "$OUTTXT" ]'
check "stderr empty (P5 forbids it)"  '[ -z "$ERRTXT" ]'

echo "9. No argument"
run
check "exit 1, stdout and stderr empty" '[ $RC -eq 1 ] && [ -z "$OUTTXT" ] && [ -z "$ERRTXT" ]'

echo "10. Text file and empty file named like videos"
run "$MEDIA/notes.mp4"
check "text file: exit 1, stdout empty, stderr empty" '[ $RC -eq 1 ] && [ -z "$OUTTXT" ] && [ -z "$ERRTXT" ]'
run "$MEDIA/empty.mov"
check "empty file: exit 1, stdout empty, stderr empty" '[ $RC -eq 1 ] && [ -z "$OUTTXT" ] && [ -z "$ERRTXT" ]'

echo "11. Stdin held open by the caller (must not wait for it)"
# A FIFO whose writer never closes: reading from it would block until the writer exits.
mkfifo "$WORK/held-open"
sleep 30 > "$WORK/held-open" &
holder=$!
start=$SECONDS
OUTTXT=$("$SCRIPT" "$MEDIA/normal.mp4" 2>/dev/null < "$WORK/held-open")
RC=$?; SECS=$((SECONDS-start))
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "returns without waiting on stdin (< 15 s)" '[ $SECS -lt 15 ] && [ $RC -eq 0 ]'

echo "12. Hung ffmpeg: watchdog must kill it and return"
FAKE="$WORK/fakebin"; mkdir -p "$FAKE"
cp "$BIN_DIR/ffprobe" "$FAKE/ffprobe"
printf '#!/bin/sh\nsleep 60\n' > "$FAKE/ffmpeg"; chmod +x "$FAKE/ffmpeg"
start=$SECONDS
OUTTXT=$(VID2MOS_BIN_DIR="$FAKE" VID2MOS_TIMEOUT=3 "$SCRIPT" "$MEDIA/normal.mp4" 2>"$WORK/stderr.txt")
RC=$?; SECS=$((SECONDS-start)); ERRTXT=$(cat "$WORK/stderr.txt")
check "exit 1, stdout empty, stderr empty" '[ $RC -eq 1 ] && [ -z "$OUTTXT" ] && [ -z "$ERRTXT" ]'
check "returned within 12 s of a 3 s limit" '[ $SECS -le 12 ]'
check "no leftover fake ffmpeg process"     '! pgrep -f "$FAKE/ffmpeg" >/dev/null'

echo "13. Hung ffprobe: watchdog must kill it and the run must still end"
printf '#!/bin/sh\nsleep 60\n' > "$FAKE/ffprobe"; chmod +x "$FAKE/ffprobe"
cp "$FFMPEG" "$FAKE/ffmpeg"
start=$SECONDS
OUTTXT=$(VID2MOS_BIN_DIR="$FAKE" VID2MOS_PROBE_TIMEOUT=3 "$SCRIPT" "$MEDIA/normal.mp4" 2>"$WORK/stderr.txt")
RC=$?; SECS=$((SECONDS-start))
check "ends within 25 s (probe limit 3 s per call)" '[ $SECS -le 25 ]'
check "stderr empty"                                '[ ! -s "$WORK/stderr.txt" ]'
check "no leftover fake ffprobe process"            '! pgrep -f "$FAKE/ffprobe" >/dev/null'

echo "14. Logging"
check "log file written"                    '[ -s "$WORK/vid2mos.log" ]'
check "log records the host name"           'grep -q "host=$(hostname -s)" "$WORK/vid2mos.log"'
check "log has OK and FAIL lines"           'grep -q " OK " "$WORK/vid2mos.log" && grep -q " FAIL " "$WORK/vid2mos.log"'
check "log names the input file"            'grep -q "does-not-exist.mp4" "$WORK/vid2mos.log"'
check "every run logs a START line"        '[ "$(grep -c " START " "$WORK/vid2mos.log")" -ge 10 ]'
check "timestamp has date, time, seconds and UTC offset" 'grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4} host=" "$WORK/vid2mos.log"'
check "hung ffmpeg is logged as TIMED OUT"  'grep -q "TIMED OUT" "$WORK/vid2mos.log"'
check "corrupt file is NOT logged as a timeout" '! grep "notes.mp4" "$WORK/vid2mos.log" | grep -q "TIMED OUT"'
check "corrupt file is logged as an ffmpeg failure" 'grep "notes.mp4" "$WORK/vid2mos.log" | grep -q "ffmpeg failed\|no preview produced"'

echo "15. Log summary tool"
SUM="$HERE/vid2mos-log-summary.sh"
if [ -x "$SUM" ]; then
    cp "$WORK/vid2mos.log" "$WORK/sum.log"
    echo "2026-11-22 10:00:00 -0700 host=testhost user=root pid=99999 START input=\"/x/never-finished.mov\" script=s bin=b" >> "$WORK/sum.log"
    summary=$("$SUM" "$WORK/sum.log" 2>&1)
    check "summary lists this host with OK and FAIL counts" 'printf "%s" "$summary" | grep -q "$(hostname -s)"'
    check "summary reports an unfinished run"               'printf "%s" "$summary" | grep -q "never finished (hung, killed, or still running): [1-9]"'
    check "summary shows the unfinished input"              'printf "%s" "$summary" | grep -q "never-finished.mov"'
    check "summary shows the hung-ffmpeg timeout"           'printf "%s" "$summary" | grep -q "TIMED OUT"'
    # pid reuse: an earlier START that never finished must not be hidden by a later run with the same pid
    printf '%s\n' \
      "2026-11-20 09:00:00 -0700 host=testhost user=root pid=4242 START input=\"/x/hung-on-day1.mov\" script=s bin=b" \
      "2026-11-22 09:00:00 -0700 host=testhost user=root pid=4242 START input=\"/x/fine-on-day3.mov\" script=s bin=b" \
      "2026-11-22 09:00:01 -0700 host=testhost user=root pid=4242 OK (1s) frames=1 via=nb_frames interval=1 input=\"/x/fine-on-day3.mov\" output=\"o\"" > "$WORK/reuse.log"
    reuse=$("$SUM" "$WORK/reuse.log" 2>&1)
    check "pid reuse does not hide an earlier unfinished run" 'printf "%s" "$reuse" | grep -q "hung-on-day1.mov"'
    check "a finished run is not reported as unfinished"      '! printf "%s" "$reuse" | grep -q "fine-on-day3.mov\" script"'
else
    bad "vid2mos-log-summary.sh not found beside the test script"
fi

echo "16. Daily log files and pruning"
LD="$WORK/logs"; mkdir -p "$LD"
touch -t 202601010000 "$LD/vid2mos-2026-01-01.log"                       # far older than 30 days
recent=$(date -v-5d +%Y-%m-%d); touch "$LD/vid2mos-$recent.log"          # 5 days old: must stay
env -u VID2MOS_LOG VID2MOS_LOG_DIR="$LD" "$SCRIPT" "$MEDIA/normal.mp4" >/dev/null 2>&1
today="$LD/vid2mos-$(date +%Y-%m-%d).log"
check "today's file is vid2mos-YYYY-MM-DD.log"    '[ -s "$today" ]'
check "log lines went to the daily file"           'grep -q " OK " "$today"'
check "file older than 30 days was pruned"         '[ ! -e "$LD/vid2mos-2026-01-01.log" ]'
check "recent daily file was kept"                 '[ -e "$LD/vid2mos-$recent.log" ]'
if [ -x "$SUM" ]; then
    summary=$("$SUM" "$LD" 2>&1)
    check "summary reads a folder of daily logs"   'printf "%s" "$summary" | grep -q "$(hostname -s)"'
fi

echo
echo "Shared log copy, --version, --selftest"
SH="$WORK/shared"; mkdir -p "$SH"
HN=$(hostname -s)
VID2MOS_SHARED_DIR="$SH" run "$MEDIA/short3s.mp4"
sf="$SH/vid2mos-$HN-$(date +%Y-%m-%d).log"
for _ in 1 2 3 4 5 6; do [ -s "$sf" ] && grep -q " OK " "$sf" && break; sleep 0.5; done
check "shared file is vid2mos-<host>-YYYY-MM-DD.log" '[ -s "$sf" ]'
check "shared copy holds START and OK"               'grep -q " START " "$sf" && grep -q " OK " "$sf"'
check "run is unchanged: one-line JPEG path, no stderr" 'is_one_line && is_jpeg "$OUTTXT" && [ -z "$ERRTXT" ]'
check "shared lines match the local log"             '[ "$(grep -c "pid=" "$sf")" -le "$(grep -c "pid=" "$WORK/vid2mos.log")" ] && grep -q "$(sed -n "s/.*pid=\([0-9]*\) .*/\1/p" "$sf" | tail -1)" "$WORK/vid2mos.log"'

VID2MOS_SHARED_DIR="$WORK/no-such-share" run "$MEDIA/short3s.mp4"
check "missing shared folder never fails the run"    '[ $RC -eq 0 ] && is_jpeg "$OUTTXT"'
check "missing shared folder adds no stderr"         '[ -z "$ERRTXT" ]'
check "missing shared folder is not created"         '[ ! -e "$WORK/no-such-share" ]'

chmod 555 "$SH"
VID2MOS_SHARED_DIR="$SH" run "$MEDIA/short3s.mp4"
chmod 755 "$SH"
check "read-only shared folder never fails the run"  '[ $RC -eq 0 ] && is_jpeg "$OUTTXT" && [ -z "$ERRTXT" ]'

# A stalled share must not delay the run: a FIFO with no reader blocks any write to it.
mkdir -p "$WORK/stuck"; mkfifo "$WORK/stuck/vid2mos-$HN-$(date +%Y-%m-%d).log"
VID2MOS_SHARED_DIR="$WORK/stuck" run "$MEDIA/short3s.mp4"
check "blocked shared write does not delay the run"  '[ $RC -eq 0 ] && [ "$SECS" -le 5 ] && is_jpeg "$OUTTXT"'
pkill -f "vid2mos-$HN-$(date +%Y-%m-%d).log" 2>/dev/null
exec 9<>"$WORK/stuck/vid2mos-$HN-$(date +%Y-%m-%d).log"; exec 9>&-   # release any stuck writers

check "--version prints the version"                 '"$SCRIPT" --version | grep -Eq "^vid2mos-hardened [0-9]+\.[0-9]+\.[0-9]+$"'
: > "$WORK/vid2mos.log"
st=$("$SCRIPT" --selftest "$MEDIA/normal.mp4" 2>&1); strc=$?
check "--selftest passes on a healthy machine"       '[ $strc -eq 0 ] && printf "%s" "$st" | grep -q "^result=PASS$"'
check "--selftest reports key=value lines"           'printf "%s" "$st" | grep -q "^ffmpeg=ok$" && printf "%s" "$st" | grep -q "^source_readable=ok$"'
check "--selftest writes no log line"                '[ ! -s "$WORK/vid2mos.log" ]'
st=$("$SCRIPT" --selftest "$MEDIA/does-not-exist.mp4" 2>&1); strc=$?
check "--selftest fails on an unreadable source"     '[ $strc -eq 1 ] && printf "%s" "$st" | grep -q "^source_readable=FAIL$" && printf "%s" "$st" | grep -q "^result=FAIL$"'
st=$(VID2MOS_BIN_DIR="$WORK/none" "$SCRIPT" --selftest 2>&1); strc=$?
check "--selftest fails when ffmpeg is missing"      '[ $strc -eq 1 ] && printf "%s" "$st" | grep -q "^ffmpeg=FAIL$"'
st=$(VID2MOS_SHARED_DIR="$WORK/no-such-share" "$SCRIPT" --selftest 2>&1); strc=$?
check "--selftest fails on an unwritable shared dir" '[ $strc -eq 1 ] && printf "%s" "$st" | grep -q "^shared_dir_writable=FAIL$"'

st=$("$SCRIPT" --selftest 2>&1)
check "--selftest names the ffmpeg version"          'printf "%s" "$st" | grep -q "^ffmpeg_version=ffmpeg version "'
check "--selftest names the exact binaries"          'printf "%s" "$st" | grep -q "^ffmpeg_path=$BIN_DIR/ffmpeg$"'

echo
echo "Symbolic links are not previewed (1.2.1)"
ln -s "$MEDIA/normal.mp4" "$MEDIA/link.mp4"
ln -s "$MEDIA/gone.mp4" "$MEDIA/broken-link.mp4"
: > "$WORK/vid2mos.log"
run "$MEDIA/link.mp4"
check "a link fails at once, stdout and stderr empty"   '[ $RC -eq 1 ] && [ -z "$OUTTXT" ] && [ -z "$ERRTXT" ] && [ $SECS -le 2 ]'
check "the reason names the symbolic link"               'grep "link.mp4" "$WORK/vid2mos.log" | grep -q "FAIL .*source is a symbolic link, not previewed"'
run "$MEDIA/broken-link.mp4"
check "a broken link gets the same reason"               '[ $RC -eq 1 ] && grep "broken-link.mp4" "$WORK/vid2mos.log" | grep -q "symbolic link"'
VID2MOS_FOLLOW_SYMLINKS=1 run "$MEDIA/link.mp4"
check "VID2MOS_FOLLOW_SYMLINKS=1 previews the target"    '[ $RC -eq 0 ] && is_jpeg "$OUTTXT"'
rm -f "$MEDIA/link.mp4" "$MEDIA/broken-link.mp4"

echo
echo "Size rotation keeps every rotation (1.2.0)"
RL="$WORK/rot.log"
for _ in 1 2 3; do VID2MOS_LOG="$RL" VID2MOS_LOG_MAX_BYTES=100 "$SCRIPT" "$MEDIA/short3s.mp4" >/dev/null 2>&1; done
check "rotations are numbered .1, .2 and none is overwritten" '[ -s "$RL.1" ] && [ -s "$RL.2" ] && [ -s "$RL" ]'
check "every run's OK line survives the rotations"            '[ "$(cat "$RL" "$RL".* | grep -c " OK ")" -eq 3 ]'

echo
echo "Separate ffmpeg and ffprobe (1.2.0)"
FK="$WORK/fakeffmpeg"; mkdir -p "$FK"
printf '#!/bin/sh\necho "fake ffmpeg: Invalid argument" >&2\nexit 234\n' > "$FK/ffmpeg"; chmod +x "$FK/ffmpeg"
: > "$WORK/vid2mos.log"
VID2MOS_FFMPEG="$FK/ffmpeg" run "$MEDIA/normal.mp4"
check "VID2MOS_FFMPEG is used instead of the folder"  '[ $RC -eq 1 ] && grep -q "ffmpeg failed (rc=234)" "$WORK/vid2mos.log"'
check "START line names the ffmpeg and ffprobe used"  'grep " START " "$WORK/vid2mos.log" | grep -q "ffmpeg=\"$FK/ffmpeg\" ffprobe=\"$BIN_DIR/ffprobe\""'
check "failure leaves ffmpeg stderr in the log file"   'f=$(sed -n "s/.* see \(.*\.log\) input=.*/\1/p" "$WORK/vid2mos.log" | tail -1); [ -n "$f" ] && grep -q "Invalid argument" "$f"'
VID2MOS_BIN_DIR="$WORK/none" VID2MOS_FFMPEG="$BIN_DIR/ffmpeg" VID2MOS_FFPROBE="$BIN_DIR/ffprobe" run "$MEDIA/normal.mp4"
check "both overrides work with no bin folder at all" '[ $RC -eq 0 ] && is_jpeg "$OUTTXT" && [ -z "$ERRTXT" ]'
st=$(VID2MOS_FFPROBE="$WORK/none/ffprobe" "$SCRIPT" --selftest 2>&1); strc=$?
check "--selftest checks the overridden ffprobe"      '[ $strc -eq 1 ] && printf "%s" "$st" | grep -q "^ffprobe=FAIL$"'

echo
echo "Test mode (1.2.0)"
TM="$WORK/tm"; mkdir -p "$TM/daily" "$TM/shared" "$TM/out"
tlog="$TM/out/vid2mos-test-$(date +%Y-%m-%d).log"
OUTTXT=$(env -u VID2MOS_LOG VID2MOS_LOG_DIR="$TM/daily" VID2MOS_SHARED_DIR="$TM/shared" VID2MOS_TMP="$TM/out" \
    "$SCRIPT" --test "$MEDIA/normal.mp4" 2>"$WORK/stderr.txt" < /dev/null); RC=$?; ERRTXT=$(cat "$WORK/stderr.txt")
sleep 1
check "--test: same contract (one JPEG path, no stderr)" '[ $RC -eq 0 ] && is_one_line && is_jpeg "$OUTTXT" && [ -z "$ERRTXT" ]'
check "--test: nothing in the daily log folder"         '[ -z "$(ls -A "$TM/daily")" ]'
check "--test: nothing in the shared folder"            '[ -z "$(ls -A "$TM/shared")" ]'
check "--test: log is beside the output, tagged"        'grep -q "user=[^ ]* mode=test pid=[0-9]* START " "$tlog" && grep -q "mode=test pid=[0-9]* OK " "$tlog"'
check "--test: an untagged reader does not see a run"   '! grep -Eq "user=[^ ]+ pid=[0-9]+ (START|OK|FAIL)" "$tlog"'
rm -f "$tlog"
OUTTXT=$(env -u VID2MOS_LOG VID2MOS_MODE=test VID2MOS_LOG_DIR="$TM/daily" VID2MOS_TMP="$TM/out" \
    "$SCRIPT" "$MEDIA/short3s.mp4" 2>/dev/null < /dev/null); RC=$?
check "VID2MOS_MODE=test works like --test"             '[ $RC -eq 0 ] && is_jpeg "$OUTTXT" && grep -q "mode=test" "$tlog" && [ -z "$(ls -A "$TM/daily")" ]'
OUTTXT=$(VID2MOS_LOG="$TM/pinned.log" "$SCRIPT" --test -v "$MEDIA/short3s.mp4" 2>"$WORK/stderr.txt" < /dev/null); RC=$?
check "--test -v: pinned log honoured, -v echoes"       '[ $RC -eq 0 ] && grep -q "mode=test" "$TM/pinned.log" && grep -q "mode=test" "$WORK/stderr.txt"'
OUTTXT=$(env -u VID2MOS_TMP -u VID2MOS_LOG "$SCRIPT" --test "$MEDIA/short3s.mp4" 2>/dev/null < /dev/null); RC=$?
check "--test: default output folder is per user"       '[ $RC -eq 0 ] && case "$OUTTXT" in /tmp/vid2mos-test-$(id -un)/*) true;; *) false;; esac'
[ -n "$OUTTXT" ] && rm -f "$OUTTXT"
if [ -x "$SUM" ]; then
    summary=$("$SUM" "$TM/pinned.log" 2>&1)
    check "log summary skips test lines"                '! printf "%s" "$summary" | grep -q "^$(hostname -s) "'
fi

echo
echo "batch-vid2mos.sh stays out of the daily log"
BATCH="$HERE/batch-vid2mos.sh"
if [ -x "$BATCH" ]; then
    BM="$WORK/batch"; mkdir -p "$BM/media" "$BM/daily"
    cp "$MEDIA/normal.mp4" "$MEDIA/short3s.mp4" "$BM/media/"
    out=$(env -u VID2MOS_LOG VID2MOS_LOG_DIR="$BM/daily" VID2MOS_SHARED_DIR="$TM/shared" \
        "$BATCH" "$BM/media" --script "$SCRIPT" --bin-dir "$BIN_DIR" --report "$BM/r.tsv" 2>&1); brc=$?
    check "batch passes on good media"                  '[ $brc -eq 0 ] && [ "$(grep -c . "$BM/r.tsv")" -eq 3 ]'
    check "batch writes its own tagged log"             '[ "$(grep -c "mode=test pid=[0-9]* OK " "$BM/r.log")" -eq 2 ]'
    check "batch leaves daily and shared folders empty" '[ -z "$(ls -A "$BM/daily")" ] && [ -z "$(ls -A "$TM/shared")" ]'
    out=$(env -u VID2MOS_LOG "$BATCH" "$BM/media" --script "$SCRIPT" --ffmpeg "$FK/ffmpeg" --report "$BM/f.tsv" 2>&1); brc=$?
    check "batch --ffmpeg uses that ffmpeg"             '[ $brc -ne 0 ] && grep -q "rc=234" "$BM/f.log"'
    out=$("$BATCH" "$BM/media" --ffmpeg relative/ffmpeg 2>&1); brc=$?
    check "batch rejects a relative --ffmpeg"           '[ $brc -eq 2 ]'
fi

echo
echo "prepare-client.sh"
PREP="$HERE/prepare-client.sh"
if [ -x "$PREP" ]; then
    PD="$WORK/prep"; mkdir -p "$PD"
    out=$("$PREP" --check --dest "$PD/inst.sh" --bin-dir "$BIN_DIR" 2>&1); prc=$?
    check "--check changes nothing and reports FIX"       '[ ! -e "$PD/inst.sh" ] && [ $prc -eq 1 ] && printf "%s" "$out" | grep -q "FIX   not installed"'
    out=$("$PREP" --dest "$PD/inst.sh" --bin-dir "$BIN_DIR" --source "$MEDIA/normal.mp4" 2>&1); prc=$?
    check "install succeeds and says Ready"               '[ $prc -eq 0 ] && printf "%s" "$out" | grep -q "^Ready\."'
    check "a fresh install prints no FIX line"            '! printf "%s" "$out" | grep -q "FIX"'
    check "installed copy is identical and executable"    'cmp -s "$HERE/vid2mos-hardened.sh" "$PD/inst.sh" && [ -x "$PD/inst.sh" ]'
    check "installed mode is 755"                         '[ "$(stat -f %Lp "$PD/inst.sh")" = "755" ]'
    check "source path was checked"                       'printf "%s" "$out" | grep -q "source_readable=ok"'
    out=$("$PREP" --dest "$PD/inst.sh" --bin-dir "$BIN_DIR" 2>&1); prc=$?
    check "second run is idempotent (already current)"    '[ $prc -eq 0 ] && printf "%s" "$out" | grep -q "is current" && [ ! -e "$PD/inst.sh.previous" ]'
    echo "# local edit" >> "$PD/inst.sh"
    out=$("$PREP" --dest "$PD/inst.sh" --bin-dir "$BIN_DIR" 2>&1); prc=$?
    check "a different installed copy is replaced"        '[ $prc -eq 0 ] && cmp -s "$HERE/vid2mos-hardened.sh" "$PD/inst.sh"'
    check "replacing says so, without a FIX line"         'printf "%s" "$out" | grep -q "replacing it" && ! printf "%s" "$out" | grep -q "FIX"'
    out=$("$PREP" --check --dest "$PD/inst.sh" --bin-dir "$BIN_DIR" 2>&1); prc=$?
    echo "# drift" >> "$PD/inst.sh"
    out=$("$PREP" --check --dest "$PD/inst.sh" --bin-dir "$BIN_DIR" 2>&1); prc=$?
    check "--check still reports an outdated copy as FIX" '[ $prc -eq 1 ] && printf "%s" "$out" | grep -q "FIX   installed copy" && grep -q "# drift" "$PD/inst.sh"'
    mkdir -p "$PD/ro"; chmod 555 "$PD/ro"
    out=$("$PREP" --dest "$PD/ro/inst.sh" --bin-dir "$BIN_DIR" 2>&1); prc=$?
    chmod 755 "$PD/ro"
    check "a failed install is FIX and exits 1"           '[ $prc -eq 1 ] && printf "%s" "$out" | grep -q "FIX   could not write"'
    check "the replaced copy is kept as .previous"        'grep -q "local edit" "$PD/inst.sh.previous"'
    out=$("$PREP" --dest "$PD/inst.sh" --bin-dir "$WORK/no-tools" 2>&1); prc=$?
    check "missing ffmpeg is reported and fails"          '[ $prc -eq 1 ] && printf "%s" "$out" | grep -q "FIX   .*ffmpeg is missing"'
    out=$("$PREP" --dest "$PD/inst.sh" --bin-dir "$BIN_DIR" --source "$MEDIA/does-not-exist.mov" 2>&1); prc=$?
    check "an unreadable source path fails the self-test" '[ $prc -eq 1 ] && printf "%s" "$out" | grep -q "source_readable=FAIL"'
    mkdir -p "$PD/lonely"; cp "$PREP" "$PD/lonely/"
    out=$("$PD/lonely/prepare-client.sh" --dest "$PD/x.sh" 2>&1); prc=$?
    check "no script beside it fails clearly"             '[ $prc -eq 1 ] && printf "%s" "$out" | grep -q "not found beside this file"'
    out=$("$PREP" --bogus 2>&1); prc=$?
    check "unknown option exits 2"                        '[ $prc -eq 2 ]'
fi

echo
echo "Result: $pass passed, $fail failed"

# ------------------------------------------------------- original, for contrast
if [ -n "$ORIGINAL" ]; then
    echo
    echo "Original script, same media (informational):"
    export AWPST_SRV_HOME; AWPST_SRV_HOME="$(dirname "$BIN_DIR")"
    for f in normal.mp4 short3s.mp4 five-frames.mp4 nocount.ts still.jpg notes.mp4 does-not-exist.mp4; do
        o=$("$ORIGINAL" "$MEDIA/$f" 2>"$WORK/o_err.txt" < /dev/null); r=$?
        e=$(head -c 90 "$WORK/o_err.txt" | tr '\n' ' ')
        j="no"; [ -n "$o" ] && is_jpeg "$o" && j="yes"
        printf '  %-18s exit=%s  printed-path=%s  real-jpeg=%s  stderr="%s"\n' "$f" "$r" "$([ -n "$o" ] && echo yes || echo no)" "$j" "$e"
        [ -n "$o" ] && rm -f "$o"
    done
fi

[ $fail -eq 0 ]
