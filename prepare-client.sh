#!/bin/bash
# prepare-client.sh - get one Mac ready to generate P5 previews with vid2mos-hardened.sh
# and to be watched by P5 Preview Monitor. Run it ON the client (or the server).
#
#   sudo ./prepare-client.sh                 install and self-test
#   ./prepare-client.sh --check              change nothing, report only
#   sudo ./prepare-client.sh --source /Volumes/Media/clip.mov     also test a source path
#
# It installs vid2mos-hardened.sh (the copy beside this file) to /Library/Scripts, owned by
# root, mode 755, without quarantine flags, then runs the script's own --selftest.
# It never edits P5's settings, never turns on Remote Login and never touches SSH keys:
# those are printed as next steps for you to do.
#
# Options:
#   --check            report only, change nothing
#   --dest PATH        install somewhere else (default /Library/Scripts/vid2mos-hardened.sh)
#   --source PATH      a file the preview job will read; checked as the installing user
#   --bin-dir DIR      folder with ffmpeg + ffprobe (default /usr/local/aw/bin)
#   -h, --help
#
# Exit status: 0 ready, 1 something needs fixing, 2 bad usage.

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/vid2mos-hardened.sh"
DEST="/Library/Scripts/vid2mos-hardened.sh"
BIN_DIR="${VID2MOS_BIN_DIR:-/usr/local/aw/bin}"
CHECK=""
SOURCE_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check)   CHECK=1; shift;;
        --dest)    DEST="$2"; shift 2;;
        --source)  SOURCE_PATH="$2"; shift 2;;
        --bin-dir) BIN_DIR="$2"; shift 2;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2;;
    esac
done

problems=0
ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  FIX   %s\n' "$1"; problems=$((problems+1)); }
note() { printf '        %s\n' "$1"; }

version_of() { /bin/bash "$1" --version 2>/dev/null | awk '{print $NF}'; }

echo "Preparing this Mac ($(hostname -s)) for P5 previews"
echo

echo "1. The script"
if [ ! -f "$SRC" ]; then
    warn "vid2mos-hardened.sh not found beside this file ($HERE)"
    exit 1
fi
src_ver="$(version_of "$SRC")"
[ -n "$src_ver" ] && ok "source script is version $src_ver" || { warn "the source script does not answer --version"; exit 1; }

# --check reports what is out of date as FIX. A normal run says what it is about to replace
# and FIX appears only if that replacement fails.
NEED_INSTALL=""
dest_ver=""
if [ -f "$DEST" ]; then
    dest_ver="$(version_of "$DEST")"
    if cmp -s "$SRC" "$DEST"; then
        ok "installed copy at $DEST is current ($dest_ver)"
    else
        NEED_INSTALL=1
        if [ -n "$CHECK" ]; then
            warn "installed copy at $DEST is ${dest_ver:-unknown}, not the version here ($src_ver)"
        elif [ "$dest_ver" = "$src_ver" ]; then
            note "installed copy at $DEST is $dest_ver but differs from the copy here: replacing it"
        else
            note "replacing installed copy at $DEST (${dest_ver:-unknown version}) with $src_ver"
        fi
    fi
else
    NEED_INSTALL=1
    if [ -n "$CHECK" ]; then warn "not installed at $DEST"
    else note "not installed at $DEST yet: installing $src_ver"; fi
fi

if [ -n "$NEED_INSTALL" ] && [ -z "$CHECK" ]; then
    dest_dir="$(dirname "$DEST")"
    mkdir -p "$dest_dir" 2>/dev/null
    if [ -f "$DEST" ]; then cp -p "$DEST" "$DEST.previous" 2>/dev/null; fi
    if cp "$SRC" "$DEST" 2>/dev/null && chmod 755 "$DEST" 2>/dev/null; then
        xattr -c "$DEST" 2>/dev/null
        [ "$(id -u)" -eq 0 ] && chown root:wheel "$DEST" 2>/dev/null
        ok "installed $DEST (version $(version_of "$DEST"))"
        [ -f "$DEST.previous" ] && note "the previous copy is kept as $DEST.previous"
    else
        warn "could not write $DEST: run this with sudo"
    fi
fi
[ "$(id -u)" -eq 0 ] || [ -n "$CHECK" ] || note "(not running as root: fine for a test, but P5 runs the script as root)"

echo
echo "2. ffmpeg and ffprobe"
for tool in ffmpeg ffprobe; do
    if [ -x "$BIN_DIR/$tool" ]; then ok "$BIN_DIR/$tool"
    else warn "$BIN_DIR/$tool is missing (P5 installs these; use --bin-dir for another location)"; fi
done

echo
echo "3. Self-test of the installed script"
target="$DEST"; [ -f "$target" ] || target="$SRC"
st_args=(--selftest); [ -n "$SOURCE_PATH" ] && st_args+=("$SOURCE_PATH")
st_out="$(VID2MOS_BIN_DIR="$BIN_DIR" /bin/bash "$target" "${st_args[@]}" 2>&1)"
echo "$st_out" | sed 's/^/        /'
if printf '%s\n' "$st_out" | grep -q '^result=PASS$'; then ok "self-test passed"
else warn "self-test failed (see the FAIL lines above)"; fi

echo
echo "4. Remote Login (SSH), for P5 Preview Monitor"
if [ "$(id -u)" -eq 0 ]; then
    state="$(systemsetup -getremotelogin 2>/dev/null | tr 'A-Z' 'a-z')"
    case "$state" in
        *": on"*)  ok "Remote Login is on";;
        *": off"*) warn "Remote Login is off. Turn it on in System Settings > General > Sharing, or: sudo systemsetup -setremotelogin on";;
        *)         note "could not read Remote Login state";;
    esac
else
    note "run with sudo to check Remote Login, or look in System Settings > General > Sharing"
fi

echo
if [ "$problems" -le 0 ]; then
    echo "Ready."
    echo
    echo "Next, by hand:"
    echo "  - In P5, set the preview script to: $DEST"
    echo "  - On the P5 server, enable this machine for preview (proxy) generation, if it is a client."
    echo "  - From the Mac running P5 Preview Monitor, set up key login to this machine:"
    echo "      ssh-copy-id USER@$(hostname -s)     then     ssh -o BatchMode=yes USER@$(hostname -s) hostname"
    exit 0
fi
echo "$problems thing(s) need fixing (marked FIX above)."
exit 1
