# firetv-declutter (macOS)

Make an Amazon Fire TV faster and quieter from your Mac: turn off Amazon's ads,
tracking and telemetry, and swap the ad-filled home screen for a clean one with
a dock of your favourite apps and rotating nature wallpapers.

Everything is **reversible**. Apps are disabled, never uninstalled, and every
change is recorded so one double-click puts the TV back exactly as it was.

> **Testing status:** every step in this tool was first done by hand on a
> Toshiba 55C350LU (Fire OS 7.7.1.7) and checked with screenshots from the TV.
> The packaged tool itself has been tested against a simulated TV, not yet a
> real one, so try `--dry-run` first. Other Fire OS 7 TVs and sticks should
> work. Fire OS 6/8 may work. **Vega OS devices are not
> supported** (they aren't Android). Use at your own risk.

## What it does

1. Finds your Fire TV on your Wi-Fi and connects over ADB.
2. Backs up the TV's app list and settings before changing anything.
3. Offers the **Recommended preset** or lets you **Customize** group by group.
4. Disables the chosen Amazon services and applies privacy settings.
5. Installs [Projectivy Launcher](https://github.com/spocky/miproja1) (official
   GitHub release) and turns on its Home-button takeover.
6. Takes TV screenshots before and after, and writes a full log.

### Recommended preset

| Turned off | Left alone (Customize to turn off) |
|---|---|
| Ads and viewing tracking (ad ID, content recognition) | Alexa voice |
| Telemetry, metrics and log uploaders | Screen mirroring (Miracast) |
| Autoplay previews, demo content, tutorials | Smart home, Matter, video calls |
| Amazon shopping | Amazon Music and Photos |
| Games hub | Amazon Kids |
| miniTV | Silk browser |

Plus: limit ad tracking on, interest-based ads off, usage-data collection off,
content recognition off, and faster (0.5x) animations.

**Never touched:** AirPlay, Live TV, HDMI inputs, the Appstore, Fire OS updates,
the keyboard, Wi-Fi/Bluetooth, Prime Video and every app you installed.

The full list, with a comment on each package, is in [`debloat.conf`](debloat.conf).
A few packages (ad deep-linking, device metrics, crash and log managers) are
protected by Amazon on some models; the tool reports and skips them.

## Before you start

On the Fire TV:

1. **Settings > My Fire TV > About**: select the device name 7 times to unlock
   Developer Options (skip if you already see Developer Options).
2. **Settings > My Fire TV > Developer Options**: turn on **ADB debugging**.

Your Mac must be on the same Wi-Fi network as the TV.

## Run it

1. Download this repo (green **Code** button > **Download ZIP**) and unzip it.
2. Double-click **Start Here.command**.
   - If macOS says it can't be opened: right-click it, choose **Open**, then **Open** again.
   - If macOS asks to let Terminal find devices on your local network: **Allow**.
3. On the TV, when asked **Allow USB debugging?**, tick **Always allow from this
   computer** and choose **OK**.
4. Choose the Recommended preset or Customize.
5. Finish the home screen on the TV with the remote (the tool prints these steps):
   - Click through Projectivy's welcome screens. Allow TV listings if you use
     Live TV, and answer **No** to anonymous usage reporting.
   - **Make your dock:** Menu button (three lines) > **Edit categories** >
     **New category**. Set **Title** to `Favorites` (on the keyboard choose
     **Next**), then **Manage apps** and switch on your favourite apps in the
     order you want them. Press Back until you're home.
   - **Menu > Projectivy settings > General**: make sure both anonymous
     usage/crash reports are off.

Pressing Home may show Amazon's screen for a moment before Projectivy takes
over. That's a Fire TV limitation, and it's normal.

Command-line options:

```
./firetv-declutter.sh                 # interactive
./firetv-declutter.sh --ip 192.168.1.50
./firetv-declutter.sh --dry-run       # show what would change
./firetv-declutter.sh --yes           # Recommended preset, no questions
./firetv-declutter.sh --restore       # undo everything
```

## Undo

Double-click **Restore.command**, then restart the TV
(**Settings > My Fire TV > Restart**). It turns every disabled app back on,
resets every changed setting to its old value, switches off the Home-button
takeover, and offers to uninstall Projectivy.

Restore relies on the `tvs/` folder this tool creates next to it, so keep
that folder. You can also turn apps back on by hand in
**Settings > Applications > Manage Installed Applications**.

## Files it creates

```
platform-tools/            Google's ADB tools (downloaded on first run)
tvs/<serial>/
  backup-original/         snapshot from the very first run
  backup-<date>/           snapshot from each run
  changes/                 exactly what was changed (used by Restore)
  screens/                 TV screenshots
  firetv-declutter.log     everything that happened
```

`tvs/` is in `.gitignore`. It holds details about your TV, so don't commit it.

## If a Fire OS update undoes the home screen

Amazon updates sometimes turn accessibility services off. Run
**Start Here.command** again (already-done steps are skipped), or turn
Projectivy back on in **Settings > Accessibility**.

## Development

`tests/run-tests.sh` runs the whole flow against a simulated TV
(`tests/fake-adb.sh`) on macOS or Linux: Recommended run, re-run, Customize,
restore, and refusing non-Fire OS devices. The Projectivy download from GitHub
isn't exercised in tests.

## Credits

- [Projectivy Launcher](https://github.com/spocky/miproja1) by spocky (free, with an optional premium tier).
- Android platform-tools by Google.

Not affiliated with Amazon, Toshiba or Projectivy.
