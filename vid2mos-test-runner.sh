#!/bin/bash
# vid2mos-test-runner.sh - run the preview script over a list of files, with one or more ffmpeg
# builds and a chosen timeout, and write one result row per file per build. Made to be started
# detached by P5 Preview Monitor ("Retry failed files"), and just as usable from Terminal.
#
# Usage:
#   ./vid2mos-test-runner.sh --run-dir DIR --list FILE [--mode script|fallback|matrix]
#                            [--toolchain LABEL=FFMPEG:FFPROBE ...] [--script PATH]
#                            [--timeout S|none] [--keep-jpegs] [--jpeg-dir DIR] [--no-probe]
#
#   --run-dir    folder for this run (created; must be empty or hold an earlier run of this script)
#   --list       file of absolute paths, one per line
#   --mode       script: first toolchain only (default); fallback: the next one when one fails;
#                matrix: every toolchain on every file
#   --toolchain  a labelled ffmpeg + ffprobe pair, absolute paths, repeatable. Default:
#                Archiware=/usr/local/aw/bin/ffmpeg:/usr/local/aw/bin/ffprobe (what P5 uses)
#   --script     preview script (default /Library/Scripts/vid2mos-hardened.sh; needs 1.2.0+)
#   --timeout    ffmpeg limit per file in seconds, or none (default: the script's, 120 s)
#   --keep-jpegs keep each preview: in DIR/jpeg, or in --jpeg-dir (a review folder, e.g. on
#                shared storage), named <n>-<toolchain>-<file name>.jpg
#   --no-probe   skip the one ffprobe read per file (codec, size, duration)
#
# Output in DIR:
#   results.tsv   n toolchain result seconds rc jpeg_bytes jpeg reason size_bytes codec width
#                 height duration path      (result: ok, fail, missing, symlink)
#   state         "running D T" while it runs, then "done D T" or "stopped D T" (D rows of T files)
#   pid           this runner's process id
#   run.log       the script's own log for this run (test mode: the daily log is never touched)
#   ffmpeg/       ffmpeg's error log for each failure, <n>-<toolchain>.log
# Stop: touch DIR/stop (it stops after the current file), or kill the pid (stops at once, and the
# ffmpeg it started is killed too).
#
# Runs as whoever starts it. Nothing in the source folders is written; previews go to DIR/work.

RUN_DIR=""; LIST=""; MODE=script; SCRIPT="/Library/Scripts/vid2mos-hardened.sh"; TIMEOUT=""
KEEP=""; JPEG_DIR=""; PROBE=1; TOOLCHAINS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --run-dir)    RUN_DIR="$2"; shift 2;;
        --list)       LIST="$2"; shift 2;;
        --mode)       MODE="$2"; shift 2;;
        --toolchain)  TOOLCHAINS+=("$2"); shift 2;;
        --script)     SCRIPT="$2"; shift 2;;
        --timeout)    TIMEOUT="$2"; shift 2;;
        --keep-jpegs) KEEP=1; shift;;
        --jpeg-dir)   JPEG_DIR="$2"; KEEP=1; shift 2;;
        --no-probe)   PROBE=""; shift;;
        -h|--help)    sed -n '2,33p' "$0"; exit 0;;
        *)            echo "unknown option: $1"; exit 2;;
    esac
done

die() { echo "$*" >&2; [ -d "$RUN_DIR" ] && printf 'error %s\n' "$*" > "$RUN_DIR/state"; exit 2; }
[ -n "$RUN_DIR" ] && [ "${RUN_DIR#/}" != "$RUN_DIR" ] || { echo "--run-dir must be an absolute path"; exit 2; }
mkdir -p "$RUN_DIR" || { echo "cannot create $RUN_DIR"; exit 2; }
[ -f "$LIST" ] || die "list not found: $LIST"
case "$MODE" in script|fallback|matrix) ;; *) die "unknown mode: $MODE";; esac
[ -x "$SCRIPT" ] || die "script not executable: $SCRIPT"
case "$TIMEOUT" in
    "") ;;
    none) TIMEOUT=604800;;
    *[!0-9]*) die "--timeout must be whole seconds or none";;
esac
[ ${#TOOLCHAINS[@]} -gt 0 ] || TOOLCHAINS=("Archiware=${AWPST_SRV_HOME:-/usr/local/aw}/bin/ffmpeg:${AWPST_SRV_HOME:-/usr/local/aw}/bin/ffprobe")
LABELS=(); FFMPEGS=(); FFPROBES=()
for t in "${TOOLCHAINS[@]}"; do
    label="${t%%=*}"; pair="${t#*=}"; ff="${pair%%:*}"; fp="${pair#*:}"
    case "$label" in ''|*[!A-Za-z0-9_.-]*) die "toolchain label must be letters, digits, . _ -: $label";; esac
    [ "${ff#/}" != "$ff" ] && [ "${fp#/}" != "$fp" ] || die "toolchain paths must be absolute: $t"
    LABELS+=("$label"); FFMPEGS+=("$ff"); FFPROBES+=("$fp")
done
if [ -n "$JPEG_DIR" ]; then
    [ "${JPEG_DIR#/}" != "$JPEG_DIR" ] || die "--jpeg-dir must be an absolute path"
    mkdir -p "$JPEG_DIR" && [ -w "$JPEG_DIR" ] || die "cannot write to $JPEG_DIR"
else
    JPEG_DIR="$RUN_DIR/jpeg"
fi
script_version=$("$SCRIPT" --version 2>/dev/null | awk '{print $2}')
case "$script_version" in 1.0.*|1.1.*|"") die "script ${script_version:-unknown} cannot take another ffmpeg (needs 1.2.0)";; esac

