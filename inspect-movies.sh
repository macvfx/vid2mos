#!/bin/bash
# Survey listed movies, then optionally copy, decode, preview, and hash them.
# macOS /bin/bash 3.2 compatible. --skipcopy inspects originals read-only.
set -u
set -o pipefail
umask 077

usage() {
    cat <<'EOF'
Usage: inspect-movies.sh [--survey] [--skipcopy] FILE_LIST TEMP_LOCATION [VID2MOS_SCRIPT]

FILE_LIST: one absolute movie path per line, without shell quotes or escaping.
Blank lines are ignored; CRLF and an unterminated final line are supported.
TEMP_LOCATION: parent directory for a new, unique movie-inspection.XXXXXX run.
VID2MOS_SCRIPT: optional override; otherwise try /Library/Scripts/vid2mos-hardened.sh,
then vid2mos-hardened.sh beside this script.
--skipcopy (also --skip-copy): inspect source movies directly without copying.
--survey: quick survey and metadata only; no copies, SHA-256, decode, or previews.
Every run surveys ALL source files before starting intensive checks.
Options may appear before or after the positional arguments; -- ends options.

Each numbered movie directory contains reports/ and output/, plus input/ when copying.
summary.tsv records results; reports/commands.tsv records command exit codes.
survey.tsv records name, path, size, type, and basic check status for all entries.
The survey reads originals directly, even in copy mode. Quick metadata uses
ExifTool -fast2 (may omit deep tags) and bounded ffprobe discovery (5 MB / 5 s
analysis budget, not a wall-clock timeout). Metadata reads can still be slow.
Files are retained. Nothing is automatically deleted, including copied movies.
Survey tools: ffprobe, exiftool, file (on PATH).
Full inspection also requires ffmpeg and shasum.
Optional inspection tools: mediainfo, mdls, xattr.

DECODE_SECONDS=30 by default; set to 0 for a full video/audio decode check.
Progress is printed every PROGRESS_INTERVAL seconds (default 5). Copy progress
uses the destination's reported file size; allocated/sparse files can make this
approximate. Other steps show elapsed time, including the whole-file SHA-256 read.
Ctrl-C stops active commands and retains the partial run for inspection.
Terminal output is colored automatically; redirected output is plain text.
Set NO_COLOR=1 to disable color. Reports always remain plain text.
--skipcopy still reads the whole source for SHA-256, and previews use the source.
Existing VID2MOS toolchain/timeout settings are honored. Preview logs and
images are redirected into this run; VID2MOS_MODE=test disables production
logging in versions that support it. Older versions may still use syslog.
Exit: 0 = all required checks passed, 1 = file/check/tool/preview failure,
      2 = invalid arguments or setup failure. Processing continues after file failures.
EOF
}
die() { printf 'Error: %s\n' "$*" >&2; exit 2; }
SKIPCOPY=0
SURVEY_ONLY=0
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --skipcopy|--skip-copy|-skipcopy) SKIPCOPY=1; shift;;
        --survey) SURVEY_ONLY=1; shift;;
        -h|--help) usage; exit 0;;
        --) shift; POSITIONAL+=("$@"); break;;
        -*) die "Unknown option: $1";;
        *) POSITIONAL+=("$1"); shift;;
    esac
done
[ "${#POSITIONAL[@]}" -ge 2 ] && [ "${#POSITIONAL[@]}" -le 3 ] || { usage >&2; exit 2; }
set -- "${POSITIONAL[@]}"
C_RESET='' C_ACTIVE='' C_OK='' C_WARN='' C_FAIL=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    C_RESET=$'\033[0m'; C_ACTIVE=$'\033[1;36m'; C_OK=$'\033[1;32m'
    C_WARN=$'\033[1;33m'; C_FAIL=$'\033[1;31m'
