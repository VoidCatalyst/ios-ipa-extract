#!/usr/bin/env bash
#
# extract-ipa.sh — Pull an installed app off a jailbroken iOS device (over SSH)
#                  and package it as a .ipa file.
#
# Works over slow/flaky links: the app is tar'd on the device, then pulled in
# resumable fixed-size chunks with `dd` and verified with an md5 checksum.
#
# NOTE: the extracted binary is still App Store-encrypted (a raw container copy,
#       not a decrypted dump). For a decrypted IPA use a runtime dumper such as
#       frida-ios-dump or TrollDecrypt.
#
# Requirements (on the machine you run this FROM):
#   - ssh, scp            (openssh)
#   - zip
#   - python3             (to read app names from binary Info.plist files)
#   - sshpass             (only if you pass a password with -p / IPA_SSH_PASS)
#
# Usage:
#   ./extract-ipa.sh -l                         # list every installed app
#   ./extract-ipa.sh "JDVVNL Dashboard"         # find + extract by name
#   ./extract-ipa.sh -o ~/ipas "com.jdvvnl.utility"
#   IPA_SSH_PASS=alpine ./extract-ipa.sh -l
#
set -euo pipefail

# ---- configuration ----------------------------------------------------------
# Precedence (lowest to highest): built-in defaults -> config file -> env vars
# -> command-line flags. Each teammate can drop an extract-ipa.conf next to the
# script (or at ~/.config/extract-ipa.conf) with their own device details, e.g.
#     HOST=192.168.1.42
#     SSH_USER=mobile
#     PASS=alpine
#     JOBS=8
# so nobody has to edit this script.

# built-in defaults
HOST="192.168.1.54"
SSH_USER="mobile"
PASS=""
JOBS=4
OUTDIR="."
LIST_ONLY=0
APP_ROOT="/var/containers/Bundle/Application"
# Prefer hardware-accelerated ciphers (iOS has ARMv8 AES); fall back gracefully.
CIPHERS="aes128-gcm@openssh.com,aes128-ctr,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com"

# config file
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _cf in "$_SELF_DIR/extract-ipa.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/extract-ipa.conf" "$HOME/.extract-ipa.conf"; do
  if [[ -f "$_cf" ]]; then # shellcheck disable=SC1090
    source "$_cf"; break
  fi
done

# environment overrides
HOST="${IPA_SSH_HOST:-$HOST}"
SSH_USER="${IPA_SSH_USER:-$SSH_USER}"
PASS="${IPA_SSH_PASS:-$PASS}"

usage() {
  cat <<EOF
extract-ipa.sh — extract an app from a jailbroken iOS device as a .ipa

Usage: $0 [options] [app-name-or-bundleid-query]

Options:
  -H host   Device IP / hostname        (default: $HOST, or \$IPA_SSH_HOST)
  -u user   SSH user                    (default: $SSH_USER, or \$IPA_SSH_USER)
  -p pass   SSH password                (or \$IPA_SSH_PASS; omit for key auth)
  -o dir    Output directory            (default: current directory)
  -j N      Parallel download streams   (default: $JOBS; 1 = single stream)
  -l        List installed apps and exit
  -h        Show this help

Faster transfers: the download is split across N parallel SSH connections so
the device can use multiple CPU cores for encryption. Use -j to tune (try
-j 6 or -j 8 on a fast link; -j 1 for a single stream). A password (-p) or an
SSH key is required for -j > 1 so the extra connections don't prompt.

Examples:
  $0 -l
  $0 -p kali "JDVVNL Dashboard"
  $0 -p kali -j 8 -o ~/ipas Dashboard
EOF
}

while getopts "H:u:p:o:j:c:lh" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    p) PASS="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    c) : ;;  # deprecated (chunk size); kept for backward compatibility
    l) LIST_ONLY=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
QUERY="${*:-}"

# ---- prerequisite checks ----------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed." >&2; exit 1; }; }
need ssh; need zip; need python3
if [[ -n "$PASS" ]]; then need sshpass; fi

