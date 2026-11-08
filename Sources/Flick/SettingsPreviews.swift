import SwiftUI

/// The desktop picture, small, for the previews in Settings. `grid` is the blurred
/// dark version the Spaces grid sits on.
final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()

    @Published private(set) var plain: CGImage?
    @Published private(set) var grid: CGImage?
    private var key = ""

    func load() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(url.path) \(dark)"
        guard key != self.key else { return }
        self.key = key
        DispatchQueue.global(qos: .userInitiated).async {
            let plain = Overlay.loadWallpaper(url, dark: dark, side: 900)
            let grid = Overlay.loadWallpaper(url, dark: true, side: 360).flatMap {
                Overlay.blurred($0, veil: NSColor.black.withAlphaComponent(0.08).cgColor, tint: nil)
            }
            DispatchQueue.main.async {
                self.plain = plain
                self.grid = grid
            }
        }
    }
}

private struct Backdrop: View {
    let image: CGImage?

    var body: some View {
        // Takes the size it's offered, whatever the picture's shape.
        Color.clear
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [Color(white: 0.45), Color(white: 0.25)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
    }
}

/// The switcher's own glass, so the preview matches it.
private struct Glass: NSViewRepresentable {
    let clear: Bool
    let tint: NSColor?
    let radius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) { return NSGlassEffectView() }
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.style = clear ? .clear : .regular
            glass.tintColor = tint
            glass.cornerRadius = radius
        } else {
            view.layer?.cornerRadius = radius
        }
    }
}

// MARK: Switcher

/// The ⌘Tab switcher in miniature, with your windows, following the settings as they change.
struct SwitcherPreview: View {
    struct Style {
        var size: Double
        var corners: Double
        var clear: Bool
        var tint: NSColor?
        var highlight: NSColor?
        var thumbnails: Bool
        var titles: Bool
        var icons: Bool
    }

    private struct Sample: Identifiable {
        let id: Int
        let title: String
        let icon: CGImage?
        let picture: CGImage?
    }

    let style: Style
    @ObservedObject private var wallpaper = Wallpaper.shared
    @State private var samples: [Sample] = []
    @Environment(\.colorScheme) private var scheme

    private let k: CGFloat = 0.44          // the preview's scale
    private let height: CGFloat = 200

    var body: some View {
        ZStack {
            Backdrop(image: wallpaper.plain)
                .frame(height: height)
                .clipped()
            panel
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the switcher")
        .onAppear {
            Wallpaper.shared.load()
            samples = Self.collect()
        }
    }

    private var tile: CGSize {
        let s = CGFloat(style.size)
        let header: CGFloat = style.titles || style.icons ? 26 : 8
        return style.thumbnails ? CGSize(width: 232 * s * k, height: (150 * s + header) * k)
                                : CGSize(width: 136 * s * k, height: (96 * s + (style.titles ? 28 : 0)) * k)
    }

    private var panel: some View {
        HStack(spacing: 6 * k) {
            ForEach(samples) { sample in
                tileView(sample)
                    .frame(width: tile.width, height: tile.height)
                    .overlay {
                        if sample.id == 1 {
                            RoundedRectangle(cornerRadius: max(style.corners - 14 + 2, 4) * k)
                                .stroke(Color(nsColor: style.highlight ?? .controlAccentColor), lineWidth: 2)
                                .padding(-1)
                        }
                    }
            }
        }
        .padding(14 * k)
        .background(Glass(clear: style.clear, tint: style.tint, radius: style.corners * k))
    }

    private var halo: Color {
        style.clear ? Color(nsColor: .windowBackgroundColor).opacity(0.9) : .clear
    }

    @ViewBuilder
    private func tileView(_ sample: Sample) -> some View {
        let font = Font.system(size: max(12 * k, 7), weight: .medium)
        if style.thumbnails {
            VStack(alignment: .leading, spacing: 0) {
                if style.titles || style.icons {
                    HStack(spacing: 5 * k) {
                        if style.icons, let icon = sample.icon {
                            Image(decorative: icon, scale: 1).resizable().frame(width: 18 * k, height: 18 * k)
                        }
                        if style.titles {
                            Text(sample.title).font(font).lineLimit(1).shadow(color: halo, radius: 1.5)
                        }
                    }
                    .frame(height: 18 * k)
                    .padding(.top, 4 * k)
                    .padding(.bottom, 4 * k)
                } else {
                    Spacer().frame(height: 8 * k)
                }
                ZStack {
                    if let picture = sample.picture {
                        Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 7 * k))
                    } else if let icon = sample.icon {
                        Image(decorative: icon, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .padding(tile.height * 0.18)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 8 * k)
            }
            .padding(.horizontal, 8 * k)
        } else {
            VStack(spacing: 0) {
                if let icon = sample.icon {
                    let room = tile.height - (style.titles ? 28 * k : 0)
                    let side = min(tile.width, room) * 0.72
                    Image(decorative: icon, scale: 1).resizable().frame(width: side, height: side)
                        .frame(maxHeight: .infinity)
                }
                if style.titles {
                    Text(sample.title).font(font).lineLimit(1).shadow(color: halo, radius: 1.5)
                        .padding(.horizontal, 8 * k)
                        .frame(height: 28 * k)
                }
            }
        }
    }

    /// Your three most recent windows, or stand-ins when there aren't enough.
    private static func collect() -> [Sample] {
        let me = getpid()
        var samples: [Sample] = []
        for item in Store.shared.snapshot where item.pid != me && !item.minimized && !item.hidden {
            samples.append(Sample(id: samples.count, title: item.title.isEmpty ? item.appName : item.title,
                                  icon: item.icon, picture: Thumbs.shared.image(item.id)))
            if samples.count == 3 { return samples }
        }
        for (id, name) in [("com.apple.finder", "Finder"), ("com.apple.Safari", "Safari"), ("com.apple.Notes", "Notes")] {
            guard samples.count < 3 else { break }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let icon = url.flatMap { NSWorkspace.shared.icon(forFile: $0.path).cgImage(forProposedRect: nil, context: nil, hints: nil) }
            samples.append(Sample(id: samples.count, title: name, icon: icon, picture: nil))
        }
        return samples
    }
}

// MARK: Current Space or all

/// Two pictures to pick from, as System Settings does for Light and Dark.
struct SpacesChoice: View {
    @Binding var currentOnly: Bool
    @ObservedObject private var wallpaper = Wallpaper.shared

