# brother-autoscan

Feed a sheet into a **Brother DS-640** on macOS and it lands in a folder. No Brother app, no clicks.

## Quick start
1. Install Brother's scanner driver (`Brother_ScannerDrivers_ICA`) once. Quit Brother iPrint&Scan / BR-Receipts, since they lock the scanner.
2. Build and install:
   ```bash
   ./build.sh
   ```
3. Plug in the scanner. A window and notification appear. Feed a sheet and it's saved (default `~/Documents/Scans`, 300 dpi, PDF).

The window lets you change folder, resolution, format (PDF/JPEG/PNG/TIFF), JPEG quality, color and auto-crop, shows a thumbnail of the last capture, and lists every capture (double-click to reveal in Finder). Scans are taken as lossless TIFF, cropped to the paper (removes the gray scanner background and the white padding below the scan area), and only then encoded to your chosen format. Settings persist. It auto-starts at login.

Headless alternative: `swiftc -O cli/autoscan.swift -o autoscan && ./autoscan --dir ~/Scans --dpi 300 --format pdf`

## Duplicates and stored OCR
Every scan is OCR'd once (Apple Vision) and the full result - every line with its box, confidence and orientation, plus perceptual hashes - is stored in a central store at `~/Library/Application Support/AutoScan/` keyed by the file's SHA-256 (`ocr/<sha>.json`, `index.json`). It survives renames/moves and is there for receipt processing later.

Menu bar > **Find Duplicates...** opens a review window: groups as thumbnails, per-file match reason, checkboxes (exact/high-confidence copies pre-selected, the largest file is kept), per-group and global "Move to Trash". Nothing is deleted; files go to the Trash. A new scan that matches an existing one triggers a notification.

Matching (see `app/Dup.swift`): SHA-256 for exact copies; OCR text containment with exact number matching (so two receipts from the same shop do not merge) plus 4-orientation perceptual hash for resized/re-compressed/rotated/cropped copies. `bench/main.swift` builds variants of real scans plus look-alike negatives and checks nothing is wrongly merged:
`swiftc -O bench/main.swift app/Crop.swift app/Dup.swift -o dupbench && ./dupbench scan1.jpg scan2.jpg`

## How it works
The DS-640 exposes only vendor-specific USB interfaces, but Brother's ICA driver makes it a standard ImageCaptureCore scanner. The app opens it, selects the document feeder, and requests a scan about once a second.

- `app/` - AutoScan.app (AppKit); `Crop.swift` is the content-crop (background colour = most common non-white colour, foreground bounding box)
- `cli/autoscan.swift` - command-line version
- `build.sh` - build, ad-hoc sign, install LaunchAgent (`~/Library/Logs/autoscan.log`)

## Gotchas
- ICA error -47 "busy": another app holds the scanner.
- `documentLoaded` is always true. An empty feeder returns ICA error -9933, which the app treats as "keep waiting".

## License
MIT - see [LICENSE](LICENSE).
