// autoscan: feed a sheet into the Brother DS-640 -> it is scanned straight into a folder.
// Usage: autoscan [--dir ~/Documents/Scans] [--dpi 300] [--color|--gray|--bw] [--format pdf|jpeg|png|tiff]
import Foundation
import ImageCaptureCore

var dir = NSString(string: "~/Documents/Scans").expandingTildeInPath
var dpi = 300, fmt = "pdf", pix = ICScannerPixelDataType.RGB
var a = Array(CommandLine.arguments.dropFirst())
while !a.isEmpty {
  switch a.removeFirst() {
  case "--dir": dir = NSString(string: a.removeFirst()).expandingTildeInPath
  case "--dpi": dpi = Int(a.removeFirst()) ?? 300
  case "--format": fmt = a.removeFirst()
  case "--gray": pix = .gray
  case "--bw": pix = .BW
  default: break
  }
}
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let uti = ["pdf": "com.adobe.pdf", "jpeg": "public.jpeg", "png": "public.png", "tiff": "public.tiff"][fmt] ?? "com.adobe.pdf"
func log(_ s: String) { print("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(s)"); fflush(stdout) }

class App: NSObject, ICDeviceBrowserDelegate, ICScannerDeviceDelegate {
  var scanner: ICScannerDevice?
  var feeder: ICScannerFunctionalUnitDocumentFeeder?
  var scanning = false
  var emptyFeeder = false
  var obs: NSKeyValueObservation?
  var poll: Timer?

  func deviceBrowser(_ b: ICDeviceBrowser, didAdd d: ICDevice, moreComing: Bool) {
    guard let s = d as? ICScannerDevice else { return }
    log("Scanner found: \(s.name ?? "?")"); scanner = s; s.delegate = self; s.requestOpenSession()
  }
  func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) { log("Scanner unplugged"); poll?.invalidate(); scanner = nil; feeder = nil }
  func didRemove(_ d: ICDevice) {}
  func device(_ d: ICDevice, didOpenSessionWithError e: Error?) { if let e = e { log("open error: \(e) - exiting so launchd retries"); exit(1) } }
  func device(_ d: ICDevice, didCloseSessionWithError e: Error?) {}
  func deviceDidBecomeReady(_ d: ICDevice) {
    guard let s = d as? ICScannerDevice else { return }
    s.requestSelect(.documentFeeder)
  }
  func scannerDevice(_ s: ICScannerDevice, didSelect fu: ICScannerFunctionalUnit, error: Error?) {
    guard let f = fu as? ICScannerFunctionalUnitDocumentFeeder else { log("feeder unavailable: \(String(describing: error))"); return }
    feeder = f
    f.measurementUnit = .inches
    f.documentType = .typeA4
    f.resolution = f.supportedResolutions.integerGreaterThanOrEqualTo(dpi) ?? 300
    f.pixelDataType = pix
    f.bitDepth = .depth8Bits
    f.duplexScanningEnabled = false
    f.scanArea = NSRect(origin: .zero, size: f.physicalSize)
    log("feeder physicalSize=\(f.physicalSize) scanArea=\(f.scanArea) loaded=\(f.documentLoaded) types=\(f.supportedDocumentTypes.count)")
    s.transferMode = .fileBased
    s.downloadsDirectory = URL(fileURLWithPath: dir)
    s.documentUTI = uti
    log("Ready. Feed a sheet. -> \(dir)  (\(f.resolution) dpi, \(fmt))")
    poll = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.tick() }
  }
  func tick() {
    guard let s = scanner, feeder != nil, !scanning else { return }
    scanning = true
    s.documentName = "scan-" + { let d = DateFormatter(); d.dateFormat = "yyyyMMdd-HHmmss"; return d.string(from: Date()) }()
    s.requestScan()
  }
  func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL) { log("Saved \(url.path)") }
  func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL, data: Data?) { log("Saved(data) \(url.path) bytes=\(data?.count ?? -1)") }
  func scannerDevice(_ s: ICScannerDevice, didReceiveStatusInformation st: [String: Any]) { log("status: \(st)") }
  func device(_ d: ICDevice, didEncounterError e: Error?) { if (e as NSError?)?.code == -9933 { emptyFeeder = true; return }; log("device error: \(String(describing: e))") }
  func scannerDevice(_ s: ICScannerDevice, didScanTo url: URL, data: Data?, error: Error?) { log("Saved(err) \(url.path) \(String(describing: error))") }
  func scannerDevice(_ s: ICScannerDevice, didCompleteScanWithError e: Error?) {
    if emptyFeeder { emptyFeeder = false } else { log("scan complete, error: \(String(describing: e))") }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.scanning = false }
  }
  func scannerDevice(_ s: ICScannerDevice, didReceiveButtonPress b: String) { log("Button: \(b)"); tick() }
}

let app = App(); let browser = ICDeviceBrowser(); browser.delegate = app
browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
browser.start(); log("Waiting for scanner...")
RunLoop.main.run()
