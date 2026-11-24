#!/bin/bash
# batch-vid2mos.sh - run the hardened preview script over a folder of real media and
# report, per file, whether it produced a real JPEG; optionally compare with the original.
#
# Usage:
#   ./batch-vid2mos.sh <folder> [--original PATH] [--script PATH] [--report FILE] [--keep]
#
#   <folder>      folder searched recursively for video/still files
#   --original    path of the original vid2mos.sh; adds an "old" column for comparison
#   --script      script under test (default: vid2mos-hardened.sh beside this file)
#   --report      tab-separated report (default: /tmp/vid2mos-batch-<time>.tsv)
#   --keep        keep the generated JPGs (default: delete them after checking)
#
# Run it as root (sudo) to match how P5 runs the script. Nothing in the source folder
# is modified. Previews are written to a private temp folder, not to /tmp directly.

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/vid2mos-hardened.sh"
ORIGINAL=""
REPORT="/tmp/vid2mos-batch-$(date +%Y%m%d-%H%M%S).tsv"
KEEP=""
DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --original) ORIGINAL="$2"; shift 2;;
        --script)   SCRIPT="$2"; shift 2;;
        --report)   REPORT="$2"; shift 2;;
        --keep)     KEEP=1; shift;;
        -h|--help)  sed -n '2,15p' "$0"; exit 0;;
        -*)         echo "unknown option: $1"; exit 2;;
        *)          DIR="$1"; shift;;
    esac
done

[ -d "$DIR" ]    || { echo "usage: $0 <folder> [--original PATH] [--script PATH] [--report FILE] [--keep]"; exit 2; }
[ -x "$SCRIPT" ] || { echo "script not executable: $SCRIPT"; exit 2; }
[ -z "$ORIGINAL" ] || [ -x "$ORIGINAL" ] || { echo "original not executable: $ORIGINAL"; exit 2; }

OUT="$(mktemp -d /tmp/vid2mos-batch.XXXXXX)" || exit 2
if [ -n "$KEEP" ]; then
    echo "Previews kept in: $OUT"
else
    trap 'rm -rf "$OUT"' EXIT
fi
export VID2MOS_TMP="$OUT"
# Log: same daily-file default as the script itself (unless VID2MOS_LOG pins one file).
if [ -n "$VID2MOS_LOG" ]; then
    LOG="$VID2MOS_LOG"
else
    if [ -w /var/log ]; then LOG_DIR=/var/log; else LOG_DIR=/tmp; fi
    LOG="${VID2MOS_LOG_DIR:-$LOG_DIR}/vid2mos-$(date +%Y-%m-%d).log"
fi

is_jpeg() { [ -s "$1" ] && [ "$(head -c 2 "$1" | xxd -p)" = "ffd8" ]; }

printf 'file\tnew_rc\tnew_jpg\tnew_secs\told_jpg\tpath\n' > "$REPORT"

total=0; new_ok=0; new_bad=0; old_bad=0; rescued=0; slowest=0; slowest_name=""

while IFS= read -r f; do
    total=$((total+1))

    s=$SECONDS
    new=$("$SCRIPT" "$f" 2>/dev/null < /dev/null); rc=$?
    secs=$((SECONDS-s))
    if [ $rc -eq 0 ] && is_jpeg "$new"; then n_jpg=yes; new_ok=$((new_ok+1)); else n_jpg=NO; new_bad=$((new_bad+1)); fi
    [ "$secs" -gt "$slowest" ] && { slowest=$secs; slowest_name=$(basename "$f"); }

    o_jpg="-"
    if [ -n "$ORIGINAL" ]; then
        old=$(AWPST_SRV_HOME="${AWPST_SRV_HOME:-/usr/local/aw}" "$ORIGINAL" "$f" 2>/dev/null < /dev/null)
        if is_jpeg "$old"; then o_jpg=yes; else o_jpg=NO; old_bad=$((old_bad+1)); [ "$n_jpg" = yes ] && rescued=$((rescued+1)); fi
        [ -n "$old" ] && [ "$old" != "$new" ] && [ "$old" = "${old#"$OUT"}" ] && rm -f "$old"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(basename "$f")" "$rc" "$n_jpg" "$secs" "$o_jpg" "$f" >> "$REPORT"
    printf '%-4s %-3s %4ss  %s\n' "$n_jpg" "${o_jpg}" "$secs" "$(basename "$f")"
    [ -n "$KEEP" ] || rm -f "$new"
done < <(find "$DIR" -type f \( \
    -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mxf' -o -iname '*.mkv' \
    -o -iname '*.avi' -o -iname '*.mts' -o -iname '*.m2ts' -o -iname '*.ts' -o -iname '*.mpg' \
    -o -iname '*.mpeg' -o -iname '*.wmv' -o -iname '*.webm' -o -iname '*.r3d' -o -iname '*.braw' \
    -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.tif' -o -iname '*.tiff' \
    \) ! -name '._*' | sort)

echo
echo "------------------------------------------------------------"
echo "Files checked        : $total"
echo "New script  OK       : $new_ok"
echo "New script  FAILED   : $new_bad   (genuinely unreadable files are expected here)"
if [ -n "$ORIGINAL" ]; then
echo "Original    FAILED   : $old_bad   (printed a path or nothing, but no real JPEG)"
echo "Rescued by new script: $rescued   (original failed, new succeeded)"
fi
echo "Slowest file         : ${slowest}s  ${slowest_name}"
echo "Report               : $REPORT"
echo "Script log           : $LOG   (FAIL lines: $(grep -c ' FAIL ' "$LOG" 2>/dev/null || echo 0) total in the log)"

if [ "$new_bad" -gt 0 ]; then
    echo
    echo "Files the new script could not preview:"
    awk -F'\t' 'NR>1 && $3=="NO" {print "  " $6}' "$REPORT"
fi

[ "$new_bad" -eq 0 ]
