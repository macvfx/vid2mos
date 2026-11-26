#!/bin/bash
# size-survey.sh - list the video files under a folder with their sizes, and summarise them
# (count, total, min, max, mean, median, percentiles, size bands, per extension), so the preview
# timeout can be set from real numbers instead of a guess.
#
# Usage:
#   ./size-survey.sh <folder> [--report FILE] [--rate MBPS] [--timeout S] [--probe] [--ffprobe PATH]
#
#   <folder>     folder searched recursively (read-only; nothing is opened except with --probe)
#   --report     tab-separated report, one row per file (default: /tmp/vid2mos-sizes-<time>.tsv)
#   --rate       read speed to estimate with, MB/s (default 400: a busy 10GbE share; a quiet
#                one reaches 800-1000). The estimate is size / rate: the time just to read the file.
#   --timeout    the preview timeout to compare against, seconds (default 120, vid2mos's default)
#   --probe      also ask ffprobe for duration and codec of each file (reads headers only, 30 s
#                limit per file). Slower on a big folder; worth it on a sample.
#   --ffprobe    ffprobe to use with --probe (default /usr/local/aw/bin/ffprobe, P5's own)
#
# Why size matters: vid2mos builds its mosaic with ffmpeg's select+tile filter, which decodes every
# frame from the seek point to the end of the file. So a preview costs at least one full read of
# the file, and a file whose read alone takes longer than the timeout can never get a preview.
#
# Symbolic links are counted, not followed (vid2mos 1.2.1 refuses them). ._* files are skipped.

DIR=""; REPORT="/tmp/vid2mos-sizes-$(date +%Y%m%d-%H%M%S).tsv"; RATE=400; TIMEOUT=120; PROBE=""
FFPROBE="${AWPST_SRV_HOME:-/usr/local/aw}/bin/ffprobe"
while [ $# -gt 0 ]; do
    case "$1" in
        --report)  REPORT="$2"; shift 2;;
        --rate)    RATE="$2"; shift 2;;
        --timeout) TIMEOUT="$2"; shift 2;;
        --probe)   PROBE=1; shift;;
        --ffprobe) FFPROBE="$2"; shift 2;;
        -h|--help) sed -n '2,24p' "$0"; exit 0;;
        -*)        echo "unknown option: $1"; exit 2;;
        *)         DIR="$1"; shift;;
    esac
done
[ -d "$DIR" ] || { echo "usage: $0 <folder> [--report FILE] [--rate MBPS] [--timeout S] [--probe]"; exit 2; }
case "$RATE" in ''|*[!0-9]*) echo "--rate must be a whole number of MB/s"; exit 2;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout must be whole seconds"; exit 2;; esac
[ -z "$PROBE" ] || [ -x "$FFPROBE" ] || { echo "ffprobe not executable: $FFPROBE"; exit 2; }

