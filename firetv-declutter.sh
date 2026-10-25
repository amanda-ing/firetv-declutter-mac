#!/bin/bash
# firetv-declutter (macOS)
# Reversibly debloats an Amazon Fire TV running Fire OS over Wi-Fi ADB, and
# optionally installs the Projectivy home screen. Every change is recorded so
# it can be undone with:  ./firetv-declutter.sh --restore
#
# Usage:
#   ./firetv-declutter.sh                 interactive run (recommended preset or customize)
#   ./firetv-declutter.sh --ip 192.168.1.50
#   ./firetv-declutter.sh --dry-run       show what would change, change nothing
#   ./firetv-declutter.sh --restore       undo everything this tool changed
#   ./firetv-declutter.sh --yes           accept the Recommended preset without questions
#
# Environment (mainly for testing): ADB=/path/to/adb  FIRETV_IP=...  ASSUME_DEFAULTS=1

set -u
VERSION="1.0.0"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1

CONF="$HERE/debloat.conf"
STATE_ROOT="$HERE/tvs"
PT_DIR="$HERE/platform-tools"
ADB_BIN="${ADB:-}"
MODE="run"; DRY=0; IP="${FIRETV_IP:-}"; YES="${ASSUME_DEFAULTS:-0}"
TV=""; STATE=""; LOG=""

PROJECTIVY_PKG="com.spocky.projengmenu"
PROJECTIVY_SVC_DEFAULT="com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService"
PROJECTIVY_API="${PROJECTIVY_API:-https://api.github.com/repos/spocky/miproja1/releases/latest}"
PROJECTIVY_URL_PREFIX="https://github.com/spocky/miproja1/releases/download/"

# Settings changed by the "privacy" and "speed" choices: namespace key value
PRIVACY_SETTINGS="secure limit_ad_tracking 1
secure amz_limit_ad_tracking 1
secure non_amz_limit_ad_tracking 1
secure advertisingIdApp:interestBasedAds:value 0
secure pact_usage_collection_enabled 0
secure setting.com.amazon.tv.acr.enabled 0"
SPEED_SETTINGS="global window_animation_scale 0.5
global transition_animation_scale 0.5
global animator_duration_scale 0.5"

# ---------- helpers ----------
say()  { echo "$*"; [ -n "$LOG" ] && echo "$*" >> "$LOG"; return 0; }
hr()   { say "------------------------------------------------------------"; }
die()  { say ""; say "STOPPED: $*"; pause_exit 1; }
pause_exit() { [ "$YES" = 1 ] || read -r -p "Press Enter to close. " _ < /dev/tty 2>/dev/null; exit "${1:-0}"; }

# ask "question" y|n  -> exit status 0 means yes
ask() {
  local q="$1" d="$2" a hint="[y/N]"
  [ "$d" = y ] && hint="[Y/n]"
  if [ -n "${FIRETV_ANSWERS:-}" ]; then   # test hook: space-separated scripted answers
    a="${FIRETV_ANSWERS%% *}"; FIRETV_ANSWERS="${FIRETV_ANSWERS#* }"; [ "$a" = "$FIRETV_ANSWERS" ] && FIRETV_ANSWERS=""
    [ "$a" = "-" ] && a="$d"; say "$q $hint -> $a"; case "$a" in [Yy]*) return 0;; *) return 1;; esac
  fi
  if [ "$YES" = 1 ]; then say "$q $hint -> $d (default)"; [ "$d" = y ]; return; fi
  read -r -p "$q $hint " a < /dev/tty || a=""
  a="${a:-$d}"
  [ -n "$LOG" ] && echo "$q $hint -> $a" >> "$LOG"
  case "$a" in [Yy]*) return 0;; *) return 1;; esac
}

# adb wrappers. </dev/null matters: adb reads stdin and would swallow loop input.
adbx()  { "$ADB_BIN" "$@" </dev/null; }
adbt()  { "$ADB_BIN" -s "$TV" "$@" </dev/null; }
tvsh()  { adbt shell "$@" 2>&1 | tr -d '\r'; }

# ---------- setup ----------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --ip) IP="${2:-}"; shift;;
      --dry-run) DRY=1;;
      --restore) MODE="restore";;
      --yes|-y) YES=1;;
      --version) echo "firetv-declutter $VERSION (macOS)"; exit 0;;
      -h|--help) sed -n '2,16p' "$0"; exit 0;;
      *) echo "Unknown option: $1"; exit 2;;
    esac
    shift
  done
}

