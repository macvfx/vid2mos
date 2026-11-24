#!/bin/bash
# vid2mos-hardened.sh - P5 Archive video preview generator (mosaic of 12 frames).
#
# Drop-in replacement for vid2mos.sh. Same contract with P5:
#   * argument  : full path of the video to convert  (or: -v <file> for a shell test)
#   * stdout    : ONLY the full path of the generated JPG, on success
#   * stderr    : nothing
#   * exit code : 0 on success, 1 on failure (and nothing on stdout)
#
# What is different from the original:
#   * Every run is logged (host, user, pid, input, result, seconds) to
#       $VID2MOS_LOG_DIR/vid2mos-YYYY-MM-DD.log (one file per day; folder defaults to /var/log
#       when writable, else /tmp; files older than VID2MOS_KEEP_DAYS, default 30, are pruned)  and to the system log via logger(1)
#     so a failed preview can be traced to the machine that ran it.
#   * ffmpeg runs with -nostdin and every tool gets stdin from /dev/null,
#     so nothing can sit waiting on an inherited pipe.
#   * ffprobe and ffmpeg each run under a watchdog (VID2MOS_TIMEOUT, default 120 s for
#     ffmpeg, VID2MOS_PROBE_TIMEOUT, default 30 s for ffprobe), so an offline or very
#     slow source cannot hang the run. The watchdog never keeps stdout open.
#   * Frame count "N/A", empty or 0 no longer breaks the arithmetic: the script falls
#     back to duration x frame rate, then to the first frames of the file.
#   * Clips shorter than the 10 s seek point (and still images) are retried without a seek.
#   * The output file name includes a short hash of the input path, so two files with
#     the same name in different folders cannot overwrite each other's preview.
#   * The result is checked: a missing or empty JPG is a failure, not a printed path.
#   * Optional second copy of the log in a shared folder (VID2MOS_SHARED_DIR), one file per
#     host per day, so a monitor can read every machine's runs from one place. The copy is
#     best effort: it is written in the background and can never delay or fail a run.
#   * --version and --selftest [source-path] for pre-flight checks (see below).
#
# Modes besides a normal run (neither is used by P5; both write to stdout):
#   --version              print the script version
#   --selftest [path]      check this machine: ffmpeg/ffprobe, temp and log folders, the shared
#                          folder (when set) and, if a path is given, that it is readable.
#                          Prints key=value lines and ends with result=PASS or result=FAIL.
#                          Exit 0 on PASS. Writes no START line and no preview.
#
# Environment (all optional):
#   VID2MOS_BIN_DIR        folder holding ffmpeg + ffprobe (tests / non-standard installs)
#   AWPST_SRV_HOME         set by P5; ffmpeg/ffprobe are taken from $AWPST_SRV_HOME/bin
#   VID2MOS_TMP            output folder (default /tmp)
#   VID2MOS_LOG_DIR        folder for the daily logs (default /var/log if writable, else /tmp)
#   VID2MOS_KEEP_DAYS      days of daily logs to keep (default 30)
#   VID2MOS_LOG            pin ONE fixed log file instead of daily files (tests)
#   VID2MOS_SHARED_DIR     also copy every log line to $VID2MOS_SHARED_DIR/vid2mos-<host>-YYYY-MM-DD.log
#   VID2MOS_TIMEOUT        ffmpeg limit, seconds
#   VID2MOS_PROBE_TIMEOUT  ffprobe limit, seconds

VERSION="1.1.0"
MODE=""
VERBOSE=""
case "$1" in
    --version)  MODE=version; shift;;
    --selftest) MODE=selftest; shift;;
esac
if [ "$1" = "-v" ]; then
    VERBOSE=1
    shift
fi
input_file="$1"

# ---------------------------------------------------------------- settings
if [ -n "$VID2MOS_BIN_DIR" ]; then
    AW_BIN="$VID2MOS_BIN_DIR"
elif [ -n "$AWPST_SRV_HOME" ]; then
    AW_BIN="$AWPST_SRV_HOME/bin"
else
    AW_BIN="/usr/local/aw/bin"
fi
FFMPEG="$AW_BIN/ffmpeg"
FFPROBE="$AW_BIN/ffprobe"
TMP="${VID2MOS_TMP:-/tmp}"
# Log file. One file per day (vid2mos-YYYY-MM-DD.log): no renaming, so concurrent runs cannot
# race, and old days stay put until VID2MOS_KEEP_DAYS (default 30) have passed.
# VID2MOS_LOG pins one fixed file instead (used by the tests).
LOG_KEEP_DAYS="${VID2MOS_KEEP_DAYS:-30}"
LOG_DIR=""
if [ -n "$VID2MOS_LOG" ]; then
    LOG="$VID2MOS_LOG"
