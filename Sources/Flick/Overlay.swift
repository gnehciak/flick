import Cocoa

/// The switcher window. It stays in the window list at zero alpha, and its layers
/// are built before it's needed, so showing it is a single alpha change.
final class Overlay {
    static let shared = Overlay()

    private let panel: NSPanel
    private var glass: NSView?
    private let host = HostView()
    private let selection = CALayer()
    private var tiles: [Tile] = []
    private var sections: [Section] = []
    private var groups: [Group] = []
    private var items: [Item] = []
    private var showingThumbnails = false
    private var showingGrid = false
    private var shown = false
    private var scrubbing = false
    private var closing = false
    private var fadeHoldNow = fadeHold
    private var arrived = true
    private var closeCount = 0
    private let backdrop = CALayer()
    private var backdropReady = false
    private var backdropCount = 0
    private var wallpaper: (key: String, image: CGImage)?
    private var sharpened: [(tile: Tile, id: CGWindowID)] = []
    private var drag: Drag?
    private var moveBefore: [CGWindowID: CGRect]?
    private var sharp: [CGWindowID: CGImage] = [:]
    private var sharpCount = 0
    private var hovering: DispatchWorkItem?
    private var progress = 0.0
    private var ticker: Ticker?
    private var index = 0

    private static let pad: CGFloat = 14, gap: CGFloat = 6
    private static let groupedZoom: CGFloat = 2

    private struct Group {
        let title: String
        let frame: CGRect
        let current: Bool
        let space: UInt64
        let members: [Int]
        let edgeRight: Bool
        let edgeBottom: Bool
        let align: CATextLayerAlignmentMode
        let labelBelow: Bool
    }

    private struct Drag {
        let index: Int
        let press: CGPoint
        let start: CGPoint
        var moving = false
    }