ensure_adb() {
  if [ -n "$ADB_BIN" ] && [ -x "$ADB_BIN" ]; then return; fi
  if [ -x "$PT_DIR/adb" ]; then ADB_BIN="$PT_DIR/adb"; return; fi
  say "Downloading Google's official ADB tools (platform-tools)..."
  curl -fsSL -o "$HERE/platform-tools.zip" "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip" \
    || die "Could not download platform-tools. Check your internet connection."
  unzip -q -o "$HERE/platform-tools.zip" -d "$HERE" && rm -f "$HERE/platform-tools.zip"
  [ -x "$PT_DIR/adb" ] || die "platform-tools did not unpack as expected."
  ADB_BIN="$PT_DIR/adb"
}

my_ip() {
  local ifc ip
  for ifc in en0 en1 en2 en3 en4 en5 en6; do
    ip=$(ipconfig getifaddr "$ifc" 2>/dev/null) && [ -n "$ip" ] && { echo "$ip"; return; }
  done
  # Linux fallback (used for testing)
  hostname -I 2>/dev/null | awk '{print $1}'
}

scan_for_tvs() {
  local me prefix i tmp
  me=$(my_ip)
  [ -z "$me" ] && return
  prefix="${me%.*}"
  say "Scanning $prefix.1-254 for devices with ADB debugging on (about 10 seconds)..."
  tmp=$(mktemp)
  for i in $(seq 1 254); do
    ( nc -z -G 1 -w 1 "$prefix.$i" 5555 >/dev/null 2>&1 && echo "$prefix.$i" >> "$tmp" ) &
  done
  wait
  sort -t. -k4 -n -u "$tmp"; rm -f "$tmp"
}

pick_tv_ip() {
  if [ -n "$IP" ]; then return; fi
  if [ -f "$STATE_ROOT/last-ip.txt" ]; then
    IP=$(cat "$STATE_ROOT/last-ip.txt")
    say "Trying the TV used last time: $IP"
    adbx connect "$IP:5555" >/dev/null 2>&1
    if [ "$(adbx -s "$IP:5555" get-state 2>/dev/null)" = "device" ]; then return; fi
    IP=""
  fi
  local found n
  found=$(scan_for_tvs)
  n=$(printf '%s\n' "$found" | grep -c . || true)
  if [ "$n" = 1 ]; then IP="$found"; say "Found ADB on $IP"; return; fi
  if [ "$n" -gt 1 ]; then
    say "Found more than one device with ADB on:"; printf '%s\n' "$found" | nl -w2 -s') '
    local c; read -r -p "Which number is your Fire TV? " c < /dev/tty
    IP=$(printf '%s\n' "$found" | sed -n "${c}p")
  fi
  if [ -z "$IP" ]; then
    say "No Fire TV found automatically."
    say "If macOS asked to let Terminal find devices on your local network, choose Allow and run this again."
    read -r -p "Or type the TV's IP address (Settings > My Fire TV > About > Network): " IP < /dev/tty
  fi
  [ -n "$IP" ] || die "No TV IP address."
}

connect_tv() {
  TV="$IP:5555"
  say ""; say ">>> Look at the TV. If it asks 'Allow USB debugging?', tick 'Always allow from this computer' and choose OK."
  adbx connect "$TV" >/dev/null 2>&1
  local st="" t
  for t in $(seq 1 45); do
    st=$(adbx -s "$TV" get-state 2>/dev/null)
    [ "$st" = "device" ] && break
    sleep 2; adbx connect "$TV" >/dev/null 2>&1
  done
  [ "$st" = "device" ] || die "Could not connect to $TV. Check that ADB debugging is on (Settings > My Fire TV > Developer Options) and accept the prompt on the TV, then run again."
  mkdir -p "$STATE_ROOT"; echo "$IP" > "$STATE_ROOT/last-ip.txt"
}

check_device() {
  local name sdk model serial
  name=$(tvsh getprop ro.build.version.name)
  sdk=$(tvsh getprop ro.build.version.sdk)
  model=$(tvsh getprop ro.product.model)
  serial=$(tvsh getprop ro.serialno | tr -cd 'A-Za-z0-9_-')
  [ -z "$serial" ] && serial=$(echo "$IP" | tr '.' '-')
  STATE="$STATE_ROOT/$serial"
  mkdir -p "$STATE/changes" "$STATE/screens"
  LOG="$STATE/firetv-declutter.log"
  { echo; echo "===== $(date) $MODE (v$VERSION) ====="; } >> "$LOG"
  say "TV: $model | ${name:-unknown OS} | Android SDK ${sdk:-?}"
  case "$name" in
    *"Fire OS"*) ;;
    *) die "This doesn't look like Fire OS ('$name'). Vega OS and other systems are not supported.";;
  esac
  case "$name" in
    *"Fire OS 7"*) ;;
    *) say "Note: tested on Fire OS 7. Your version should work, but take extra care.";;
  esac
}

