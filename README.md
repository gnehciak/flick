# Flick

⌘Tab for every window, with the switcher on screen a few milliseconds after the key. The overlay uses native Liquid Glass (`NSGlassEffectView`) on macOS 26 and later.

```bash
./build.sh --install
```

Needs Accessibility. Screen Recording adds thumbnails, and without it tiles show app icons.
Both survive rebuilds because `build.sh` signs with a local key in `.signing`. Keep that folder.

## Why not AltTab

AltTab waits before it shows anything. By default it holds the overlay back 100 ms so a quick ⌘Tab doesn't flash it, and you feel that wait every time you switch. Flick has no wait. The window list is already in memory and the overlay is already built, so it appears the moment you press the key. It starts the switch while the key is still down, so a quick tap is finished by the time you let go. It also jumps straight to windows on other Spaces instead of sliding there.

| | Flick | AltTab |
| --- | --- | --- |
| Overlay after ⌘Tab | 0.6–2 ms | 100 ms default delay |
| Window on top after release, median | 1.3 ms | 47.2 ms |
| Window on top after release, worst | 8.5 ms | 63.9 ms |
| Window on another Space | Jump, 70–165 ms across 3 Spaces | System slide |
| App size | 2 MB | 31 MB |

Flick and AltTab 7.26 on one Mac. Flick's figures are from 42 switches holding ⌘ for 90 ms, and 18 ms median with a 30 ms hold. AltTab's are from 14 switches holding ⌘ for 30 ms, in an earlier test on a quieter Mac. Native ⌘Tab took 46.4 ms in that test. Without Early Switch, Flick takes the same time as native. The window still takes about 50 ms from the press, so the gain is the wait after release. Flick's overlay time runs up to the point it's made visible, before the next screen refresh. AltTab's 100 ms is its setting, not a timing, and it can be lowered. The Space row comes from AltTab's source, not a timing.

AltTab has far more options, ships updates and runs on older versions of macOS. Its current release has Liquid Glass too. Flick's Space jump needs macOS 27.

## Keys

| Key | Action |
| --- | --- |
| ⌘Tab, ⇧⌘Tab | Next, previous |
| Release ⌘, Return, Space | Switch |
| Arrows | Move. By position when showing all Spaces. |
| S | Flip between the current Space and all Spaces, this time only. |
| 1 to 9 | With all Spaces showing, that Space's windows. Press again for the next. |
| Esc | Cancel |
| W | Close window |
| Q | Quit app |

The mouse works too. With all Spaces showing, clicking an empty part of a Space goes there.

## Settings

Menu bar icon > Settings, or open Flick from Applications. Changes apply straight away, and each tab shows a live preview where it helps. Flick opens Settings by itself when it still needs Accessibility.

- **General:** the shortcut (⌘, ⌥ or ⌃ Tab; with ⌥ or ⌃ the system ⌘Tab stays on), the delay before the switcher shows, Early Switch, Open at Login and the menu bar icon. It also shows whether Accessibility and Screen Recording are allowed, with a button to each in System Settings.
- **Appearance:** a miniature switcher with your own windows on your wallpaper, which follows glass, tint, highlight, size and corners as you change them. Window previews, titles, app icons, and which display it shows on.
- **Windows:** what ⌘Tab shows, the current Space or all Spaces as a grid. S in the switcher flips between them for one time. Minimized windows, hidden apps and ignored apps.
- **Spaces:** your Spaces as the grid lays them out, with their names and apps. Organise… names, reorders and hides them and sets the columns. Reduced Motion fades the grid instead of zooming, and also follows System Settings. In the grid, drag a tile onto another Space to move the window there (macOS 27 and later, same display).
- **Gestures:** Three Finger Switch swipes sideways through windows, as on Windows: keep the fingers down to choose, lift to switch, add a fourth finger to cancel. Its preview marks where each step lands at the chosen sensitivity, and higher sensitivity means less finger travel. Swipe Up for Spaces opens the grid with three fingers up instead of Mission Control, following your fingers, and down closes it. The tab warns when the system's own trackpad gestures would get in the way.
- **About:** the version, Buy Me a Coffee and the source code, the keys in the switcher, Reset All Settings and Quit.

## Free and open source

Flick is free, with every feature, under the [MIT licence](LICENSE). It never connects to the internet. If it saves you time, you can buy me a coffee from Settings > About.

To install a downloaded copy, move Flick to Applications and open it. It isn't notarized, so the first time macOS may ask you to allow it in System Settings > Privacy & Security.

To build it yourself you only need Apple's Command Line Tools:

```bash
./build.sh --install
```

The first build makes a signing key in `.signing`, kept out of the repository, so Accessibility and Screen Recording survive later rebuilds on your Mac. The coffee and source links are the `Links` constants at the top of `SettingsView.swift`, and the website is in `site/`.

