# ScheduledJiggler

A macOS menu-bar app inspired by [Jiggler](https://github.com/bhaller/Jiggler) with **time-based scheduling**.

Written in Objective-C. Keeps your Mac awake by moving the mouse when idle, and **stops automatically at a time you choose**.

## Features

- **Menu bar only** — no Dock icon
- **Time picker** — choose the stop time with a native `NSDatePicker` (24h format)
- **Auto-start at login** — via `SMAppService`
- **Configurable idle threshold** — 10s to 10min (default: 2 min)
- **Configurable jiggle interval** — 5s to 2min (default: 30s)
- **Smart mouse tracking** — small random movements, doesn't drift far
- **Power management** — prevents display sleep while jiggling
- **App Nap prevention** — stays responsive in background

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 14+ to build
- Accessibility permissions

## Building

1. Open `ScheduledJiggler.xcodeproj` in Xcode
2. Set your signing team in Signing & Capabilities
3. ⌘R to build and run

## Creating a DMG

1. In Xcode: **Product → Archive**
2. In Organizer: **Distribute App → Copy App**
3. Then in Terminal:

```bash
mkdir -p ~/Desktop/dmg-content
cp -r /path/to/ScheduledJiggler.app ~/Desktop/dmg-content/
ln -s /Applications ~/Desktop/dmg-content/Applications
hdiutil create -volname "ScheduledJiggler" \
  -srcfolder ~/Desktop/dmg-content \
  -ov -format UDZO \
  ~/Desktop/ScheduledJiggler.dmg
rm -rf ~/Desktop/dmg-content
```

## License

GPL-3.0

## Credits

Inspired by [Jiggler](https://github.com/bhaller/Jiggler) by Ben Haller / Stick Software.