# portable file size
fsize() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }

WORK="$(mktemp -d)"
CTL="$WORK/cm.sock"
cleanup() {
  # tear down the shared SSH master connection, then remove temp files
  ssh -o ControlPath="$CTL" -O exit "$SSH_USER@$HOST" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---- ssh wrappers -----------------------------------------------------------
# Control commands reuse ONE multiplexed master connection (single auth, no
# repeated prompts). Parallel download workers each open their OWN connection so
# the device can encrypt multiple streams on multiple CPU cores at once.
BASE_OPTS=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=10 -o LogLevel=ERROR -o Ciphers="$CIPHERS")
SSH_OPTS=("${BASE_OPTS[@]}" -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=120)
if [[ -n "$PASS" ]]; then
  SSH=(sshpass -p "$PASS" ssh "${SSH_OPTS[@]}")
  WSSH=(sshpass -p "$PASS" ssh "${BASE_OPTS[@]}")   # independent worker connection
else
  SSH=(ssh "${SSH_OPTS[@]}")
  WSSH=(ssh "${BASE_OPTS[@]}")
fi
run()  { "${SSH[@]}"  "$SSH_USER@$HOST" "$@"; }
wrun() { "${WSSH[@]}" "$SSH_USER@$HOST" "$@"; }

echo ">> Connecting to $SSH_USER@$HOST ..." >&2
# First call establishes the shared master connection (single auth prompt).
run 'echo ok >/dev/null' || { echo "error: cannot SSH to $SSH_USER@$HOST" >&2; exit 1; }

# ---- discover installed apps ------------------------------------------------
# The device has no plist tooling, so we stream every app's Info.plist here and
# parse the binary plists locally with python3.
echo ">> Reading installed app list ..." >&2
run "cd '$APP_ROOT' && tar cf - */*.app/Info.plist 2>/dev/null" > "$WORK/info.tar"
mkdir -p "$WORK/pl"
tar xf "$WORK/info.tar" -C "$WORK/pl" 2>/dev/null || true

# index.tsv columns:  display \t bundleid \t version \t container_uuid \t app_folder
python3 - "$WORK/pl" > "$WORK/index.tsv" <<'PY'
import sys, os, glob, plistlib
root = sys.argv[1]
rows = []
for f in glob.glob(os.path.join(root, "*", "*.app", "Info.plist")):
    try:
        d = plistlib.load(open(f, "rb"))
    except Exception:
        continue
    parts = f.split(os.sep)
    folder = parts[-2]          # e.g. Runner.app
    uuid   = parts[-3]          # container UUID
    disp = d.get("CFBundleDisplayName") or d.get("CFBundleName") or folder[:-4]
    bid  = d.get("CFBundleIdentifier", "")
    ver  = "%s (%s)" % (d.get("CFBundleShortVersionString", "?"),
                        d.get("CFBundleVersion", "?"))
    rows.append((disp, bid, ver, uuid, folder))
for r in sorted(rows, key=lambda x: x[0].lower()):
    print("\t".join(r))
PY

APP_COUNT=$(wc -l < "$WORK/index.tsv" | tr -d ' ')
if [[ "$APP_COUNT" -eq 0 ]]; then
  echo "error: no apps found (check the SSH user can read $APP_ROOT)." >&2
  exit 1
fi

if [[ "$LIST_ONLY" -eq 1 ]]; then
  printf '%-32s %-40s %s\n' "APP" "BUNDLE ID" "VERSION"
  printf '%-32s %-40s %s\n' "$(printf '%.0s-' {1..32})" "$(printf '%.0s-' {1..40})" "-------"
  while IFS=$'\t' read -r disp bid ver uuid folder; do
    printf '%-32.32s %-40.40s %s\n' "$disp" "$bid" "$ver"
  done < "$WORK/index.tsv"
  echo "" >&2
  echo "$APP_COUNT apps. Re-run with an app name or bundle id to extract one." >&2
  exit 0
