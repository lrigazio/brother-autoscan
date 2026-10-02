import Cocoa
import ImageCaptureCore

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

class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
           ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
  var win: NSWindow!
  var folderLabel = NSTextField(labelWithString: "")
  var statusLabel = NSTextField(labelWithString: "Waiting for scanner...")
  var dpiPop = NSPopUpButton(), fmtPop = NSPopUpButton(), colPop = NSPopUpButton()
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
    func label(_ s: String, _ y: CGFloat) { let l = NSTextField(labelWithString: s); l.frame = NSRect(x: 16, y: y, width: 80, height: 20); v.addSubview(l) }
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
    for p in [dpiPop, fmtPop, colPop] { p.target = self; p.action = #selector(saveSettings) }
    let col = NSTableColumn(identifier: .init("f")); col.title = "Captured (double-click to reveal)"; col.width = 470
    table.addTableColumn(col); table.dataSource = self; table.delegate = self; table.doubleAction = #selector(reveal); table.target = self
    let sv = NSScrollView(frame: NSRect(x: 16, y: 16, width: 488, height: 200)); sv.documentView = table; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder; v.addSubview(sv)
    folderLabel.stringValue = dir
    win.center()
  }
  @objc func saveSettings() {
    defaults.set(dpis[dpiPop.indexOfSelectedItem], forKey: "dpi"); defaults.set(fmtPop.indexOfSelectedItem, forKey: "fmt"); defaults.set(colPop.indexOfSelectedItem, forKey: "col")
  }
  @objc func chooseDir() {
    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
    p.directoryURL = URL(fileURLWithPath: dir)
    NSApp.activate(ignoringOtherApps: true)
    if p.runModal() == .OK, let u = p.url { dir = u.path; folderLabel.stringValue = dir }
  }
  @objc func reveal() { let r = table.clickedRow; if r >= 0 { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: files[r])]) } }
  func numberOfRows(in t: NSTableView) -> Int { files.count }
  func tableView(_ t: NSTableView, objectValueFor c: NSTableColumn?, row: Int) -> Any? { files[row] }
  func addFile(_ path: String) {
    guard !files.contains(path) else { return }
    files.insert(path, at: 0); table.reloadData()
    statusLabel.stringValue = "Saved \(URL(fileURLWithPath: path).lastPathComponent)"
    notify("Scan saved", path)
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
    f.resolution = f.supportedResolutions.integerGreaterThanOrEqualTo(dpis[dpiPop.indexOfSelectedItem]) ?? 300
    f.pixelDataType = colors[colPop.indexOfSelectedItem].1
    s.downloadsDirectory = URL(fileURLWithPath: dir); s.documentUTI = formats[fmtPop.indexOfSelectedItem].1
    let d = DateFormatter(); d.dateFormat = "yyyyMMdd-HHmmss"; s.documentName = "scan-" + d.string(from: Date())
    s.requestScan()
  }
  func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL) { addFile(url.path) }
  func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL, data: Data?) { addFile(url.path) }
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
