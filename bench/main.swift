// Duplicate-detection benchmark: builds variants of real scans + synthetic look-alikes in a temp dir,
// runs the engine and checks nothing is wrongly merged. Usage: dupbench <scan1.jpg> <scan2.jpg>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AppKit

setenv("AUTOSCAN_STORE", NSTemporaryDirectory() + "dupbench-store", 1)
try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "dupbench-store")
let args = Array(CommandLine.arguments.dropFirst())
let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dupbench-\(getpid())")
try? FileManager.default.removeItem(at: work); try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
func load(_ p: String) -> CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!, 0, nil)! }
func save(_ img: CGImage, _ name: String, _ type: UTType = .jpeg, q: Double = 0.9) {
  let d = CGImageDestinationCreateWithURL(work.appendingPathComponent(name) as CFURL, type.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary); CGImageDestinationFinalize(d)
}
func ctx(_ w: Int, _ h: Int) -> CGContext { CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)! }
func scaled(_ i: CGImage, _ s: Double) -> CGImage { let c = ctx(Int(Double(i.width) * s), Int(Double(i.height) * s)); c.interpolationQuality = .high; c.draw(i, in: CGRect(x: 0, y: 0, width: c.width, height: c.height)); return c.makeImage()! }
func tilted(_ i: CGImage, deg: Double) -> CGImage {
  let c = ctx(i.width, i.height); c.setFillColor(CGColor(gray: 0.7, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: i.width, height: i.height))
  c.translateBy(x: CGFloat(i.width) / 2, y: CGFloat(i.height) / 2); c.rotate(by: CGFloat(deg * .pi / 180)); c.translateBy(x: -CGFloat(i.width) / 2, y: -CGFloat(i.height) / 2)
  c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height)); return c.makeImage()!
}
func pdf(_ i: CGImage, _ name: String) { let p = PDFDocument(); p.insert(PDFPage(image: NSImage(cgImage: i, size: NSSize(width: i.width / 4, height: i.height / 4)))!, at: 0); p.write(to: work.appendingPathComponent(name)) }
func receipt(_ n: String, _ date: String, _ prices: [String], _ total: String, scale: CGFloat = 1) -> CGImage {
  let w = Int(1000 * scale), h = Int(1400 * scale), c = ctx(w, h)
  c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
  let g = NSGraphicsContext(cgContext: c, flipped: true); NSGraphicsContext.current = g
  c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
  let font = NSFont.monospacedSystemFont(ofSize: 38 * scale, weight: .regular)
  let lines = ["SUPERMERCADO LA ESQUINA", "RUT 76.123.456-7", "AVDA LAS CONDES 1234 SANTIAGO", "BOLETA ELECTRONICA N \(n)", "FECHA \(date)", "",
               "LECHE ENTERA 1L        \(prices[0])", "PAN MOLDE INTEGRAL     \(prices[1])", "QUESO GAUDA 250G       \(prices[2])", "", "TOTAL                  \(total)", "", "GRACIAS POR SU COMPRA", "VERIFIQUE DOCUMENTO WWW.SII.CL"]
  for (i, l) in lines.enumerated() { (l as NSString).draw(at: NSPoint(x: 40 * scale, y: (60 + CGFloat(i) * 70) * scale), withAttributes: [.font: font, .foregroundColor: NSColor.black]) }
  return c.makeImage()!
}

let r1 = load(args[0]), r2 = load(args[1])
let c1 = autoCrop(r1)!.image
save(r1, "r1.jpg"); try! FileManager.default.copyItem(at: work.appendingPathComponent("r1.jpg"), to: work.appendingPathComponent("r1_copy.jpg"))
save(r1, "r1_as_png.png", .png); save(scaled(r1, 0.5), "r1_half_q60.jpg", q: 0.6); save(r1, "r1_full_q95.jpg", q: 0.95)
save(rotatedImg(c1, .right), "r1_rot90cw.png", .png); save(rotatedImg(c1, .down), "r1_rot180.jpg"); save(tilted(r1, deg: 4), "r1_tilt4.jpg")
save(c1.cropping(to: CGRect(x: 0, y: 0, width: c1.width, height: c1.height * 3 / 4))!, "r1_top75.jpg"); pdf(c1, "r1.pdf")
save(r2, "r2.jpg"); save(r2, "r2_as_png.png", .png); save(scaled(r2, 0.5), "r2_half.jpg", q: 0.7)
save(receipt("1512106", "29/08/2025 14:04", ["3.800", "7.400", "2.100"], "13.300"), "sA.png", .png)
save(receipt("1512107", "30/08/2025 09:12", ["3.900", "7.400", "2.400"], "13.700"), "sB.png", .png)          // same template, different numbers
save(receipt("1512106", "29/08/2025 14:04", ["3.800", "7.400", "2.100"], "13.300", scale: 0.6), "sA_small.jpg", q: 0.7)
func rotatedImg(_ i: CGImage, _ o: CGImagePropertyOrientation) -> CGImage { rotated(i, o) }

let t0 = Date()
let eng = DupEngine()
let docs = eng.docs(in: work.path)
print("fingerprinted \(docs.count) files in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
for d in docs { let p = d.rec.pages[0]; print(String(format: "  %-18@ orient=%d lines=%3d tokens=%3d", (d.path as NSString).lastPathComponent as NSString, p.orientation, p.lines.count, d.tokens[0].count)) }
let groups = eng.groups(docs)
print("\nGROUPS")
for g in groups { for (i, m) in g.members.enumerated() where i > 0 { print("    \((m.path as NSString).lastPathComponent): \(g.links[i].map { "\($0.tier.label) - \($0.reason)" } ?? "no direct link to keeper")") }; print("[\(g.tier.label)] keeper=\((g.members[g.keeper].path as NSString).lastPathComponent)  \(g.members.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "))  -- \(g.reason)") }

// checks
func fam(_ p: String) -> String { let n = (p as NSString).lastPathComponent; return n.hasPrefix("r1") ? "r1" : n.hasPrefix("r2") ? "r2" : n.hasPrefix("sA") ? "sA" : "sB" }
var bad = 0
for g in groups where Set(g.members.map { fam($0.path) }).count > 1 { print("FAIL: mixed group \(g.members.map { fam($0.path) })"); bad += 1 }
for f in ["r1", "r2", "sA", "sB"] {
  let all = docs.filter { fam($0.path) == f }.count
  let best = groups.filter { $0.tier >= .duplicate }.map { $0.members.filter { fam($0.path) == f }.count }.max() ?? 0
  print("\(f): \(best)/\(all) files in one Duplicate/Exact group")
}
print(bad == 0 ? "NO FALSE MERGES" : "FALSE MERGES: \(bad)")

if let h = docs.first(where: { $0.path.hasSuffix("r1_half_q60.jpg") }), let b = docs.first(where: { $0.path.hasSuffix("r1_as_png.png") }) {
  let ta = h.tokens[0], tb = b.tokens[0]
  print("DEBUG half vs full: tokens \(ta.count)/\(tb.count) inter=\(ta.intersection(tb).count) nums \(h.nums[0].count)/\(b.nums[0].count) inter=\(h.nums[0].intersection(b.nums[0]).count)")
  print("  only in half:", ta.subtracting(tb).sorted().prefix(25)); print("  numbers half:", h.nums[0].sorted()); print("  numbers full:", b.nums[0].sorted())
  print("  compare:", compare(h, b).map { "\($0.tier.label) \($0.reason)" } ?? "nil")
}