    var body: some View {
        HStack(spacing: 28) {
            option(true, "Current Space") { compact }
            option(false, "All Spaces") { grid }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .onAppear { Wallpaper.shared.load() }
    }

    private func option<Picture: View>(_ value: Bool, _ title: String, @ViewBuilder picture: () -> Picture) -> some View {
        let chosen = currentOnly == value
        return Button { currentOnly = value } label: {
            VStack(spacing: 6) {
                picture()
                    .frame(width: 150, height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(chosen ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: chosen ? 3 : 1)
                            .padding(chosen ? -3 : 0)
                    }
                Text(title)
                    .fontWeight(chosen ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var compact: some View {
        ZStack {
            Backdrop(image: wallpaper.plain)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 26, height: 18)
                        .overlay {
                            if i == 1 { RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: 1.5).padding(-1.5) }
                        }
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
        }
    }

    private var grid: some View {
        ZStack {
            Backdrop(image: wallpaper.grid)
            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { column in
                            cell(row * 2 + column)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay(alignment: .trailing) {
                                    if column == 0 { Rectangle().fill(Color.white.opacity(0.25)).frame(width: 0.5) }
                                }
                                .overlay(alignment: .bottom) {
                                    if row == 0 { Rectangle().fill(Color.white.opacity(0.25)).frame(height: 0.5) }
                                }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ n: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<(n % 3 + 1), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 16, height: 11)
                    .overlay {
                        if n == 0 && i == 0 {
                            RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 1.5).padding(-1.5)
                        }
                    }
            }
        }
    }
}

// MARK: Spaces grid

/// Your Spaces as the grid lays them out: names in the corners, each one's apps.
struct SpacesMap: View {
    @ObservedObject private var wallpaper = Wallpaper.shared
    @State private var spaces: [Spaces.Info] = []
    @State private var layout = Prefs.current.layout
    @State private var apps: [UInt64: [CGImage]] = [:]

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var columns: Int {
        let count = max(spaces.count, 1)
        return layout.columns > 0 ? min(layout.columns, count) : Int(Double(count).squareRoot().rounded(.up))
    }