screenshot() { adbt exec-out screencap -p > "$STATE/screens/$1.png" 2>/dev/null && say "  screenshot: tvs/$(basename "$STATE")/screens/$1.png"; }

# ---------- backup ----------
backup() {
  local b="$STATE/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$b"
  say "Backing up the TV's current state to tvs/$(basename "$STATE")/$(basename "$b") ..."
  tvsh getprop                       > "$b/getprop.txt"
  tvsh pm list packages -f -U        > "$b/packages-all.txt"
  tvsh pm list packages -s           > "$b/packages-system.txt"
  tvsh pm list packages -3           > "$b/packages-user-installed.txt"
  tvsh pm list packages -d           > "$b/packages-disabled.txt"
  tvsh pm list packages -e           > "$b/packages-enabled.txt"
  tvsh settings list global          > "$b/settings-global.txt"
  tvsh settings list secure          > "$b/settings-secure.txt"
  tvsh settings list system          > "$b/settings-system.txt"
  tvsh cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME > "$b/home-launcher.txt"
  [ -d "$STATE/backup-original" ] || cp -R "$b" "$STATE/backup-original"
  say "  $(grep -c . "$b/packages-all.txt") packages and all settings saved. Original backup: backup-original/"
  screenshot "01-before"
}

# ---------- plan ----------
GROUP_IDS=(); GROUP_REC=(); GROUP_TITLE=()
load_groups() {
  local line id rec title
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      @group*)
        read -r _ id rec title <<< "$line"
        GROUP_IDS+=("$id"); GROUP_REC+=("$rec"); GROUP_TITLE+=("$title");;
    esac
  done < "$CONF"
}
group_packages() { # id -> package names
  awk -v g="$1" '/^@group/{cur=$2; next} /^[[:space:]]*#/||/^[[:space:]]*$/{next} cur==g{print $1}' "$CONF"
}

CHOSEN=(); DO_PRIVACY=1; DO_SPEED=1; DO_LAUNCHER=1
choose_plan() {
  local i
  hr
  say "RECOMMENDED PRESET"
  say "  Turn off:"
  for i in "${!GROUP_IDS[@]}"; do [ "${GROUP_REC[$i]}" = disable ] && say "    - ${GROUP_TITLE[$i]}"; done
  say "  Leave alone:"
  for i in "${!GROUP_IDS[@]}"; do [ "${GROUP_REC[$i]}" = keep ] && say "    - ${GROUP_TITLE[$i]}"; done
  say "    - AirPlay, Live TV, HDMI inputs, the Appstore, updates and all your streaming apps (never touched)"
  say "  Also: privacy settings (limit ad tracking, no interest-based ads, no usage data),"
  say "        faster animations, and the Projectivy ad-free home screen."
  hr
  if ask "Use the recommended preset?" y; then
    for i in "${!GROUP_IDS[@]}"; do [ "${GROUP_REC[$i]}" = disable ] && CHOSEN+=("${GROUP_IDS[$i]}"); done
    return
  fi
  say "Customize: answer yes to turn a group OFF."
  for i in "${!GROUP_IDS[@]}"; do
    local d=n; [ "${GROUP_REC[$i]}" = disable ] && d=y
    ask "Turn off: ${GROUP_TITLE[$i]}?" "$d" && CHOSEN+=("${GROUP_IDS[$i]}")
  done
  ask "Apply privacy settings (limit ad tracking, no interest-based ads, no usage data)?" y || DO_PRIVACY=0
  ask "Speed up menu animations (0.5x)?" y || DO_SPEED=0
  ask "Install the Projectivy ad-free home screen?" y || DO_LAUNCHER=0
}

# ---------- apply ----------
record_setting_before() { # ns key old
  local f="$STATE/changes/settings-before.tsv"
  grep -q "^$1	$2	" "$f" 2>/dev/null || printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$f"
}