fi
status() {
    local color=$1; shift
    local format=$1; shift
    printf '%s' "$color"
    # Call sites supply literal printf formats; path values are separate arguments.
    # shellcheck disable=SC2059
    printf "$format" "$@"
    printf '%s' "$C_RESET"
}
LIST=$1
[ -f "$LIST" ] && [ -r "$LIST" ] || die "Cannot read list: $LIST"
DECODE_SECONDS=${DECODE_SECONDS:-30}
case "$DECODE_SECONDS" in ''|*[!0-9]*) die 'DECODE_SECONDS must be a nonnegative integer';; esac
PROGRESS_INTERVAL=${PROGRESS_INTERVAL:-5}
case "$PROGRESS_INTERVAL" in ''|*[!0-9]*) die 'PROGRESS_INTERVAL must be a positive integer';; esac
[ "$PROGRESS_INTERVAL" -gt 0 ] || die 'PROGRESS_INTERVAL must be a positive integer'
OS=$(uname -s)
HERE=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 2
SCRIPT=${3:-}
if [ -z "$SCRIPT" ]; then
    for candidate in /Library/Scripts/vid2mos-hardened.sh "$HERE/vid2mos-hardened.sh"; do
        if [ -f "$candidate" ] && [ -r "$candidate" ]; then SCRIPT=$candidate; break; fi
    done
fi
if [ -n "$SCRIPT" ] && [ "$SURVEY_ONLY" -eq 0 ]; then
    SCRIPT=$(cd -- "$(dirname -- "$SCRIPT")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$SCRIPT")") || exit 2
    [ -f "$SCRIPT" ] && [ -r "$SCRIPT" ] || die "Cannot read preview script: $SCRIPT"
fi
mkdir -p -- "$2" || die "Cannot create temporary location: $2"
TEMP_ROOT=$(cd -- "$2" && pwd -P) || exit 2
RUN=$(mktemp -d "$TEMP_ROOT/movie-inspection.XXXXXX") || die 'Cannot create run directory'
SUMMARY="$RUN/summary.tsv"
printf 'item\tresult\tsource_shell_quoted\n' > "$SUMMARY"
status "$C_ACTIVE" 'Results: %s\n' "$RUN"
if [ "$SURVEY_ONLY" -eq 1 ]; then
    status "$C_WARN" 'Survey only: no copies, hashes, decode checks, or previews.\n'
elif [ "$SKIPCOPY" -eq 1 ]; then
    status "$C_WARN" 'Copy disabled: inspecting source movies directly (SHA-256 still reads each whole file).\n'