fi

if [[ -z "$QUERY" ]]; then
  echo "error: no app specified. Use -l to list apps, or pass a name/bundle id." >&2
  usage
  exit 1
fi

# ---- match the query --------------------------------------------------------
MATCHES="$(grep -i -- "$QUERY" "$WORK/index.tsv" || true)"
NMATCH=$(printf '%s' "$MATCHES" | grep -c . || true)

if [[ "$NMATCH" -eq 0 ]]; then
  echo "error: no app matches '$QUERY'. Try -l to see all apps." >&2
  exit 1
elif [[ "$NMATCH" -gt 1 ]]; then
  echo "error: '$QUERY' matches $NMATCH apps — be more specific:" >&2
  echo "$MATCHES" | while IFS=$'\t' read -r disp bid ver uuid folder; do
    printf '   %-30s %s\n' "$disp" "$bid" >&2
  done
  exit 1
fi

IFS=$'\t' read -r DISP BID VER UUID FOLDER <<< "$MATCHES"
REMOTE_APP="$APP_ROOT/$UUID/$FOLDER"
echo ">> Match: $DISP  [$BID]  v$VER" >&2
echo ">> Path : $REMOTE_APP" >&2

# ---- stage a tar on the device ---------------------------------------------
REMOTE_TAR="/tmp/_ipaextract_$$.tar"
echo ">> Packaging on device ..." >&2
run "cd '$APP_ROOT/$UUID' && tar cf '$REMOTE_TAR' '$FOLDER'"
TOTAL=$(run "wc -c < '$REMOTE_TAR'" | tr -d ' ')
RMD5=$(run "md5sum '$REMOTE_TAR' 2>/dev/null | cut -d' ' -f1 || md5 -q '$REMOTE_TAR'")
echo ">> Size: $TOTAL bytes (md5 $RMD5)" >&2

# ---- download ---------------------------------------------------------------
LOCAL_TAR="$WORK/app.tar"

human_rate() { # bytes seconds -> "x.x MB/s"
  awk -v b="$1" -v s="$2" 'BEGIN{ if(s<=0)s=1; printf "%.1f MB/s", b/s/1048576 }'
}

# Single resumable stream (used for -j 1 and flaky links).
download_single() {
  : > "$LOCAL_TAR"
  local have aligned now start el STALL=0
  while :; do
    have=$(fsize "$LOCAL_TAR")
    aligned=$(( (have / 1048576) * 1048576 ))
    if (( aligned != have && have < TOTAL )); then truncate -s "$aligned" "$LOCAL_TAR"; have=$aligned; fi
    (( have >= TOTAL )) && break
    ( start=$(date +%s)
      while :; do
        now=$(fsize "$LOCAL_TAR"); el=$(( $(date +%s) - start ))
        printf '\r   %d / %d bytes (%d%%)  %s   ' "$now" "$TOTAL" "$(( now*100/TOTAL ))" "$(human_rate $((now-have)) $el)" >&2
        sleep 1
      done ) & local poller=$!
    run "dd if='$REMOTE_TAR' bs=1048576 skip=$(( have/1048576 )) 2>/dev/null" >> "$LOCAL_TAR" || true
    kill "$poller" 2>/dev/null || true; wait "$poller" 2>/dev/null || true
    now=$(fsize "$LOCAL_TAR")
    if (( now == have )); then
      STALL=$((STALL+1)); (( STALL >= 5 )) && { echo ""; echo "error: transfer stalled." >&2; exit 1; }
      echo "   ...no progress, retrying in 2s" >&2; sleep 2
    else STALL=0; fi
  done
  printf '\r   %d / %d bytes (100%%)                    \n' "$TOTAL" "$TOTAL" >&2
}

