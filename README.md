# brother-autoscan

Feed a sheet into a Brother DS-640 on macOS and get it saved to a folder. No Brother app, no clicks.

The DS-640 exposes only vendor-specific USB interfaces, but Brother's ICA driver
(`/Library/Image Capture/Devices/Brother Scanner.app`) makes it a standard ImageCaptureCore scanner.
This talks to it via ImageCaptureCore and polls the document feeder.

- `app/` - AutoScan.app (AppKit): window on scanner detect, folder/resolution/format/color settings, notifications, capture list. Runs at login via launchd.
- `cli/autoscan.swift` - headless version (`--dir --dpi --format --gray --bw`).
- `build.sh` - build, sign ad-hoc, install the LaunchAgent.

## Notes
- Quit Brother iPrint&Scan / BR-Receipts: they hold the scanner (ICA error -47 "busy").
- `documentLoaded` is unreliable (always true). Empty feeder = ICA error -9933, so the app just retries about once a second.
- Log: `~/Library/Logs/autoscan.log`.