Space switching and the swipe override build on [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by jurplel, under the MIT licence. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## How it stays fast

- The window list lives in memory and updates in the background. Pressing ⌘Tab asks nothing of the WindowServer or any app.
- Keys are handled on their own high-priority thread.
- The overlay stays in the window list at zero alpha with its layers built, so showing it is an alpha change.
- Focus goes straight to the WindowServer, so a hung app can't hold up a switch.
- Windows on another Space are reached directly with bridged SkyLight operations, in about 15 ms at any distance, and otherwise with a zero-distance Dock swipe. Both come from [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) (MIT). No slide either way. macOS 27 and later.
- Thumbnails and refreshes wait until after a switch.
- A quick tap almost always goes to the previous window, so Early Switch brings it forward at the press. Esc puts the first window back, and tabbing further just moves on. It skips windows that are minimized, hidden or on another Space.

macOS takes about 45 ms to bring a window forward. Early Switch runs that while the key is down, so it still takes that long.

## Safety

Flick turns the system ⌘Tab off while it runs and restores it on quit, on signals and when Accessibility is removed. The launch agent `~/Library/LaunchAgents/local.flick.app.plist` restarts it after a crash. A hot key covers secure input, which silences event taps.

## Performance

`tools/perf.py` measures GPU, CPU and memory in each state, with Flick off as the baseline, and puts Flick back when it ends. Doesn't move focus. `FLICK_SELFTEST=<report> FLICK_CHANGETEST=1` lists which windows keep changing on screen, which is what keeps the WindowServer busy.

## Testing

`Sources/Flick/SelfTest.swift` runs when launched with `open -n --env`. Build the fixture with `swiftc tools/fixture/main.swift -o <path>`. Add `FLICK_REPLACE=1` if Flick is already running, and `FLICK_LOG=<file>` for timings.

| Variables | What it does |
| --- | --- |
| `FLICK_SELFTEST=<report> FLICK_REVEALTEST=1` | Overlay timing. Doesn't move focus. |
| `FLICK_SELFTEST=<report> FLICK_CLOSETEST=<fixture>` | Window close. Doesn't move focus. |
| `FLICK_SELFTEST=<report> FLICK_FIXTURE=<fixture>` | Full run with posted keys. Takes over focus. |
| Add `FLICK_SHORT=1` to the full run | Flips and the W key only, about 10 seconds. |
| Add `FLICK_BASELINE=<name>` to the full run | Times another switcher instead. |
| `FLICK_SELFTEST=<report> FLICK_PREFTEST=1` | Shortcuts, filters and delay, live. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_FADETEST=<png>` | Thumbnail crossfade, with a mid-fade capture. Doesn't move focus. |
| `FLICK_SELFTEST=<report> FLICK_STICKYTEST=<sticky>` | A window on every Space, live title. Build `tools/sticky.swift`. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_EARLYTEST=<fixture>` | Early Switch can be undone. Takes over focus. |
| Add `FLICK_EARLY=1` and `FLICK_HOLDMS=<ms>` to the full run | Early Switch on, and how long ⌘ is held. |
| `FLICK_SELFTEST=<report> FLICK_SETTINGSTEST=1` | Settings in the list, Q closes it. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_SPACESTEST=1 FLICK_ALLSPACES=1` | Spaces view layout and arrows. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_FLIPTEST=1` | The S key, with real keys. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_SWIPETEST=1` | Vertical swipes through the tap. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_OPENTEST=<prefix>` | The swipe's opening animation. Add `FLICK_SLOWOPEN=<n>` for frames. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_REDUCEDTEST=1` | Reduced Motion. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_MOVETEST=<fixture>` | Drags a throwaway window between Spaces. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_PICKTEST=<fixture>` | Clicks and drags in the grid with throwaway windows. Takes over focus. |
| `FLICK_SELFTEST=<report> FLICK_JUMPTEST=1` | Swipes against direct Space jumps. Takes over the screen. |
| `FLICK_SELFTEST=<report> FLICK_RECORDTEST=<mov>` | Films a cold and a warm click on another Space. Takes over the screen. |
| `FLICK_SELFTEST=<report> FLICK_TOUCHTEST=1` | The three finger gesture with made-up touches. Focus stays put. |
| `FLICK_SELFTEST=<report> FLICK_BENCH=1` | Refresh and capture times, memory. Doesn't move focus. |
| `FLICK_SNAPSHOT=<png>` | Screenshots the overlay. Add `FLICK_ALLSPACES=1` for the Spaces view. |
| `FLICK_SETTINGSHOT=<png>` | Screenshots each Settings tab to `<png>-<tab>.png`. Add `FLICK_SETTINGSTAB=<tab>` for one. |
| `FLICK_ORGANISERSHOT=<png>` | Screenshots the Spaces organiser. |