WORK="$RUN_DIR/work"; LOGF="$RUN_DIR/run.log"; RESULTS="$RUN_DIR/results.tsv"
mkdir -p "$WORK" "$RUN_DIR/ffmpeg" || die "cannot write to $RUN_DIR"
[ -z "$KEEP" ] || mkdir -p "$JPEG_DIR"
rm -f "$RUN_DIR/stop"
echo $$ > "$RUN_DIR/pid"
total=$(grep -c . "$LIST")
done_n=0
printf 'n\ttoolchain\tresult\tseconds\trc\tjpeg_bytes\tjpeg\treason\tsize_bytes\tcodec\twidth\theight\tduration\tpath\n' > "$RESULTS"
printf 'running 0 %d\n' "$total" > "$RUN_DIR/state"

export VID2MOS_MODE=test VID2MOS_TMP="$WORK" VID2MOS_LOG="$LOGF"
unset VID2MOS_SHARED_DIR
[ -z "$TIMEOUT" ] || export VID2MOS_TIMEOUT="$TIMEOUT"

child=""
on_term() {
    [ -n "$child" ] && kill -TERM "$child" 2>/dev/null
    pkill -TERM -f -- "$WORK/" 2>/dev/null      # the ffmpeg/ffprobe writing into this run
    printf 'stopped %d %d\n' "$done_n" "$total" > "$RUN_DIR/state"
    exit 143
}
trap on_term TERM INT HUP

clean() { printf '%s' "$1" | tr '\t\n\r' '   '; }

# probe_file <ffprobe> <file> -> codec<TAB>width<TAB>height<TAB>duration (30 s limit)
probe_file() {
    local out="$WORK/.probe.$$"
    "$1" -v error -select_streams v:0 -show_entries stream=codec_name,width,height:format=duration \
        -of default=noprint_wrappers=1 "$2" > "$out" 2>/dev/null < /dev/null &
    local pid=$!
    ( sleep 30; kill -TERM "$pid" 2>/dev/null ) > /dev/null 2>&1 & local dog=$!
    wait "$pid" 2>/dev/null; kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
    awk -F= '{v[$1]=$2} END {printf "%s\t%s\t%s\t%s", v["codec_name"], v["width"], v["height"], v["duration"]}' "$out"
    rm -f "$out"
}

row() {   # row n label result secs rc jpeg_bytes jpeg reason
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$(clean "$7")" "$(clean "$8")" \
        "$size" "$probe" "$(clean "$f")" >> "$RESULTS"
}

n=0
while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    [ -e "$RUN_DIR/stop" ] && break
    n=$((n+1))
    size=""; probe=$'\t\t\t'
    if [ -L "$f" ]; then
        row "$n" "-" symlink 0 "" "" "" "source is a symbolic link, not previewed"
    elif [ ! -f "$f" ] || [ ! -r "$f" ]; then
        row "$n" "-" missing 0 "" "" "" "not found or not readable by $(id -un)"
    else
        size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null)
        [ -z "$PROBE" ] || probe="$(probe_file "${FFPROBES[0]}" "$f")"
        for i in "${!LABELS[@]}"; do
            label="${LABELS[$i]}"
            before=$( { wc -l < "$LOGF"; } 2>/dev/null || echo 0)
            start=$SECONDS
            out="$WORK/.out.$$"
            VID2MOS_FFMPEG="${FFMPEGS[$i]}" VID2MOS_FFPROBE="${FFPROBES[$i]}" "$SCRIPT" "$f" > "$out" 2>/dev/null < /dev/null &
            child=$!; wait "$child"; rc=$?; child=""
            secs=$((SECONDS - start))
            jpg="$(head -n 1 "$out")"; rm -f "$out"
            if [ $rc -eq 0 ] && [ -s "$jpg" ] && [ "$(head -c 2 "$jpg" | xxd -p)" = "ffd8" ]; then
                bytes=$(stat -f %z "$jpg" 2>/dev/null || stat -c %s "$jpg" 2>/dev/null)
                kept=""
                if [ -n "$KEEP" ]; then
                    kept="$JPEG_DIR/$n-$label-$(basename -- "${f%.*}").jpg"
                    mv -f "$jpg" "$kept" || kept=""
                else
                    rm -f "$jpg"
                fi
                row "$n" "$label" ok "$secs" "$rc" "$bytes" "$kept" ""
                [ "$MODE" = matrix ] || break
            else
                line=$(tail -n +"$((before + 1))" "$LOGF" 2>/dev/null | grep ' FAIL ' | tail -n 1)
                reason=$(printf '%s' "$line" | sed -e 's/.* FAIL ([0-9]*s) //' -e 's/ input=".*//')
                fflog=$(printf '%s' "$reason" | sed -n 's/.* see \(\/.*\.log\)$/\1/p')
                reason=$(printf '%s' "$reason" | sed 's/ see \/.*\.log$//')
                [ -n "$reason" ] || reason="no preview produced (rc=$rc)"
                [ -n "$fflog" ] && [ -f "$fflog" ] && mv -f "$fflog" "$RUN_DIR/ffmpeg/$n-$label.log"
                row "$n" "$label" fail "$secs" "$rc" "" "" "$reason"
                [ "$MODE" = script ] && break
            fi
        done
    fi
    done_n=$n
    printf 'running %d %d\n' "$done_n" "$total" > "$RUN_DIR/state"
done < "$LIST"

if [ -e "$RUN_DIR/stop" ]; then
    printf 'stopped %d %d\n' "$done_n" "$total" > "$RUN_DIR/state"
else
    printf 'done %d %d\n' "$done_n" "$total" > "$RUN_DIR/state"
fi
rm -f "$RUN_DIR/pid"
exit 0
