import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Is this a bad scan (feed glitch: smeared / stretched paper, partial or mangled content, washed out, blank)?
/// Image metrics plus what the stored OCR saw. Bad scans are handled before, and apart from, duplicate matching.
struct ScanQuality: Codable {
  var inkFrac: Double        // share of pixels that are ink
  var contrast: Double       // background level minus the darkest 1% (0...255)
  var streakFrac: Double     // share of text-like blocks (barcodes excluded) that are stretched: edges only horizontal, nothing vertical
  var unexplained: Double    // share of ink that is neither in a recognized text line nor in a barcode
  var ocrConf: Double        // average OCR line confidence (0...1)
  var ocrLines: Int
  var severity: Int          // 0 fine, 1 suspicious, 2 bad
  var reasons: [String]
}
let qualityVersion = 3

private func barcodeBoxes(_ img: CGImage) -> [CGRect] {   // normalized, top-left origin
  let req = VNDetectBarcodesRequest()
  try? VNImageRequestHandler(cgImage: img, orientation: .up).perform([req])
  return (req.results ?? []).map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
}

func analyzeQuality(_ img: CGImage, rec: DocRec?) -> ScanQuality {
  var content = autoCrop(img)?.image ?? img
  if let p = rec?.pages.first, let o = CGImagePropertyOrientation(rawValue: p.orientation) { content = rotated(content, o) }   // same frame as the stored OCR boxes
  let sc = min(1.0, 900.0 / Double(max(content.width, content.height)))
  let w = max(48, Int(Double(content.width) * sc)), h = max(48, Int(Double(content.height) * sc))
  let px = grayPixels(content, w, h)
  let sorted = px.sorted()
  let bg = Double(sorted[Int(Double(sorted.count - 1) * 0.9)]), dark = Double(sorted[Int(Double(sorted.count - 1) * 0.01)])
  let contrast = bg - dark
  let thr = Float(bg * 0.6)

  // regions explained by OCR lines and barcodes
  var cover = [Bool](repeating: false, count: w * h), barcode = [Bool](repeating: false, count: w * h)
  func mark(_ a: inout [Bool], _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
    let ax = max(0, Int(x0 * Double(w))), bx = min(w, Int(x1 * Double(w)) + 1), ay = max(0, Int(y0 * Double(h))), by = min(h, Int(y1 * Double(h)) + 1)
    if ax < bx && ay < by { for y in ay..<by { for x in ax..<bx { a[y * w + x] = true } } }
  }
  if let p = rec?.pages.first { for l in p.lines { mark(&cover, l.x - 0.012, l.y - 0.35 * l.h, l.x + l.w + 0.012, l.y + 1.35 * l.h) } }
  for b in barcodeBoxes(content) { mark(&cover, b.minX - 0.01, b.minY - 0.01, b.maxX + 0.01, b.maxY + 0.01); mark(&barcode, b.minX - 0.02, b.minY - 0.02, b.maxX + 0.02, b.maxY + 0.02) }

  var ink = 0, free = 0
  for i in 0..<(w * h) where px[i] < thr { ink += 1; if !cover[i] { free += 1 } }
  let inkFrac = Double(ink) / Double(w * h), unexplained = ink > 0 ? Double(free) / Double(ink) : 0

  // stretched blocks: strong horizontal change, almost no vertical change (outside barcodes)
  let B = 40; var inkBlocks = 0, streak = 0
  for by in stride(from: 0, to: h - B, by: B) { for bx in stride(from: 0, to: w - B, by: B) {
    if barcode[(by + B / 2) * w + bx + B / 2] { continue }
    var gx: Float = 0, gy: Float = 0, n = 0
    for y in by..<(by + B - 1) { for x in bx..<(bx + B - 1) {
      let v = px[y * w + x]; if v < thr { n += 1 }
      gx += abs(px[y * w + x + 1] - v); gy += abs(px[(y + 1) * w + x] - v)
    } }
    if n > B * B / 50 && n < B * B * 9 / 10 { inkBlocks += 1; if gx > 6 * (gy + 1) && gx > 600 { streak += 1 } }
  } }
  let streakFrac = inkBlocks >= 6 ? Double(streak) / Double(inkBlocks) : 0

  var conf = 0.0, lines = 0
  if let p = rec?.pages.first, !p.lines.isEmpty { lines = p.lines.count; conf = p.lines.map { Double($0.conf) }.reduce(0, +) / Double(lines) }

  // Vision reports lower confidence for CJK, Thai, Arabic... even when it reads them correctly, so confidence is only trusted for Latin text
  let chars = (rec?.pages.first?.lines ?? []).flatMap { Array($0.text.unicodeScalars) }.filter { $0.properties.isAlphabetic }
  let nonLatin = chars.isEmpty ? 0.0 : Double(chars.filter { $0.value >= 0x0590 }.count) / Double(chars.count)
  let trustConf = nonLatin < 0.15
  var reasons = [String](), sev = 0
  let poorText = rec != nil && (trustConf ? (lines < 12 && conf < 0.8) : lines < 8)   // OCR found little, or little that it trusts
  if rec != nil && lines < 2 { reasons.append(inkFrac < 0.003 ? "blank page" : "no readable text (washed out, or content missing)"); sev = 2 }
  if poorText && streakFrac >= 0.15 { reasons.append(String(format: "smeared / stretched (%.0f%% of the text area) - feed glitch", streakFrac * 100)); sev = 2 }
  if poorText && unexplained >= 0.35 && inkFrac > 0.01 { reasons.append(String(format: "mangled or partial (%.0f%% of the ink is not readable text, %d lines read)", unexplained * 100, lines)); sev = 2 }
  if sev == 0 && rec != nil && inkFrac > 0.03 && (lines < 3 || (trustConf && conf < 0.45)) { reasons.append(String(format: "text barely readable (%d lines, %.0f%% confidence)", lines, conf * 100)); sev = 1 }
  return ScanQuality(inkFrac: inkFrac, contrast: contrast, streakFrac: streakFrac, unexplained: unexplained, ocrConf: conf, ocrLines: lines, severity: sev, reasons: reasons)
}

extension Store {
  var qualDir: URL { root.appendingPathComponent("quality") }
  func quality(_ sha: String) -> ScanQuality? {
    guard let d = try? Data(contentsOf: qualDir.appendingPathComponent("\(sha)-v\(qualityVersion).json")) else { return nil }
    return try? JSONDecoder().decode(ScanQuality.self, from: d)
  }
  func saveQuality(_ q: ScanQuality, _ sha: String) {
    try? FileManager.default.createDirectory(at: qualDir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(q) { try? d.write(to: qualDir.appendingPathComponent("\(sha)-v\(qualityVersion).json")) }
  }
}

extension DupEngine {
  /// Quality for every doc (cached by content hash). Returns path -> quality.
  func qualities(_ docs: [Doc]) -> [String: ScanQuality] {
    var out = [String: ScanQuality](); let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: docs.count) { i in
      let d = docs[i]
      var q = Store.shared.quality(d.rec.sha)
      if q == nil, let img = loadPageImages(URL(fileURLWithPath: d.path), maxPixel: 1800, maxPages: 1).first {
        q = analyzeQuality(img, rec: d.rec); Store.shared.saveQuality(q!, d.rec.sha)
      }
      if let q = q { lock.lock(); out[d.path] = q; lock.unlock() }
    }
    return out
  }
}
