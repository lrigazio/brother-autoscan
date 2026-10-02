import Cocoa
import PDFKit

/// Floating enlarged preview: appears under the cursor, disappears as soon as the mouse leaves it (no click needed).
final class ZoomPanel: NSPanel {
  static let shared = ZoomPanel()
  private let iv = NSImageView()
  private var timer: Timer?
  private var token = 0

  private init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isFloatingPanel = true; level = .floating; hasShadow = true; isOpaque = true; backgroundColor = .black
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    iv.imageScaling = .scaleProportionallyUpOrDown; contentView = iv
  }
  override var canBecomeKey: Bool { false }

  func show(path: String) {
    let at = NSEvent.mouseLocation; token += 1; let t = token
    DispatchQueue.global().async {
      let url = URL(fileURLWithPath: path); var img: NSImage?
      if url.pathExtension.lowercased() == "pdf", let pg = PDFDocument(url: url)?.page(at: 0) {
        let b = pg.bounds(for: .mediaBox), sc = 3000 / max(b.width, b.height)
        img = pg.thumbnail(of: NSSize(width: b.width * sc, height: b.height * sc), for: .mediaBox)
      } else if let s = CGImageSourceCreateWithURL(url as CFURL, nil),
                let c = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 3200] as CFDictionary) {
        img = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
      }
      DispatchQueue.main.async { if t == self.token, let i = img { self.present(i, at: at) } }
    }
  }

  private func present(_ img: NSImage, at p: NSPoint) {
    guard img.size.width > 0, img.size.height > 0 else { return }
    let scr = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    let vis = scr.visibleFrame
    let k = min(vis.width * 0.92 / img.size.width, vis.height * 0.92 / img.size.height, 3)
    let w = img.size.width * k, h = img.size.height * k
    // centred on the cursor, clamped to the screen: the cursor always starts inside the panel
    let x = min(max(p.x - w / 2, vis.minX), vis.maxX - w), y = min(max(p.y - h / 2, vis.minY), vis.maxY - h)
    iv.image = img
    setFrame(NSRect(x: x, y: y, width: w, height: h), display: true); orderFrontRegardless()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      if !NSMouseInRect(NSEvent.mouseLocation, self.frame.insetBy(dx: -1, dy: -1), false) { self.hide() }
    }
  }

  func hide() { token += 1; timer?.invalidate(); timer = nil; orderOut(nil) }
}
