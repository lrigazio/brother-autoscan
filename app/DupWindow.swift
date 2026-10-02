import Cocoa
import PDFKit

final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

/// Review window: every duplicate group as a row of thumbnails; checkboxes pick what goes to the Trash.
final class DupController: NSObject, NSWindowDelegate {
  let engine = DupEngine()
  var win: NSWindow!
  let status = NSTextField(labelWithString: "")
  let progress = NSProgressIndicator()
  let trashBtn = NSButton(title: "", target: nil, action: nil)
  let list = FlippedStack()
  var dir = ""
  var docs: [Doc] = []
  var groups: [DupGroup] = []
  var remove = Set<String>()            // paths currently selected for the Trash
  var thumbs: [String: NSImage] = [:]
  var scanning = false

  override init() {
    super.init()
    win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = "AutoScan - Duplicates"; win.isReleasedWhenClosed = false; win.delegate = self; win.minSize = NSSize(width: 640, height: 400)
    let v = win.contentView!
    status.frame = NSRect(x: 16, y: 684, width: 560, height: 20); status.autoresizingMask = [.maxXMargin, .minYMargin]; v.addSubview(status)
    progress.style = .bar; progress.isIndeterminate = false; progress.frame = NSRect(x: 16, y: 664, width: 300, height: 10); progress.autoresizingMask = [.maxXMargin, .minYMargin]; progress.isHidden = true; v.addSubview(progress)
    func btn(_ t: String, _ a: Selector, _ x: CGFloat) -> NSButton { let b = NSButton(title: t, target: self, action: a); b.frame = NSRect(x: x, y: 678, width: 130, height: 28); b.autoresizingMask = [.minXMargin, .minYMargin]; v.addSubview(b); return b }
    _ = btn("Rescan", #selector(rescan), 600); _ = btn("Select suggested", #selector(selectSuggested), 735)
    trashBtn.target = self; trashBtn.action = #selector(trashSelected); trashBtn.bezelStyle = .rounded; trashBtn.frame = NSRect(x: 600, y: 642, width: 365, height: 30); trashBtn.autoresizingMask = [.minXMargin, .minYMargin]
    trashBtn.keyEquivalent = "\r"; v.addSubview(trashBtn)
    let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: 980, height: 630)); sc.autoresizingMask = [.width, .height]; sc.hasVerticalScroller = true; sc.drawsBackground = false
    list.orientation = .vertical; list.alignment = .leading; list.spacing = 18; list.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
    list.translatesAutoresizingMaskIntoConstraints = false; sc.documentView = list
    NSLayoutConstraint.activate([list.topAnchor.constraint(equalTo: sc.contentView.topAnchor), list.leadingAnchor.constraint(equalTo: sc.contentView.leadingAnchor), list.trailingAnchor.constraint(equalTo: sc.contentView.trailingAnchor)])
    v.addSubview(sc); win.center()
  }
  func windowShouldClose(_ s: NSWindow) -> Bool { s.orderOut(nil); return false }

  func show(dir: String) {
    self.dir = dir; win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); rescan()
  }
  @objc func rescan() {
    guard !scanning else { return }
    scanning = true; status.stringValue = "Reading scans in \(dir)..."; progress.isHidden = false; progress.doubleValue = 0
    let d = dir
    DispatchQueue.global().async {
      let docs = self.engine.docs(in: d) { done, total in DispatchQueue.main.async { self.progress.maxValue = Double(total); self.progress.doubleValue = Double(done); self.status.stringValue = "Reading text from scans: \(done)/\(total)" } }
      let groups = self.engine.groups(docs)
      DispatchQueue.main.async {
        self.docs = docs; self.groups = groups; self.scanning = false; self.progress.isHidden = true
        self.selectSuggested(); self.render()
      }
    }
  }

  // MARK: selection
  func suggested(_ g: DupGroup) -> [String] {
    guard g.tier >= .duplicate else { return [] }
    return g.members.indices.filter { $0 != g.keeper && (g.links[$0]?.tier ?? .possible) >= .duplicate }.map { g.members[$0].path }
  }
  @objc func selectSuggested() { remove = Set(groups.flatMap { suggested($0) }); refreshCounts(); render() }
  func size(_ paths: Set<String>) -> Int { docs.filter { paths.contains($0.path) }.reduce(0) { $0 + $1.size } }
  func refreshCounts() {
    let n = remove.count
    trashBtn.title = n == 0 ? "Nothing selected" : "Move \(n) selected file\(n == 1 ? "" : "s") to Trash (\(ByteCountFormatter.string(fromByteCount: Int64(size(remove)), countStyle: .file)))..."
    trashBtn.isEnabled = n > 0
    let dupGroups = groups.filter { $0.tier >= .duplicate }.count, poss = groups.count - dupGroups
    status.stringValue = groups.isEmpty ? "No duplicates found in \(docs.count) files." : "\(dupGroups) duplicate group\(dupGroups == 1 ? "" : "s"), \(poss) possible - \(docs.count) files scanned"
  }
  @objc func toggle(_ b: NSButton) { if b.state == .on { remove.insert(b.identifier!.rawValue) } else { remove.remove(b.identifier!.rawValue) }; refreshCounts() }
  @objc func keepThis(_ b: NSButton) {
    let parts = b.identifier!.rawValue.split(separator: "|", maxSplits: 1).map(String.init)
    guard parts.count == 2, let gi = Int(parts[0]), gi < groups.count, let mi = groups[gi].members.firstIndex(where: { $0.path == parts[1] }) else { return }
    var g = groups[gi]
    for p in suggested(g) { remove.remove(p) }
    let k = g.members[mi]; g.members.remove(at: mi); g.members.insert(k, at: 0); g.keeper = 0
    g.links = g.members.enumerated().map { $0.offset == 0 ? nil : compare(k, $0.element) }
    groups[gi] = g
    if g.tier >= .duplicate { for p in suggested(g) { remove.insert(p) } }
    render()
  }
  @objc func reveal(_ g: NSClickGestureRecognizer) { if let p = g.view?.identifier?.rawValue { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }

  @objc func trashSelected() { confirmTrash(remove) }
  @objc func trashGroup(_ b: NSButton) {
    guard let gi = Int(b.identifier?.rawValue ?? ""), gi < groups.count else { return }
    confirmTrash(Set(groups[gi].members.map { $0.path }).intersection(remove))
  }
  func confirmTrash(_ paths: Set<String>) {
    guard !paths.isEmpty else { return }
    let a = NSAlert(); a.messageText = "Move \(paths.count) file\(paths.count == 1 ? "" : "s") to the Trash?"
    a.informativeText = "Frees \(ByteCountFormatter.string(fromByteCount: Int64(size(paths)), countStyle: .file)). You can restore them from the Trash."
    a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    NSWorkspace.shared.recycle(paths.map { URL(fileURLWithPath: $0) }) { _, err in
      DispatchQueue.main.async {
        if let err = err { self.status.stringValue = "Trash error: \(err.localizedDescription)" }
        self.remove.subtract(paths); self.rescan()
      }
    }
  }

  // MARK: rendering
  func thumb(_ path: String, into iv: NSImageView) {
    if let t = thumbs[path] { iv.image = t; return }
    DispatchQueue.global().async {
      let url = URL(fileURLWithPath: path); var img: NSImage?
      if url.pathExtension.lowercased() == "pdf" { img = PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: NSSize(width: 300, height: 300), for: .mediaBox) }
      else if let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let c = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 300] as CFDictionary) {
        img = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
      }
      DispatchQueue.main.async { if let i = img { self.thumbs[path] = i; iv.image = i } }
    }
  }
  func label(_ s: String, size: CGFloat = 11, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s); l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size); l.textColor = color
    l.lineBreakMode = .byTruncatingMiddle; l.translatesAutoresizingMaskIntoConstraints = false; l.widthAnchor.constraint(equalToConstant: 160).isActive = true; return l
  }
  func render() {
    refreshCounts()
    list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
    if groups.isEmpty { list.addArrangedSubview(NSTextField(labelWithString: "Nothing to review.")); return }
    let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
    for (gi, g) in groups.enumerated() {
      let header = NSStackView(); header.orientation = .horizontal; header.spacing = 10
      let color: NSColor = g.tier == .exact ? .systemRed : g.tier == .duplicate ? .systemOrange : .systemYellow
      header.addArrangedSubview(label(g.tier.label, size: 13, bold: true, color: color))
      let reason = NSTextField(labelWithString: "\(g.members.count) files - \(g.reason)"); reason.textColor = .secondaryLabelColor; header.addArrangedSubview(reason)
      let gb = NSButton(title: "Trash selected in group", target: self, action: #selector(trashGroup(_:))); gb.identifier = NSUserInterfaceItemIdentifier("\(gi)"); gb.controlSize = .small; header.addArrangedSubview(gb)

      let row = NSStackView(); row.orientation = .horizontal; row.spacing = 14; row.alignment = .top; row.translatesAutoresizingMaskIntoConstraints = false
      for (mi, m) in g.members.enumerated() {
        let card = NSStackView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 4
        let iv = NSImageView(); iv.imageScaling = .scaleProportionallyUpOrDown; iv.wantsLayer = true; iv.layer?.borderWidth = 1; iv.layer?.borderColor = NSColor.separatorColor.cgColor
        iv.translatesAutoresizingMaskIntoConstraints = false; iv.widthAnchor.constraint(equalToConstant: 160).isActive = true; iv.heightAnchor.constraint(equalToConstant: 160).isActive = true
        iv.identifier = NSUserInterfaceItemIdentifier(m.path); iv.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(reveal(_:))))
        thumb(m.path, into: iv); card.addArrangedSubview(iv)
        card.addArrangedSubview(label((m.path as NSString).lastPathComponent, bold: true))
        let p = m.rec.pages[0]
        card.addArrangedSubview(label("\(p.w)x\(p.h)\(m.rec.pages.count > 1 ? " - \(m.rec.pages.count) pages" : "") - \(ByteCountFormatter.string(fromByteCount: Int64(m.size), countStyle: .file))", color: .secondaryLabelColor))
        card.addArrangedSubview(label(df.string(from: Date(timeIntervalSince1970: m.mtime)), color: .secondaryLabelColor))
        if mi == g.keeper {
          card.addArrangedSubview(label("KEEP", bold: true, color: .systemGreen))
        } else {
          let link = g.links[mi]
          let why = label(link.map { "\($0.tier.label): \($0.reason)" } ?? "linked via another copy, not a direct match", size: 10, color: .secondaryLabelColor)
          why.lineBreakMode = .byWordWrapping; why.maximumNumberOfLines = 3; why.preferredMaxLayoutWidth = 160; card.addArrangedSubview(why)
          let cb = NSButton(checkboxWithTitle: "Move to Trash", target: self, action: #selector(toggle(_:)))
          cb.identifier = NSUserInterfaceItemIdentifier(m.path); cb.state = remove.contains(m.path) ? .on : .off; card.addArrangedSubview(cb)
          let kb = NSButton(title: "Keep this one instead", target: self, action: #selector(keepThis(_:))); kb.controlSize = .small
          kb.identifier = NSUserInterfaceItemIdentifier("\(gi)|\(m.path)"); card.addArrangedSubview(kb)
        }
        row.addArrangedSubview(card)
      }
      let sc = NSScrollView(); sc.hasHorizontalScroller = row.arrangedSubviews.count > 4; sc.drawsBackground = false; sc.documentView = row; sc.translatesAutoresizingMaskIntoConstraints = false
      sc.heightAnchor.constraint(equalToConstant: 300).isActive = true
      NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: sc.contentView.topAnchor), row.leadingAnchor.constraint(equalTo: sc.contentView.leadingAnchor)])
      let box = NSStackView(views: [header, sc]); box.orientation = .vertical; box.alignment = .leading; box.spacing = 6
      box.translatesAutoresizingMaskIntoConstraints = false
      list.addArrangedSubview(box)
      box.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -32).isActive = true
      sc.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
    }
  }
}
