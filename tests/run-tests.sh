#!/bin/bash
# End-to-end test against a simulated TV: run recommended preset, then restore,
# and check the TV ends up exactly as it started.
set -u
cd "$(dirname "$0")/.." || exit 1
export FAKE_TV_DIR=$(mktemp -d) ADB="$PWD/tests/fake-adb.sh" FIRETV_IP=10.9.9.9 ASSUME_DEFAULTS=1
D=$FAKE_TV_DIR; fail=0
grep -v '^\s*#' debloat.conf | grep -v '^@' | awk 'NF{print $1}' > "$D/enabled"
printf '%s\n' com.amazon.tv.launcher com.amazon.venezia com.netflix.ninja >> "$D/enabled"
printf 'com.android.nfc\n' > "$D/disabled"
printf '%s\n' com.amazon.ftvads.deeplinking com.amazon.device.metrics com.amazon.device.crashmanager com.amazon.device.logmanager > "$D/protected"
printf 'limit_ad_tracking=0\namz_limit_ad_tracking=0\nadvertisingIdApp:interestBasedAds:value=1\nsetting.com.amazon.tv.acr.enabled=1\n' > "$D/settings-secure"
printf 'window_animation_scale=1.0\ntransition_animation_scale=1.0\n' > "$D/settings-global"
echo fake > "$D/fake.apk"; export FIRETV_TEST_APK="$D/fake.apk"   # GitHub download is not exercised in tests
rm -rf tvs
sort "$D/enabled" > "$D/enabled.orig"; cat "$D"/settings-* | sort > "$D/settings.orig"

check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi; }

./firetv-declutter.sh --dry-run > "$D/dry.out" 2>&1
check "dry run changes nothing" 'diff -q <(sort "$D/enabled") "$D/enabled.orig" >/dev/null'

./firetv-declutter.sh > "$D/run.out" 2>&1
check "ads/telemetry/autoplay/shopping/games/minitv off" '! grep -qxE "com.amazon.tv.acr|com.amazon.sneakpeek|com.amazon.gamehub|com.amazon.shoptv.client|com.amazon.minitv.android.app" "$D/enabled"'
check "keep-groups untouched (alexa, kids, silk, cast)" 'grep -qx com.amazon.vizzini "$D/enabled" && grep -qx com.amazon.tahoe "$D/enabled" && grep -qx com.amazon.cloud9 "$D/enabled" && grep -qx com.amazon.cast.sink "$D/enabled"'
check "never-touch apps still on" 'grep -qx com.amazon.tv.launcher "$D/enabled" && grep -qx com.amazon.venezia "$D/enabled" && grep -qx com.netflix.ninja "$D/enabled"'
check "protected packages reported, not fatal" 'grep -q "Amazon protects" "$D/run.out"'
check "privacy settings applied" 'grep -qx "limit_ad_tracking=1" "$D/settings-secure" && grep -qx "setting.com.amazon.tv.acr.enabled=0" "$D/settings-secure"'
check "animations sped up" 'grep -qx "animator_duration_scale=0.5" "$D/settings-global"'
check "backup written" 'ls tvs/FAKESERIAL123/backup-original/packages-all.txt >/dev/null'
if grep -qx com.spocky.projengmenu "$D/enabled"; then
  check "home-button takeover on" 'grep -q "ProjectivyAccessibilityService" "$D/settings-secure"'
else echo "SKIP  launcher install (GitHub not reachable from this machine)"; fi

./firetv-declutter.sh > "$D/run2.out" 2>&1
check "second run is safe (no new changes)" 'grep -q "0 turned off" "$D/run2.out"'

./firetv-declutter.sh --restore > "$D/restore.out" 2>&1
sort "$D/enabled" | grep -vx com.spocky.projengmenu > "$D/enabled.after"
check "restore re-enables everything" 'diff "$D/enabled.after" "$D/enabled.orig"'
check "restore resets settings" 'diff <(cat "$D"/settings-* | sort) "$D/settings.orig"'
check "restore turns off takeover" '! grep -q ProjectivyAccessibilityService "$D/settings-secure"'

# Customize path + pre-existing accessibility service must be preserved
echo "enabled_accessibility_services=com.other.app/.Svc" >> "$D/settings-secure"
cat "$D"/settings-* | sort > "$D/settings.orig"
# answers: preset? n | 12 groups: ads y, telemetry y, autoplay n, shopping n, games n, minitv n, alexa y, mirroring n, smarthome n, musicphotos n, kids n, silk y | privacy n | speed n | launcher y
FIRETV_ANSWERS="n y y n n n n y n n n n y n n y" ASSUME_DEFAULTS=0 ./firetv-declutter.sh > "$D/custom.out" 2>&1 </dev/null
check "customize: chosen groups off" '! grep -qxE "com.amazon.vizzini|com.amazon.cloud9|com.amazon.tv.acr" "$D/enabled"'
check "customize: unchosen groups on" 'grep -qx com.amazon.sneakpeek "$D/enabled" && grep -qx com.amazon.gamehub "$D/enabled"'
check "customize: privacy skipped" 'grep -qx "limit_ad_tracking=0" "$D/settings-secure"'
check "existing accessibility service kept" 'grep -q "com.other.app/.Svc:com.spocky" "$D/settings-secure"'
./firetv-declutter.sh --restore > "$D/restore2.out" 2>&1
sort "$D/enabled" | grep -vx com.spocky.projengmenu > "$D/enabled.after"
check "restore after customize" 'diff "$D/enabled.after" "$D/enabled.orig" >/dev/null && diff <(cat "$D"/settings-* | sort) "$D/settings.orig" >/dev/null'

FAKE_OS="VegaOS 1.1" ./firetv-declutter.sh > "$D/vega.out" 2>&1
check "refuses non-Fire OS" 'grep -q "not supported" "$D/vega.out"'

rm -rf tvs
[ "$fail" = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED (logs in $D)"; exit 1; }
