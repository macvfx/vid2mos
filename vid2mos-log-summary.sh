#!/bin/bash
# vid2mos-log-summary.sh - read the vid2mos-hardened log and show which runs succeeded.
#
# Usage:
#   ./vid2mos-log-summary.sh [LOGFILE|FOLDER ...] [--since "YYYY-MM-DD HH:MM[:SS]"] [--last N]
#
#   LOGFILE   one or more log files or folders. Default: every vid2mos*.log in /var/log and /tmp
#             (the daily files vid2mos-YYYY-MM-DD.log plus any older single vid2mos.log)
#   --since   only lines at or after this local time (timestamps sort as text)
#   --last    how many of the most recent failures / unfinished runs to list (default 10)
#
# Output: totals per host, a per-minute table (so one archive job stands out), runs that
# STARTED but never reported OK or FAIL (hung or killed), and the latest failures.

FILES=(); SINCE=""; LAST=10
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="$2"; shift 2;;
        --last)  LAST="$2"; shift 2;;
        -h|--help) sed -n '2,12p' "$0"; exit 0;;
        -*) echo "unknown option: $1"; exit 2;;
        *)  FILES+=("$1"); shift;;
    esac
done
LIST=()
if [ ${#FILES[@]} -eq 0 ]; then
    for f in /var/log/vid2mos*.log /tmp/vid2mos*.log; do [ -f "$f" ] && LIST+=("$f"); done
else
    for a in "${FILES[@]}"; do
        if [ -d "$a" ]; then for f in "$a"/vid2mos*.log; do [ -f "$f" ] && LIST+=("$f"); done
        elif [ -f "$a" ]; then LIST+=("$a")
        else echo "not found: $a"; exit 2; fi
    done
fi
[ ${#LIST[@]} -gt 0 ] || { echo "no vid2mos logs found"; exit 2; }
for f in "${LIST[@]}"; do [ -r "$f" ] || { echo "cannot read $f (try sudo)"; exit 2; }; done

echo "Logs  : ${#LIST[@]} file(s), $(basename "${LIST[0]}") ... $(basename "${LIST[${#LIST[@]}-1]}")"
[ -n "$SINCE" ] && echo "Since : $SINCE"
echo

# Lines look like: 2026-11-22 15:54:42 -0700 host=H user=U pid=N <START|OK|FAIL|retry ...> ...
awk -v since="$SINCE" -v last="$LAST" '
function field(name,   i, a) { for (i = 1; i <= NF; i++) if (index($i, name "=") == 1) { return substr($i, length(name) + 2) } return "" }
{
    ts = substr($0, 1, 19)
    if (since != "" && ts < since) next
    if (field("mode") == "test") next    # test runs (script --test, batch-vid2mos.sh) are not P5 runs
    host = field("host"); pid = field("pid"); key = host ":" pid
    minute = substr($0, 1, 16)

    if ($0 ~ / START /) {
        # pids are reused over days: a START whose key is still open never finished
        if ((key in started) && !(key in done)) lost[++nl] = started[key]
        delete done[key]; started[key] = $0; next
    }
    if ($0 ~ / retry without seek /) { retries[host]++; next }
    if ($0 ~ / OK \(/)   { ok[host]++;   perminute[minute, "ok"]++;   minutes[minute] = 1; done[key] = 1; next }
    if ($0 ~ / FAIL \(/) {
        bad[host]++; perminute[minute, "bad"]++; minutes[minute] = 1; done[key] = 1
        if ($0 ~ /TIMED OUT/) timedout[host]++
        fails[++nf] = $0; next
    }
}
END {
    printf "%-20s %6s %6s %8s %9s\n", "Host", "OK", "FAIL", "retried", "timed out"
    for (h in ok) hosts[h] = 1
    for (h in bad) hosts[h] = 1
    for (h in hosts) printf "%-20s %6d %6d %8d %9d\n", h, ok[h], bad[h], retries[h], timedout[h]

    print ""
    print "Per minute (one archive job usually shows as a burst):"
    printf "%-17s %6s %6s\n", "Minute", "OK", "FAIL"
    nm = 0; for (m in minutes) ml[++nm] = m
    # simple insertion sort (few rows)
    for (i = 2; i <= nm; i++) { v = ml[i]; j = i - 1; while (j > 0 && ml[j] > v) { ml[j+1] = ml[j]; j-- } ml[j+1] = v }
    for (i = 1; i <= nm; i++) printf "%-17s %6d %6d\n", ml[i], perminute[ml[i], "ok"], perminute[ml[i], "bad"]

    print ""
    unf = 0
    for (i = 1; i <= nl; i++) unfinished[++unf] = lost[i]
    for (k in started) if (!(k in done)) unfinished[++unf] = started[k]
    # oldest first
    for (i = 2; i <= unf; i++) { v = unfinished[i]; j = i - 1; while (j > 0 && unfinished[j] > v) { unfinished[j+1] = unfinished[j]; j-- } unfinished[j+1] = v }
    printf "Started but never finished (hung, killed, or still running): %d\n", unf
    for (i = (unf > last ? unf - last + 1 : 1); i <= unf; i++) print "  " substr(unfinished[i], 1, 200)

    print ""
    printf "Latest failures (up to %d):\n", last
    for (i = (nf > last ? nf - last + 1 : 1); i <= nf; i++) print "  " substr(fails[i], 1, 220)
}' "${LIST[@]}"