EXT='mov|mp4|m4v|mxf|mkv|avi|mts|m2ts|ts|mpg|mpeg|wmv|webm|r3d|braw'
match() { find "$DIR" "$@" \( -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mxf' \
    -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mts' -o -iname '*.m2ts' -o -iname '*.ts' \
    -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.wmv' -o -iname '*.webm' -o -iname '*.r3d' \
    -o -iname '*.braw' \) ! -name '._*' 2>/dev/null; }

# probe_one <file> -> "duration<TAB>codec<TAB>width<TAB>height", 30 s limit
probe_one() {
    local out; out="$(mktemp /tmp/vid2mos-survey.XXXXXX)"
    "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name,width,height:format=duration \
        -of default=noprint_wrappers=1 "$1" > "$out" 2>/dev/null < /dev/null &
    local pid=$!
    ( sleep 30; kill -TERM "$pid" 2>/dev/null ) > /dev/null 2>&1 & local dog=$!
    wait "$pid" 2>/dev/null; kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
    awk -F= '{v[$1]=$2} END {printf "%s\t%s\t%s\t%s", v["duration"], v["codec_name"], v["width"], v["height"]}' "$out"
    rm -f "$out"
}

echo "Folder  : $DIR"
echo "Report  : $REPORT"
echo "Estimate: read at $RATE MB/s, compared with a ${TIMEOUT}s timeout"
echo

printf 'size_bytes\tsize_gb\tread_secs\text\tin_fcp_library\tduration\tcodec\twidth\theight\tpath\n' > "$REPORT"
n=0
while IFS= read -r f; do
    n=$((n+1))
    size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f" 2>/dev/null || echo 0)
    ext="${f##*.}"; ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    case "$f" in *.fcpbundle/*|*.FCPBUNDLE/*) lib=yes;; *) lib=no;; esac
    probe=$'\t\t\t'
    [ -z "$PROBE" ] || probe="$(probe_one "$f")"
    awk -v s="$size" -v r="$RATE" -v e="$ext" -v l="$lib" -v p="$probe" -v f="$f" 'BEGIN {
        printf "%d\t%.2f\t%d\t%s\t%s\t%s\t%s\n", s, s / 1e9, s / (r * 1e6), e, l, p, f }' >> "$REPORT"
    [ $((n % 200)) -eq 0 ] && echo "  $n files…"
done < <(match -type f | sort)
links=$(match -type l | wc -l | tr -d ' ')

awk -F'\t' -v rate="$RATE" -v timeout="$TIMEOUT" -v links="$links" -v probe="$PROBE" '
function human(b) {
    if (b >= 1e12) return sprintf("%.2f TB", b / 1e12)
    if (b >= 1e9)  return sprintf("%.1f GB", b / 1e9)
    if (b >= 1e6)  return sprintf("%.0f MB", b / 1e6)
    return sprintf("%.0f KB", b / 1e3)
}
function hms(s) { s = int(s + 0.5); return s >= 3600 ? sprintf("%dh%02dm", s / 3600, (s % 3600) / 60) : (s >= 60 ? sprintf("%dm%02ds", s / 60, s % 60) : s "s") }
function pct(p,   i) { i = int((n - 1) * p + 0.5) + 1; return size[i] }
{ n++; size[n] = $1 + 0; total += $1; byext[$4]++; extbytes[$4] += $1
  if ($5 == "yes") lib++
  if ($1 < 1e9) band[1]++; else if ($1 < 1e10) band[2]++; else if ($1 < 1e11) band[3]++; else if ($1 < 1e12) band[4]++; else band[5]++
  if ($3 + 0 > timeout) over++
}
END {
    print "------------------------------------------------------------"
    if (n == 0) { print "No video files found."; print "Symbolic links  : " links; exit }
    printf "Video files     : %d (%s in all)\n", n, human(total)
    printf "Symbolic links  : %d (not counted above; vid2mos 1.2.1 skips them)\n", links
    printf "Inside .fcpbundle: %d\n", lib
    printf "Smallest        : %s\n", human(size[1])
    printf "Median          : %s\n", human(pct(0.5))
    printf "Mean            : %s\n", human(total / n)
    printf "90th percentile : %s\n", human(pct(0.9))
    printf "95th percentile : %s\n", human(pct(0.95))
    printf "99th percentile : %s\n", human(pct(0.99))
    printf "Largest         : %s\n", human(size[n])
    print ""
    print "Size bands"
    split("under 1 GB|1-10 GB|10-100 GB|100 GB-1 TB|1 TB and over", names, "|")
    for (b = 1; b <= 5; b++) printf "  %-14s %d\n", names[b], band[b]
    print ""
    print "By extension"
    for (e in byext) printf "  %-6s %6d files  %s\n", e, byext[e], human(extbytes[e])
    print ""
    printf "Read time at %d MB/s (the least a preview can take; decoding adds to it)\n", rate
    printf "  median %s, 95th percentile %s, largest %s\n", hms(pct(0.5) / (rate * 1e6)), hms(pct(0.95) / (rate * 1e6)), hms(size[n] / (rate * 1e6))
    printf "  %d file(s) take longer than the %ds timeout just to read\n", over, timeout
    printf "  a timeout covering 95%% of files: about %s; all files: about %s (read only, x2 for decoding is safer)\n", hms(pct(0.95) / (rate * 1e6)), hms(size[n] / (rate * 1e6))
}' < <(tail -n +2 "$REPORT" | sort -t$'\t' -k1,1n)
if [ -n "$PROBE" ]; then
    cut -f6 "$REPORT" | tail -n +2 | grep -E '^[0-9.]+$' | sort -n | awk '
    function hms(s) { s = int(s + 0.5); return s >= 3600 ? sprintf("%dh%02dm", s / 3600, (s % 3600) / 60) : (s >= 60 ? sprintf("%dm%02ds", s / 60, s % 60) : s "s") }
    { d[++n] = $1; t += $1 }
    END { if (n) { print ""; printf "Duration (%d probed): shortest %s, median %s, longest %s, total %s\n", n, hms(d[1]), hms(d[int((n + 1) / 2)]), hms(d[n]), hms(t) } }'
fi
echo "Report          : $REPORT"