    private struct Layout {
        let frame: NSRect
        let tiles: [CGRect]
        var groups: [Group] = []
    }

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0

        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        // Side by side, not nested, so the grid can do without the glass.
        let container = NSView(frame: panel.contentLayoutRect)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        let effect: NSView
        if #available(macOS 26.0, *) {
            effect = NSGlassEffectView()
        } else {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            effect = view
        }
        effect.frame = container.bounds
        effect.autoresizingMask = [.width, .height]
        container.addSubview(effect)
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        backdrop.isHidden = true
        container.layer?.addSublayer(backdrop)
        host.frame = container.bounds
        container.addSubview(host)
        glass = effect

        selection.borderWidth = 3
        selection.zPosition = 1000
        selection.isHidden = true
        host.layer?.addSublayer(selection)
    }

    func warmUp() {
        panel.orderFrontRegardless()
        // So the first swipe finds the wallpaper ready.
        if Prefs.current.swipeUp || !Prefs.current.currentSpaceOnly { requestBackdrop() }
    }

    func applyStyle() {
        let prefs = Prefs.current
        if #available(macOS 26.0, *), let view = glass as? NSGlassEffectView {
            view.style = prefs.clearGlass ? .clear : .regular
            view.tintColor = prefs.tint
        }
        applyCorners()
    }

    private func applyCorners() {
        let radius = showingGrid ? 0 : Prefs.current.corners
        if #available(macOS 26.0, *), let view = glass as? NSGlassEffectView {
            view.cornerRadius = radius
        } else {
            glass?.layer?.cornerRadius = radius
        }
    }

    /// `grid` overrides the Spaces setting for an open switcher.
    func prepare(_ items: [Item], index: Int, grid: Bool? = nil) {
        if closing {   // a new ⌘Tab doesn't wait for the last close
            endScrubState()
            dropSharpened()
        }
        self.items = items
        self.index = index
        guard !items.isEmpty else {
            // A view with nothing in it, such as flipping back to an empty Space.
            if shown { hide() }
            return
        }

        let prefs = Prefs.current
        let screens = NSScreen.screens
        let underMouse = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        // Screens can be empty for a moment around sleep. An open switcher stays put.
        let showing = shown ? panel.screen : nil
        guard let screen = showing ?? (prefs.mainDisplay ? screens.first : underMouse) ?? NSScreen.main ?? screens.first else { return }
        let area = screen.visibleFrame
        let thumbnails = Thumbs.shared.enabled
        let header = thumbnails && (prefs.titles || prefs.icons)
        let scale = screen.backingScaleFactor
        let spaces = Spaces.arranged(Store.shared.spaceList, prefs.layout)
        let grouped = (grid ?? !prefs.currentSpaceOnly) && !spaces.isEmpty
        let densest = screens.map(\.backingScaleFactor).max() ?? 2
        let largest = prefs.size * (grouped ? Self.groupedZoom : 1)
        Thumbs.shared.setFit(CGSize(width: (232 * largest - 16) * densest, height: (150 * largest - 8) * densest), items: items)

        let sized: (CGFloat) -> CGSize = { k in
            thumbnails ? CGSize(width: 232 * k, height: 150 * k + (header ? 26 : 8))
                       : CGSize(width: 136 * k, height: 96 * k + (prefs.titles ? 28 : 0))
        }
        let layout = grouped ? gridLayout(items, spaces: spaces, names: prefs.layout, screen: screen, largest: largest, sized: sized)
                             : compactLayout(items.count, area: screen.visibleFrame, sized(prefs.size))
        groups = layout.groups

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(layout.frame, display: false)
        if showingGrid != grouped {
            showingGrid = grouped
            applyCorners()
        }
        if !grouped { clearBackdrop() } else if !shown, !scrubbing { requestBackdrop() }

        while tiles.count < items.count {
            let tile = Tile()
            host.layer?.addSublayer(tile.root)
            tiles.append(tile)
        }
        while sections.count < layout.groups.count {
            let section = Section()
            host.layer?.insertSublayer(section.root, at: 0)
            sections.append(section)
        }
        showingThumbnails = thumbnails

        var label = NSColor.labelColor.cgColor, accent = NSColor.controlAccentColor.cgColor
        var halo = NSColor.windowBackgroundColor.cgColor
        var line = label
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.cgColor
            accent = (prefs.highlight ?? NSColor.controlAccentColor).cgColor
            halo = NSColor.windowBackgroundColor.cgColor
            line = NSColor.labelColor.withAlphaComponent(0.22).cgColor
        }
        if grouped {
            // The background is always dark here, whatever the system's appearance.
            label = NSColor.white.cgColor
            line = NSColor.white.withAlphaComponent(0.2).cgColor
            halo = NSColor.black.withAlphaComponent(0.6).cgColor
        }
        let textHalo = grouped || prefs.clearGlass ? halo : nil
        selection.borderColor = accent
        selection.cornerRadius = max(prefs.corners - Self.pad + 2, 4)

        for (i, section) in sections.enumerated() {
            guard i < layout.groups.count else { section.root.isHidden = true; continue }
            let group = layout.groups[i]
            section.update(group.title, frame: group.frame, scale: scale, label: label, halo: textHalo,
                           current: group.current, line: line, edgeRight: group.edgeRight, edgeBottom: group.edgeBottom,
                           align: group.align, labelBelow: group.labelBelow)
        }
        for (i, t) in tiles.enumerated() {
            guard i < items.count else { t.root.isHidden = true; continue }
            t.root.isHidden = false
            t.root.frame = layout.tiles[i]
            t.update(items[i], size: layout.tiles[i].size, thumbnails: thumbnails, titles: prefs.titles, icons: prefs.icons, scale: scale, label: label,
                     halo: textHalo)
        }
        drag = nil
        sections.forEach { $0.setTarget(nil) }
        if let before = moveBefore {
            moveBefore = nil
            settleMoves(from: before)
        }
        placeSelection()
        CATransaction.commit()
        panel.invalidateShadow()
        host.hitTiles = { [weak self] point in self?.tileIndex(at: point) }
        host.missedTiles = { [weak self] point in self?.spaceClicked(point) }
        host.gridMouse = grouped ? { [weak self] phase, point in self?.gridMouse(phase, point) } : nil
    }

    /// One centred panel of tiles, in most recent order.
    private func compactLayout(_ count: Int, area: NSRect, _ start: CGSize) -> Layout {
        let pad = Self.pad, gap = Self.gap
        var tile = start
        let maxW = area.width * 0.92 - pad * 2, maxH = area.height * 0.86 - pad * 2

        var columns = 1, rows = 1
        for _ in 0..<12 {
            columns = max(1, min(count, Int((maxW + gap) / (tile.width + gap))))
            rows = (count + columns - 1) / columns
            if CGFloat(rows) * (tile.height + gap) - gap <= maxH { break }
            tile = CGSize(width: tile.width * 0.88, height: tile.height * 0.88)
        }

        let width = CGFloat(columns) * (tile.width + gap) - gap + pad * 2
        let height = CGFloat(rows) * (tile.height + gap) - gap + pad * 2
        let frame = NSRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
        let frames = (0..<count).map { i -> CGRect in
            let row = i / columns, column = i % columns
            let inRow = row == rows - 1 ? count - row * columns : columns
            let rowInset = CGFloat(columns - inRow) * (tile.width + gap) / 2
            let x = pad + rowInset + CGFloat(column) * (tile.width + gap)
            let y = height - pad - CGFloat(row + 1) * tile.height - CGFloat(row) * gap
            return CGRect(x: x, y: y, width: tile.width, height: tile.height)
        }
        return Layout(frame: frame, tiles: frames)
    }

    /// The whole screen as a fixed grid: a Space's cell depends only on how many Spaces
    /// there are, never on what's in it. Windows scale to fit their own cell. Tiles keep
    /// their index, so Tab order and clicks work as they do in the compact panel.
    private func gridLayout(_ items: [Item], spaces: [Spaces.Info], names: Prefs.SpaceLayout, screen: NSScreen,
                            largest: CGFloat, sized: (CGFloat) -> CGSize) -> Layout {
        var members = Array(repeating: [Int](), count: spaces.count)
        let current = spaces.firstIndex(where: \.current) ?? 0
        for (i, item) in items.enumerated() {
            members[spaces.firstIndex { $0.id == item.home } ?? current].append(i)
        }

        let margin: CGFloat = 0, between: CGFloat = 0, inset: CGFloat = 20, heading: CGFloat = 42
        let gap = Self.gap
        let frame = screen.frame
        let count = spaces.count
        let columns = names.columns > 0 ? min(names.columns, count) : Int(Double(count).squareRoot().rounded(.up))
        let rows = (count + columns - 1) / columns
        let cell = CGSize(width: (frame.width - margin * 2 - between * CGFloat(columns - 1)) / CGFloat(columns),
                          height: (frame.height - margin * 2 - between * CGFloat(rows - 1)) / CGFloat(rows))
        let room = CGSize(width: cell.width - inset * 2, height: cell.height - heading - inset)

        // A tile is base * k plus a fixed header, so the best k for a grid can be solved.
        let fixed = sized(0), one = sized(1)
        let base = CGSize(width: one.width - fixed.width, height: one.height - fixed.height)
        func best(_ count: Int) -> (k: CGFloat, across: Int) {
            var result: (k: CGFloat, across: Int) = (0, 1)
            for across in 1...max(count, 1) {
                let down = (count + across - 1) / across
                let wide = ((room.width + gap) / CGFloat(across) - gap - fixed.width) / base.width
                let tall = ((room.height + gap) / CGFloat(down) - gap - fixed.height) / base.height
                let k = min(largest, wide, tall)
                if k > result.k { result = (k, across) }
            }
            return result
        }

        var frames = Array(repeating: CGRect.zero, count: items.count)
        var groups: [Group] = []
        for (n, space) in spaces.enumerated() {
            let column = n % columns, row = n / columns
            let x = margin + CGFloat(column) * (cell.width + between)
            let top = frame.height - margin - CGFloat(row) * (cell.height + between)
            let inside = members[n]
            // Names sit in the screen's corners, so they lean outwards from the middle.
            let align: CATextLayerAlignmentMode = column == 0 ? .left : column == columns - 1 ? .right : .center
            let labelBelow = rows > 1 && row == rows - 1
            var title = Spaces.name(space, names)
            title = title.isEmpty ? "Desktop" : title
            groups.append(Group(title: title, frame: CGRect(x: x, y: top - cell.height, width: cell.width, height: cell.height),
                                current: space.current, space: space.id, members: inside,
                                edgeRight: column < columns - 1, edgeBottom: row < rows - 1, align: align, labelBelow: labelBelow))
            guard !inside.isEmpty else { continue }
            let (k, across) = best(inside.count)
            let tile = sized(k)
            let down = (inside.count + across - 1) / across
            let drop = (room.height - (CGFloat(down) * (tile.height + gap) - gap)) / 2
            for (m, i) in Self.byPosition(inside, items, across: across).enumerated() {
                let r = m / across, c = m % across
                let inRow = min(across, inside.count - r * across)
                let row = CGFloat(inRow) * (tile.width + gap) - gap
                frames[i] = CGRect(x: x + (cell.width - row) / 2 + CGFloat(c) * (tile.width + gap),
                                   y: top - (labelBelow ? inset : heading) - drop - CGFloat(r + 1) * tile.height - CGFloat(r) * gap,
                                   width: tile.width, height: tile.height)
            }
        }
        return Layout(frame: frame, tiles: frames, groups: groups)
    }

    /// Reading order by where the windows really are: rows from the top of the screen,
    /// then left to right. Nothing here depends on which window you used last, so tiles
    /// stay put from one look to the next. Window number settles exact ties.
    private static func byPosition(_ members: [Int], _ items: [Item], across: Int) -> [Int] {
        func before(_ a: CGFloat, _ b: CGFloat, _ i: Int, _ j: Int) -> Bool { a != b ? a < b : items[i].id < items[j].id }
        let top = members.sorted { before(items[$0].frame.midY, items[$1].frame.midY, $0, $1) }
        return stride(from: 0, to: top.count, by: across).flatMap { start in
            top[start..<min(start + across, top.count)].sorted { before(items[$0].frame.midX, items[$1].frame.midX, $0, $1) }
        }
    }

    /// The next window in a section, wrapping, starting from its most recent.
    func nextWindow(inSection n: Int) -> Int? {
        guard groups.indices.contains(n), !groups[n].members.isEmpty else { return nil }
        let members = groups[n].members
        guard let at = members.firstIndex(of: index) else { return members[0] }
        return members[(at + 1) % members.count]
    }

    /// A tile can be dragged if its window is on one desktop. Windows on every Space,
    /// minimized or hidden windows and full-screen windows have nowhere to move from.
    private func canMove(_ item: Item) -> Bool {
        !item.minimized && !item.hidden && item.pid != getpid() && item.space != 0 && item.space == item.home
    }

    func gridMouse(_ phase: HostView.Phase, _ point: CGPoint) {
        switch phase {
        case .down:
            guard let i = tileIndex(at: point), tiles.indices.contains(i) else { spaceClicked(point); return }
            drag = Drag(index: i, press: point, start: tiles[i].root.position)
            // Most presses are clicks. The grid hides the switch, so it can start now
            // rather than when the button comes up.
            Switcher.shared.startPick(i)

        case .dragged:
            guard var current = drag, items.indices.contains(current.index), canMove(items[current.index]) else { return }
            if !current.moving {
                guard hypot(point.x - current.press.x, point.y - current.press.y) > 6 else { return }
                current.moving = true
                drag = current
                Switcher.shared.undoPick()
                Switcher.shared.select(current.index)
            }
            let tile = tiles[current.index]
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tile.root.zPosition = 950
            tile.root.position = CGPoint(x: current.start.x + point.x - current.press.x, y: current.start.y + point.y - current.press.y)
            selection.isHidden = true
            let accent = selection.borderColor
            let over = groups.firstIndex { $0.frame.contains(point) }
            for (n, section) in sections.enumerated() { section.setTarget(n == over && groups[n].space != items[current.index].home ? accent : nil) }
            CATransaction.commit()

        case .up:
            guard let current = drag else { return }
            drag = nil
            sections.forEach { $0.setTarget(nil) }
            guard current.moving else {
                // A click. Only now is it known not to be a drag.
                if tileIndex(at: point) == current.index {
                    Switcher.shared.select(current.index)
                    Switcher.shared.commit()
                } else {
                    Switcher.shared.undoPick()
                }
                return
            }
            drop(current, at: point)
        }
    }

    private func drop(_ current: Drag, at point: CGPoint) {
        let item = items[current.index]
        let spaces = Store.shared.spaceList
        var before = Dictionary(tiles.prefix(items.count).enumerated().map { (items[$0].id, $1.root.frame) }, uniquingKeysWith: { first, _ in first })
        before[item.id] = tiles[current.index].root.frame
        moveBefore = before
        // Moving between displays could leave a window off screen, so it stays put for now.
        if let target = groups.first(where: { $0.frame.contains(point) }), target.space != item.home,
           spaces.first(where: { $0.id == target.space })?.display == spaces.first(where: { $0.id == item.space })?.display,
           Priv.move(item.id, to: target.space) {
            Log.write("moved \(item.appName) to \(target.title)")
            Store.shared.schedule(after: 0.04)
            Store.shared.lookAgainSoon()
        }
        // No change means it didn't move, or wasn't asked to, so it goes back.
        let wait = target(of: point) == item.home ? 0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.moveBefore != nil, self.shown else { return }
            self.prepare(self.items, index: self.index, grid: true)
        }
    }

    private func target(of point: CGPoint) -> UInt64? { groups.first { $0.frame.contains(point) }?.space }

    /// Tiles glide from where they were to where the new layout puts them. Reduced Motion
    /// keeps this: you're moving the tile yourself, so it shows where the window went.
    private func settleMoves(from before: [CGWindowID: CGRect]) {
        for (i, tile) in tiles.prefix(items.count).enumerated() {
            let to = tile.root.frame
            guard let from = before[items[i].id], from != to, to.width > 0 else { continue }
            let scale = from.width / to.width
            let start = CATransform3DScale(CATransform3DMakeTranslation(from.midX - to.midX, from.midY - to.midY, 0), scale, scale, 1)
            let glide = CABasicAnimation(keyPath: "transform")
            glide.fromValue = start
            glide.toValue = CATransform3DIdentity
            glide.duration = 0.26
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            tile.root.add(glide, forKey: "move")
        }
    }

    /// For the self test: a drag from one tile to one cell, through the real handlers.
    func simulateDrag(_ i: Int, toCell n: Int) {
        let from = CGPoint(x: tiles[i].root.frame.midX, y: tiles[i].root.frame.midY)
        let to = CGPoint(x: groups[n].frame.midX, y: groups[n].frame.midY)
        gridMouse(.down, from)
        gridMouse(.dragged, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2))
        gridMouse(.dragged, to)
        gridMouse(.up, to)
    }

    var sectionSpaces: [UInt64] { groups.map(\.space) }
    var gliding: Int { tiles.filter { $0.root.animation(forKey: "move") != nil }.count }

    private func spaceClicked(_ point: CGPoint) {
        guard let group = groups.first(where: { $0.frame.contains(point) }) else {
            // Nothing else ends a grid opened by a swipe with the mouse.
            if Switcher.shared.isSticky { Switcher.shared.cancel() }
            return
        }
        if let first = group.members.first {
            Switcher.shared.select(first)
            Switcher.shared.commit()
        } else {
            Switcher.shared.go(to: group.space)
        }
    }

    /// For the self test.
    var sectionFrames: [CGRect] { groups.map(\.frame) }
    var isVisible: Bool { shown }
    var windowAlpha: CGFloat { panel.alphaValue }
    var scrubProgress: Double { progress }
    /// What's really on screen: the window's alpha and the content's fade together.
    var contentOpacity: Float {
        guard let layer = panel.contentView?.layer else { return 0 }
        return (layer.presentation()?.opacity ?? layer.opacity) * Float(panel.alphaValue)
    }

    /// For the self test: at the closed end of the timeline, how big each picture is
    /// compared with its real window. 1 is exact.
    func closedSizes() -> [(name: String, ratio: Double, needed: Double)] {
        beginScrub(at: 0)
        CATransaction.flush()
        let rects = windowRects()
        defer { hide() }
        return items.enumerated().compactMap { i, item in
            guard tiles.indices.contains(i), let real = rects[item.id] else { return nil }
            let picture = tiles[i].pictureFrame
            guard picture.width > 0, let scale = tiles[i].root.presentation()?.transform.m11 else { return nil }
            return (item.appName, scale * picture.width / real.width, real.width / picture.width)
        }
    }
    var isOpaque: Bool { panel.isOpaque }
    var hasBackdrop: Bool { backdropReady }
    var chosenPictureWidth: Int { DispatchQueue.main.sync { tiles.first?.pictureWidth ?? 0 } }
    var animationsRunning: Int { (tiles.map(\.root) + sections.map(\.root)).filter { $0.animation(forKey: "open") != nil }.count }
    var fillsScreen: Bool { panel.frame == panel.screen?.frame }
    var sectionTitles: [String] { groups.map(\.title) }
    func tileFrame(_ i: Int) -> CGRect { tiles[i].root.frame }

    /// The closest tile in a direction. dy of 1 is down the screen.
    func neighbour(dx: Int, dy: Int) -> Int? {
        guard tiles.indices.contains(index) else { return nil }
        let from = tiles[index].root.frame
        var best: (index: Int, score: CGFloat)?
        for i in 0..<min(items.count, tiles.count) where i != index {
            let to = tiles[i].root.frame
            let x = to.midX - from.midX, y = from.midY - to.midY
            let along = x * CGFloat(dx) + y * CGFloat(dy)
            guard along > 1 else { continue }
            let score = along + abs(dx != 0 ? y : x) * 2
            if best == nil || score < best!.score { best = (i, score) }
        }
        return best?.index
    }

    /// Screen position of a tile, top-left origin, for the self test's mouse clicks.
    func tileCenter(_ i: Int) -> CGPoint? {
        guard tiles.indices.contains(i) else { return nil }
        let r = panel.convertToScreen(host.convert(tiles[i].root.frame, to: nil))
        return CGPoint(x: r.midX, y: (NSScreen.screens.first?.frame.height ?? 0) - r.midY)
    }

    private func tileIndex(at point: CGPoint) -> Int? {
        tiles.prefix(items.count).firstIndex { $0.root.frame.contains(point) }
    }

    private func placeSelection() {
        guard tiles.indices.contains(index), index < items.count else { selection.isHidden = true; return }
        selection.isHidden = false
        selection.frame = tiles[index].root.frame.insetBy(dx: -1, dy: -1)
        host.layer?.addSublayer(selection)
    }

    func select(_ index: Int) {
        self.index = index
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeSelection()
        CATransaction.commit()
        guard showingGrid, shown, items.indices.contains(index) else { return }
        // Pointing at a window: get everything ready in case you pick it.
        let item = items[index]
        hovering?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Store.shared.tracker(for: item.pid) { $0.wake() }
            if !self.reduced, !item.minimized, !item.hidden { self.fetchSharp([item.id]) }
        }
        hovering = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func reveal(animated: Bool = false) {
        guard !items.isEmpty else { return }
        if animated {
            beginScrub(at: 0)
            endScrub(open: true, velocity: 0)
            return
        }
        shown = true
        host.armMouse()
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        if showingGrid { requestBackdrop() }
        CATransaction.flush()
    }

    func hide() {
        shown = false
        panel.alphaValue = 0
        endScrubState()
        dropSharpened()
        clearBackdrop()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        if showingGrid {
            tiles.forEach { $0.letGo() }
            // Back to the panel now, while nobody's waiting. Resizing from full screen took
            // 8 ms, and on the next ⌘Tab that would come out of the 0.5 ms it should take.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, !self.shown, !self.scrubbing, !Switcher.shared.isActive else { return }
                self.prepare(Switcher.shared.restingItems, index: 0)
            }
        }
        CATransaction.flush()
    }

    /// Full-size pictures for the zoom, taken while you're only looking at the grid. On
    /// the click they'd compete with the switch itself and show up as a stutter.
    private func fetchSharp(_ ids: [CGWindowID]) {
        let wanted = ids.filter { sharp[$0] == nil }
        guard !wanted.isEmpty else { return }
        let count = sharpCount
        Self.sharpQueue.async { [weak self] in
            for id in wanted {
                guard let full = Priv.capture(id) else { continue }
                DispatchQueue.main.async {
                    guard let self, self.sharpCount == count else { return }
                    self.sharp[id] = full
                    // Picked before this arrived: the zoom starts slowly, so it can still use it.
                    if self.closing, let i = self.items.firstIndex(where: { $0.id == id }), self.tiles.indices.contains(i) {
                        self.tiles[i].showFull(full)
                        self.sharpened.append((self.tiles[i], id))
                    }
                }
            }
        }
    }

    private static let sharpQueue = DispatchQueue(label: "flick.sharp", qos: .userInitiated)

    private func fetchVisibleSharp() {
        let visible = Store.shared.visibleSpaces
        fetchSharp(items.filter { !$0.minimized && !$0.hidden && visible.contains($0.space) }.prefix(6).map(\.id))
    }

    /// A full window picture is tens of megabytes, so they go as soon as the zoom ends.
    private func dropSharpened() {
        sharp = [:]
        sharpCount += 1
        hovering?.cancel()
        guard !sharpened.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for entry in sharpened { entry.tile.setThumbnail(Thumbs.shared.image(entry.id)) }
        CATransaction.commit()
        sharpened = []
    }

    /// A full-screen window with anything see-through in it keeps the WindowServer
    /// redrawing every window underneath, and live glass on top of that. It took the GPU
    /// from about 40% to 80%. So the grid sits on your wallpaper, blurred once and kept,
    /// and when it's still the window goes opaque and all of that stops: about 3%.
    private func requestBackdrop() {
        guard !backdropReady, let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        // As Launchpad does: the dark version whatever the appearance, rich and unwashed.
        let dark = true
        let prefs = Prefs.current
        let key = "\(url.path) \(prefs.tint?.description ?? "")"
        if let wallpaper, wallpaper.key == key {
            useBackdrop(wallpaper.image)
            return
        }
        backdropCount += 1
        let count = backdropCount
        // Small on purpose: it's about to be blurred, and the layer scales it back up.
        let side = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor / 8)
        let veil = NSColor.black.withAlphaComponent(0.08).cgColor
        let tint = prefs.tint?.cgColor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let began = now()
            guard let picture = Self.loadWallpaper(url, dark: dark, side: side),
                  let image = Self.blurred(picture, veil: veil, tint: tint) else { return }
            Log.write("wallpaper loaded in \(String(format: "%.1f", ms(since: began)))ms")
            DispatchQueue.main.async {
                guard let self else { return }
                self.wallpaper = (key, image)   // kept: it's only about 600 KB
                if self.backdropCount == count, self.shown || self.scrubbing { self.useBackdrop(image) }
            }
        }
    }

    private func useBackdrop(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = image
        backdrop.isHidden = false
        CATransaction.commit()
        glass?.isHidden = true
        backdropReady = true
        if shown, !scrubbing { settleBackdrop() }
    }

    /// Dynamic wallpapers hold several pictures. Their metadata says which is for light
    /// and which for dark.
    static func loadWallpaper(_ url: URL, dark: Bool, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var index = CGImageSourceGetPrimaryImageIndex(source)
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
           let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, "apple_desktop:apr" as CFString) as String?,
           let data = Data(base64Encoded: text),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let chosen = plist[dark ? "d" : "l"] as? Int, chosen < CGImageSourceGetCount(source) {
            index = chosen
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side,
                       kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, index, options)
    }

    static func blurred(_ image: CGImage, veil: CGColor, tint: CGColor?) -> CGImage? {
        let input = CIImage(cgImage: image)
        let soft = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7])
            .cropped(to: input.extent)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let result = CIContext().createCGImage(soft, from: input.extent),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(result, in: bounds)
        ctx.setFillColor(veil)
        ctx.fill(bounds)
        if let tint {
            ctx.setFillColor(tint)
            ctx.fill(bounds)
        }
        return ctx.makeImage()
    }

    /// For the self test: does an opaque grid make the apps it covers slower to pick?
    var neverOpaque = false
    private(set) var lastArrival: Double?

    private func settleBackdrop() {
        guard backdropReady, showingGrid, shown, !panel.isOpaque, !neverOpaque else { return }
        panel.backgroundColor = .black
        panel.isOpaque = true
    }

    private func unsettleBackdrop() {
        guard panel.isOpaque else { return }
        panel.isOpaque = false
        panel.backgroundColor = .clear
    }

    private func clearBackdrop() {
        backdropCount += 1
        backdropReady = false
        unsettleBackdrop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = nil
        backdrop.isHidden = true
        CATransaction.commit()
        glass?.isHidden = false
    }

    private func endScrubState(stayOpaque: Bool = false) {
        panel.contentView?.layer?.removeAnimation(forKey: "closeFade")
        if !stayOpaque { unsettleBackdrop() }
        ticker?.stop()
        ticker = nil
        scrubbing = false
        closing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tiles.map(\.root) + sections.map(\.root) + [selection] {
            layer.removeAnimation(forKey: "open")
            layer.removeAnimation(forKey: "openFade")
        }
        tiles.forEach { $0.stopHeaderFade() }
        host.layer?.speed = 1
        host.layer?.timeOffset = 0
        CATransaction.commit()
    }

    /// A rectangle from the window list, in the panel's own coordinates.
    private func inPanel(_ r: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.height ?? 0
        let origin = panel.frame.origin
        return CGRect(x: r.minX - origin.x, y: top - r.maxY - origin.y, width: r.width, height: r.height)
    }

    /// Where each window on screen is right now.
    private func windowRects() -> [CGWindowID: CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? else { return [:] }
        var rects: [CGWindowID: CGRect] = [:]
        for case let w as NSDictionary in list {
            guard (w[kCGWindowLayer] as? Int) == 0, let id = w[kCGWindowNumber] as? CGWindowID,
                  let bounds = w[kCGWindowBounds] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bounds) else { continue }
            rects[id] = inPanel(r)
        }
        return rects
    }

    /// One step of the opening, placed on a timeline from 0 (closed) to 1 (open). The
    /// timeline doesn't play by itself: `host` is paused and a finger or a spring moves it.
    private func step(_ keyPath: String, _ from: Any, _ to: Any, begin: Double, length: Double, eased: Bool = false) -> CABasicAnimation {
        let step = CABasicAnimation(keyPath: keyPath)
        step.fromValue = from
        step.toValue = to
        step.beginTime = max(begin, 0.000001)   // 0 would mean "now"
        step.duration = length
        step.fillMode = .both
        step.isRemovedOnCompletion = false
        if eased { step.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) }
        return step
    }

    /// Windows on screen run from where they really are to their tiles. Everything else
    /// settles into place around them.
    private func addTimeline(into focus: Item? = nil) {
        guard !reduced else { return }
        // Going to another Space, the windows here aren't what's coming, so only the
        // chosen one has somewhere to fly to.
        let staying = focus.map { $0.space == 0 || Store.shared.visibleSpaces.contains($0.space) } ?? true
        var rects = staying ? windowRects() : [:]
        if let focus {
            rects[focus.id] = focus.minimized || focus.hidden ? nil : rects[focus.id] ?? inPanel(focus.frame)
        }
        let visible = CGRect(origin: .zero, size: panel.frame.size)
        let identity = CATransform3DIdentity
        for (n, section) in sections.prefix(groups.count).enumerated() {
            let begin = Double(n) * 0.04
            section.root.add(step("opacity", 0, 1, begin: begin, length: 0.6), forKey: "openFade")
        }
        for (i, tile) in tiles.prefix(items.count).enumerated() {
            let to = tile.root.frame
            let picture = tile.pictureFrame
            let chosen = items[i].id == focus?.id
            tile.root.zPosition = chosen ? 900 : CGFloat(items.count - i)
            if let from = rects[items[i].id], from.intersects(visible), picture.width > 0 {
                // Starts with the picture exactly over the real window. The tile scales
                // around its centre, so the picture's offset scales too.
                let scale = from.width / picture.width
                let offset = CGPoint(x: picture.midX - to.width / 2, y: picture.midY - to.height / 2)
                let start = CATransform3DScale(CATransform3DMakeTranslation(from.midX - scale * offset.x - to.midX,
                                                                            from.midY - scale * offset.y - to.midY, 0), scale, scale, 1)
                tile.root.add(step("transform", start, identity, begin: 0, length: 1), forKey: "open")
                for layer in tile.header { layer.add(step("opacity", 0, 1, begin: 0.82, length: 0.18), forKey: "openFade") }
            } else {
                let begin = 0.08 + Double(min(i, 12)) * 0.012
                tile.root.add(step("transform", CATransform3DMakeScale(0.86, 0.86, 1), identity, begin: begin, length: 0.6, eased: true), forKey: "open")
                tile.root.add(step("opacity", 0, 1, begin: begin, length: 0.5), forKey: "openFade")
            }
        }
        selection.add(step("opacity", 0, 1, begin: 0.75, length: 0.25), forKey: "openFade")
    }

    /// Puts the grid at a point on its opening: 0 closed, 1 open.
    func beginScrub(at start: Double) {
        guard !items.isEmpty else { return }
        startTimeline(at: start, into: nil)
        shown = true
        if showingGrid { requestBackdrop() }
        host.armMouse()
        panel.ignoresMouseEvents = false
    }

    /// Picking a window: the grid stays up while the switch happens behind it, and the
    /// tile grows into the real window, so the old window never shows in between.
    func closeInto(_ item: Item?) {
        guard shown, showingGrid else { hide(); return }
        guard !reduced else {
            fadeHoldNow = item.map { $0.space != 0 && !Store.shared.visibleSpaces.contains($0.space) } == true ? Self.jumpHold : Self.fadeHold
            watchArrival(of: item.flatMap { $0.minimized || $0.hidden ? nil : $0 })
            fadeOut()
            return
        }
        guard let item else { hide(); return }
        let from = scrubbing ? progress : 1
        // A thumbnail stretched to window size is blurry, so the zoom gets the real pixels.
        // They're already here if you spent a moment in the grid.
        let began = now()
        for (i, other) in items.enumerated() where tiles.indices.contains(i) {
            guard let full = sharp[other.id] else { continue }
            tiles[i].showFull(full)
            sharpened.append((tiles[i], other.id))
        }
        watchArrival(of: item.minimized || item.hidden ? nil : item)
        startTimeline(at: from, into: item, stayOpaque: true)
        if sharp[item.id] == nil, !item.minimized, !item.hidden { fetchSharp([item.id]) }
        Log.write("close started in \(String(format: "%.2f", ms(since: began)))ms, \(sharpened.count) sharp, opaque \(panel.isOpaque)")
        closing = true
        shown = false
        panel.ignoresMouseEvents = true
        endScrub(open: false, velocity: 0)
    }

    /// Nothing moves, from the setting here or the one in System Settings.
    private var reduced: Bool { Prefs.current.reducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Esc and the like: a fade in Reduced Motion, otherwise gone at once.
    func dismiss() {
        fadeHoldNow = Self.fadeHold
        arrived = true
        if reduced, shown, showingGrid, !scrubbing { fadeOut() } else { hide() }
    }

    private func fadeOut() {
        startTimeline(at: 1, into: nil, stayOpaque: true)
        closing = true
        shown = false
        panel.ignoresMouseEvents = true
        endScrub(open: false, velocity: 0)
    }

    private func startTimeline(at start: Double, into focus: Item?, stayOpaque: Bool = false) {
        endScrubState(stayOpaque: stayOpaque)
        scrubbing = true
        progress = start
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layer?.speed = 0
        host.layer?.timeOffset = start
        addTimeline(into: focus)
        CATransaction.commit()
        panel.alphaValue = alpha(start)
        CATransaction.flush()
    }

    /// The glass eases in across nearly the whole opening, with no edge where it stops.
    private func alpha(_ progress: Double) -> CGFloat {
        let x = min(1, max(0, progress / 0.9))
        return CGFloat(x * x * (3 - 2 * x))
    }

    func scrub(to value: Double) {
        guard scrubbing, ticker == nil else { return }
        progress = min(1, max(0, value))
        show(progress)
    }

    private func show(_ value: Double, opacity: CGFloat? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.layer?.timeOffset = value
        CATransaction.commit()
        panel.alphaValue = opacity ?? alpha(value)
        // See-through only for as long as it has to be: once the background has fully faded
        // in, the WindowServer can stop drawing everything underneath, tiles still moving.
        if !closing {
            if value >= 0.9 { settleBackdrop() } else { unsettleBackdrop() }
        }
    }

    /// Lets go. A short curve of fixed length carries on at the finger's speed and comes
    /// to rest exactly on time, with none of the slow creep a spring has at the end.
    func endScrub(open: Bool, velocity: Double) {
        guard scrubbing, ticker == nil else { return }
        let target = open ? 1.0 : 0.0
        let distance = target - progress
        guard closing || abs(distance) > 0.002 else { land(open); return }
        let fading = closing && reduced
        let zooming = closing && !reduced
        let start = progress, began = now()
        let settling = 0.26 + 0.1 * abs(distance)
        // 1 - (1 - t)^power starts at `power` times the average speed, so a faster finger
        // gets a steeper curve and carries straight into it.
        let toward = velocity * (distance > 0 ? 1 : -1)
        let power = abs(distance) > 0 ? min(max(toward * settling / abs(distance), 4), 6) : 4
        // Closing has two steps that never overlap: first the part that shows the window
        // coming (the zoom, or a still hold), and only then the fade that uncovers it.
        let first = fading ? fadeHoldNow : Self.zoomLength
        let fadeLength = (fading ? Self.fadeLength : Self.zoomFade) * Self.slowdown
        let firstLength = first * Self.slowdown
        var fadeBegan: UInt64?
        var fadeSent = false
        let ticker = Ticker { [weak self] in
            guard let self else { return }
            guard self.closing else {
                let t = min(ms(since: began) / 1000 / (settling * Self.slowdown), 1)
                self.progress = start + distance * (1 - pow(1 - t, power))
                self.show(self.progress)
                if t >= 1 { self.land(open) }
                return
            }
            let elapsed = ms(since: began) / 1000
            if zooming { self.progress = start + distance * Self.zoomCurve(min(elapsed / firstLength, 1)) }
            // Opaque means the WindowServer has nothing else to draw while the switch happens.
            // It lets go before anything needs to look smooth, as the redraw of everything
            // underneath costs a few frames.
            if elapsed > firstLength * (zooming ? 0.7 : 0.5) { self.unsettleBackdrop() }
            // Uncover the window when it's really there, not after a set time: an app that
            // hasn't been used for a while can take half a second. The cap keeps a hung app
            // from holding the grid up.
            if fadeBegan == nil, elapsed >= firstLength, self.arrived || elapsed >= Self.arrivalCap * Self.slowdown {
                fadeBegan = now()
                Log.write(String(format: "fade started %.0fms after the click, window \(self.arrived ? "there" : "not there yet")", elapsed * 1000))
            }
            guard let fadeBegan else {
                self.show(self.progress, opacity: 1)
                return
            }
            let left = max(1 - ms(since: fadeBegan) / 1000 / fadeLength, 0)
            // The render server runs this, so nothing happening here can make it hitch. Run
            // from here, a busy moment just after a click froze it for 100 ms.
            if !fadeSent {
                fadeSent = true
                if zooming { self.show(0, opacity: 1) }
                self.fadeOnRenderServer(fadeLength)
            }
            if left <= 0 {
                self.progress = 0
                self.land(false)
            }
        }
        self.ticker = ticker
        ticker.start(on: host)
        // Refresh callbacks stop for a display that sleeps or disconnects, and the overlay
        // must never be left partway. If this one is still going, finish it now.
        let longest = closing ? Self.arrivalCap + first + Self.fadeLength : settling
        DispatchQueue.main.asyncAfter(deadline: .now() + longest * Self.slowdown + 0.15) { [weak self, weak ticker] in
            guard let self, let ticker, self.ticker === ticker else { return }
            Log.write("landing finished by the backstop")
            self.progress = target
            self.show(target)
            self.land(open)
        }
    }

    private func fadeOnRenderServer(_ seconds: Double) {
        guard let layer = panel.contentView?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = seconds
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "closeFade")
        CATransaction.flush()
    }

    /// Watches for the picked window reaching the top of its Space.
    private func watchArrival(of item: Item?) {
        closeCount += 1
        let count = closeCount
        arrived = item == nil
        guard let item else { return }
        let own = getpid()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let began = now()
            while ms(since: began) < Self.arrivalCap * 1000 * Self.slowdown {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? ?? []
                // Its own window has to be on screen, or an app with windows on this Space
                // too would seem to have arrived before the jump.
                let present = list.contains { ($0 as? NSDictionary)?[kCGWindowNumber] as? CGWindowID == item.id }
                for case let w as NSDictionary in list where present && (w[kCGWindowLayer] as? Int) == 0 {
                    guard let pid = w[kCGWindowOwnerPID] as? pid_t, pid != own, let bounds = w[kCGWindowBounds] as? NSDictionary,
                          let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 200, rect.height >= 150 else { continue }
                    if (w[kCGWindowNumber] as? CGWindowID) == item.id || pid == item.pid {
                        let took = ms(since: began)
                        Log.write(String(format: "window arrived %.0fms after the click", took))
                        DispatchQueue.main.async {
                            guard let self, self.closeCount == count else { return }
                            self.arrived = true
                            self.lastArrival = took
                        }
                        return
                    }
                    break
                }
                usleep(6000)
            }
        }
    }

    private static let zoomLength = 0.28, zoomFade = 0.11
    private static let fadeHold = 0.06, fadeLength = 0.18
    private static let jumpHold = 0.16   // another Space has to be built first
    private static let arrivalCap = 0.7  // the longest the grid waits for a window

    /// The cubic bezier (0.2, 0, 0, 1). The zoom starts from rest, with no finger to carry
    /// on from, so it eases in briefly before the long ease-out.
    private static func zoomCurve(_ t: Double) -> Double {
        guard t > 0, t < 1 else { return t <= 0 ? 0 : 1 }
        func x(_ u: Double) -> Double { 3 * (1 - u) * (1 - u) * u * 0.2 + u * u * u }
        func y(_ u: Double) -> Double { 3 * (1 - u) * u * u + u * u * u }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if x(middle) < t { low = middle } else { high = middle }
        }
        return y((low + high) / 2)
    }

    private func land(_ open: Bool) {
        if open {
            endScrubState()
            panel.alphaValue = 1
            settleBackdrop()
            CATransaction.flush()
            if showingGrid, !reduced { fetchVisibleSharp() }
        } else if closing {
            hide()
        } else {
            Switcher.shared.cancel()
        }
    }

    /// For the self test, to see an animation frame by frame.
    private static let slowdown = Double(ProcessInfo.processInfo.environment["FLICK_SLOWOPEN"] ?? "") ?? 1

    func thumbnailChanged(_ id: CGWindowID) {
        guard showingThumbnails,
              let i = items.firstIndex(where: { $0.id == id }), tiles.indices.contains(i),
              let image = Thumbs.shared.image(id) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiles[i].setThumbnail(image, fade: shown)
        CATransaction.commit()
    }

    /// For the self test: how much of a tile's old thumbnail is still showing.
    func fadeLevel(_ i: Int) -> Float { tiles[i].fadeLevel }
    var windowID: CGWindowID { CGWindowID(truncatingIfNeeded: panel.windowNumber) }
}

