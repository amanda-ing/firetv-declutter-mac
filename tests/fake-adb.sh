#!/bin/bash
# Simulated Fire TV for tests. State lives in $FAKE_TV_DIR.
D="${FAKE_TV_DIR:?}"; cat >/dev/null 2>&1 &   # adb reads stdin; mimic but don't block
[ "$1" = "-s" ] && shift 2
cmd="$1"; shift || true
case "$cmd" in
  connect) echo "connected to $1";; 
  get-state) echo device;;
  exec-out) printf '\x89PNG fake';;
  install) cp /dev/null "$D/installed-apk"; echo "com.spocky.projengmenu" >> "$D/enabled"; echo Success;;
  uninstall) grep -vx "$1" "$D/enabled" > "$D/t"; mv "$D/t" "$D/enabled"; echo Success;;
  shell)
    sub="$1"; shift || true
    case "$sub" in
      getprop)
        case "${1:-}" in
          ro.build.version.name) echo "${FAKE_OS:-Fire OS 7.7.1.7 (PS7717/5741)}";;
          ro.build.version.sdk) echo 28;; ro.product.model) echo AFTFAKE;; ro.serialno) echo FAKESERIAL123;;
          "") echo "[ro.product.model]: [AFTFAKE]";; esac;;
      pm)
        a="$1"; shift
        case "$a" in
          list)
            shift; f="all"; filt=""
            for x in "$@"; do case "$x" in -e) f=e;; -d) f=d;; -s|-3|-f|-U) ;; *) filt="$x";; esac; done
            case $f in e) src="$D/enabled";; d) src="$D/disabled";; all) src=all;; esac
            if [ "$src" = all ]; then cat "$D/enabled" "$D/disabled"; else cat "$src"; fi | grep -F -- "$filt" | sed 's/^/package:/' | tr '\n' '\n' | sed 's/$/\r/';;
          disable-user)
            p="${@: -1}"
            if grep -qx "$p" "$D/protected"; then echo "Security exception: Cannot disable a protected package: $p"; exit 0; fi
            grep -vx "$p" "$D/enabled" > "$D/t"; mv "$D/t" "$D/enabled"; echo "$p" >> "$D/disabled"
            echo "Package $p new state: disabled-user";;
          enable)
            p="${@: -1}"; grep -vx "$p" "$D/disabled" > "$D/t"; mv "$D/t" "$D/disabled"; echo "$p" >> "$D/enabled"
            echo "Package $p new state: enabled";;
        esac;;
      settings)
        a="$1"; ns="${2:-}"; k="${3:-}"; v="${4:-}"; F="$D/settings-$ns"; touch "$F"
        case "$a" in
          get) val=$(grep -F "$k=" "$F" | grep "^$k=" | head -1 | cut -d= -f2-); echo "${val:-null}";;
          put) grep -v "^$k=" "$F" > "$D/t"; mv "$D/t" "$F"; echo "$k=$v" >> "$F";;
          delete) grep -v "^$k=" "$F" > "$D/t"; mv "$D/t" "$F";;
          list) cat "$F";;
        esac;;
      dumpsys)
        if [ "${1:-}" = package ] && grep -qx com.spocky.projengmenu "$D/enabled"; then
          echo "        619eb5b com.spocky.projengmenu/.services.ProjectivyAccessibilityService filter"; fi;;
      cmd) echo "com.amazon.tv.launcher/.ui.HomeActivity_vNext";;
      *) :;;
    esac;;
esac
exit 0
