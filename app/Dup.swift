import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import CryptoKit
import AppKit

// MARK: - Stored records (central store, keyed by SHA-256 of the file)

/// One recognized line of text. Box is normalized (0...1) in the upright image, origin top-left.
struct OCRLine: Codable { var text: String; var x: Double; var y: Double; var w: Double; var h: Double; var conf: Float }
struct PageRec: Codable {
  var w: Int; var h: Int                 // size of the (cropped, upright) page image in pixels
  var orientation: UInt32                // CGImagePropertyOrientation OCR needed (1 = already upright)
  var hashes: [UInt64]                   // pHash at 0/90/180/270 degrees
  var lines: [OCRLine]
}
struct DocRec: Codable { var sha: String; var ocrVersion: Int; var created: Double; var pages: [PageRec] }
struct IndexEntry: Codable { var size: Int; var mtime: Double; var sha: String }
let ocrVersion = 2     // 2: multi-language OCR (es, tr, it, ja, fr, de, pt, zh)

final class Store {
  static let shared = Store()
  let root: URL, recDir: URL, indexURL: URL
  var index: [String: IndexEntry] = [:]
  let lock = NSLock()
  init() {
    if let o = ProcessInfo.processInfo.environment["AUTOSCAN_STORE"] { root = URL(fileURLWithPath: o) }   // tests use a scratch store
    else { root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AutoScan") }
    recDir = root.appendingPathComponent("ocr")
    indexURL = root.appendingPathComponent("index.json")
    try? FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
    if let d = try? Data(contentsOf: indexURL), let i = try? JSONDecoder().decode([String: IndexEntry].self, from: d) { index = i }
  }
  func rec(_ sha: String) -> DocRec? {
    guard let d = try? Data(contentsOf: recDir.appendingPathComponent(sha + ".json")), let r = try? JSONDecoder().decode(DocRec.self, from: d),
          r.ocrVersion == ocrVersion else { return nil }
    return r
  }
  func save(_ r: DocRec) {
    if let d = try? JSONEncoder().encode(r) { try? d.write(to: recDir.appendingPathComponent(r.sha + ".json")) }
  }
  func entry(_ path: String) -> IndexEntry? { lock.lock(); defer { lock.unlock() }; return index[path] }
  func setEntry(_ path: String, _ e: IndexEntry) { lock.lock(); index[path] = e; lock.unlock() }
  func saveIndex(keeping paths: Set<String>? = nil) {
    lock.lock(); if let p = paths { index = index.filter { p.contains($0.key) } }
    let d = try? JSONEncoder().encode(index); lock.unlock()
    if let d = d { try? d.write(to: indexURL) }
  }
  /// Register a file we just wrote together with the OCR we already have for it.
  func register(path: String, rec: DocRec) {
    save(rec)
    let a = try? FileManager.default.attributesOfItem(atPath: path)
    setEntry(path, IndexEntry(size: (a?[.size] as? Int) ?? 0, mtime: (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, sha: rec.sha))
    saveIndex()
  }
}

enum Tier: Int, Comparable {
  case possible = 0, duplicate = 1, exact = 2
  static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
  var label: String { ["Possible duplicate", "Duplicate", "Exact copy"][rawValue] }
}
struct Match { var tier: Tier; var score: Double; var reason: String }

struct Doc {
  let path: String, size: Int, mtime: Double, rec: DocRec
  let tokens: [Set<String>], nums: [Set<String>]
  init(path: String, size: Int, mtime: Double, rec: DocRec) {
    self.path = path; self.size = size; self.mtime = mtime; self.rec = rec
    let toks = rec.pages.map { Set(tokenize($0.lines.map { $0.text }.joined(separator: " "))) }
    tokens = toks
    nums = toks.map { $0.filter { $0.count >= 3 && $0.rangeOfCharacter(from: .decimalDigits) != nil } }
  }
}
/// links[i] = direct comparison of members[i] against the keeper (members[0]); nil for the keeper itself or when only linked through another copy.
struct DupGroup { var tier: Tier; var members: [Doc]; var keeper: Int; var reason: String; var links: [Match?] }

// MARK: - Image loading, hashing, OCR

func loadPageImages(_ url: URL, maxPixel: Int = 3200, maxPages: Int = 12) -> [CGImage] {
  if url.pathExtension.lowercased() == "pdf" {
    guard let doc = PDFDocument(url: url) else { return [] }
    var out = [CGImage]()
    for i in 0..<min(doc.pageCount, maxPages) {
      guard let p = doc.page(at: i) else { continue }
      let b = p.bounds(for: .mediaBox); guard b.width > 0, b.height > 0 else { continue }
      let sc = CGFloat(maxPixel) / max(b.width, b.height)
      let ns = p.thumbnail(of: NSSize(width: b.width * sc, height: b.height * sc), for: .mediaBox)
      var r = CGRect(origin: .zero, size: ns.size)
      if let cg = ns.cgImage(forProposedRect: &r, context: nil, hints: nil) { out.append(cg) }
    }
    return out
  }
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
  let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                               kCGImageSourceThumbnailMaxPixelSize: maxPixel]
  return (0..<min(CGImageSourceGetCount(src), maxPages)).compactMap { CGImageSourceCreateThumbnailAtIndex(src, $0, opts as CFDictionary) }
}

func grayPixels(_ img: CGImage, _ w: Int, _ h: Int) -> [Float] {
  var buf = [UInt8](repeating: 0, count: w * h)
  buf.withUnsafeMutableBytes { p in
    guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  return buf.map { Float($0) }
}

private let dctN = 32
private let cosT: [[Float]] = {
  var t = [[Float]]()
  for u in 0..<8 {
    var row = [Float]()
    for x in 0..<dctN {
      let a: Double = (2.0 * Double(x) + 1.0) * Double(u)
      row.append(Float(cos(a * Double.pi / Double(2 * dctN))))
    }
    t.append(row)
  }
  return t
}()
private func pHash(_ px: [Float]) -> UInt64 {
  var c = [Float](repeating: 0, count: 64)
  for u in 0..<8 { for v in 0..<8 {
    var s: Float = 0
    for y in 0..<dctN { let cy = cosT[u][y]; for x in 0..<dctN { s += px[y * dctN + x] * cosT[v][x] * cy } }
    c[u * 8 + v] = s
  } }
  let med = c.dropFirst().sorted()[31]
  var h: UInt64 = 0
  for i in 1..<64 where c[i] > med { h |= 1 << UInt64(i) }
  return h
}
private func rot90(_ p: [Float]) -> [Float] {
  var o = p
  for y in 0..<dctN { for x in 0..<dctN { o[y * dctN + x] = p[(dctN - 1 - x) * dctN + y] } }
  return o
}
func rotationHashes(_ img: CGImage) -> [UInt64] {
  var p = grayPixels(img, dctN, dctN), out = [UInt64]()
  for _ in 0..<4 { out.append(pHash(p)); p = rot90(p) }
  return out
}

/// Rotate so that an image Vision reads best with orientation `o` becomes upright.
func rotated(_ img: CGImage, _ o: CGImagePropertyOrientation) -> CGImage {
  guard o == .right || o == .left || o == .down else { return img }
  let w = img.width, h = img.height, swap = o != .down
  let nw = swap ? h : w, nh = swap ? w : h
  guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
  switch o {
  case .right: ctx.translateBy(x: 0, y: CGFloat(w)); ctx.rotate(by: -.pi / 2)        // 90 clockwise
  case .left:  ctx.translateBy(x: CGFloat(h), y: 0); ctx.rotate(by: .pi / 2)         // 90 counter-clockwise
  default:     ctx.translateBy(x: CGFloat(w), y: CGFloat(h)); ctx.rotate(by: .pi)    // 180
  }
  ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  return ctx.makeImage() ?? img
}

private let moneyRE = try! NSRegularExpression(pattern: #"\d{1,3}(?:[.,]\d{3})+(?:[.,]\d{2})?|\d+[.,]\d{2}(?!\d)"#)
private let dateRE = try! NSRegularExpression(pattern: #"(?<![\d/.-])\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}(?![\d])"#)
private let cjkDateRE = try! NSRegularExpression(pattern: #"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日"#)
private let yenRE = try! NSRegularExpression(pattern: #"(\d[\d,]*)\s*円"#)
private let timeRE = try! NSRegularExpression(pattern: #"(?<!\d)\d{1,2}:\d{2}(?::\d{2})?(?!\d)"#)

/// Words and numbers, plus whole amounts ("$4266"), dates ("@3/21/25") and times ("~21:33"). Those carry
/// the receipt's identity, unlike street numbers and phone digits that repeat on every receipt of a shop.
func tokenize(_ s: String) -> [String] {
  let f = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
  var out = f.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
  let r = NSRange(f.startIndex..., in: f), ns = f as NSString
  for m in moneyRE.matches(in: f, range: r) { out.append("$" + ns.substring(with: m.range).filter { $0.isNumber }) }
  for m in dateRE.matches(in: f, range: r) {
    let parts = ns.substring(with: m.range).components(separatedBy: CharacterSet(charactersIn: "/.-")).map { String(Int($0) ?? 0) }
    out.append("@" + parts.joined(separator: "/"))
  }
  for m in cjkDateRE.matches(in: f, range: r) { out.append("@" + (1...3).map { String(Int(ns.substring(with: m.range(at: $0))) ?? 0) }.joined(separator: "/")) }
  for m in yenRE.matches(in: f, range: r) { out.append("$" + ns.substring(with: m.range(at: 1)).filter { $0.isNumber }) }
  for m in timeRE.matches(in: f, range: r) { out.append("~" + ns.substring(with: m.range)) }
  return out
}

/// OCR with orientation detection. Returns lines (upright-image coordinates) and the orientation that worked.
func recognizeLines(_ original: CGImage) -> (lines: [OCRLine], orientation: CGImagePropertyOrientation) {
  // low-res scans OCR badly: upscale small images first (boxes are normalized, so this is invisible downstream)
  var img = original
  let big = max(original.width, original.height)
  if big < 1800, let c = CGContext(data: nil, width: Int(Double(original.width) * min(3, 1800.0 / Double(big))), height: Int(Double(original.height) * min(3, 1800.0 / Double(big))),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
    c.interpolationQuality = .high; c.draw(original, in: CGRect(x: 0, y: 0, width: c.width, height: c.height)); img = c.makeImage() ?? original
  }
  func run(_ o: CGImagePropertyOrientation) -> ([OCRLine], Float) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate; req.usesLanguageCorrection = false
    if let langs = try? req.supportedRecognitionLanguages() {
      let want = ["en-US", "es-ES", "tr-TR", "it-IT", "ja-JP", "fr-FR", "de-DE", "pt-BR", "zh-Hans"].filter { langs.contains($0) }
      if !want.isEmpty { req.recognitionLanguages = want }
    }
    if #available(macOS 13.0, *) { req.automaticallyDetectsLanguage = true }
    try? VNImageRequestHandler(cgImage: img, orientation: o).perform([req])
    var lines = [OCRLine](), score: Float = 0
    for ob in req.results ?? [] {
      guard let c = ob.topCandidates(1).first else { continue }
      let b = ob.boundingBox
      lines.append(OCRLine(text: c.string, x: Double(b.minX), y: Double(1 - b.maxY), w: Double(b.width), h: Double(b.height), conf: c.confidence))
      score += c.confidence * Float(tokenize(c.string).count)
    }
    return (lines, score)
  }
  var best = run(.up), bestO = CGImagePropertyOrientation.up
  if best.0.reduce(0, { $0 + tokenize($1.text).count }) < 15 || best.1 < 8 {
    for o in [CGImagePropertyOrientation.right, .down, .left] {
      let r = run(o); if r.1 > best.1 * 1.5 { best = r; bestO = o }
    }
  }
  return (best.0.sorted { ($0.y, $0.x) < ($1.y, $1.x) }, bestO)
}

func sha256(_ url: URL) -> String {
  guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
  return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

/// Analyze one page image: OCR (+ detect/fix rotation) and hashes. Returns the page record and the upright image.
func analyzePage(_ raw: CGImage, crop: Bool) -> (PageRec, CGImage) {
  let cropped = crop ? (autoCrop(raw)?.image ?? raw) : raw
  let (lines, o) = recognizeLines(cropped)
  let upright = rotated(cropped, o)
  return (PageRec(w: upright.width, h: upright.height, orientation: o.rawValue, hashes: rotationHashes(upright), lines: lines), upright)
}

/// Record for a file on disk: reuse the stored OCR if this content was seen before, otherwise OCR it once.
func record(for url: URL, sha: String) -> DocRec? {
  if let r = Store.shared.rec(sha) { return r }
  let imgs = loadPageImages(url); guard !imgs.isEmpty else { return nil }
  let pages = imgs.map { analyzePage($0, crop: true).0 }
  let r = DocRec(sha: sha, ocrVersion: ocrVersion, created: Date().timeIntervalSince1970, pages: pages)
  Store.shared.save(r)
  return r
}

// MARK: - Comparison

func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

/// True when a and b differ by at most one substitution (same length). Tolerates single OCR misreads on long tokens.
private func oneSub(_ a: [UInt8], _ b: [UInt8]) -> Bool {
  guard a.count == b.count else { return false }
  var d = 0; for i in 0..<a.count where a[i] != b[i] { d += 1; if d > 1 { return false } }
  return true
}
/// Size of the intersection, counting long tokens (>= 6 chars) that differ by one character as equal.
func fuzzyIntersection(_ a: Set<String>, _ b: Set<String>) -> Int {
  var n = a.intersection(b).count
  let ra = a.subtracting(b).filter { $0.count >= 6 }, rb = Array(b.subtracting(a).filter { $0.count >= 6 }.map { Array($0.utf8) })
  var used = Set<Int>()
  for t in ra {
    let u = Array(t.utf8)
    if let j = rb.indices.first(where: { !used.contains($0) && oneSub(u, rb[$0]) }) { used.insert(j); n += 1 }
  }
  return n
}

func comparePages(_ a: PageRec, _ ta: Set<String>, _ na: Set<String>, _ b: PageRec, _ tb: Set<String>, _ nb: Set<String>) -> Match? {
  let pd = (0..<4).map { hamming(a.hashes[0], b.hashes[$0]) }.min()!
  if ta.count >= 8 && tb.count >= 8 {
    let mn = min(ta.count, tb.count), mx = max(ta.count, tb.count)
    let cont = Double(fuzzyIntersection(ta, tb)) / Double(mn), ratio = Double(mn) / Double(mx)
    // Identity fields that clearly disagree mean two different receipts, however alike the template is.
    let aA = na.filter { $0.hasPrefix("$") }, aB = nb.filter { $0.hasPrefix("$") }
    let aMin = min(aA.count, aB.count)
    // an amount "matches" if equal or one misread digit apart (OCR noise)
    let (sm, lg) = aA.count <= aB.count ? (aA, aB) : (aB, aA)
    let aMatch = sm.filter { x in lg.contains { y in x == y || oneSub(Array(x.utf8), Array(y.utf8)) } }.count
    let amountsDiffer = aMin >= 1 && Double(aMatch) / Double(aMin) < 0.5
    let dA = na.filter { $0.hasPrefix("@") }, dB = nb.filter { $0.hasPrefix("@") }
    let datesDiffer = !dA.isEmpty && !dB.isEmpty && !dA.contains { x in dB.contains { y in x == y || oneSub(Array(x.utf8), Array(y.utf8)) } }
    if amountsDiffer || datesDiffer { return nil }   // different receipt, however alike the template looks
    let nMin = min(na.count, nb.count)
    let nCont = nMin > 0 ? Double(fuzzyIntersection(na, nb)) / Double(nMin) : 1
    let textOK = cont >= 0.8 && (nMin >= 3 ? nCont >= 0.8 : (cont >= 0.9 && mn >= 25))
    let why = String(format: "text %.0f%%%@", cont * 100, nMin >= 3 ? String(format: ", numbers %.0f%%", nCont * 100) : "")
    if textOK { return ratio >= 0.5 ? Match(tier: .duplicate, score: cont, reason: why + (pd <= 8 ? ", same look" : ""))
                                    : Match(tier: .possible, score: cont, reason: why + " (one is a partial crop)") }
    if cont >= 0.7 && nMin >= 3 && nCont >= 0.75 { return Match(tier: .possible, score: cont, reason: why) }
    return nil
  }
  if pd <= 2 { return Match(tier: .duplicate, score: 1 - Double(pd) / 64, reason: "same image (distance \(pd)/64)") }
  if pd <= 8 { return Match(tier: .possible, score: 1 - Double(pd) / 64, reason: "similar image (distance \(pd)/64)") }
  return nil
}

func compare(_ a: Doc, _ b: Doc) -> Match? {
  if !a.rec.sha.isEmpty && a.rec.sha == b.rec.sha { return Match(tier: .exact, score: 1, reason: "identical file") }
  let (s, l) = a.rec.pages.count <= b.rec.pages.count ? (a, b) : (b, a)
  if s.rec.pages.count == l.rec.pages.count {
    var worst: Match?
    for i in 0..<s.rec.pages.count {
      guard let m = comparePages(s.rec.pages[i], s.tokens[i], s.nums[i], l.rec.pages[i], l.tokens[i], l.nums[i]) else { return nil }
      if worst == nil || m.tier < worst!.tier { worst = m }
    }
    return worst
  }
  for i in 0..<s.rec.pages.count {
    let ok = (0..<l.rec.pages.count).contains { j in
      (comparePages(s.rec.pages[i], s.tokens[i], s.nums[i], l.rec.pages[j], l.tokens[j], l.nums[j])?.tier ?? .possible) >= .duplicate }
    if !ok { return nil }
  }
  return Match(tier: .possible, score: 0.5, reason: "one file contains the other's pages")
}

// MARK: - Engine

final class DupEngine {
  static let exts: Set<String> = ["pdf", "jpg", "jpeg", "png", "tif", "tiff", "heic"]
  let store = Store.shared

  func files(in dir: String) -> [URL] {
    let e = FileManager.default.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    return (e?.allObjects as? [URL] ?? []).filter { Self.exts.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
  }

  /// Docs for every file in dir; OCR happens only for content not already in the store.
  func docs(in dir: String, progress: ((Int, Int) -> Void)? = nil) -> [Doc] {
    let urls = files(in: dir)
    var result = [Doc?](repeating: nil, count: urls.count)
    let lock = NSLock(); var done = 0
    DispatchQueue.concurrentPerform(iterations: urls.count) { i in
      let u = urls[i]
      let a = try? FileManager.default.attributesOfItem(atPath: u.path)
      let size = (a?[.size] as? Int) ?? 0, mt = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      var sha: String
      if let e = store.entry(u.path), e.size == size, e.mtime == mt { sha = e.sha } else { sha = sha256(u); store.setEntry(u.path, IndexEntry(size: size, mtime: mt, sha: sha)) }
      if !sha.isEmpty, let rec = record(for: u, sha: sha) {
        let d = Doc(path: u.path, size: size, mtime: mt, rec: rec)
        lock.lock(); result[i] = d; lock.unlock()
      }
      lock.lock(); done += 1; let n = done; lock.unlock()
      progress?(n, urls.count)
    }
    store.saveIndex(keeping: Set(urls.map { $0.path }))
    return result.compactMap { $0 }
  }

  /// Candidate pairs: close hashes, or sharing numeric / rare tokens. Avoids O(n^2) text comparisons.
  func pairs(_ docs: [Doc]) -> [(Int, Int, Match)] {
    let n = docs.count; guard n > 1 else { return [] }
    var df = [String: [Int]]()
    for (i, d) in docs.enumerated() { for t in Set(d.tokens.flatMap { $0 }) where t.count >= 5 || t.rangeOfCharacter(from: .decimalDigits) != nil { df[t, default: []].append(i) } }
    var cand = Set<Int>(), shared = [Int: Int]()
    for (_, ids) in df where ids.count >= 2 && ids.count <= max(8, n / 20) {
      for x in 0..<ids.count { for y in (x + 1)..<ids.count { shared[ids[x] * n + ids[y], default: 0] += 1 } }
    }
    for (k, c) in shared where c >= 2 { cand.insert(k) }
    for i in 0..<n { for j in (i + 1)..<n {
      let a = docs[i].rec.pages[0], b = docs[j].rec.pages[0]
      if docs[i].rec.sha == docs[j].rec.sha || (0..<4).map({ hamming(a.hashes[0], b.hashes[$0]) }).min()! <= 14 { cand.insert(i * n + j) }
    } }
    var out = [(Int, Int, Match)]()
    for k in cand.sorted() { if let m = compare(docs[k / n], docs[k % n]) { out.append((k / n, k % n, m)) } }
    return out
  }

  func groups(_ docs: [Doc]) -> [DupGroup] {
    let edges = pairs(docs)
    func build(_ lo: Tier, _ hi: Tier, excluding: Set<Int>) -> ([DupGroup], Set<Int>) {
      var parent = Array(0..<docs.count)
      func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
      var used = Set<Int>(), best = [Int: (Tier, String)]()
      let es = edges.filter { $0.2.tier >= lo && $0.2.tier <= hi && !excluding.contains($0.0) && !excluding.contains($0.1) }
      for (a, b, _) in es { parent[find(a)] = find(b); used.insert(a); used.insert(b) }
      for (a, _, m) in es { let r = find(a); if best[r] == nil || m.tier > best[r]!.0 { best[r] = (m.tier, m.reason) } }
      var members = [Int: [Int]]()
      for i in used { members[find(i), default: []].append(i) }
      let gs: [DupGroup] = members.map { (r, ids) in
        let ds = ids.map { docs[$0] }.sorted { ($0.size, -$0.mtime) > ($1.size, -$1.mtime) }   // keeper = largest, then oldest
        let links: [Match?] = ds.enumerated().map { $0.offset == 0 ? nil : compare(ds[0], $0.element) }
        let direct = links.compactMap { $0 }
        let tier = direct.map { $0.tier }.max() ?? best[r]!.0
        return DupGroup(tier: tier, members: ds, keeper: 0, reason: direct.max(by: { $0.tier < $1.tier })?.reason ?? best[r]!.1, links: links)
      }
      return (gs.sorted { ($0.tier, $0.members[0].path) > ($1.tier, $1.members[0].path) }, used)
    }
    let (dups, used) = build(.duplicate, .exact, excluding: [])
    let (poss, _) = build(.possible, .possible, excluding: used)
    return dups + poss
  }

  /// Existing files that look like `file` (used right after a new scan).
  func matches(for file: String, in dir: String) -> [(Doc, Match)] {
    let ds = docs(in: dir)
    guard let me = ds.first(where: { $0.path == file }) else { return [] }
    return ds.filter { $0.path != file }.compactMap { o in compare(me, o).map { (o, $0) } }.sorted { $0.1.tier > $1.1.tier }
  }
}
