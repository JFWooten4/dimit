<img src="docs/images/icon.png" width="96" alt="">

# Dimit

**Free and open source under the MIT licence.** Dimit is a native macOS menu-bar
app that warms your screen down to pure red, dims it in software, and offers a
PWM-Safe mode that holds supported backlights at 100%. Two sliders, three
presets, one ON/OFF button. English, Uzbek (Latin), and Russian.

[Download from GitHub Releases](https://github.com/azakapro/dimit/releases),
or [build it yourself](#how-to-build). Every feature is free: no accounts,
licence keys, activation, or telemetry.

- **Warmth from 6500K to “0K”.** The display's gamma tables produce the tint;
  “0K” is a name for pure red, not a physical temperature.
- **Software brightness down to 10%**, with settings applied across connected displays.
- **PWM-Safe mode** pins a supported hardware backlight at 100% and uses software
  dimming. Whether that eliminates pulsing depends on the panel; Dimit does not
  measure flicker. Third-party DDC/CI control is experimental and off by default.
- **Sunset/sunrise or fixed-time schedules**, calculated locally from a bundled
  city list or an optional device location, plus presets and global shortcuts.
- **Bell-curve schedule** with wake-up, peak and bedtime controls: ease from a
  chosen low brightness to a daytime peak, then gradually dim again for the night.
- **Restore Colours** is available from the menu. OFF, quit, signal handlers,
  and launch restore the gamma tables; restoration on relaunch also handles a
  force-killed process.

The app makes no network requests unless you enable automatic updates or
explicitly choose **Check for Updates…**. Sparkle uses the
[GitHub Pages appcast](https://azakapro.github.io/dimit/appcast.xml) and release
assets for updates. Automatic checks are off by default. No Accessibility,
Screen Recording, or administrator permission is required; Location is requested
only when you press **Use my location**.

## How to install

Requires **macOS 13 or later**, on Apple silicon or Intel; the release build is
universal. This is the deployment target, not a claim that every version has
been tested. See the systems and limitations below.

1. Download the DMG attached to a [GitHub Release](https://github.com/azakapro/dimit/releases).
2. Open it and drag **Dimit.app** into **Applications**.
3. The current v0.6 beta is ad-hoc signed and **not notarized**. After downloading
   it from this repository, remove its quarantine flag in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Dimit.app
   ```

4. Open Dimit from Applications. Its icon appears in the menu bar, with no Dock icon.

Follow the signing status in each release's notes; a future notarized release
will not need the quarantine step. Quit an older running copy before installing
an update. Full packaging instructions are in [docs/RELEASE.md](docs/RELEASE.md).

## Tested systems

These are the reports we have, including failures. See [hardware QA](docs/QA.md)
for the checks, measurements, and remaining gaps.

| Mac / display | macOS | Observed result |
|---|---|---|
| MacBook Pro 16-inch M1 Pro (`MacBookPro18,1`), built-in XDR | 27.0 beta (`26A5416b`) | Warmth, dimming, PWM pin/restore, scheduling, and sleep/wake exercised; gamma capture checked with QuickTime and Zoom. |
| Same Mac with Xiaomi Mi Monitor, 2560×1440 at 144 Hz | 27.0 beta | Gamma applies to both displays and re-applies on reconnect. DDC reads return an error; hardware brightness control remains unconfirmed. |
| MacBook Air (M2), built-in | 15.6 | Warmth and dimming reported working; the broader matrix is pending. |
| MacBook Pro (M4), built-in XDR / ProMotion | 26.6.2 | Warmth, dimming, PWM-Safe, install and UI all reported working. |

macOS 13 and 14, Intel hardware, and other display combinations still need reports.

## Known limitations

- **macOS 26 colour bug.** On some Macs, macOS 26 stores a gamma change and reports
  success while the screen keeps its normal colours. Tracked Apple reports are
  **FB18559786, FB19136488, and FB22273730**; the evidence and Apple's forum threads
  are in [CLAUDE.md §3.3](CLAUDE.md#33-gamma-tables-gammacontrollerswift) and
  [QA](docs/QA.md). Turning off automatic brightness in System Settings → Displays
  helps on many of them. Every Mac we have been able to test on works, so this is
  Apple's evidence rather than ours. Dimit has no tint fallback: where the bug does
  hit, dimming and PWM-Safe still work but colours do not change, and **pinning the
  backlight without working gamma dimming makes the screen brighter**.
- **Capture with other recorders.** Screenshots, QuickTime recordings and Zoom shares
  show normal colours on the Macs tested; screenshots were also checked below 30%,
  where dimming uses an overlay window, and the overlay does not appear in them.
  `sharingType = .none` is what excludes it, and Apple describes that as legacy with
  no guarantee against ScreenCaptureKit — OBS-class recorders, and recordings or
  shares taken below 30%, are still untested.
- **Experimental DDC.** Off by default, limited to one external monitor, and no
  successful third-party backlight pin has been confirmed. A DDC transaction can
  briefly block the UI; the Mi Monitor returned error frames in hardware testing.
- **Coverage and polish.** Other hardware and macOS versions, full capture coverage,
  keyboard focus, VoiceOver, and fluent Uzbek/Russian review still need testing.
  Pending checks remain visible in [QA](docs/QA.md).

## How to build

Install Xcode 26 or newer and select it with `xcode-select`. The project uses a
Swift 6 toolchain in **Swift 5 language mode**. Bootstrap installs XcodeGen via
Homebrew if it is missing, then generates the project:

```bash
git clone https://github.com/azakapro/dimit.git
cd dimit
scripts/bootstrap.sh
xcodebuild test -project Dimit.xcodeproj -scheme Dimit -destination 'platform=macOS'
scripts/build.sh
```

Quit any running Dimit before the last command: it builds a universal release
app and verifies that the artifact launches and exits cleanly. The result is
`build/release/Dimit.app`; `scripts/build_dmg.sh` packages an ad-hoc beta DMG.
For local debugging, open `Dimit.xcodeproj` and run the Dimit scheme.

`Dimit.xcodeproj` is generated and gitignored: edit `project.yml`, then re-run
bootstrap. The two existing Swift packages are pinned:
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) and
[Sparkle](https://github.com/sparkle-project/Sparkle).

Read [CONTRIBUTING.md](CONTRIBUTING.md), [the engineering spec](CLAUDE.md), and
[the architecture](docs/ARCHITECTURE.md) before changing display code. On a new
macOS build, run `swift scripts/gamma_spike.swift` before trusting gamma results.
[The plan](docs/PLAN.md) records cycles C0–C7 and PR requirements.

## How to report a bug

[Open a bug report](https://github.com/azakapro/dimit/issues/new?template=bug_report.md)
with the app version, Mac model, macOS version, display and connection, steps,
and expected versus actual behaviour. **Do not paste serial numbers** or precise
personal coordinates. Review copied diagnostics and screenshots before sharing.
For colour issues, describe the physical screen; screenshots cannot prove a gamma tint.
[The tester checklist](docs/TESTING_CHECKLIST.md) lists useful hardware checks.

## Support

Dimit is free and always will be. If it earned a place in your menu bar,
[you can buy me a coffee](https://buymeacoffee.com/azakapro) — entirely optional,
and it unlocks nothing, because there is nothing to unlock.

## Licence

[MIT](LICENSE) · Copyright © 2026 Azizullo Temirov.