else
    LOG_DIR="${VID2MOS_LOG_DIR:-}"
    if [ -z "$LOG_DIR" ]; then
        if [ -w /var/log ]; then LOG_DIR=/var/log; else LOG_DIR=/tmp; fi   # P5 runs as root
    fi
    LOG="$LOG_DIR/vid2mos-$(date +%Y-%m-%d).log"
fi
SHARED_DIR="${VID2MOS_SHARED_DIR:-}"
FFMPEG_TIMEOUT="${VID2MOS_TIMEOUT:-120}"
PROBE_TIMEOUT="${VID2MOS_PROBE_TIMEOUT:-30}"

position=10                    # seek point, seconds
tiles_x=4; tiles_y=3           # 4 x 3 = 12 frames
frames_wanted=$(( tiles_x * tiles_y ))
tiling="${tiles_x}x${tiles_y}"

HOST=$(hostname -s 2>/dev/null || echo unknown)
START=$SECONDS

# ----------------------------------------------------------------- logging
# Second copy of a line in the shared folder. A share can be stale or unmounted, and a write to
# one can block for a long time, so the write runs in a detached background job that nothing
# waits for, with its output closed. At worst a few stuck writers pile up; the run itself is
# never delayed and never fails because of the share. Lines from one run can land out of order
# by a moment, so readers must pair START with OK/FAIL by host and pid, never by position.
shared_copy() {
    [ -n "$SHARED_DIR" ] || return 0
    local f="$SHARED_DIR/vid2mos-$HOST-$(date +%Y-%m-%d).log"
    ( printf '%s\n' "$1" >> "$f" ) > /dev/null 2>&1 < /dev/null &
    return 0
}

# Never writes to stdout or stderr (P5 forbids it); -v echoes to stderr for shell tests.
log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S %z') host=$HOST user=$(id -un) pid=$$ $*"
    if [ -n "$LOG_DIR" ] && [ ! -e "$LOG" ]; then   # first line of a new day: prune old days
        find "$LOG_DIR" -maxdepth 1 -name 'vid2mos-*.log*' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
    fi
    if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi
    printf '%s\n' "$line" >> "$LOG" 2>/dev/null
    shared_copy "$line"
    logger -t vid2mos "host=$HOST pid=$$ $*" >/dev/null 2>&1
    [ -n "$VERBOSE" ] && printf '%s\n' "$line" >&2
    return 0
}

fail() {
    log "FAIL ($(( SECONDS - START ))s) $1 input=\"$input_file\""
    exit 1
}

# ------------------------------------------------------------- other modes
if [ "$MODE" = "version" ]; then
    echo "vid2mos-hardened $VERSION"
    exit 0
fi

if [ "$MODE" = "selftest" ]; then
    st_ok=1
    st_check() {   # st_check <label> <test-command...> : prints label=ok or label=FAIL
        local label=$1; shift
        if "$@" 2>/dev/null; then echo "$label=ok"; else echo "$label=FAIL"; st_ok=0; fi
    }
    echo "version=$VERSION"
    echo "host=$HOST"
    echo "user=$(id -un)"
    echo "script=$0"
    echo "bin_dir=$AW_BIN"
    st_check ffmpeg  test -x "$FFMPEG"
    st_check ffprobe test -x "$FFPROBE"
    st_check tmp_dir test -d "$TMP" -a -w "$TMP"
    if [ -n "$LOG_DIR" ]; then
        echo "log_dir=$LOG_DIR"
        st_check log_dir_writable test -w "$LOG_DIR"
    else
        echo "log_file=$LOG"
    fi
    if [ -n "$SHARED_DIR" ]; then
        echo "shared_dir=$SHARED_DIR"
        # A stale mount can hang a test, so probe in the background and give it 5 s.
        probe_mark="$TMP/.vid2mos-selftest.$$"
        ( : > "$SHARED_DIR/.vid2mos-selftest-$HOST-$$" && rm -f "$SHARED_DIR/.vid2mos-selftest-$HOST-$$" && : > "$probe_mark" ) \
            > /dev/null 2>&1 < /dev/null &
        st_wait=0
        while [ ! -e "$probe_mark" ] && [ "$st_wait" -lt 5 ]; do sleep 1; st_wait=$(( st_wait + 1 )); done
        if [ -e "$probe_mark" ]; then echo "shared_dir_writable=ok"; rm -f "$probe_mark"
        else echo "shared_dir_writable=FAIL"; st_ok=0; fi
    else
        echo "shared_dir=unset"
    fi
    if [ -n "$input_file" ]; then
        echo "source=$input_file"
        st_check source_readable test -r "$input_file"
    fi
    if [ "$st_ok" = 1 ]; then echo "result=PASS"; exit 0; fi
    echo "result=FAIL"; exit 1
fi

log "START input=\"$input_file\" script=$0 bin=$AW_BIN"

