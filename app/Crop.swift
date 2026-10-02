import CoreGraphics
import Foundation

/// Crops a scan to its content. A feeder scan has three regions: the paper, the gray scanner
/// background around it, and pure-white padding below the real scan area. Returns the cropped
/// image and the crop rect (pixels), or nil when there is nothing sensible to crop.
func autoCrop(_ img: CGImage) -> (image: CGImage, rect: CGRect)? {
  let w = img.width, h = img.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let drawn: Bool = buf.withUnsafeMutableBytes { p in
    guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  guard drawn else { return nil }

  let k = max(1, min(w, h) / 500)             // sample every k-th pixel
  let sw = w / k, sh = h / k
  guard sw > 20, sh > 20 else { return nil }
  @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = ((y * k) * w + x * k) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
  }

  // 1. Background colour = most common non-white colour (16-level bins).
  var hist = [Int](repeating: 0, count: 4096)
  var sum = [(Int, Int, Int)](repeating: (0, 0, 0), count: 4096)
  for y in 0..<sh { for x in 0..<sw {
    let (r, g, b) = px(x, y)
    if min(r, g, b) >= 225 { continue }
    let bin = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
    hist[bin] += 1; sum[bin] = (sum[bin].0 + r, sum[bin].1 + g, sum[bin].2 + b)
  } }
  guard let mode = hist.indices.max(by: { hist[$0] < hist[$1] }), Double(hist[mode]) / Double(sw * sh) > 0.02 else { return nil }
  let n = hist[mode]
  let bg = (sum[mode].0 / n, sum[mode].1 / n, sum[mode].2 / n)

  // 2. Padding: contiguous pure-white rows at the bottom of the image.
  var padStart = sh
  while padStart > 0 {
    var white = 0
    for x in 0..<sw { let (r, g, b) = px(x, padStart - 1); if min(r, g, b) >= 250 { white += 1 } }
    if Double(white) / Double(sw) >= 0.995 { padStart -= 1 } else { break }
  }
  guard padStart > 20 else { return nil }

  // 3. Foreground = anything that differs from the background colour, inside the real scan area.
  let tol = 30
  var rows = [Int](repeating: 0, count: padStart), cols = [Int](repeating: 0, count: sw)
  for y in 0..<padStart { for x in 0..<sw {
    let (r, g, b) = px(x, y)
    if max(abs(r - bg.0), abs(g - bg.1), abs(b - bg.2)) > tol { rows[y] += 1; cols[x] += 1 }
  } }
  let rThr = max(3, sw / 100), cThr = max(3, padStart / 100)
  guard let y0 = rows.firstIndex(where: { $0 >= rThr }), let y1 = rows.lastIndex(where: { $0 >= rThr }),
        let x0 = cols.firstIndex(where: { $0 >= cThr }), let x1 = cols.lastIndex(where: { $0 >= cThr }) else { return nil }

  // 4. Back to full-res pixels with a small margin.
  let m = 8
  let rx0 = max(0, x0 * k - m), ry0 = max(0, y0 * k - m)
  let rx1 = min(w, (x1 + 1) * k + m), ry1 = min(h, (y1 + 1) * k + m)
  let rect = CGRect(x: rx0, y: ry0, width: rx1 - rx0, height: ry1 - ry0)
  if rect.width * rect.height > 0.97 * Double(w * h) { return nil }   // content fills the page
  guard let out = img.cropping(to: rect) else { return nil }
  return (out, rect)
}
