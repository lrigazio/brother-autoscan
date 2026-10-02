import Cocoa
import ImageCaptureCore
import PDFKit
import UniformTypeIdentifiers

let defaults = UserDefaults.standard
func notify(_ title: String, _ body: String) {
  func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
  let p = Process(); p.launchPath = "/usr/bin/osascript"
  p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
  try? p.run()
}
let formats: [(String, String)] = [("PDF", "com.adobe.pdf"), ("JPEG", "public.jpeg"), ("PNG", "public.png"), ("TIFF", "public.tiff")]
let colors: [(String, ICScannerPixelDataType)] = [("Color", .RGB), ("Gray", .gray), ("Black & White", .BW)]
let dpis = [150, 200, 300, 600]
let jpegQualities = [70, 80, 90, 95, 100]
let rawDir = NSTemporaryDirectory() + "autoscan-raw"

func encode(_ img: CGImage, to url: URL, format: Int, quality: Int, dpi: Int) -> Bool {
  if format == 0 {   // PDF: page size in points = pixels * 72 / dpi
    let ns = NSImage(cgImage: img, size: NSSize(width: Double(img.width) * 72 / Double(dpi), height: Double(img.height) * 72 / Double(dpi)))
    guard let page = PDFPage(image: ns) else { return false }
    let doc = PDFDocument(); doc.insert(page, at: 0); return doc.write(to: url)
  }
  let type = [nil, UTType.jpeg, UTType.png, UTType.tiff][format]!
  guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
  var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
  if format == 1 { props[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100 }
  CGImageDestinationAddImage(d, img, props as CFDictionary)
  return CGImageDestinationFinalize(d)
}

class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
           ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
  var win: NSWindow!
  var folderLabel = NSTextField(labelWithString: "")
  var statusLabel = NSTextField(labelWithString: "Waiting for scanner...")
  var dpiPop = NSPopUpButton(), fmtPop = NSPopUpButton(), colPop = NSPopUpButton(), qPop = NSPopUpButton()
  var cropBox = NSButton(checkboxWithTitle: "Auto-crop to content", target: nil, action: nil)
  var thumb = NSImageView()
  var seen = Set<String>()
  var qLabel = NSTextField()
  var table = NSTableView()
  var files: [String] = []
  var browser = ICDeviceBrowser()
  var scanner: ICScannerDevice?, feeder: ICScannerFunctionalUnitDocumentFeeder?
  var scanning = false, emptyFeeder = false
  var poll: Timer?

  var dir: String {
    get { defaults.string(forKey: "dir") ?? NSString("~/Documents/Scans").expandingTildeInPath }
    set { defaults.set(newValue, forKey: "dir") }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    buildWindow()
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
    browser.start()
  }
  func windowShouldClose(_ s: NSWindow) -> Bool { s.orderOut(nil); return false }

  func buildWindow() {
    win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    win.title = "AutoScan - Brother DS-640"; win.delegate = self; win.isReleasedWhenClosed = false
    let v = win.contentView!
    @discardableResult func label(_ s: String, _ y: CGFloat) -> NSTextField { let l = NSTextField(labelWithString: s); l.frame = NSRect(x: 16, y: y, width: 80, height: 20); v.addSubview(l); return l }
    statusLabel.frame = NSRect(x: 16, y: 364, width: 488, height: 20); statusLabel.font = .boldSystemFont(ofSize: 13); v.addSubview(statusLabel)
    label("Folder", 332)
    folderLabel.frame = NSRect(x: 96, y: 332, width: 310, height: 20); folderLabel.lineBreakMode = .byTruncatingHead; v.addSubview(folderLabel)
    let ch = NSButton(title: "Change...", target: self, action: #selector(chooseDir)); ch.frame = NSRect(x: 414, y: 326, width: 90, height: 28); v.addSubview(ch)
    label("Resolution", 298); dpiPop.frame = NSRect(x: 96, y: 294, width: 100, height: 26)
    dpiPop.addItems(withTitles: dpis.map { "\($0) dpi" }); dpiPop.selectItem(at: dpis.firstIndex(of: defaults.integer(forKey: "dpi")) ?? 2); v.addSubview(dpiPop)
    label("Format", 266); fmtPop.frame = NSRect(x: 96, y: 262, width: 100, height: 26)
    fmtPop.addItems(withTitles: formats.map { $0.0 }); fmtPop.selectItem(at: defaults.integer(forKey: "fmt")); v.addSubview(fmtPop)
    label("Color", 234); colPop.frame = NSRect(x: 96, y: 230, width: 130, height: 26)
    colPop.addItems(withTitles: colors.map { $0.0 }); colPop.selectItem(at: defaults.integer(forKey: "col")); v.addSubview(colPop)
    qLabel = label("JPEG quality", 202); qPop.frame = NSRect(x: 96, y: 198, width: 100, height: 26)
    qPop.addItems(withTitles: jpegQualities.map { "\($0)%" }); qPop.selectItem(at: jpegQualities.firstIndex(of: defaults.integer(forKey: "q")) ?? 2); v.addSubview(qPop)
    cropBox.frame = NSRect(x: 250, y: 296, width: 200, height: 22); cropBox.state = defaults.object(forKey: "crop") == nil || defaults.bool(forKey: "crop") ? .on : .off; v.addSubview(cropBox)
    thumb.frame = NSRect(x: 374, y: 164, width: 130, height: 126); thumb.imageScaling = .scaleProportionallyUpOrDown
    thumb.wantsLayer = true; thumb.layer?.borderWidth = 1; thumb.layer?.borderColor = NSColor.separatorColor.cgColor; v.addSubview(thumb)
    for p in [dpiPop, fmtPop, colPop, qPop] { p.target = self; p.action = #selector(saveSettings) }
    cropBox.target = self; cropBox.action = #selector(saveSettings); updateQuality()
    let col = NSTableColumn(identifier: .init("f")); col.title = "Captured (double-click to reveal)"; col.width = 470
    table.addTableColumn(col); table.dataSource = self; table.delegate = self; table.allowsEmptySelection = true; table.doubleAction = #selector(reveal); table.target = self
    let sv = NSScrollView(frame: NSRect(x: 16, y: 16, width: 488, height: 140)); sv.documentView = table; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder; v.addSubview(sv)
    folderLabel.stringValue = dir
    win.center()
  }
  func updateQuality() { let j = fmtPop.indexOfSelectedItem == 1; qPop.isHidden = !j; qLabel.isHidden = !j }
  @objc func saveSettings() {
    updateQuality()
    defaults.set(dpis[dpiPop.indexOfSelectedItem], forKey: "dpi"); defaults.set(fmtPop.indexOfSelectedItem, forKey: "fmt"); defaults.set(colPop.indexOfSelectedItem, forKey: "col")
    defaults.set(jpegQualities[qPop.indexOfSelectedItem], forKey: "q"); defaults.set(cropBox.state == .on, forKey: "crop")
  }
  @objc func chooseDir() {
    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
    p.directoryURL = URL(fileURLWithPath: dir)
    NSApp.activate(ignoringOtherApps: true)
    if p.runModal() == .OK, let u = p.url { dir = u.path; folderLabel.stringValue = dir }
  }
  @objc func reveal() { let r = table.clickedRow; if r >= 0 { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: files[r])]) } }
  func tableViewSelectionDidChange(_ n: Notification) { let r = table.selectedRow; if r >= 0 { thumb.image = NSImage(contentsOfFile: files[r]) } }
  func numberOfRows(in t: NSTableView) -> Int { files.count }
  func tableView(_ t: NSTableView, objectValueFor c: NSTableColumn?, row: Int) -> Any? { files[row] }
  func addFile(_ path: String, note: String) {
    files.insert(path, at: 0); table.reloadData(); thumb.image = NSImage(contentsOfFile: path)
    statusLabel.stringValue = "Saved \(URL(fileURLWithPath: path).lastPathComponent) (\(note))"
    notify("Scan saved", path)
  }
  /// raw lossless scan -> crop -> encode final file
  func process(raw: URL) {
    guard seen.insert(raw.path).inserted else { return }
    let fmt = fmtPop.indexOfSelectedItem, q = jpegQualities[qPop.indexOfSelectedItem], dpi = dpis[dpiPop.indexOfSelectedItem]
    let crop = cropBox.state == .on, outDir = dir
    let name = raw.deletingPathExtension().lastPathComponent
    DispatchQueue.global().async {
      var result: (String, String)?
      if let src = CGImageSourceCreateWithURL(raw as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        var out = img, note = "not cropped"
        if crop, let c = autoCrop(img) { out = c.image; note = "cropped \(img.width)x\(img.height) -> \(out.width)x\(out.height)" }
        let ext = ["pdf", "jpg", "png", "tiff"][fmt]
        let dest = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).\(ext)")
        if encode(out, to: dest, format: fmt, quality: q, dpi: dpi) { result = (dest.path, note) }
      }
      try? FileManager.default.removeItem(at: raw)
      DispatchQueue.main.async {
        if let (p, n) = result { self.addFile(p, note: n) } else { self.statusLabel.stringValue = "Error: could not process scan" }
      }
    }
  }

  // MARK: scanner
  func deviceBrowser(_ b: ICDeviceBrowser, didAdd d: ICDevice, moreComing: Bool) {
    guard let s = d as? ICScannerDevice else { return }
    scanner = s; s.delegate = self; s.requestOpenSession()
  }
  func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) {
    poll?.invalidate(); scanner = nil; feeder = nil; statusLabel.stringValue = "Scanner unplugged"; win.orderOut(nil)
  }
  func didRemove(_ d: ICDevice) {}
  func device(_ d: ICDevice, didOpenSessionWithError e: Error?) {
    if e != nil {
      statusLabel.stringValue = "Scanner busy (another app has it) - retrying"
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(1) }
    }
  }
  func device(_ d: ICDevice, didCloseSessionWithError e: Error?) {}
  func deviceDidBecomeReady(_ d: ICDevice) { (d as? ICScannerDevice)?.requestSelect(.documentFeeder) }
  func scannerDevice(_ s: ICScannerDevice, didSelect fu: ICScannerFunctionalUnit, error: Error?) {
    guard let f = fu as? ICScannerFunctionalUnitDocumentFeeder else { return }
    feeder = f; f.measurementUnit = .inches; f.documentType = .typeA4; f.bitDepth = .depth8Bits; f.duplexScanningEnabled = false
    f.scanArea = NSRect(origin: .zero, size: f.physicalSize); s.transferMode = .fileBased
    statusLabel.stringValue = "Ready - feed a sheet"
    win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    notify("AutoScan started", "\(dpis[dpiPop.indexOfSelectedItem]) dpi, \(formats[fmtPop.indexOfSelectedItem].0) -> \(dir)")
    poll?.invalidate(); poll = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.tick() }
  }
  func tick() {
    guard let s = scanner, let f = feeder, !scanning else { return }
    scanning = true
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: rawDir, withIntermediateDirectories: true)
    f.resolution = f.supportedResolutions.integerGreaterThanOrEqualTo(dpis[dpiPop.indexOfSelectedItem]) ?? 300
    f.pixelDataType = colors[colPop.indexOfSelectedItem].1
    s.downloadsDirectory = URL(fileURLWithPath: rawDir); s.documentUTI = UTType.tiff.identifier   // lossless raw; encoded after cropping
    let d = DateFormatter(); d.dateFormat = "yyyyMMdd-HHmmss"; s.documentName = "scan-" + d.string(from: Date())
    s.requestScan()
  }
  func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL) { process(raw: url) }
  func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL, data: Data?) { process(raw: url) }
  func device(_ d: ICDevice, didEncounterError e: Error?) {
    if (e as NSError?)?.code == -9933 { emptyFeeder = true; return }
    statusLabel.stringValue = "Error: \(e?.localizedDescription ?? "unknown")"
  }
  func scannerDevice(_ s: ICScannerDevice, didCompleteScanWithError e: Error?) {
    emptyFeeder = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.scanning = false }
  }
}

let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let delegate = App(); app.delegate = delegate; app.run()