apply_packages() {
  local enabled g p out n_off=0 n_skip=0 n_prot=0
  enabled=$(tvsh pm list packages -e)
  say ""; say "Turning off packages..."
  for g in "${CHOSEN[@]+"${CHOSEN[@]}"}"; do
    for p in $(group_packages "$g"); do
      if ! printf '%s\n' "$enabled" | grep -qx "package:$p"; then
        say "  skip  $p (not on this TV or already off)"; n_skip=$((n_skip+1)); continue
      fi
      if [ "$DRY" = 1 ]; then say "  would turn off  $p"; continue; fi
      out=$(tvsh pm disable-user --user 0 "$p")
      if printf '%s' "$out" | grep -q "disabled-user"; then
        say "  off   $p"; echo "$p" >> "$STATE/changes/disabled-by-tool.txt"; n_off=$((n_off+1))
      elif printf '%s' "$out" | grep -qi "protected"; then
        say "  kept  $p (Amazon protects this one)"; n_prot=$((n_prot+1))
      else
        say "  FAIL  $p: $(printf '%s' "$out" | head -1)"
      fi
    done
  done
  say "  $n_off turned off, $n_prot protected by Amazon, $n_skip not present."
}

apply_settings() {
  local list="" ns key val old
  [ "$DO_PRIVACY" = 1 ] && list="$PRIVACY_SETTINGS"
  [ "$DO_SPEED" = 1 ] && list="$list
$SPEED_SETTINGS"
  [ -z "$(echo "$list" | tr -d '[:space:]')" ] && return
  say ""; say "Changing settings..."
  while read -r ns key val; do
    [ -z "$ns" ] && continue
    old=$(tvsh settings get "$ns" "$key")
    if [ "$DRY" = 1 ]; then say "  would set $key: $old -> $val"; continue; fi
    record_setting_before "$ns" "$key" "$old"
    adbt shell settings put "$ns" "$key" "$val" >/dev/null 2>&1
    say "  $key: $old -> $(tvsh settings get "$ns" "$key")"
  done <<< "$list"
}

install_launcher() {
  [ "$DO_LAUNCHER" = 1 ] || return
  say ""; say "Installing the Projectivy home screen..."
  if [ "$DRY" = 1 ]; then say "  would download the latest Projectivy release from GitHub and turn on its Home-button takeover"; return; fi
  local url apk="$STATE/projectivy.apk" svc before new
  if ! tvsh pm list packages "$PROJECTIVY_PKG" | grep -qx "package:$PROJECTIVY_PKG"; then
    if [ -n "${FIRETV_TEST_APK:-}" ]; then cp "$FIRETV_TEST_APK" "$apk"; url="$PROJECTIVY_URL_PREFIX(test)"; else
    url=$(curl -fsSL "$PROJECTIVY_API" | grep -o '"browser_download_url": *"[^"]*\.apk"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
    case "$url" in "$PROJECTIVY_URL_PREFIX"*) ;; *) say "  Could not find the official Projectivy APK on GitHub; skipping the home screen."; return;; esac
    say "  downloading $url"
    curl -fsSL -o "$apk" "$url" || { say "  download failed; skipping."; return; }
    fi
    say "  sha256 $(shasum -a 256 "$apk" 2>/dev/null | cut -d' ' -f1)"
    adbt install -r "$apk" 2>&1 | tail -1 | sed 's/^/  /'
    tvsh pm list packages "$PROJECTIVY_PKG" | grep -qx "package:$PROJECTIVY_PKG" || { say "  install failed; skipping."; return; }
    echo "$PROJECTIVY_PKG" >> "$STATE/changes/installed-by-tool.txt"
  else
    say "  Projectivy is already installed."
  fi
  svc=$(tvsh dumpsys package "$PROJECTIVY_PKG" | grep -o "$PROJECTIVY_PKG/[A-Za-z0-9_.]*AccessibilityService" | head -1)
  [ -n "$svc" ] || svc="$PROJECTIVY_SVC_DEFAULT"
  case "$svc" in */.*) svc="$PROJECTIVY_PKG/$PROJECTIVY_PKG${svc#*/}";; esac
  before=$(tvsh settings get secure enabled_accessibility_services)
  if printf '%s' "$before" | grep -q "$svc"; then
    say "  Home-button takeover already on."
  else
    [ -f "$STATE/changes/accessibility-before.txt" ] || printf '%s\n' "$before" > "$STATE/changes/accessibility-before.txt"
    if [ -z "$before" ] || [ "$before" = "null" ]; then new="$svc"; else new="$before:$svc"; fi
    adbt shell settings put secure enabled_accessibility_services "$new" >/dev/null 2>&1
    record_setting_before secure accessibility_enabled "$(tvsh settings get secure accessibility_enabled)"
    adbt shell settings put secure accessibility_enabled 1 >/dev/null 2>&1
    say "  Home-button takeover turned on (Projectivy accessibility service)."
  fi
  adbt shell monkey -p "$PROJECTIVY_PKG" -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1
  sleep 5; screenshot "02-projectivy"
}