fi
printf 'Output location: %s\n' "$TEMP_ROOT"
df -h "$TEMP_ROOT"
ACTIVE_PID=''
PROGRESS_PID=''
# Limit cancellation to descendants of this run, including converter children.
stop_tree() {
    local pid=$1 child
    for child in $(pgrep -P "$pid" 2>/dev/null); do stop_tree "$child"; done
    kill -TERM "$pid" 2>/dev/null || true
}
cancel() {
    trap '' INT TERM HUP
    [ -z "$PROGRESS_PID" ] || stop_tree "$PROGRESS_PID"
    [ -z "$ACTIVE_PID" ] || stop_tree "$ACTIVE_PID"
    printf 'cancelled\n' > "$RUN/state"
    status "$C_WARN" '\nCancelled. Partial files retained in: %s\n' "$RUN" >&2
    exit "$1"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM
trap 'cancel 129' HUP
printf 'running\n' > "$RUN/state"
record_environment() {
{
    printf 'Started: '; date
    printf 'Preview script: %s\nDecode seconds: %s (0 = full file)\n' "${SCRIPT:-MISSING}" "$DECODE_SECONDS"
    printf 'Skip copy: %s\n' "$SKIPCOPY"
    printf 'Survey only: %s\n' "$SURVEY_ONLY"
    uname -a
    for tool in ffprobe ffmpeg exiftool file shasum mediainfo mdls xattr; do
        printf '%s: ' "$tool"; command -v "$tool" || true
    done
    if [ -n "$SCRIPT" ] && [ "$SURVEY_ONLY" -eq 0 ]; then /bin/bash "$SCRIPT" --version; fi
    command -v ffmpeg >/dev/null && ffmpeg -version
    command -v ffprobe >/dev/null && ffprobe -version
    command -v exiftool >/dev/null && exiftool -ver
} > "$RUN/environment.txt" 2>&1 < /dev/null
}

file_bytes() {
    if [ "$OS" = Darwin ]; then stat -L -f %z "$1" 2>/dev/null
    else stat -L -c %s "$1" 2>/dev/null; fi
}

# Each command gets its own stdout, stderr, exact invocation, and exit code.
capture() {
    local label=$1 required=$2 rc started=$SECONDS expected=0
    shift 2
    status "$C_ACTIVE" '  %s: starting\n' "$label"
    if [ "$label" = copy ]; then
        expected=$(file_bytes "$source") || expected=0
        printf '    %s -> %s\n    Source size: %s bytes\n' "$source" "$COPY" "$expected"
    fi
    { printf '%q ' "$@"; printf '\n'; } > "$REPORTS/$label.command.txt"
    if command -v "$1" >/dev/null 2>&1; then
        "$@" > "$REPORTS/$label.stdout.txt" 2> "$REPORTS/$label.stderr.txt" < /dev/null &
        ACTIVE_PID=$!
        (
            while sleep "$PROGRESS_INTERVAL"; do
                kill -0 "$ACTIVE_PID" 2>/dev/null || break
                elapsed=$((SECONDS - started))
                if [ "$label" = copy ]; then
                    copied=$(file_bytes "$COPY") || copied=0
                    printf '%s' "$C_ACTIVE"
                    awk -v n="$copied" -v total="$expected" -v t="$elapsed" 'BEGIN {
                        pct = total > 0 ? 100*n/total : 0
                        printf "  copy: %.1f%%, %.0f / %.0f bytes (%.2f / %.2f GiB), %ds elapsed", pct, n, total, n/1073741824, total/1073741824, t
                        if (t > 0) printf ", %.1f MiB/s average", n/1048576/t
                        printf "\n"
                    }'
                    printf '%s' "$C_RESET"
                else
                    status "$C_ACTIVE" '  %s: still running, %ss elapsed\n' "$label" "$elapsed"
                fi
            done
        ) &
        PROGRESS_PID=$!
        wait "$ACTIVE_PID"; rc=$?
        stop_tree "$PROGRESS_PID"
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=''
        ACTIVE_PID=''
    else
        printf 'Tool unavailable: %s\n' "$1" > "$REPORTS/$label.stderr.txt"
        : > "$REPORTS/$label.stdout.txt"
        rc=127
    fi
    printf '%s\t%s\t%s\n' "$label" "$required" "$rc" >> "$REPORTS/commands.tsv"
    if [ "$rc" -eq 0 ]; then
        status "$C_OK" '  %s: done (%ss)\n' "$label" "$((SECONDS - started))"
    elif [ "$rc" -eq 127 ] && [ "$required" = no ]; then
        status "$C_WARN" '  %s: skipped (tool unavailable)\n' "$label"
    else
        status "$C_FAIL" '  %s: exit %s (%ss); see %s\n' "$label" "$rc" "$((SECONDS - started))" "$REPORTS/$label.stderr.txt"
    fi
    LAST_RC=$rc
    if [ "$required" = yes ] && [ "$rc" -ne 0 ]; then failed=1; fi
    return 0
}
# Freeze the list so every phase sees the same entries and item numbers.
LIST_SNAPSHOT="$RUN/files.txt"
total=0
while IFS= read -r source || [ -n "$source" ]; do
    source=${source%$'\r'}
    [ -n "$source" ] || continue
    printf '%s\n' "$source" >> "$LIST_SNAPSHOT"
    total=$((total + 1))
done < "$LIST"
[ "$total" -gt 0 ] || { printf 'empty\n' > "$RUN/state"; die 'No movie paths found'; }

set_item() {
    item=$(printf '%06d' "$n")
    WORK="$RUN/$item"
    REPORTS="$WORK/reports"
    OUTPUT="$WORK/output"
}
save_result() {
    result=OK
    [ "$failed" -eq 0 ] || result=FAIL
    printf '%s\n' "$result" > "$WORK/result"
    printf '%s\n' "$1" > "$WORK/phase"
}
refresh_summary() {
    local dir
    printf 'item\tresult\tphase\tsource_shell_quoted\n' > "$SUMMARY"
    for dir in "$RUN"/[0-9]*/; do
        [ -f "$dir/result" ] || continue
        printf '%s\t%s\t%s\t%q\n' "$(basename "$dir")" "$(cat "$dir/result")" \
            "$(cat "$dir/phase")" "$(cat "$dir/source-path.txt")" >> "$SUMMARY"
    done
}
# Display selected JSON field lines; the complete JSON remains in reports/.
show_fields() {
    local report=$1 pattern=$2
    [ -s "$report" ] || return 0
    awk -v pattern="$pattern" '$0 ~ pattern {sub(/^[[:space:]]*/, ""); print "    " $0}' "$report"
}