# ---------------------------------------------------------------- watchdog
# run_limited <seconds> <command...>   stdin from /dev/null; kills the command on timeout.
# The watchdog's output is sent to /dev/null so it never holds P5's pipes open.
# When the command has already finished, the watchdog exits without touching the marker.
run_limited() {
    local limit=$1; shift
    "$@" < /dev/null &
    local pid=$!
    ( sleep "$limit"; kill -0 "$pid" 2>/dev/null || exit 0; : > "$TIMEOUT_MARK"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) \
        > /dev/null 2>&1 < /dev/null &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    pkill -P "$watchdog" 2>/dev/null
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$rc"
}

is_posint() { case "$1" in ''|*[!0-9]*) return 1;; *) [ "$1" -ge 1 ];; esac; }

# ------------------------------------------------------------------- checks
[ -n "$input_file" ]     || fail "no input file given"
[ -f "$input_file" ]     || fail "input file not found or not readable"
[ -x "$FFMPEG" ]         || fail "ffmpeg not executable at $FFMPEG"
[ -x "$FFPROBE" ]        || fail "ffprobe not executable at $FFPROBE"
[ -d "$TMP" ] && [ -w "$TMP" ] || fail "output folder $TMP not writable"

# ------------------------------------------------------ probe: frame count
probe_file="$TMP/.vid2mos-probe.$$"
TIMEOUT_MARK="$TMP/.vid2mos-timeout.$$"   # created by the watchdog only when it fires
trap 'rm -f "$probe_file" "$probe_file".* "$TIMEOUT_MARK"' EXIT

probe() {   # probe <entries>  -> first value on one line, or empty
    # ffprobe runs directly under the watchdog (no wrapper shell), so a timeout kills ffprobe itself.
    run_limited "$PROBE_TIMEOUT" "$FFPROBE" -v error -select_streams v:0 \
        -show_entries "$1" -of default=noprint_wrappers=1:nokey=1 "$input_file" \
        > "$probe_file" 2> /dev/null
    head -n 1 "$probe_file" 2>/dev/null | tr -d '"[:space:]'
}

total_frames=$(probe stream=nb_frames)
method="nb_frames"
if ! is_posint "$total_frames"; then
    # No usable frame count (common for MXF, TS, some MKV): estimate from duration x rate.
    duration=$(probe format=duration)
    rate=$(probe stream=avg_frame_rate)
    total_frames=$(awk -v d="$duration" -v r="$rate" 'BEGIN {
        split(r, f, "/"); fps = (f[2] > 0) ? f[1] / f[2] : f[1] + 0
        if (d + 0 > 0 && fps > 0) printf "%d", d * fps; else print 0 }' 2>/dev/null)
    method="duration*rate"
fi

if is_posint "$total_frames"; then
    interval=$(( total_frames / frames_wanted ))
    [ "$interval" -ge 1 ] || interval=1
else
    interval=1                    # unknown length: just take the first frames
    method="unknown"
fi

# ----------------------------------------------------------- make the mosaic
base=$(basename -- "$input_file")
base="${base%.*}"
hash=$(printf '%s' "$input_file" | shasum 2>/dev/null | cut -c1-8)
output_file="$TMP/${base}-${hash}.jpg"
ffmpeg_log="$TMP/${base}-${hash}.log"
rm -f "$output_file"

make_mosaic() {   # make_mosaic [seek-seconds]   (no argument = no -ss at all)
    local seek=()
    [ -n "$1" ] && seek=(-ss "$1")
    rm -f "$output_file" "$TIMEOUT_MARK"   # a probe timeout must not be blamed on ffmpeg
    run_limited "$FFMPEG_TIMEOUT" "$FFMPEG" \
        -nostdin -hide_banner -loglevel error \
        "${seek[@]}" -i "$input_file" \
        -an -sn -dn \
        -frames 1 \
        -filter:v "select=not(mod(n\,$interval)),scale=320:240,tile=$tiling" \
        -y "$output_file" > /dev/null 2> "$ffmpeg_log"
    return $?
}

make_mosaic "$position"; rc=$?
if [ ! -s "$output_file" ]; then
    # Short clip (shorter than the seek point), a still image, or the seek found nothing:
    # retry with no seek at all (note: "-ss 0" makes ffmpeg 7.x emit nothing for a JPEG).
    log "retry without seek rc=$rc input=\"$input_file\""
    make_mosaic; rc=$?
fi

if [ $rc -ne 0 ] && [ ! -s "$output_file" ]; then
    if [ -e "$TIMEOUT_MARK" ]; then
        fail "ffmpeg TIMED OUT after ${FFMPEG_TIMEOUT}s and was killed (rc=$rc) see $ffmpeg_log"
    fi
    fail "ffmpeg failed (rc=$rc) see $ffmpeg_log"
fi
[ -s "$output_file" ] || fail "no preview produced (rc=$rc) see $ffmpeg_log"

# Success: the log of a clean run is not needed.
rm -f "$ffmpeg_log"
log "OK ($(( SECONDS - START ))s) frames=$total_frames via=$method interval=$interval input=\"$input_file\" output=\"$output_file\""
printf '%s\n' "$output_file"
exit 0