finish_run() {
  if [ "$DRY" != 1 ]; then
    adbt shell input keyevent KEYCODE_HOME >/dev/null 2>&1; sleep 6; screenshot "03-after"
  fi
  hr
  if [ "$DRY" = 1 ]; then say "DRY RUN finished. Nothing on the TV was changed."; pause_exit 0; fi
  say "DONE. Everything changed is recorded in tvs/$(basename "$STATE")/changes/"
  say "To undo it all: double-click 'Restore.command' (or run ./firetv-declutter.sh --restore)."
  if [ "$DO_LAUNCHER" = 1 ]; then
    cat <<'EOT' | while IFS= read -r l; do say "$l"; done

FINISH THE HOME SCREEN ON THE TV (with the remote):
  1. Click through Projectivy's welcome screens. Allow the TV listings permission if you
     use Live TV. Answer No to anonymous usage reporting.
  2. Make your dock: press Menu (the button with three lines) > Edit categories >
     New category. Set Title to "Favorites" (on the keyboard, choose Next to confirm),
     then scroll down to Manage apps and switch on your favourite apps in the order
     you want them. Press Back until you're home: the new row sits at the top.
  3. Check privacy: Menu > Projectivy settings > General > turn off "Enable anonymous
     usage reports" and "Enable anonymous crash reports".
  Pressing Home may show Amazon's screen for a moment before Projectivy takes over.
  That's normal on Fire TV.
EOT
  fi
  pause_exit 0
}

# ---------- restore ----------
restore() {
  local c="$STATE/changes" p a ns key old n=0
  [ -d "$c" ] && [ -n "$(ls -A "$c" 2>/dev/null)" ] || die "No recorded changes for this TV in tvs/$(basename "$STATE")/changes/. Nothing to restore."
  say "Restoring this TV to how it was before firetv-declutter..."
  if [ -f "$c/accessibility-before.txt" ]; then
    a=$(cat "$c/accessibility-before.txt")
    if [ -z "$a" ] || [ "$a" = "null" ]; then
      adbt shell settings delete secure enabled_accessibility_services >/dev/null 2>&1
    else
      adbt shell settings put secure enabled_accessibility_services "$a" >/dev/null 2>&1
    fi
    adbt shell am force-stop "$PROJECTIVY_PKG" >/dev/null 2>&1
    say "  Home-button takeover turned off."
    mv "$c/accessibility-before.txt" "$c/accessibility-before.restored-$(date +%s).txt"
  fi
  if [ -f "$c/disabled-by-tool.txt" ]; then
    for p in $(sort -u "$c/disabled-by-tool.txt"); do
      if adbt shell pm enable --user 0 "$p" 2>&1 | grep -q "enabled"; then say "  on    $p"; n=$((n+1)); else say "  FAIL  $p"; fi
    done
    mv "$c/disabled-by-tool.txt" "$c/disabled-by-tool.restored-$(date +%s).txt"
  fi
  if [ -f "$c/settings-before.tsv" ]; then
    while IFS=$'\t' read -r ns key old; do
      [ -z "$ns" ] && continue
      if [ -z "$old" ] || [ "$old" = "null" ]; then adbt shell settings delete "$ns" "$key" >/dev/null 2>&1
      else adbt shell settings put "$ns" "$key" "$old" >/dev/null 2>&1; fi
      say "  reset $key -> $old"
    done < "$c/settings-before.tsv"
    mv "$c/settings-before.tsv" "$c/settings-before.restored-$(date +%s).tsv"
  fi
  if [ -f "$c/installed-by-tool.txt" ] && ask "Also uninstall Projectivy?" n; then
    adbt uninstall "$PROJECTIVY_PKG" 2>&1 | tail -1 | sed 's/^/  /'
    mv "$c/installed-by-tool.txt" "$c/installed-by-tool.restored-$(date +%s).txt"
  fi
  hr
  say "Restored ($n apps turned back on). Restart the TV to finish: Settings > My Fire TV > Restart."
  pause_exit 0
}

# ---------- main ----------
main() {
  parse_args "$@"
  echo "firetv-declutter $VERSION - reversible Fire TV cleanup"
  [ -f "$CONF" ] || { echo "debloat.conf is missing."; exit 1; }
  ensure_adb
  pick_tv_ip
  connect_tv
  check_device
  if [ "$MODE" = restore ]; then restore; fi
  [ "$DRY" = 1 ] && say "DRY RUN: nothing will be changed."
  backup
  load_groups
  choose_plan
  apply_packages
  apply_settings
  install_launcher
  finish_run
}

main "$@"