# Parallel download: split the file into MB-aligned ranges pulled over separate
# SSH connections at once, so the device encrypts on multiple CPU cores.
download_parallel() {
  local jobs=$1
  local total_mb=$(( (TOTAL + 1048575) / 1048576 ))
  local part_mb=$(( (total_mb + jobs - 1) / jobs ))
  local nworkers=$(( (total_mb + part_mb - 1) / part_mb ))
  local partdir="$WORK/parts"; rm -rf "$partdir"; mkdir -p "$partdir"
  echo "   ($nworkers streams x ${part_mb}MB)" >&2

  want_size() { local off=$(( $1 * part_mb * 1048576 )) cap=$(( part_mb*1048576 )) rem=$(( TOTAL - $1*part_mb*1048576 ))
                (( rem < 0 )) && rem=0; (( rem < cap )) && echo "$rem" || echo "$cap"; }

  ( start=$(date +%s)
    while :; do
      local now=0 s
      for ((i=0;i<nworkers;i++)); do s=$(fsize "$partdir/p$i" 2>/dev/null || echo 0); now=$((now+s)); done
      local el=$(( $(date +%s) - start ))
      printf '\r   %d / %d bytes (%d%%)  %s   ' "$now" "$TOTAL" "$(( now*100/TOTAL ))" "$(human_rate "$now" "$el")" >&2
      sleep 1
    done ) & local poller=$!

  local attempt pids i want have p
  for attempt in 1 2 3 4 5; do
    pids=(); local need=0
    for ((i=0;i<nworkers;i++)); do
      want=$(want_size "$i"); have=$(fsize "$partdir/p$i" 2>/dev/null || echo 0)
      (( have == want )) && continue
      need=1; : > "$partdir/p$i"
      wrun "dd if='$REMOTE_TAR' bs=1048576 skip=$(( i*part_mb )) count=$part_mb 2>/dev/null" > "$partdir/p$i" &
      pids+=($!)
    done
    (( need == 0 )) && break
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
    (( attempt < 5 )) && sleep 1
  done

  kill "$poller" 2>/dev/null || true; wait "$poller" 2>/dev/null || true

  : > "$LOCAL_TAR"
  for ((i=0;i<nworkers;i++)); do
    want=$(want_size "$i"); have=$(fsize "$partdir/p$i" 2>/dev/null || echo 0)
    (( have != want )) && { echo ""; echo "error: stream $i incomplete ($have/$want bytes)." >&2; exit 1; }
    cat "$partdir/p$i" >> "$LOCAL_TAR"
  done
  printf '\r   %d / %d bytes (100%%)                    \n' "$TOTAL" "$TOTAL" >&2
}

echo ">> Downloading ..." >&2
if (( JOBS <= 1 )); then download_single; else download_parallel "$JOBS"; fi

# ---- verify -----------------------------------------------------------------
LMD5=$(md5sum "$LOCAL_TAR" 2>/dev/null | cut -d' ' -f1 || md5 -q "$LOCAL_TAR")
run "rm -f '$REMOTE_TAR'" || true
if [[ "$RMD5" != "$LMD5" ]]; then
  echo "error: checksum mismatch (device $RMD5 != local $LMD5)." >&2
  exit 1
fi
echo ">> Checksum OK." >&2

# ---- package the .ipa -------------------------------------------------------
rm -rf "$WORK/Payload"; mkdir "$WORK/Payload"
tar xf "$LOCAL_TAR" -C "$WORK/Payload"

mkdir -p "$OUTDIR"
SAFE_NAME="$(echo "$DISP" | tr -cd '[:alnum:]._ -' | tr ' ' '_')"
[[ -z "$SAFE_NAME" ]] && SAFE_NAME="app"
OUT="$OUTDIR/${SAFE_NAME}.ipa"
( cd "$WORK" && zip -qr9 out.zip Payload )
mv "$WORK/out.zip" "$OUT"

echo ""
echo "Done: $OUT"
echo "  app     : $DISP"
echo "  bundle  : $BID"
echo "  version : $VER"
echo "  size    : $(du -h "$OUT" | cut -f1)"