    var body: some View {
        let columns = self.columns
        let rows = max((spaces.count + columns - 1) / columns, 1)
        ZStack {
            Backdrop(image: wallpaper.grid)
            if spaces.isEmpty {
                Text("No Spaces found").foregroundStyle(.white.opacity(0.7))
            }
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { column in
                            let i = row * columns + column
                            Group {
                                if i < spaces.count { cell(spaces[i], row: row, column: column, rows: rows, columns: columns) } else { Color.clear }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .trailing) {
                                if column < columns - 1 { Rectangle().fill(Color.white.opacity(0.2)).frame(width: 0.5) }
                            }
                            .overlay(alignment: .bottom) {
                                if row < rows - 1 { Rectangle().fill(Color.white.opacity(0.2)).frame(height: 0.5) }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 210)
        .clipped()
        .accessibilityElement(children: .combine)
        .onAppear {
            Wallpaper.shared.load()
            load()
        }
        .onReceive(refresh) { _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let saved = Prefs.current.layout
            if saved != layout { load() }
        }
    }

    private func cell(_ space: Spaces.Info, row: Int, column: Int, rows: Int, columns: Int) -> some View {
        let top = row == 0 || rows == 1
        let horizontal: HorizontalAlignment = column == 0 ? .leading : column == columns - 1 ? .trailing : .center
        let corner = Alignment(horizontal: horizontal, vertical: top ? .top : .bottom)
        return ZStack(alignment: corner) {
            HStack(spacing: 4) {
                ForEach(Array((apps[space.id] ?? []).prefix(5).enumerated()), id: \.offset) { _, icon in
                    Image(decorative: icon, scale: 1).resizable().frame(width: 20, height: 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(Spaces.name(space, layout))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .opacity(space.current ? 1 : 0.6)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
    }

    private func load() {
        layout = Prefs.current.layout
        let all = Store.shared.spaceList
        spaces = Spaces.arranged(all, layout)
        let current = all.first(where: \.current)?.id ?? 0
        let me = getpid()
        var found: [UInt64: [CGImage]] = [:]
        var seen: [UInt64: Set<pid_t>] = [:]
        for item in Store.shared.snapshot where item.pid != me {
            let home = item.home == 0 ? current : item.home
            guard let icon = item.icon, seen[home, default: []].insert(item.pid).inserted else { continue }
            found[home, default: []].append(icon)
        }
        apps = found
    }
}

// MARK: Gestures

private func ease(_ t: Double) -> Double {
    let u = min(max(t, 0), 1)
    return u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
}

private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

/// Three fingers on a trackpad, sliding sideways, and the selection it moves. The tick
/// marks are where each step lands at the chosen sensitivity.
struct SidewaysPreview: View {
    let sensitivity: Double

    private let tiles = 6
    private let start = 0.2, travel = 0.6      // of the trackpad's width

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(&context, size, time: reduceMotion ? 2.2 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 190)
        .accessibilityLabel("Three fingers sliding sideways move the selection one window per step")
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, time: Double) {
        let cycle = 4.4
        let p = time.truncatingRemainder(dividingBy: cycle)
        let moved: Double, down: Double
        switch p {
        case ..<0.5: moved = 0; down = p / 0.5
        case ..<3.1: moved = travel * ease((p - 0.5) / 2.6); down = 1
        case ..<3.8: moved = travel; down = 1
        default: moved = travel; down = max(0, 1 - (p - 3.8) / 0.35)
        }
        let engage = TouchSwipe.engageAt / sensitivity, step = TouchSwipe.stepAt / sensitivity
        let open = moved > engage && p < 3.8
        let selected = open ? min(1 + Int((moved - engage) / step), tiles - 1) : -1

        let ink = Color.primary
        let accent = Color.accentColor

        // The switcher.
        let tileW: CGFloat = 46, tileH: CGFloat = 30, gap: CGFloat = 5
        let stripW = CGFloat(tiles) * tileW + CGFloat(tiles - 1) * gap + 14
        let strip = CGRect(x: (size.width - stripW) / 2, y: 4, width: stripW, height: tileH + 14)
        context.opacity = open ? 1 : 0.35
        context.fill(Path(roundedRect: strip, cornerRadius: 10), with: .color(ink.opacity(0.07)))
        for i in 0..<tiles {
            let r = CGRect(x: strip.minX + 7 + CGFloat(i) * (tileW + gap), y: strip.minY + 7, width: tileW, height: tileH)
            context.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(ink.opacity(0.16)))
            if i == selected {
                context.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5), with: .color(accent), lineWidth: 2.5)
            }
        }
        context.opacity = 1

        // The trackpad.
        let padW: CGFloat = 230, padH: CGFloat = 130
        let pad = CGRect(x: (size.width - padW) / 2, y: strip.maxY + 10, width: padW, height: padH)
        context.fill(Path(roundedRect: pad, cornerRadius: 12), with: .color(ink.opacity(0.06)))
        context.stroke(Path(roundedRect: pad, cornerRadius: 12), with: .color(ink.opacity(0.18)), lineWidth: 1)

        // Where each step lands.
        let x0 = pad.minX + CGFloat(start) * padW
        var mark = engage
        var marks = 0
        while mark <= travel + 0.0001, marks < 40 {
            let x = x0 + CGFloat(mark) * padW
            let tick = Path(CGRect(x: x - 0.5, y: pad.maxY - 14, width: 1, height: 8))
            context.fill(tick, with: .color(ink.opacity(moved >= mark ? 0.55 : 0.22)))
            mark += step
            marks += 1
        }

        // Three fingers.
        let cx = x0 + CGFloat(moved) * padW, cy = pad.midY - 4
        for (dx, dy) in [(-26.0, 8.0), (0.0, 0.0), (26.0, 5.0)] {
            let r = CGRect(x: cx + CGFloat(dx) - 11, y: cy + CGFloat(dy) - 11, width: 22, height: 22)
            context.fill(Path(ellipseIn: r), with: .color(ink.opacity(0.28 * down)))
            context.stroke(Path(ellipseIn: r), with: .color(ink.opacity(0.4 * down)), lineWidth: 1)
        }
    }
}

/// Three fingers sliding up, and the Spaces grid following them.
struct UpPreview: View {
    @ObservedObject private var wallpaper = Wallpaper.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(&context, size, time: reduceMotion ? 2.0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 140)
        .onAppear { Wallpaper.shared.load() }
        .accessibilityLabel("Three fingers sliding up open the Spaces grid as they move")
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, time: Double) {
        let cycle = 4.0
        let p = time.truncatingRemainder(dividingBy: cycle)
        let level: Double, down: Double
        switch p {
        case ..<0.4: level = 0; down = p / 0.4
        case ..<2.0: level = ease((p - 0.4) / 1.6); down = 1
        case ..<2.3: level = 1; down = max(0, 1 - (p - 2.0) / 0.3)
        case ..<3.4: level = 1; down = 0
        default: level = 1 - ease((p - 3.4) / 0.6); down = 0
        }
        let ink = Color.primary

        let padW: CGFloat = 170, padH: CGFloat = 110, screenW: CGFloat = 176, screenH: CGFloat = 110
        let gap: CGFloat = 36
        let left = (size.width - padW - gap - screenW) / 2
        let pad = CGRect(x: left, y: (size.height - padH) / 2, width: padW, height: padH)
        context.fill(Path(roundedRect: pad, cornerRadius: 11), with: .color(ink.opacity(0.06)))
        context.stroke(Path(roundedRect: pad, cornerRadius: 11), with: .color(ink.opacity(0.18)), lineWidth: 1)
        let cy = pad.maxY - 26 - CGFloat(p < 2.0 ? level : 1) * (padH - 52)
        for (dx, dy) in [(-22.0, 6.0), (0.0, 0.0), (22.0, 4.0)] {
            let r = CGRect(x: pad.midX + CGFloat(dx) - 10, y: cy + CGFloat(dy) - 10, width: 20, height: 20)
            context.fill(Path(ellipseIn: r), with: .color(ink.opacity(0.28 * down)))
            context.stroke(Path(ellipseIn: r), with: .color(ink.opacity(0.4 * down)), lineWidth: 1)
        }

        // The screen, with the grid coming in over it.
        let screen = CGRect(x: pad.maxX + gap, y: (size.height - screenH) / 2, width: screenW, height: screenH)
        let shape = Path(roundedRect: screen, cornerRadius: 6)
        context.drawLayer { layer in
            layer.clip(to: shape)
            if let plain = wallpaper.plain {
                layer.draw(Image(decorative: plain, scale: 1).resizable(), in: fill(screen, plain))
            } else {
                layer.fill(shape, with: .color(.gray))
            }
            layer.opacity = level
            if let grid = wallpaper.grid {
                layer.draw(Image(decorative: grid, scale: 1).resizable(), in: fill(screen, grid))
            } else {
                layer.fill(shape, with: .color(.black.opacity(0.7)))
            }
            let zoom = 1.25 - 0.25 * CGFloat(level)
            let cellW = screen.width / 2, cellH = screen.height / 2
            for row in 0..<2 {
                for column in 0..<2 {
                    let cell = CGRect(x: screen.minX + CGFloat(column) * cellW, y: screen.minY + CGFloat(row) * cellH, width: cellW, height: cellH)
                    let count = (row * 2 + column) % 3 + 1
                    let w: CGFloat = 20 * zoom, h: CGFloat = 13 * zoom, g: CGFloat = 4
                    let total = CGFloat(count) * w + CGFloat(count - 1) * g
                    for i in 0..<count {
                        let r = CGRect(x: cell.midX - total / 2 + CGFloat(i) * (w + g), y: cell.midY - h / 2, width: w, height: h)
                        layer.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.white.opacity(0.8)))
                    }
                }
            }
            layer.fill(Path(CGRect(x: screen.midX - 0.25, y: screen.minY, width: 0.5, height: screen.height)), with: .color(.white.opacity(0.3)))
            layer.fill(Path(CGRect(x: screen.minX, y: screen.midY - 0.25, width: screen.width, height: 0.5)), with: .color(.white.opacity(0.3)))
        }
        context.stroke(shape, with: .color(ink.opacity(0.2)), lineWidth: 1)
    }

