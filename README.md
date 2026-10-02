# brother-autoscan

Feed a sheet into a **Brother DS-640** on macOS and it lands in a folder. No Brother app, no clicks.

## Quick start
1. Install Brother's scanner driver (`Brother_ScannerDrivers_ICA`) once. Quit Brother iPrint&Scan / BR-Receipts, since they lock the scanner.
2. Build and install:
   ```bash
   ./build.sh
   ```
3. Plug in the scanner. A window and notification appear. Feed a sheet and it's saved (default `~/Documents/Scans`, 300 dpi, PDF).

The window lets you change folder, resolution, format and color, and lists every capture (double-click to reveal in Finder). Settings persist. It auto-starts at login.

Headless alternative: `swiftc -O cli/autoscan.swift -o autoscan && ./autoscan --dir ~/Scans --dpi 300 --format pdf`

## How it works
The DS-640 exposes only vendor-specific USB interfaces, but Brother's ICA driver makes it a standard ImageCaptureCore scanner. The app opens it, selects the document feeder, and requests a scan about once a second.

- `app/` - AutoScan.app (AppKit)
- `cli/autoscan.swift` - command-line version
- `build.sh` - build, ad-hoc sign, install LaunchAgent (`~/Library/Logs/autoscan.log`)

## Gotchas
- ICA error -47 "busy": another app holds the scanner.
- `documentLoaded` is always true. An empty feeder returns ICA error -9933, which the app treats as "keep waiting".