status "$C_ACTIVE" '\nQuick survey: %s listed files — name, path, size, type\n' "$total"
printf 'item\tname_shell_quoted\tsource_shell_quoted\tsize_bytes\tfile_type_shell_quoted\tresult\n' > "$RUN/survey.tsv"
n=0
while IFS= read -r source; do
    n=$((n + 1)); set_item
    mkdir -p "$REPORTS" "$OUTPUT" || die "Cannot create folders for $item"
    printf '%s\n' "$source" > "$WORK/source-path.txt"
    printf 'command\trequired\texit_code\n' > "$REPORTS/commands.tsv"
    failed=0; size=unknown; description=unavailable
    status "$C_ACTIVE" '\n[%s/%s] %s\n' "$n" "$total" "$(basename -- "$source")"
    printf '  Path: %s\n' "$source"
    case "$source" in
        /*) ;;
        *) printf 'Expected an absolute path\n' > "$REPORTS/input-error.txt"; failed=1;;
    esac
    if [ "$failed" -eq 0 ] && { [ ! -f "$source" ] || [ ! -r "$source" ]; }; then
        printf 'Not a readable regular file\n' > "$REPORTS/input-error.txt"
        failed=1
    fi
    if [ "$failed" -eq 0 ]; then
        size=$(file_bytes "$source") || { size=unknown; failed=1; }
        printf '  Size: %s bytes' "$size"
        if [ "$size" != unknown ]; then awk -v n="$size" 'BEGIN {printf " (%.2f GiB)", n/1073741824}'; fi
        printf '\n'
        capture file yes file -b "$source"
        description=$(cat "$REPORTS/file.stdout.txt")
        printf '  Type: %s\n' "${description:-unavailable}"
        capture file-mime no file -b --mime-type "$source"
        capture ls no ls -l "$source"
        if [ "$OS" = Darwin ]; then capture stat no stat -x "$source"
        else capture stat no stat "$source"; fi
    else
        status "$C_FAIL" '  FAIL: %s\n' "$(cat "$REPORTS/input-error.txt")"
    fi
    save_result basics
    printf '%s\t%q\t%q\t%s\t%q\t%s\n' "$item" "$(basename -- "$source")" "$source" "$size" "$description" "$result" >> "$RUN/survey.tsv"
done < "$LIST_SNAPSHOT"
refresh_summary
status "$C_OK" '\nBasic survey saved: %s\n' "$RUN/survey.tsv"
record_environment

status "$C_ACTIVE" '\nQuick metadata for all files (before intensive checks)\n'
n=0
while IFS= read -r source; do
    n=$((n + 1)); set_item
    [ ! -f "$REPORTS/input-error.txt" ] || continue
    failed=0; [ "$(cat "$WORK/result")" = OK ] || failed=1
    status "$C_ACTIVE" '\n[%s/%s] %s — metadata\n' "$n" "$total" "$(basename -- "$source")"
    capture exiftool yes exiftool -fast2 -json -G1 -a -s "$source"
    show_fields "$REPORTS/exiftool.stdout.txt" '"[^"]*(FileType|MIMEType|ImageWidth|ImageHeight|Duration|VideoFrameRate|CompressorName|AudioFormat)"[[:space:]]*:'
    capture ffprobe yes ffprobe -v error -probesize 5000000 -analyzeduration 5000000 \
        -show_format -show_streams -show_chapters -of json "$source"
    show_fields "$REPORTS/ffprobe.stdout.txt" '"(codec_name|codec_type|width|height|avg_frame_rate|duration|format_name)"[[:space:]]*:'
    save_result metadata
    if [ "$failed" -eq 0 ]; then status "$C_OK" '  Metadata: OK\n'
    else status "$C_FAIL" '  Metadata: FAIL; see %s\n' "$REPORTS"; fi
done < "$LIST_SNAPSHOT"
refresh_summary

if [ "$SURVEY_ONLY" -eq 0 ]; then
    status "$C_ACTIVE" '\nIntensive checks: copy (unless skipped), decode, preview, SHA-256\n'
    n=0
    while IFS= read -r source; do
        n=$((n + 1)); set_item
        [ ! -f "$REPORTS/input-error.txt" ] || continue
        failed=0; [ "$(cat "$WORK/result")" = OK ] || failed=1
        status "$C_ACTIVE" '\n[%s/%s] %s — intensive checks\n' "$n" "$total" "$(basename -- "$source")"
        if [ "$SKIPCOPY" -eq 1 ]; then
            INPUT_FILE=$source
            status "$C_WARN" '  copy: skipped (--skipcopy)\n'
            printf 'Copy skipped; inspecting source directly\n' > "$REPORTS/copy.stdout.txt"
            printf 'copy-skipped\tno\t0\n' >> "$REPORTS/commands.tsv"
            copy_ok=1
        else
            mkdir -p "$WORK/input" || die "Cannot create input folder for $item"
            COPY="$WORK/input/$(basename -- "$source")"
            INPUT_FILE=$COPY
            capture copy yes cp -pL -- "$source" "$COPY"
            copy_ok=0; [ "$LAST_RC" -ne 0 ] || copy_ok=1
        fi
        if [ "$copy_ok" -eq 1 ]; then
            decode_args=()
            if [ "$DECODE_SECONDS" -ne 0 ]; then decode_args=(-t "$DECODE_SECONDS"); fi
            capture ffmpeg-decode yes ffmpeg -nostdin -hide_banner -v warning -xerror \
                -i "$INPUT_FILE" ${decode_args[@]+"${decode_args[@]}"} -map '0:v?' -map '0:a?' -sn -dn -f null -
            if [ -n "$SCRIPT" ]; then
                capture vid2mos yes env VID2MOS_MODE=test VID2MOS_TMP="$OUTPUT" \
                    VID2MOS_LOG="$OUTPUT/vid2mos.log" VID2MOS_SHARED_DIR= \
                    /bin/bash "$SCRIPT" "$INPUT_FILE"
                preview=$(cat "$REPORTS/vid2mos.stdout.txt")
                case "$preview" in
                    "$OUTPUT/"*)
                        if [ ! -s "$preview" ]; then
                            printf 'Reported preview is missing or empty\n' > "$REPORTS/preview-error.txt"
                            failed=1
                        else capture preview-file yes file -b "$preview"; fi;;
                    *) printf 'No preview path inside output folder was returned\n' > "$REPORTS/preview-error.txt"; failed=1;;
                esac
            else
                printf 'vid2mos-hardened.sh not found; supply its path as argument 3\n' > "$REPORTS/preview-error.txt"
                failed=1
            fi
            capture sha256 yes shasum -a 256 "$INPUT_FILE"
            capture mediainfo no mediainfo --Output=JSON "$INPUT_FILE"
            capture mdls no mdls "$INPUT_FILE"
            capture xattr no xattr -l "$INPUT_FILE"
        fi
        save_result intensive
        refresh_summary
        if [ "$failed" -ne 0 ]; then status "$C_FAIL" '[%s] FAIL; see %s\n' "$item" "$REPORTS"
        else status "$C_OK" '[%s] OK\n' "$item"; fi
    done < "$LIST_SNAPSHOT"
fi
bad=0
for result_file in "$RUN"/[0-9]*/result; do
    [ "$(cat "$result_file")" = OK ] || bad=$((bad + 1))
done
printf 'done\n' > "$RUN/state"
if [ "$bad" -eq 0 ]; then color=$C_OK; else color=$C_FAIL; fi
status "$color" '\nProcessed: %s; failed: %s\nSurvey: %s\nSummary: %s\n' "$total" "$bad" "$RUN/survey.tsv" "$SUMMARY"
[ "$bad" -eq 0 ]