    /// Fills the rectangle, cropping the picture rather than stretching it.
    private func fill(_ rect: CGRect, _ image: CGImage) -> CGRect {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// Fingers sliding sideways, and the next Space there at once: no slide in between.
struct InstantPreview: View {
    @ObservedObject private var wallpaper = Wallpaper.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(&context, size, time: reduceMotion ? 1.6 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 130)
        .onAppear { Wallpaper.shared.load() }
        .accessibilityLabel("Fingers swipe sideways and the next Space appears at once, with no slide")
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, time: Double) {
        let cycle = 3.2
        let p = time.truncatingRemainder(dividingBy: cycle)
        // Fingers travel left during the first half; the Space changes as soon as they move.
        let half = cycle / 2
        let leg = p < half ? p : p - half
        let moved: Double = leg < 0.25 ? 0 : min(1, (leg - 0.25) / 0.7)
        let down = leg < 1.1
        let second = (p >= half) != (moved > 0.08)   // which Space is showing
        let ink = Color.primary

        let padW: CGFloat = 150, padH: CGFloat = 96, screenW: CGFloat = 176, screenH: CGFloat = 110, gap: CGFloat = 36
        let left = (size.width - padW - gap - screenW) / 2
        let pad = CGRect(x: left, y: (size.height - padH) / 2, width: padW, height: padH)
        context.fill(Path(roundedRect: pad, cornerRadius: 11), with: .color(ink.opacity(0.06)))
        context.stroke(Path(roundedRect: pad, cornerRadius: 11), with: .color(ink.opacity(0.18)), lineWidth: 1)
        // Alternate directions, so it shows going both ways.
        let towardsLeft = p < half
        let cx = pad.midX + CGFloat(towardsLeft ? 1 - 2 * moved : -1 + 2 * moved) * 30
        for (i, dy) in [6.0, 0.0, 2.0, 9.0].enumerated() {
            let r = CGRect(x: cx + CGFloat(i) * 18 - 34, y: pad.midY + CGFloat(dy) - 9, width: 17, height: 17)
            context.fill(Path(ellipseIn: r), with: .color(ink.opacity(down ? 0.28 : 0)))
            context.stroke(Path(ellipseIn: r), with: .color(ink.opacity(down ? 0.4 : 0)), lineWidth: 1)
        }

        let screen = CGRect(x: pad.maxX + gap, y: (size.height - screenH) / 2, width: screenW, height: screenH)
        let shape = Path(roundedRect: screen, cornerRadius: 6)
        context.drawLayer { layer in
            layer.clip(to: shape)
            if let plain = wallpaper.plain {
                let scale = max(screen.width / CGFloat(plain.width), screen.height / CGFloat(plain.height))
                let w = CGFloat(plain.width) * scale, h = CGFloat(plain.height) * scale
                layer.draw(Image(decorative: plain, scale: 1).resizable(), in: CGRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h))
            } else {
                layer.fill(shape, with: .color(.gray))
            }
            let windows: [CGRect] = second
                ? [CGRect(x: 0.52, y: 0.18, width: 0.4, height: 0.5), CGRect(x: 0.1, y: 0.4, width: 0.36, height: 0.45)]
                : [CGRect(x: 0.08, y: 0.14, width: 0.5, height: 0.56), CGRect(x: 0.42, y: 0.42, width: 0.48, height: 0.44)]
            for w in windows {
                let r = CGRect(x: screen.minX + w.minX * screen.width, y: screen.minY + w.minY * screen.height,
                               width: w.width * screen.width, height: w.height * screen.height)
                layer.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(.white.opacity(0.9)))
                layer.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: 6)), with: .color(Color(white: 0.86)))
            }
            let label = Text(second ? "Desktop 2" : "Desktop 1").font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
            layer.draw(label, at: CGPoint(x: screen.minX + 8, y: screen.maxY - 8), anchor: .bottomLeading)
        }
        context.stroke(shape, with: .color(ink.opacity(0.2)), lineWidth: 1)
    }
}
