import Cocoa
import PDFKit

func appLog(_ s: String) {
  let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/autoscan.log")
  let line = "[\(Date())] \(s)\n"
  if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
}

/// Window that lets the controller handle keys before AppKit does (arrow keys, space, ...).
final class KeyWindow: NSWindow {
  var onKey: ((NSEvent) -> Bool)?
  override func sendEvent(_ e: NSEvent) { if e.type == .keyDown, onKey?(e) == true { return }; super.sendEvent(e) }
}

/// Review window. Left: scrollable list of duplicate groups. Right: the selected group, files side by side and large.
final class DupController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {
  let engine = DupEngine()
  var win: NSWindow!
  let status = NSTextField(labelWithString: "")
  let progress = NSProgressIndicator()
  let trashBtn = NSButton(title: "", target: nil, action: nil)
  let table = NSTableView()
  let header = NSTextField(labelWithString: "")
  let cardsRow = NSStackView()
  let cardsScroll = NSScrollView()
  let groupBtn = NSButton(title: "", target: nil, action: nil)
  var dir = ""
  var docs: [Doc] = []
  var groups: [DupGroup] = []
  var remove = Set<String>()            // paths currently selected for the Trash
  var thumbs: [String: NSImage] = [:]
  var scanning = false
  var current = -1
  var state: [Int] = []                 // per group: index of the file kept, or members.count = keep all, -1 = custom
  var cards: [NSView] = []
  var cbs: [Int: NSButton] = [:]
  var badges: [Int: NSTextField] = [:]
  let meta = NSTextField(wrappingLabelWithString: "")
  let hint = NSTextField(labelWithString: "Left/Right or Space: cycle keep-left / keep-right / keep-all    Up/Down: group    Return: next group")