final class HostView: NSView {
    enum Phase { case down, dragged, up }

    var gridMouse: ((Phase, CGPoint) -> Void)?
    var hitTiles: ((CGPoint) -> Int?)?
    var missedTiles: ((CGPoint) -> Void)?
    private var tracking: NSTrackingArea?
    private var armedAt: NSPoint?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The cursor may already be over a tile when the switcher opens. Only a real
    /// move should change the selection.
    func armMouse() { armedAt = NSEvent.mouseLocation }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        if let armedAt, hypot(NSEvent.mouseLocation.x - armedAt.x, NSEvent.mouseLocation.y - armedAt.y) < 3 { return }
        armedAt = nil
        if let i = hitTiles?(convert(event.locationInWindow, from: nil)) { Switcher.shared.select(i) }
    }

    override func mouseDragged(with event: NSEvent) { gridMouse?(.dragged, convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { gridMouse?(.up, convert(event.locationInWindow, from: nil)) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let gridMouse {
            gridMouse(.down, point)
            return
        }
        if let i = hitTiles?(point) {
            Switcher.shared.select(i)
            Switcher.shared.commit()
        } else {
            missedTiles?(point)
        }
    }
}

/// Calls back once per screen refresh, in step with the display.
private final class Ticker: NSObject {
    private let body: () -> Void
    private var link: AnyObject?
    private var timer: Timer?

    init(_ body: @escaping () -> Void) { self.body = body }

    @objc private func tick() { body() }

    func start(on view: NSView) {
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        timer?.invalidate()
        link = nil
        timer = nil
    }
}

/// A Space in the grid. No box of its own: a name, and a thin line where it meets the next.
private final class Section {
    let root = CALayer()
    private let title = CATextLayer()
    private let right = CALayer()
    private let bottom = CALayer()

    init() {
        title.truncationMode = .end
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.fontSize = 13
        root.addSublayer(right)
        root.addSublayer(bottom)
        root.addSublayer(title)
    }

    /// Being dropped on: the only time a Space shows a fill.
    func setTarget(_ color: CGColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.backgroundColor = color?.copy(alpha: 0.18)
        CATransaction.commit()
    }

    func update(_ text: String, frame: CGRect, scale: CGFloat, label: CGColor, halo: CGColor?,
                current: Bool, line: CGColor, edgeRight: Bool, edgeBottom: Bool,
                align: CATextLayerAlignmentMode, labelBelow: Bool) {
        root.isHidden = false
        root.frame = frame
        let hairline = 1 / max(scale, 1)
        right.isHidden = !edgeRight
        bottom.isHidden = !edgeBottom
        right.backgroundColor = line
        bottom.backgroundColor = line
        right.frame = CGRect(x: frame.width - hairline, y: 0, width: hairline, height: frame.height)
        bottom.frame = CGRect(x: 0, y: 0, width: frame.width, height: hairline)
        title.contentsScale = scale
        title.foregroundColor = label
        title.opacity = current ? 1 : 0.6
        title.shadowColor = halo
        title.shadowOpacity = halo == nil ? 0 : 0.9
        title.shadowRadius = 2.5
        title.shadowOffset = .zero
        title.string = text
        title.alignmentMode = align
        title.frame = CGRect(x: 20, y: labelBelow ? 14 : frame.height - 32, width: frame.width - 40, height: 18)
    }
}

private final class Tile {
    let root = CALayer()
    private let icon = CALayer()
    private let title = CATextLayer()
    private let thumb = CALayer()
    private let placeholder = CALayer()
    private let outgoing = CALayer()
    private var box = CGRect.zero

    var fadeLevel: Float { outgoing.presentation()?.opacity ?? 0 }

    init() {
        title.truncationMode = .end
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        thumb.cornerRadius = 7
        thumb.masksToBounds = true
        thumb.contentsGravity = .resizeAspect
        icon.contentsGravity = .resizeAspect
        placeholder.contentsGravity = .resizeAspect
        outgoing.cornerRadius = 7
        outgoing.masksToBounds = true
        outgoing.contentsGravity = .resizeAspect
        outgoing.opacity = 0
        root.addSublayer(thumb)
        root.addSublayer(placeholder)
        root.addSublayer(outgoing)
        root.addSublayer(icon)
        root.addSublayer(title)
    }

    func update(_ item: Item, size: CGSize, thumbnails: Bool, titles: Bool, icons: Bool, scale: CGFloat, label: CGColor, halo: CGColor?) {
        let inset: CGFloat = 8
        for layer in [title, icon, thumb, placeholder, outgoing] { layer.contentsScale = scale }
        title.foregroundColor = label
        // Clear glass can put anything behind the text, so it carries its own contrast.
        title.shadowColor = halo
        title.shadowOpacity = halo == nil ? 0 : 0.9
        title.shadowRadius = 2.5
        title.shadowOffset = .zero
        title.string = item.title
        title.fontSize = 12
        title.isHidden = !titles
        icon.contents = item.icon
        placeholder.contents = item.icon

        if thumbnails {
            let header: CGFloat = titles || icons ? 26 : 8
            icon.isHidden = !icons
            icon.frame = CGRect(x: inset, y: size.height - header + 3, width: 18, height: 18)
            let left = inset + (icons ? 23 : 0)
            title.alignmentMode = .left
            title.frame = CGRect(x: left, y: size.height - header + 4, width: size.width - left - inset, height: 16)
            box = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - header - inset)
            setThumbnail(Thumbs.shared.image(item.id))
        } else {
            thumb.isHidden = true
            placeholder.isHidden = true
            icon.isHidden = false
            let room = size.height - (titles ? 28 : 0)
            let side = min(size.width, room) * 0.72
            icon.frame = CGRect(x: (size.width - side) / 2, y: size.height - room + (room - side) / 2, width: side, height: side)
            title.alignmentMode = .center
            title.frame = CGRect(x: inset, y: 8, width: size.width - inset * 2, height: 16)
        }
    }

    /// The old picture sits on top and fades out over the new one, which is already
    /// fully drawn, so the glass never shows through partway.
    var pictureFrame: CGRect { thumb.isHidden ? root.bounds : thumb.frame }

    /// Core Animation keeps its own copy of what a layer shows. The cache has the original.
    func letGo() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.contents = nil
        CATransaction.commit()
    }
    var pictureWidth: Int { (thumb.contents as! CGImage?)?.width ?? 0 }

    /// Same picture and shape, at the window's full resolution.
    func showFull(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.contents = image
        placeholder.isHidden = true
        thumb.isHidden = false
        CATransaction.commit()
    }

    /// A title scaled up to window size looks wrong, so it arrives as the tile lands.
    var header: [CALayer] { [title, icon] }

    func stopHeaderFade() {
        for layer in [title, icon] { layer.removeAnimation(forKey: "openFade") }
    }

    func setThumbnail(_ image: CGImage?, fade: Bool = false) {
        let shown = thumb.isHidden ? placeholder : thumb
        if fade, let old = shown.contents {
            outgoing.contents = old
            outgoing.frame = shown.frame
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            outgoing.add(animation, forKey: "fade")
        } else if (thumb.contents as AnyObject?) !== image {
            outgoing.removeAllAnimations()
            outgoing.contents = nil
        }

        placeholder.isHidden = image != nil
        thumb.isHidden = image == nil
        guard let image else {
            let side = min(box.width, box.height) * 0.6
            placeholder.frame = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            thumb.contents = nil
            return
        }
        let ratio = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = CGFloat(image.width) * ratio, h = CGFloat(image.height) * ratio
        thumb.frame = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        thumb.contents = image
    }
}