  override init() {
    super.init()
    let W: CGFloat = 1280, H: CGFloat = 840
    win = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = "AutoScan - Duplicates"; win.isReleasedWhenClosed = false; win.delegate = self; win.minSize = NSSize(width: 900, height: 600)
    (win as! KeyWindow).onKey = { [weak self] e in self?.handleKey(e) ?? false }
    let v = win.contentView!
    status.frame = NSRect(x: 16, y: H - 34, width: 640, height: 20); status.autoresizingMask = [.maxXMargin, .minYMargin]; v.addSubview(status)
    progress.style = .bar; progress.isIndeterminate = false; progress.frame = NSRect(x: 16, y: H - 50, width: 320, height: 10); progress.autoresizingMask = [.maxXMargin, .minYMargin]; progress.isHidden = true; v.addSubview(progress)
    func btn(_ t: String, _ a: Selector, _ x: CGFloat) { let b = NSButton(title: t, target: self, action: a); b.frame = NSRect(x: W - x, y: H - 40, width: 130, height: 28); b.autoresizingMask = [.minXMargin, .minYMargin]; v.addSubview(b) }
    btn("Rescan", #selector(rescan), 290); btn("Select suggested", #selector(selectSuggested), 150)
    trashBtn.target = self; trashBtn.action = #selector(trashSelected); trashBtn.bezelStyle = .rounded
    trashBtn.frame = NSRect(x: W - 520, y: H - 74, width: 504, height: 30); trashBtn.autoresizingMask = [.minXMargin, .minYMargin]; v.addSubview(trashBtn)

    // left: groups
    let col = NSTableColumn(identifier: .init("g")); col.resizingMask = .autoresizingMask
    table.addTableColumn(col); table.headerView = nil; table.rowHeight = 76; table.dataSource = self; table.delegate = self
    table.allowsEmptySelection = false; table.style = .sourceList
    let left = NSScrollView(); left.documentView = table; left.hasVerticalScroller = true; left.autohidesScrollers = true
    // right: detail
    let right = NSView()
    header.font = .boldSystemFont(ofSize: 14); header.lineBreakMode = .byTruncatingTail
    cardsRow.orientation = .horizontal; cardsRow.distribution = .fillEqually; cardsRow.spacing = 16; cardsRow.alignment = .top
    cardsRow.translatesAutoresizingMaskIntoConstraints = false
    cardsScroll.documentView = cardsRow; cardsScroll.hasHorizontalScroller = true; cardsScroll.autohidesScrollers = true; cardsScroll.drawsBackground = false
    groupBtn.target = self; groupBtn.action = #selector(trashGroup); groupBtn.bezelStyle = .rounded
    hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; hint.lineBreakMode = .byTruncatingTail
    hint.frame = NSRect(x: 16, y: H - 70, width: 760, height: 16); hint.autoresizingMask = [.maxXMargin, .minYMargin]; v.addSubview(hint)
    meta.font = .monospacedSystemFont(ofSize: 10, weight: .regular); meta.textColor = .secondaryLabelColor; meta.maximumNumberOfLines = 9; meta.lineBreakMode = .byTruncatingTail
    for s in [header, cardsScroll, groupBtn, meta] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(s) }
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: right.topAnchor, constant: 12), header.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16),
      cardsScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10), cardsScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 16), cardsScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16),
      cardsScroll.bottomAnchor.constraint(equalTo: meta.topAnchor, constant: -8),
      meta.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 16), meta.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16), meta.bottomAnchor.constraint(equalTo: groupBtn.topAnchor, constant: -8),
      groupBtn.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16), groupBtn.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -12),
      cardsRow.topAnchor.constraint(equalTo: cardsScroll.contentView.topAnchor), cardsRow.bottomAnchor.constraint(equalTo: cardsScroll.contentView.bottomAnchor),
      cardsRow.leadingAnchor.constraint(equalTo: cardsScroll.contentView.leadingAnchor),
      cardsRow.widthAnchor.constraint(greaterThanOrEqualTo: cardsScroll.contentView.widthAnchor)])
    let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: W, height: H - 84)); split.isVertical = true; split.dividerStyle = .thin
    split.autoresizingMask = [.width, .height]; split.delegate = self
    left.frame = NSRect(x: 0, y: 0, width: 320, height: H - 84); right.frame = NSRect(x: 321, y: 0, width: W - 321, height: H - 84)
    split.addSubview(left); split.addSubview(right); v.addSubview(split)
    split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    DispatchQueue.main.async { split.setPosition(320, ofDividerAt: 0) }
    win.center()
  }
  func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 260 }
  func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 480 }
  func splitView(_ s: NSSplitView, canCollapseSubview v: NSView) -> Bool { false }
  func windowShouldClose(_ s: NSWindow) -> Bool { UserDefaults.standard.set(false, forKey: "dupsPending"); s.orderOut(nil); return false }

  /// `dupsPending` survives a restart (macOS can relaunch the app right after the folder-access prompt), so the window comes back by itself.
  func show(dir: String) { self.dir = dir; UserDefaults.standard.set(true, forKey: "dupsPending"); win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); rescan() }
  @objc func rescan() {
    guard !scanning else { return }
    scanning = true; status.stringValue = "Reading scans in \(dir)..."; progress.isHidden = false; progress.doubleValue = 0
    let d = dir
    DispatchQueue.global().async {
      let docs = self.engine.docs(in: d) { done, total in DispatchQueue.main.async { self.progress.maxValue = Double(total); self.progress.doubleValue = Double(done); self.status.stringValue = "Reading text from scans: \(done)/\(total)" } }
      let groups = self.engine.groups(docs)
      DispatchQueue.main.async {
        self.docs = docs; self.groups = groups; self.scanning = false; self.progress.isHidden = true
        UserDefaults.standard.set(false, forKey: "dupsPending")
        self.remove = Set(groups.flatMap { self.suggested($0) })
        self.state = groups.map { self.initialState($0) }
        self.table.reloadData(); self.refreshCounts()
        let keep = min(max(self.current, 0), groups.count - 1)
        if groups.isEmpty { self.current = -1; self.showGroup(-1) } else { self.table.selectRowIndexes([keep], byExtendingSelection: false); self.showGroup(keep) }
      }
    }
  }

  // MARK: selection
  func suggested(_ g: DupGroup) -> [String] {
    guard g.tier >= .duplicate else { return [] }
    return g.members.indices.filter { $0 != g.keeper && (g.links[$0]?.tier ?? .possible) >= .duplicate }.map { g.members[$0].path }
  }
  @objc func selectSuggested() { remove = Set(groups.flatMap { suggested($0) }); table.reloadData(); refreshCounts(); showGroup(current) }
  func size(_ paths: Set<String>) -> Int { docs.filter { paths.contains($0.path) }.reduce(0) { $0 + $1.size } }
  func refreshCounts() {
    let n = remove.count
    trashBtn.title = n == 0 ? "Nothing selected" : "Move \(n) selected file\(n == 1 ? "" : "s") to Trash (\(ByteCountFormatter.string(fromByteCount: Int64(size(remove)), countStyle: .file)))..."
    trashBtn.isEnabled = n > 0
    let dupGroups = groups.filter { $0.tier >= .duplicate }.count, poss = groups.count - dupGroups
    status.stringValue = groups.isEmpty ? "No duplicates found in \(docs.count) files." : "\(dupGroups) duplicate group\(dupGroups == 1 ? "" : "s"), \(poss) possible - \(docs.count) files scanned"
  }
  @objc func toggle(_ b: NSButton) {
    if b.state == .on { remove.insert(b.identifier!.rawValue) } else { remove.remove(b.identifier!.rawValue) }
    if current >= 0 && current < state.count { state[current] = -1 }
    refreshCounts(); reloadRow(current); refreshCards()
  }
  func initialState(_ g: DupGroup) -> Int {
    let sg = suggested(g)
    if sg.isEmpty { return g.members.count }
    return sg.count == g.members.count - 1 ? g.keeper : -1
  }
  /// Cycle the current group through: keep file 0, keep file 1, ..., keep all, then back to the start.
  func step(_ d: Int) {
    guard current >= 0, current < groups.count else { return }
    let n = groups[current].members.count + 1
    let s = state[current] < 0 ? (d > 0 ? 0 : n - 1) : ((state[current] + d) % n + n) % n
    apply(current, s)
  }
  func apply(_ gi: Int, _ s: Int) {
    var g = groups[gi]; let paths = g.members.map { $0.path }
    remove.subtract(paths)
    if s < g.members.count {
      g.keeper = s
      g.links = g.members.enumerated().map { $0.offset == s ? nil : compare(g.members[s], $0.element) }
      for (i, p) in paths.enumerated() where i != s { remove.insert(p) }
    }
    groups[gi] = g; state[gi] = s
    refreshCounts(); reloadRow(gi); refreshCards()
  }
  func moveGroup(_ d: Int) {
    guard !groups.isEmpty else { return }
    let i = min(max(current + d, 0), groups.count - 1)
    table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i)
  }
  /// Keyboard: Left/Right/Space cycle the keep state, Up/Down change group, Return = next group.
  func handleKey(_ e: NSEvent) -> Bool {
    guard win.isKeyWindow, !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.control), !e.modifierFlags.contains(.option) else { return false }
    switch e.keyCode {
    case 123: step(-1)
    case 124, 49: step(1)
    case 125, 36, 76: moveGroup(1)
    case 126: moveGroup(-1)
    default: return false
    }
    return true
  }
  func stateName(_ g: DupGroup, _ s: Int) -> String {
    if s == g.members.count { return "keeping all files" }
    if s < 0 { return "custom selection" }
    return "keeping \(s + 1) of \(g.members.count): \((g.members[s].path as NSString).lastPathComponent)"
  }
  /// Badges, borders and metadata follow what is selected for the Trash.
  func refreshCards() {
    guard current >= 0, current < groups.count else { return }
    let g = groups[current]
    for (i, c) in cards.enumerated() where i < g.members.count {
      let kept = !remove.contains(g.members[i].path)
      badges[i]?.stringValue = kept ? "KEEP" : "TRASH"; badges[i]?.textColor = kept ? .systemGreen : .systemRed
      cbs[i]?.state = kept ? .off : .on
      c.wantsLayer = true; c.layer?.cornerRadius = 8; c.layer?.borderWidth = 3
      let col = kept ? NSColor.systemGreen : NSColor.systemRed
      c.layer?.borderColor = col.cgColor
    }
    header.stringValue = "\(g.tier.label) - \(g.members.count) files - \(g.reason)   |   \(stateName(g, state[current]))"
    updateGroupButton(); updateMeta()
  }
  /// Small-print details of the file(s) being kept: file facts plus what the stored OCR saw.
  func updateMeta() {
    guard current >= 0, current < groups.count else { meta.stringValue = ""; return }
    let g = groups[current]
    let kept = g.members.filter { !remove.contains($0.path) }
    let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
    var out = [String]()
    for m in kept.prefix(2) {
      let p = m.rec.pages[0], lines = p.lines.map { $0.text }
      let conf = p.lines.isEmpty ? 0 : Int(p.lines.map { Double($0.conf) }.reduce(0, +) / Double(p.lines.count) * 100)
      let amounts = lines.filter { let l = $0.lowercased(); return l.contains("total") || l.contains("tip") || l.contains("amount") }.prefix(3)
      out.append("KEEP  \(m.path)")
      out.append("      \(p.w)x\(p.h) px  \(ByteCountFormatter.string(fromByteCount: Int64(m.size), countStyle: .file))  \((m.path as NSString).pathExtension.lowercased())  \(m.rec.pages.count) page(s)  \(df.string(from: Date(timeIntervalSince1970: m.mtime)))  sha \(m.rec.sha.prefix(10))")
      out.append("      OCR: \(lines.count) lines, avg confidence \(conf)%   \(lines.prefix(3).joined(separator: " | "))")
      if !amounts.isEmpty { out.append("      amounts: \(amounts.joined(separator: " | "))") }
    }
    if kept.count > 2 { out.append("      (+\(kept.count - 2) more kept)") }
    if kept.isEmpty { out.append("Nothing kept in this group - every file is selected for the Trash.") }
    meta.stringValue = out.joined(separator: "\n")
  }
  func reloadRow(_ i: Int) {
    guard i >= 0 && i < groups.count else { return }
    table.reloadData(forRowIndexes: [i], columnIndexes: [0]); table.selectRowIndexes([i], byExtendingSelection: false)
  }
  @objc func keepThis(_ b: NSButton) {
    guard current >= 0, current < groups.count, let mi = groups[current].members.firstIndex(where: { $0.path == b.identifier?.rawValue }) else { return }
    apply(current, mi)
  }
  @objc func open(_ g: NSClickGestureRecognizer) { if let p = g.view?.identifier?.rawValue { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }

  @objc func trashSelected() { confirmTrash(remove) }
  func groupSelected(_ i: Int) -> Set<String> { i >= 0 && i < groups.count ? Set(groups[i].members.map { $0.path }).intersection(remove) : [] }
  @objc func trashGroup() { confirmTrash(groupSelected(current)) }
  func updateGroupButton() { let n = groupSelected(current).count; groupBtn.title = n == 0 ? "Nothing selected in this group" : "Move \(n) selected in this group to Trash..."; groupBtn.isEnabled = n > 0 }
  func confirmTrash(_ paths: Set<String>) {
    guard !paths.isEmpty else { return }
    let a = NSAlert(); a.messageText = "Move \(paths.count) file\(paths.count == 1 ? "" : "s") to the Trash?"
    a.informativeText = "Frees \(ByteCountFormatter.string(fromByteCount: Int64(size(paths)), countStyle: .file)). You can restore them from the Trash."
    a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    let want = Set(paths)
    NSWorkspace.shared.recycle(want.map { URL(fileURLWithPath: $0) }) { trashed, err in
      DispatchQueue.main.async {
        var failed = want.subtracting(Set(trashed.keys.map { $0.path }))
        var why = [String]()
        if let err = err { why.append(err.localizedDescription) }
        for p in failed {   // second attempt through FileManager
          do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil); failed.remove(p) }
          catch { why.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)") }
        }
        appLog("trash: requested \(want.count), failed \(failed.count) \(why)")
        if !failed.isEmpty {
          let al = NSAlert(); al.alertStyle = .warning
          al.messageText = "Could not move \(failed.count) file\(failed.count == 1 ? "" : "s") to the Trash"
          al.informativeText = (why.prefix(4).joined(separator: "\n")) + "\n\nIf this says the operation is not permitted: System Settings > Privacy & Security > Files and Folders (or Full Disk Access) - allow AutoScan to change files in Documents."
          al.runModal()
        }
        self.remove.subtract(want.subtracting(failed)); self.rescan()
      }
    }
  }

  // MARK: thumbnails
  func thumb(_ path: String, _ maxPx: Int, _ done: @escaping (NSImage) -> Void) {
    let key = "\(path)@\(maxPx)"
    if let t = thumbs[key] { done(t); return }
    DispatchQueue.global().async {
      let url = URL(fileURLWithPath: path); var img: NSImage?
      if url.pathExtension.lowercased() == "pdf" { img = PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: NSSize(width: maxPx, height: maxPx), for: .mediaBox) }
      else if let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let c = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPx] as CFDictionary) {
        img = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
      }
      DispatchQueue.main.async { if let i = img { self.thumbs[key] = i; done(i) } }
    }
  }
  func tierColor(_ t: Tier) -> NSColor { t == .exact ? .systemRed : t == .duplicate ? .systemOrange : .systemYellow }

  // MARK: group list (left)
  func numberOfRows(in t: NSTableView) -> Int { groups.count }
  func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
    let g = groups[row]
    let cell = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 76))
    let iv = NSImageView(frame: NSRect(x: 10, y: 8, width: 60, height: 60)); iv.imageScaling = .scaleProportionallyUpOrDown; cell.addSubview(iv)
    thumb(g.members[g.keeper].path, 200) { iv.image = $0 }
    func lab(_ s: String, _ y: CGFloat, _ size: CGFloat, bold: Bool = false, color: NSColor = .labelColor) {
      let l = NSTextField(labelWithString: s); l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size); l.textColor = color
      l.lineBreakMode = .byTruncatingMiddle; l.frame = NSRect(x: 80, y: y, width: 215, height: 18); l.autoresizingMask = [.width]; cell.addSubview(l)
    }
    lab("\(g.tier.label) - \(g.members.count) files", 50, 13, bold: true, color: tierColor(g.tier))
    lab((g.members[g.keeper].path as NSString).lastPathComponent, 30, 11)
    let n = groupSelected(row).count
    lab(n == 0 ? "nothing selected" : "\(n) selected for Trash", 10, 11, color: .secondaryLabelColor)
    return cell
  }
  func tableViewSelectionDidChange(_ n: Notification) { if table.selectedRow >= 0 && table.selectedRow != current { showGroup(table.selectedRow) } }

  // MARK: detail (right)
  func showGroup(_ i: Int) {
    current = i
    cardsRow.arrangedSubviews.forEach { cardsRow.removeArrangedSubview($0); $0.removeFromSuperview() }
    cards = []; cbs = [:]; badges = [:]
    guard i >= 0, i < groups.count else { header.stringValue = "No duplicates to review."; header.textColor = .labelColor; groupBtn.isHidden = true; return }
    groupBtn.isHidden = false; updateGroupButton()
    let g = groups[i]
    header.textColor = tierColor(g.tier)
    let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
    for (mi, m) in g.members.enumerated() {
      let card = NSStackView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 5; card.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
      card.translatesAutoresizingMaskIntoConstraints = false
      card.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
      let iv = NSImageView(); iv.imageScaling = .scaleProportionallyUpOrDown; iv.imageAlignment = .alignTop; iv.wantsLayer = true
      iv.layer?.borderWidth = 1; iv.layer?.borderColor = NSColor.separatorColor.cgColor
      for axis in [NSLayoutConstraint.Orientation.vertical, .horizontal] {
        iv.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: axis); iv.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: axis)
      }
      iv.identifier = NSUserInterfaceItemIdentifier(m.path); iv.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(open(_:))))
      iv.toolTip = "Click to open"
      thumb(m.path, 1600) { iv.image = $0 }
      card.addArrangedSubview(iv)
      iv.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
      iv.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
      func line(_ s: String, bold: Bool = false, size: CGFloat = 12, color: NSColor = .labelColor, lines: Int = 1) {
        let l = NSTextField(wrappingLabelWithString: s); l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size); l.textColor = color
        l.maximumNumberOfLines = lines; l.lineBreakMode = lines == 1 ? .byTruncatingMiddle : .byWordWrapping
        l.setContentHuggingPriority(.required, for: .vertical); l.setContentCompressionResistancePriority(.required, for: .vertical)
        card.addArrangedSubview(l); l.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
      }
      let p = m.rec.pages[0]
      line((m.path as NSString).lastPathComponent, bold: true, size: 13)
      line("\(p.w)x\(p.h)\(m.rec.pages.count > 1 ? " - \(m.rec.pages.count) pages" : "") - \(ByteCountFormatter.string(fromByteCount: Int64(m.size), countStyle: .file)) - \(df.string(from: Date(timeIntervalSince1970: m.mtime)))", size: 11, color: .secondaryLabelColor)
      if mi != g.keeper { line(g.links[mi].map { "\($0.tier.label): \($0.reason)" } ?? "linked via another copy, not a direct match", size: 11, color: .secondaryLabelColor, lines: 2) }
      let badge = NSTextField(labelWithString: "KEEP"); badge.font = .boldSystemFont(ofSize: 13); badges[mi] = badge; card.addArrangedSubview(badge)
      let cb = NSButton(checkboxWithTitle: "Move to Trash", target: self, action: #selector(toggle(_:)))
      cb.identifier = NSUserInterfaceItemIdentifier(m.path); cb.setContentHuggingPriority(.required, for: .vertical); cbs[mi] = cb; card.addArrangedSubview(cb)
      let kb = NSButton(title: "Keep only this one", target: self, action: #selector(keepThis(_:))); kb.controlSize = .small
      kb.identifier = NSUserInterfaceItemIdentifier(m.path); kb.setContentHuggingPriority(.required, for: .vertical); card.addArrangedSubview(kb)
      cardsRow.addArrangedSubview(card); cards.append(card)
      card.heightAnchor.constraint(equalTo: cardsRow.heightAnchor).isActive = true
    }
    refreshCards()
  }
}
