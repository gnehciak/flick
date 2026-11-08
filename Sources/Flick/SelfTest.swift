import Cocoa
import Carbon

/// Drives real ⌘Tab key events through the system and records what happened.
/// Only runs when launched with FLICK_SELFTEST=<report path>.
final class SelfTest {
    private let path: String
    private var report: [String] = []
    private let source = CGEventSource(stateID: .hidSystemState)

    init(path: String) { self.path = path }

    /// Shows the real overlay for a moment and screenshots it. Doesn't touch focus.
    static func snapshot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Overlay.shared.prepare(Store.shared.snapshot, index: 1)
            Overlay.shared.reveal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", path]
                try? p.run()
                p.waitUntilExit()
                Overlay.shared.hide()
                exit(0)
            }
        }
    }

    /// Screenshots the Spaces organiser without taking focus.
    static func organiserShot(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            (NSApp.delegate as? AppDelegate)?.showOrganiser(activate: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let id = NSApp.windows.first { $0.title == "Spaces" }?.windowNumber ?? 0
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l\(id)", path]
                try? p.run()
                p.waitUntilExit()
                exit(0)
            }
        }
    }

    /// Screenshots each tab of Settings without taking focus, to <path>-<tab>.png.
    static func settingsShot(to path: String) {
        let base = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
        let only = ProcessInfo.processInfo.environment["FLICK_SETTINGSTAB"]
        let pages = SettingsPage.allCases.filter { only == nil || $0.title.lowercased() == only?.lowercased() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            func shoot(_ rest: ArraySlice<SettingsPage>) {
                guard let page = rest.first else { exit(0) }
                (NSApp.delegate as? AppDelegate)?.showSettings(activate: false, page: page)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    let id = NSApp.windows.first { $0.title == "Flick Settings" }?.windowNumber ?? 0
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l\(id)", "\(base)-\(page.title.lowercased()).png"]
                    try? p.run()
                    p.waitUntilExit()
                    shoot(rest.dropFirst())
                }
            }
            shoot(pages[...])
        }
    }

    func run() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            sleep(3)
            scenarios()
            try? report.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    private func say(_ s: String) { report.append(s) }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }

    private func commandDown() { key(55, down: true, flags: .maskCommand) }
    private func commandUp() { key(55, down: false, flags: []) }
    private func tab(flags: CGEventFlags = .maskCommand) {
        key(48, down: true, flags: flags)
        key(48, down: false, flags: flags)
    }

    /// The topmost normal window on screen.
    private func topWindow() -> (id: CGWindowID, owner: String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 60, (bounds["Height"] ?? 0) >= 60 else { continue }
            return (id, w[kCGWindowOwnerName as String] as? String ?? "?")
        }
        return nil
    }

    private func waitForTop(_ id: CGWindowID, timeout: Double = 600) -> Double? {
        let start = now()
        while ms(since: start) < timeout {
            if topWindow()?.id == id { return ms(since: start) }
            usleep(1000)
        }
        return nil
    }

    private func spaceProbe() {
        let home = Spaces.visible()
        guard let away = Store.shared.snapshot.first(where: { $0.space != 0 && !home.contains($0.space) }) else { say("no away window"); return }
        let d = Spaces.displays()
        say("displays \(d)")
        say("target \(away.appName) space \(away.space)")
        for (name, tap, stamp) in [("annotated", CGEventTapLocation.cgAnnotatedSessionEventTap, false), ("session", .cgSessionEventTap, false), ("session+pid", .cgSessionEventTap, true), ("hid", .cghidEventTap, false)] {
            Spaces.postTap = tap
            Spaces.stampPid = stamp
            let start = now()
            let ok = Spaces.jump(to: away.space, timeout: 900)
            let t = ms(since: start)
            usleep(700_000)
            let at = Spaces.visible()
            say("\(name): landed \(ok) in \(String(format: "%.1f", t))ms, now on \(at.sorted())")
            if at != home, let back = home.first {
                let s2 = now()
                let ok2 = Spaces.jump(to: back, timeout: 900)
                say("  back: \(ok2) \(String(format: "%.1f", ms(since: s2)))ms")
                usleep(700_000)
            }
        }
        say("end on \(Spaces.visible().sorted())")
    }

    /// Swaps the first tile's thumbnail for solid colours. Shows the overlay but doesn't
    /// touch focus. Writes the overlay mid-fade to <shot>.
    private func fadeTest(_ shot: String) {
        sleep(1)
        let items = Store.shared.snapshot
        guard let id = items.first?.id else { say("no windows"); return }
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 400, height: 260, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 260))
            return ctx.makeImage()!
        }
        func level() -> Float { DispatchQueue.main.sync { Overlay.shared.fadeLevel(0) } }
        func settle() { DispatchQueue.main.sync {}; usleep(30_000) }

        DispatchQueue.main.sync { Overlay.shared.prepare(items, index: 0) }
        Thumbs.shared.accept(solid(1, 0, 0), for: id)
        settle()
        say("while hidden: level \(level()), want 0")

        DispatchQueue.main.sync { Overlay.shared.prepare(items, index: 0); Overlay.shared.reveal() }
        usleep(200_000)
        Thumbs.shared.accept(solid(0, 0, 1), for: id)
        let start = now()
        var samples: [String] = []
        var saved = false
        while ms(since: start) < 320 {
            let l = level()
            samples.append(String(format: "%.0fms %.2f", ms(since: start), l))
            if !saved, ms(since: start) > 80, l > 0.2, l < 0.8 {
                saved = true
                let wid = DispatchQueue.main.sync { Overlay.shared.windowID }
                if let image = Priv.capture(wid),
                   let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: shot) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(out, image, nil)
                    CGImageDestinationFinalize(out)
                    samples.append("captured at \(String(format: "%.0f", ms(since: start)))ms")
                }
            }
            usleep(20_000)
        }
        say("fade: " + samples.joined(separator: ", "))

        Thumbs.shared.accept(solid(0, 0, 1), for: id)
        settle()
        say("same pixels: level \(level()), want 0")

        Thumbs.shared.accept(solid(0, 1, 0), for: id)
        settle()
        DispatchQueue.main.sync { Overlay.shared.prepare(items, index: 0) }
        say("prepare mid-fade: level \(level())")
        usleep(300_000)
        say("after: level \(level()), want 0")
        DispatchQueue.main.sync { Overlay.shared.hide() }
    }

    /// Runs tools/sticky, a window on every Space whose title keeps changing. Shows the
    /// overlay but doesn't touch focus.
    private func stickyTest(_ helper: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        try? p.run()
        defer { p.terminate() }
        func window() -> Item? { Store.shared.snapshot.first { $0.title.hasPrefix("Sticky") } }
        for _ in 0..<60 where window() == nil { usleep(100_000) }
        guard let item = window() else { say("no sticky window"); return }
        say("space \(item.space), want 0")

        Switcher.shared.press(reverse: false, at: now())
        let before = Switcher.shared.openTitles.first { $0.hasPrefix("Sticky") } ?? ""
        usleep(3_000_000)
        let after = Switcher.shared.openTitles.first { $0.hasPrefix("Sticky") } ?? ""
        Switcher.shared.cancel()
        say("title while open: \(before) -> \(after), changed \(before != after)")

        UserDefaults.standard.set(true, forKey: "currentSpaceOnly")
        usleep(200_000)
        Switcher.shared.press(reverse: false, at: now())
        usleep(100_000)
        say("listed with Current Space on: \(Switcher.shared.openTitles.contains { $0.hasPrefix("Sticky") })")
        Switcher.shared.cancel()
        UserDefaults.standard.removeObject(forKey: "currentSpaceOnly")

        let count = Store.shared.snapshot.count
        Store.shared.accessGranted()
        usleep(800_000)
        say("trackers rebuilt: \(count) -> \(Store.shared.snapshot.count) windows")
    }

    /// The swipe's opening animation. With FLICK_SLOWOPEN=<n> it runs n times slower and
    /// writes frames to <prefix>-N.png. Focus stays put.
    private func openTest(_ prefix: String) {
        sleep(2)
        let slow = Double(ProcessInfo.processInfo.environment["FLICK_SLOWOPEN"] ?? "") ?? 1
        func frame(_ n: Int) {
            let id = DispatchQueue.main.sync { Overlay.shared.windowID }
            guard let image = Priv.capture(id),
                  let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(prefix)-\(n).png") as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(out, image, nil)
            CGImageDestinationFinalize(out)
        }
        if slow > 1 {
            // Held at fixed points, as a finger would.
            Switcher.shared.openGrid(following: true)
            usleep(300_000)
            for (n, level) in [0.15, 0.4, 0.7, 1].enumerated() {
                DispatchQueue.main.sync { Overlay.shared.scrub(to: level) }
                usleep(120_000)
                frame(n + 1)
            }
            usleep(200_000)
            let item = Switcher.shared.openItems.first { $0.space != 0 && Store.shared.visibleSpaces.contains($0.space) }
            DispatchQueue.main.sync { Overlay.shared.closeInto(item) }
            let start = now()
            for (n, at) in [0.02, 0.06, 0.12, 0.2].enumerated() {
                while ms(since: start) < at * slow * 1000 { usleep(1000) }
                frame(n + 5)
            }
            usleep(UInt32(0.1 * slow * 1_000_000))
            Switcher.shared.cancel()
            return
        }
        Switcher.shared.openGrid()
        usleep(600_000)
        Switcher.shared.cancel()
        usleep(300_000)
        guard slow == 1 else { return }

        say("windows \(Store.shared.snapshot.count), Spaces \(Store.shared.spaceList.count), reduce motion \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")

        // Closing partway through has to leave nothing behind.
        Switcher.shared.openGrid()
        usleep(60_000)
        let during = DispatchQueue.main.sync { Overlay.shared.animationsRunning }
        Switcher.shared.cancel()
        usleep(400_000)
        let (alpha, left) = DispatchQueue.main.sync { (Overlay.shared.windowAlpha, Overlay.shared.animationsRunning) }
        say("closed mid-animation: \(during) were running, alpha \(alpha), left running \(left)")

        // ⌘Tab stays instant, straight after an animated open.
        Switcher.shared.openGrid()
        usleep(500_000)
        Switcher.shared.cancel()
        usleep(100_000)
        Switcher.shared.press(reverse: false, at: now())
        usleep(15_000)
        let quick = DispatchQueue.main.sync { (Overlay.shared.windowAlpha, Overlay.shared.animationsRunning) }
        Switcher.shared.cancel()
        usleep(100_000)
        say("⌘Tab at 15 ms: alpha \(quick.0), animations \(quick.1)")

        // Opaque only while the grid is still, and never over the compact panel.
        func look() -> String { DispatchQueue.main.sync { "opaque \(Overlay.shared.isOpaque), backdrop \(Overlay.shared.hasBackdrop), alpha \(Overlay.shared.windowAlpha)" } }
        Switcher.shared.openGrid()
        usleep(40_000)
        say("opening: \(look())")
        usleep(700_000)
        say("open and still: \(look())")
        Switcher.shared.toggleView()
        usleep(150_000)
        say("flipped to panel: \(look())")
        Switcher.shared.toggleView()
        usleep(400_000)
        say("flipped to grid: \(look())")
        Switcher.shared.cancel()
        usleep(150_000)
        say("closed: \(look())")
        Switcher.shared.press(reverse: false, at: now())
        usleep(100_000)
        say("⌘Tab panel: \(look())")
        Switcher.shared.cancel()
        usleep(100_000)

        // The zoom into a window. No switch happens here, so focus stays put.
        func zoom() -> Item? {
            Switcher.shared.openGrid()
            usleep(500_000)
            let item = Switcher.shared.openItems.first
            Switcher.shared.select(0)
            usleep(30_000)
            DispatchQueue.main.sync { Overlay.shared.closeInto(item) }
            return item
        }
        _ = zoom()
        let began = now()
        var fadedEarly = 0, samples = 0, zoomDone = 0.0, opaqueUntil = 0.0
        while ms(since: began) < 900 {
            let (alpha, level, opaque) = DispatchQueue.main.sync { (Overlay.shared.windowAlpha, Overlay.shared.scrubProgress, Overlay.shared.isOpaque) }
            guard alpha > 0 else { break }
            if opaque { opaqueUntil = ms(since: began) }
            samples += 1
            if level > 0.0005, alpha < 0.999 { fadedEarly += 1 }
            if level <= 0.0005, zoomDone == 0 { zoomDone = ms(since: began) }
            usleep(1000)
        }
        let closed = ms(since: began)
        say(String(format: "stayed opaque until %.0f ms", opaqueUntil))
        say(String(format: "zoom finished at %.0f ms, \(samples) samples, faded before it finished: \(fadedEarly), want 0", zoomDone))
        let sized = Overlay.shared.chosenPictureWidth
        say("picture after the zoom \(sized) px wide, back to thumbnail size")
        Switcher.shared.cancel()
        usleep(100_000)
        let after = DispatchQueue.main.sync { (Overlay.shared.windowAlpha, Overlay.shared.animationsRunning) }
        say(String(format: "zoom close took %.0f ms, then alpha \(after.0), animations \(after.1)", closed))

        _ = zoom()
        usleep(60_000)
        Switcher.shared.cancel()
        usleep(30_000)
        Switcher.shared.press(reverse: false, at: now())
        usleep(15_000)
        let cut = DispatchQueue.main.sync { (Overlay.shared.windowAlpha, Overlay.shared.animationsRunning, Overlay.shared.isVisible) }
        Switcher.shared.cancel()
        usleep(100_000)
        say("⌘Tab during the zoom: alpha \(cut.0), animations \(cut.1), visible \(cut.2)")

        // And during the fade itself, which runs where the window's alpha can't show it.
        _ = zoom()
        usleep(320_000)
        let fading = DispatchQueue.main.sync { Overlay.shared.contentOpacity }
        Switcher.shared.cancel()
        usleep(10_000)
        Switcher.shared.press(reverse: false, at: now())
        usleep(30_000)
        let shownNow = DispatchQueue.main.sync { Overlay.shared.contentOpacity }
        Switcher.shared.cancel()
        usleep(150_000)
        say(String(format: "⌘Tab during the fade: was at %.2f, panel shows at %.2f, want 1", fading, shownNow))
    }

    /// Vertical Dock swipes through the tap. Ends with Esc, so focus stays put.
    private func swipeTest() {
        let d = UserDefaults.standard
        let learned = d.object(forKey: "swipeSign")
        d.removeObject(forKey: "swipeSign")
        defer { if let learned { d.set(learned, forKey: "swipeSign") } else { d.removeObject(forKey: "swipeSign") } }
        sleep(1)
        func state() -> String {
            let shown = DispatchQueue.main.sync { Overlay.shared.isVisible && Overlay.shared.fillsScreen }
            return "open \(Switcher.shared.isActive), sticky \(Switcher.shared.isSticky), grid on screen \(shown)"
        }
        func swipe(_ sign: Double) { Spaces.postVertical(sign: sign); usleep(250_000) }
        swipe(1)
        say("first swipe: \(state()), learned \(d.integer(forKey: "swipeSign"))")
        usleep(600_000)
        say("after 0.6 s with nothing held: \(state())")
        key(55, down: true, flags: .maskCommand); usleep(30_000); key(55, down: false, flags: []); usleep(120_000)
        say("after tapping ⌘: \(state())")
        key(48, down: true, flags: []); key(48, down: false, flags: []); usleep(60_000)
        say("Tab moved to \(Switcher.shared.selectedIndex)")
        swipe(1)
        say("second swipe closes: \(state())")
        swipe(-1)
        say("swipe down while closed: \(state())")
        swipe(1)
        usleep(500_000)
        say("swipe up: \(state())")
        key(53, down: true, flags: []); key(53, down: false, flags: []); usleep(120_000)
        say("Esc: \(state())")

        func drag(_ sign: Double, to amounts: [Double], release: Bool = true) {
            Spaces.postVertical(sign: sign, amounts: amounts, gap: 40_000, release: release)
            usleep(60_000)
        }
        func level() -> String { String(format: "%.2f", DispatchQueue.main.sync { Overlay.shared.scrubProgress }) }

        drag(1, to: [0.05, 0.1, 0.2], release: false)
        let at20 = level()
        drag(1, to: [0.3, 0.4, 0.5], release: false)
        let at50 = level()
        drag(1, to: [0.4, 0.3, 0.2], release: false)
        say("following a finger: 0.2 gives \(at20), 0.5 gives \(at50), back to 0.2 gives \(level())")
        drag(1, to: [0.1, 0.05, 0.02], release: false)
        drag(1, to: [0.02, 0.02, 0.02])
        usleep(700_000)
        say("barely moved, let go: \(state())")

        drag(1, to: [0.05, 0.1, 0.14, 0.14, 0.14])
        usleep(700_000)
        say("small slow swipe of 0.14: \(state())")
        key(53, down: true, flags: []); key(53, down: false, flags: []); usleep(400_000)

        Spaces.postVertical(sign: 1, amounts: [0.02, 0.04, 0.06], gap: 25_000)
        usleep(700_000)
        say("small relaxed swipe of 0.06: \(state())")
        key(53, down: true, flags: []); key(53, down: false, flags: []); usleep(400_000)

        drag(1, to: [0.1, 0.2, 0.3], release: false)
        Spaces.postVertical(sign: 1, amounts: [0.25, 0.17, 0.1], gap: 15_000)
        usleep(700_000)
        say("pulled back before lifting: \(state())")

        drag(1, to: [0.2, 0.4, 0.6, 0.6, 0.6])
        usleep(700_000)
        say("let go at 0.6: \(state()), level \(level())")
        func landing(_ sign: Double, _ amounts: [Double]) -> Double {
            Spaces.postVertical(sign: sign, amounts: amounts, gap: 12_000, release: false)
            usleep(120_000)
            Spaces.postVertical(sign: sign, amounts: [amounts.last ?? 0], gap: 0)
            let start = now()
            while ms(since: start) < 900, DispatchQueue.main.sync(execute: { Overlay.shared.animationsRunning }) > 0 { usleep(1000) }
            return ms(since: start)
        }
        let settleOpen = landing(-1, [0.1, 0.2, 0.28])    // from level 0.53 back to open
        say(String(format: "landing time, a short way: %.0f ms, still open \(Switcher.shared.isActive)", settleOpen))

        drag(-1, to: [0.05, 0.1, 0.15], release: false)
        say("pulling back down 0.15: level \(level())")
        drag(-1, to: [0.15, 0.15, 0.15])
        usleep(700_000)
        say("let go there: stays open \(Switcher.shared.isActive), level \(level())")

        drag(-1, to: [0.3, 0.6, 0.8, 0.8, 0.8])
        usleep(700_000)
        say("let go at 0.8 down: \(state())")

        drag(1, to: [0.2, 0.5], release: false)
        key(53, down: true, flags: []); key(53, down: false, flags: []); usleep(120_000)
        drag(1, to: [0.6, 0.7])
        usleep(500_000)
        let after = DispatchQueue.main.sync { (Overlay.shared.windowAlpha, Overlay.shared.animationsRunning) }
        say("Esc partway, rest of the swipe ignored: \(state()), alpha \(after.0), animations \(after.1)")
    }

    /// Dragging a throwaway window between Spaces, through the real mouse handlers. No real
    /// window is touched, and focus stays put.
    private func moveTest(_ path: String) {
        launch(path, "FixC", 1)
        defer { fixtures.forEach { $0.terminate() } }
        guard waitFor(["FixC 1"]) else { say("fixture not seen"); return }
        usleep(500_000)
        Switcher.shared.openGrid()
        usleep(700_000)
        defer { Switcher.shared.cancel() }
        func index() -> Int? { Switcher.shared.openItems.firstIndex { $0.title == "FixC 1" } }
        func cells() -> [UInt64] { DispatchQueue.main.sync { Overlay.shared.sectionSpaces } }
        func inside(_ space: UInt64) -> Bool {
            DispatchQueue.main.sync {
                guard let i = index(), let n = Overlay.shared.sectionSpaces.firstIndex(of: space) else { return false }
                return Overlay.shared.sectionFrames[n].contains(Overlay.shared.tileFrame(i))
            }
        }
        guard let i = index(), let id = Switcher.shared.openItems.first(where: { $0.title == "FixC 1" })?.id else { say("no tile"); return }
        let home = Priv.spaces(of: id).first ?? 0
        guard let away = cells().first(where: { $0 != home }), let cell = cells().firstIndex(of: away), let back = cells().firstIndex(of: home) else { say("no other cell"); return }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        say("window on \(home), dragging to \(away)")

        DispatchQueue.main.sync { Overlay.shared.simulateDrag(i, toCell: cell) }
        var glided = 0
        for _ in 0..<80 {
            glided = max(glided, DispatchQueue.main.sync { Overlay.shared.gliding })
            usleep(10_000)
        }
        say("tiles that glided after the drop: \(glided)")
        say("after the drag: on \(Priv.spaces(of: id)), tile in new cell \(inside(away)), grid open \(Switcher.shared.isSticky), Space unchanged \(Store.shared.visibleSpaces.contains(home))")
        say("window listed under the new Space: \(Store.shared.snapshot.first { $0.id == id }?.home == away)")

        if let j = index() { DispatchQueue.main.sync { Overlay.shared.simulateDrag(j, toCell: cell) } }
        usleep(500_000)
        say("dropped on its own cell: on \(Priv.spaces(of: id)), tile still there \(inside(away))")

        if let j = index() { DispatchQueue.main.sync { Overlay.shared.simulateDrag(j, toCell: back) } }
        usleep(800_000)
        say("dragged back: on \(Priv.spaces(of: id)), tile home \(inside(home)), focus unchanged \((NSWorkspace.shared.frontmostApplication?.localizedName ?? "") == front)")
    }

    /// The three finger gesture, fed made-up finger positions. Ends every time by adding a
    /// fourth finger, which cancels, so focus never moves.
    private func touchTest() {
        let waited = now()
        while Store.shared.snapshot.count < 3, ms(since: waited) < 8000 { usleep(100_000) }
        usleep(500_000)
        let touch = TouchSwipe.shared
        func swipe(_ points: [(Double, Double)]) { for p in points { touch.feed(x: p.0, y: p.1); usleep(11_000) } }
        func state() -> String { "open \(Switcher.shared.isActive), touch \(Switcher.shared.isTouching), selected \(Switcher.shared.selectedIndex) of \(Switcher.shared.openItems.count)" }

        swipe([(0.5, 0.5), (0.52, 0.5), (0.54, 0.5), (0.58, 0.5)])
        usleep(80_000)
        say("swiped right a little: \(state())")
        let first = Switcher.shared.selectedIndex
        swipe([(0.62, 0.5), (0.68, 0.5), (0.72, 0.5), (0.78, 0.5)])
        usleep(80_000)
        say("kept going right: \(state()), moved \(Switcher.shared.selectedIndex - first)")
        swipe([(0.66, 0.5), (0.58, 0.5)])
        usleep(80_000)
        say("came back left: \(state())")
        say("revealed \(Switcher.shared.isRevealed)")
        touch.finish(cancel: true)
        usleep(150_000)
        say("fourth finger: open \(Switcher.shared.isActive)")

        touch.finish(cancel: false)
        swipe([(0.5, 0.5), (0.48, 0.5), (0.45, 0.51), (0.42, 0.51)])
        usleep(80_000)
        say("swiped left: \(state())")
        touch.finish(cancel: true)
        usleep(150_000)

        swipe([(0.5, 0.5), (0.5, 0.55), (0.52, 0.6), (0.6, 0.7), (0.7, 0.8)])
        usleep(80_000)
        say("swiped up: open \(Switcher.shared.isActive), want false")
        touch.finish(cancel: true)

        swipe([(0.5, 0.5), (0.51, 0.5), (0.52, 0.51)])
        usleep(80_000)
        say("tiny movement: open \(Switcher.shared.isActive), want false")
        touch.finish(cancel: true)

        // At the ends it stops rather than going round.
        swipe([(0.2, 0.5), (0.24, 0.5), (0.28, 0.5)])
        usleep(60_000)
        let count = Switcher.shared.openItems.count
        swipe((1...16).map { (0.28 + Double($0) * 0.045, 0.5) })
        usleep(80_000)
        let right = Switcher.shared.selectedIndex
        swipe((1...16).reversed().map { (0.28 + Double($0) * 0.045 - 0.72, 0.5) })
        usleep(80_000)
        say("far right stops at \(right) of \(count) (want \(count - 1)), far left at \(Switcher.shared.selectedIndex) (want 0)")
        touch.finish(cancel: true)
        usleep(150_000)

        // Sensitivity: the same small swipe, low and high.
        for level in [0.5, 2.0] {
            UserDefaults.standard.set(level, forKey: "touchSensitivity")
            usleep(250_000)
            swipe([(0.5, 0.5), (0.52, 0.5), (0.535, 0.5), (0.545, 0.5)])
            usleep(80_000)
            let opened = Switcher.shared.isActive
            let before = Switcher.shared.selectedIndex
            swipe([(0.57, 0.5), (0.60, 0.5), (0.63, 0.5), (0.66, 0.5)])
            usleep(80_000)
            let moved = Switcher.shared.isActive ? (Switcher.shared.selectedIndex - before + Switcher.shared.openItems.count) % max(Switcher.shared.openItems.count, 1) : 0
            say("sensitivity \(level): a 4.5% swipe opens \(opened), 12% more moves \(moved) steps")
            touch.finish(cancel: true)
            usleep(150_000)
        }
        UserDefaults.standard.removeObject(forKey: "touchSensitivity")
        usleep(250_000)

        // ⌘ released while three fingers hold the switcher mustn't end it.
        swipe([(0.5, 0.5), (0.55, 0.5), (0.6, 0.5)])
        usleep(60_000)
        key(55, down: true, flags: .maskCommand); key(55, down: false, flags: [])
        usleep(80_000)
        say("a ⌘ tap while held: still open \(Switcher.shared.isActive)")
        touch.finish(cancel: true)
        usleep(150_000)
    }

    /// Clicks windows on other Spaces once each, with the grid opaque and see-through in
    /// turn, after a few seconds under it. Takes over the screen and moves focus.
    private func coldTest() {
        sleep(2)
        let home = Store.shared.snapshot.first
        let start = Store.shared.visibleSpaces
        var seenApps = Set<pid_t>()
        Switcher.shared.openGrid()
        usleep(500_000)
        // One window per app, most neglected first, so each click really is cold.
        let targets = Switcher.shared.openItems.reversed().filter {
            $0.space != 0 && !start.contains($0.space) && !$0.minimized && !$0.hidden && seenApps.insert($0.pid).inserted
        }.prefix(6)
        Switcher.shared.cancel()
        usleep(400_000)
        say("\(targets.count) cold targets")
        for (n, target) in targets.enumerated() {
            let see = n % 2 == 1
            DispatchQueue.main.sync { Overlay.shared.neverOpaque = see }
            Switcher.shared.openGrid()
            usleep(2_600_000)
            guard let i = Switcher.shared.openItems.firstIndex(where: { $0.id == target.id }) else { Switcher.shared.cancel(); continue }
            let spot = DispatchQueue.main.sync { () -> CGPoint in let f = Overlay.shared.tileFrame(i); return CGPoint(x: f.midX, y: f.midY) }
            let opaque = DispatchQueue.main.sync { Overlay.shared.isOpaque }
            let began = now()
            DispatchQueue.main.sync {
                Overlay.shared.gridMouse(.down, spot)
                Overlay.shared.gridMouse(.up, spot)
            }
            usleep(900_000)
            let took = DispatchQueue.main.sync { Overlay.shared.lastArrival }
            _ = began
            say("\(see ? "see-through" : "opaque") \(target.appName): grid opaque \(opaque), arrived \(took.map { String(format: "%.0f ms", $0) } ?? "not seen")")
            if let home {
                Store.shared.committed(home.id, pid: home.pid)
                Focuser.focus(home, at: now())
            }
            usleep(500_000)
        }
        DispatchQueue.main.sync { Overlay.shared.neverOpaque = false }
    }

    /// Films a cold click on a window on the farthest Space, then the same click warm.
    /// Takes over the screen and moves focus, then goes back where it started.
    private func recordTest(_ movie: String) {
        sleep(2)
        let home = Store.shared.snapshot.first
        let start = Store.shared.visibleSpaces
        Switcher.shared.openGrid()
        usleep(600_000)
        let far = Switcher.shared.openItems.last { $0.space != 0 && !start.contains($0.space) && !$0.minimized && !$0.hidden }
        Switcher.shared.cancel()
        usleep(500_000)
        guard let far else { say("no window on another Space"); return }
        say("target \(far.appName), space \(far.space)")

        let film = Process()
        film.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        film.arguments = ["-x", "-V", "10", movie]
        try? film.run()
        usleep(1_500_000)
        Log.write("MARK recording settled")

        func click(_ name: String) {
            Switcher.shared.openGrid()
            usleep(900_000)
            guard let i = Switcher.shared.openItems.firstIndex(where: { $0.id == far.id }) else { say("tile gone"); return }
            Switcher.shared.select(i)
            usleep(300_000)
            let spot = DispatchQueue.main.sync { () -> CGPoint in let f = Overlay.shared.tileFrame(i); return CGPoint(x: f.midX, y: f.midY) }
            Log.write("MARK \(name) click")
            DispatchQueue.main.sync {
                Overlay.shared.gridMouse(.down, spot)
                Overlay.shared.gridMouse(.up, spot)
            }
            usleep(1_100_000)
        }
        func goHome() {
            if let home {
                Store.shared.committed(home.id, pid: home.pid)
                Focuser.focus(home, at: now())
            }
            usleep(700_000)
        }
        click("cold")
        goHome()
        click("warm")
        goHome()
        film.waitUntilExit()
        say("filmed")
    }

    /// Changes Space, so it takes over the screen. Swipes against the direct route: how long
    /// each takes, whether windows there paint, and whether swipes still land correctly
    /// afterwards, which they wouldn't if the Dock had lost track.
    private func jumpTest() {
        sleep(1)
        guard let display = Spaces.displays().first(where: { $0.spaces.count > 1 }) else { say("needs two Spaces"); return }
        let home = display.current
        let desktops = Store.shared.spaceList.filter { !$0.fullScreen && display.spaces.contains($0.id) }.map(\.id)
        let order = desktops.filter { $0 != home }
        guard let near = order.first else { say("needs two Spaces"); return }
        func here() -> UInt64 { Spaces.displays().first { $0.id == display.id }?.current ?? 0 }
        func painted() -> String {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let ids = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? pid_t) != getpid() }.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            return "\(ids.filter { Priv.capture($0) != nil }.count)/\(ids.count) windows paint"
        }
        func trip(_ name: String, _ direct: Bool, _ target: UInt64) {
            Spaces.direct = direct
            let began = now()
            let landed = Spaces.jump(to: target)
            let took = ms(since: began)
            usleep(250_000)
            say(String(format: "%@ to %llu: landed \(landed), %.0f ms, now on \(here()), \(painted())", name, target, took))
        }
        defer { Spaces.direct = false; Spaces.jump(to: home); usleep(300_000); say("finished back home \(here() == home)") }
        for target in [near, home, near, home] { trip("swipe", false, target) }
        for target in [near, home, near, home] { trip("direct", true, target) }
        // The real question: do swipes still work after the direct route moved things?
        for target in [near, home] {
            trip("direct then", true, target)
            trip("swipe after", false, target == home ? near : home)
            trip("swipe back", false, target)
        }
        if let far = order.last, far != near {
            trip("swipe far", false, far); trip("swipe far back", false, home)
            trip("direct far", true, far); trip("direct far back", true, home)
        }
    }

    /// Takes over focus. Starting a switch on mouse down, with throwaway windows: a click
    /// has the window on top at the release, and a drag puts everything back.
    private func pickTest(_ path: String) {
        let home = Store.shared.snapshot.first
        defer {
            fixtures.forEach { $0.terminate() }
            usleep(150_000)
            if let home {
                Store.shared.committed(home.id, pid: home.pid)
                Focuser.focus(home, at: now())
            }
            usleep(200_000)
        }
        launch(path, "FixA", 1)
        launch(path, "FixB", 1)
        guard waitFor(["FixA 1", "FixB 1"]) else { say("fixtures not seen"); return }
        usleep(400_000)
        bring("FixB 1")
        bring("FixA 1")
        func open() -> (index: Int, cell: Int, id: CGWindowID)? {
            Switcher.shared.openGrid()
            usleep(700_000)
            guard let i = Switcher.shared.openItems.firstIndex(where: { $0.title == "FixB 1" }) else { return nil }
            let item = Switcher.shared.openItems[i]
            let cells = DispatchQueue.main.sync { Overlay.shared.sectionSpaces }
            guard let cell = cells.firstIndex(where: { $0 != item.space }) else { return nil }
            return (i, cell, item.id)
        }
        func centre(_ i: Int) -> CGPoint { DispatchQueue.main.sync { let f = Overlay.shared.tileFrame(i); return CGPoint(x: f.midX, y: f.midY) } }
        func name() -> String { Store.shared.snapshot.first { $0.id == topWindow()?.id }?.title ?? "other" }

        guard let a = open() else { say("no tile"); return }
        let point = centre(a.index)
        DispatchQueue.main.sync { Overlay.shared.gridMouse(.down, point) }
        let down = now()
        var landed = 0.0
        while ms(since: down) < 400 {
            if topWindow()?.id == a.id { landed = ms(since: down); break }
            usleep(1000)
        }
        say(String(format: "press: window on top %.0f ms after the press, button still down", landed))
        usleep(100_000)
        DispatchQueue.main.sync { Overlay.shared.gridMouse(.up, point) }
        usleep(600_000)
        say("click: top is \(name()), switcher closed \(!Switcher.shared.isActive)")

        bring("FixA 1")
        guard let b = open() else { say("no tile"); return }
        let start = centre(b.index)
        DispatchQueue.main.sync { Overlay.shared.gridMouse(.down, start) }
        usleep(150_000)
        DispatchQueue.main.sync { Overlay.shared.gridMouse(.dragged, CGPoint(x: start.x + 40, y: start.y + 40)) }
        usleep(400_000)
        say("drag started: top is \(name()), want FixA 1")
        DispatchQueue.main.sync { Overlay.shared.gridMouse(.up, CGPoint(x: start.x + 40, y: start.y + 40)) }
        usleep(500_000)
        Switcher.shared.cancel()
        usleep(400_000)
        say("after dropping it where it was: top is \(name()), window still on \(Priv.spaces(of: b.id))")
    }

    /// Reduced Motion: nothing moves, everything fades. Focus stays put.
    private func reducedTest() {
        sleep(2)
        let clicks = CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown)
        defer { say("real clicks during this test: \(CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown) &- clicks)") }
        func look() -> (alpha: CGFloat, moving: Int, opaque: Bool) {
            DispatchQueue.main.sync { (CGFloat(Overlay.shared.contentOpacity), Overlay.shared.animationsRunning, Overlay.shared.isOpaque) }
        }
        func fadeTime() -> (ms: Double, steps: Int) {
            let began = now()
            var seen = Set<Int>()
            while ms(since: began) < 900 {
                let alpha = look().alpha
                if alpha <= 0 { break }
                seen.insert(Int(alpha * 20))
                usleep(1000)
            }
            return (ms(since: began), seen.count)
        }
        Switcher.shared.openGrid()
        usleep(70_000)
        let opening = look()
        usleep(600_000)
        let open = look()
        say("opening: alpha \(String(format: "%.2f", opening.alpha)), moving layers \(opening.moving)")
        say("open: alpha \(open.alpha), moving layers \(open.moving), opaque \(open.opaque)")

        let item = Switcher.shared.openItems.first
        DispatchQueue.main.sync { Overlay.shared.closeInto(item) }
        let wasOpaque = look().opaque
        let picked = fadeTime()
        Switcher.shared.cancel()
        usleep(100_000)
        say(String(format: "picking a window: faded in %.0f ms over \(picked.steps) levels, opaque at the start \(wasOpaque), moving layers \(look().moving), alpha \(look().alpha)", picked.ms))

        // A window on another Space holds for longer. Only the fade runs here, no jump.
        Switcher.shared.openGrid()
        usleep(600_000)
        let elsewhere = Switcher.shared.openItems.first { $0.space != 0 && !Store.shared.visibleSpaces.contains($0.space) }
        if let elsewhere {
            DispatchQueue.main.sync { Overlay.shared.closeInto(elsewhere) }
            let began = now()
            var opaqueUntil = 0.0, fullUntil = 0.0
            while ms(since: began) < 800 {
                let state = look()
                if state.alpha <= 0 { break }
                if state.opaque { opaqueUntil = ms(since: began) }
                if state.alpha >= 0.999 { fullUntil = ms(since: began) }
                usleep(1000)
            }
            say(String(format: "window on another Space: opaque until %.0f ms, faded from %.0f ms, gone at %.0f ms", opaqueUntil, fullUntil, ms(since: began)))
        } else {
            say("no window on another Space to try")
        }
        Switcher.shared.cancel()
        usleep(200_000)

        Switcher.shared.openGrid()
        usleep(600_000)
        Switcher.shared.cancel()
        let escaped = fadeTime()
        usleep(100_000)
        say(String(format: "Esc: faded in %.0f ms over \(escaped.steps) levels, alpha \(look().alpha)", escaped.ms))

        Switcher.shared.openGrid(following: true)
        usleep(120_000)
        DispatchQueue.main.sync { Overlay.shared.scrub(to: 0.5) }
        usleep(40_000)
        say("swipe half way: alpha \(String(format: "%.2f", look().alpha)), moving layers \(look().moving)")
        Switcher.shared.cancel()
        usleep(150_000)
        Switcher.shared.openGrid()
        usleep(600_000)
        Switcher.shared.cancel()
        usleep(150_000)
        let during = DispatchQueue.main.sync { Overlay.shared.contentOpacity }
        Switcher.shared.press(reverse: false, at: now())
        usleep(30_000)
        say(String(format: "⌘Tab during the fade: was at %.2f, panel shows at %.2f, want 1", during, DispatchQueue.main.sync { Overlay.shared.contentOpacity }))
        Switcher.shared.cancel()
        usleep(150_000)

        Switcher.shared.press(reverse: false, at: now())
        usleep(15_000)
        let quick = look()
        Switcher.shared.cancel()
        usleep(300_000)
        say("⌘Tab at 15 ms: alpha \(quick.alpha), then closed alpha \(look().alpha)")
    }

    /// Which windows keep changing, across every layer. WindowServer only works when
    /// something on screen changes, so this is what's behind a busy GPU. Read only.
    private func changeTest() {
        sleep(1)
        struct Entry { let id: CGWindowID, owner: String, layer: Int, size: String, name: String }
        func picture(_ id: CGWindowID) -> Data? {
            guard let image = Priv.capture(id) else { return nil }
            let width = 128, height = max(image.height * 128 / max(image.width, 1), 1)
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  case _ = ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)), let data = ctx.data else { return nil }
            return Data(bytes: data, count: width * 4 * height)
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let entries = list.compactMap { d -> Entry? in
            guard let id = d[kCGWindowNumber as String] as? CGWindowID, let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) > 8, (b["Height"] ?? 0) > 8 else { return nil }
            return Entry(id: id, owner: d[kCGWindowOwnerName as String] as? String ?? "?", layer: d[kCGWindowLayer as String] as? Int ?? 0,
                         size: "\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))", name: String((d[kCGWindowName as String] as? String ?? "").prefix(30)))
        }
        var last: [CGWindowID: Data] = [:], changes: [CGWindowID: Int] = [:]
        let rounds = 20
        for round in 0...rounds {
            for e in entries {
                guard let now = picture(e.id) else { continue }
                if let before = last[e.id], before != now { changes[e.id, default: 0] += 1 }
                last[e.id] = now
            }
            if round < rounds { usleep(250_000) }
        }
        say("\(entries.count) windows, \(last.count) captured, \(rounds) samples")
        for e in entries.sorted(by: { changes[$0.id, default: 0] > changes[$1.id, default: 0] }) {
            say("\(changes[e.id, default: 0])/\(rounds) \(e.owner) layer \(e.layer) \(e.size) \(e.name)\(last[e.id] == nil ? " (no capture)" : "")")
        }
    }

    /// Holds Flick in one state for tools/perf.py to measure. Focus stays put.
    private func perfState(_ state: String) {
        let seconds = UInt32(ProcessInfo.processInfo.environment["FLICK_PERFSECONDS"] ?? "") ?? 10
        sleep(3)
        switch state {
        case "after-panel":
            Switcher.shared.press(reverse: false, at: now())
            usleep(300_000)
            Switcher.shared.cancel()
        case "after-grid":
            Switcher.shared.openGrid()
            sleep(1)
            Switcher.shared.cancel()
        case "open-grid":
            Switcher.shared.openGrid()
        case "open-panel":
            Switcher.shared.press(reverse: false, at: now())
        default:
            break
        }
        FileManager.default.createFile(atPath: path + ".ready", contents: nil)
        if state == "opening" || state == "closing" {
            // Nearly all the time in one phase, so the figures describe that phase.
            let start = now()
            while ms(since: start) < Double(seconds) * 1000 {
                if state == "opening" {
                    Switcher.shared.openGrid()
                    usleep(360_000)
                    Switcher.shared.cancel()
                    usleep(60_000)
                } else {
                    // Opaque first, as a real grid is by the time you click.
                    Switcher.shared.press(reverse: false, at: now())
                    usleep(30_000)
                    Switcher.shared.toggleView()
                    usleep(90_000)
                    let item = Switcher.shared.openItems.first
                    DispatchQueue.main.sync { Overlay.shared.closeInto(item) }
                    usleep(400_000)
                    Switcher.shared.cancel()
                    usleep(30_000)
                }
            }
            return
        }
        if state == "animating" {
            // Open and close again and again, as a busy swipe would.
            let start = now()
            while ms(since: start) < Double(seconds) * 1000 {
                Switcher.shared.openGrid()
                usleep(500_000)
                let item = Switcher.shared.openItems.first
                DispatchQueue.main.sync { Overlay.shared.closeInto(item) }
                usleep(450_000)
                Switcher.shared.cancel()
                usleep(100_000)
            }
            return
        }
        sleep(seconds)
        Switcher.shared.cancel()
        usleep(100_000)
    }

    /// S flipping an open switcher, with real keys. Esc ends it, so focus stays put.
    private func flipTest() {
        sleep(1)
        func state() -> (count: Int, all: Bool, full: Bool, cells: Int, shown: Bool, id: CGWindowID) {
            let items = Switcher.shared.openItems, i = Switcher.shared.selectedIndex
            let view = DispatchQueue.main.sync { (Overlay.shared.fillsScreen, Overlay.shared.sectionFrames.count, Overlay.shared.isVisible) }
            return (items.count, Switcher.shared.showingAll, view.0, view.1, view.2, items.indices.contains(i) ? items[i].id : 0)
        }
        func show(_ name: String) {
            let s = state()
            say("\(name): \(s.count) windows, all \(s.all), full screen \(s.full), \(s.cells) cells, visible \(s.shown)")
        }
        func pressS() { key(1, down: true, flags: .maskCommand); key(1, down: false, flags: .maskCommand); usleep(120_000) }

        commandDown(); usleep(5000); tab(); usleep(150_000)
        show("opened")
        let selected = state().id
        pressS()
        show("after S")
        say("same window selected \(state().id == selected), number keys work \(state().all)")
        Switcher.shared.spaceKey(1)
        usleep(50_000)
        say("key 1 selected \(Switcher.shared.openItems[Switcher.shared.selectedIndex].appName)")
        pressS()
        show("after S again")
        pressS()
        key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand); usleep(50_000)
        commandUp(); usleep(150_000)
        say("Esc closed it \(!Switcher.shared.isActive), overlay hidden \(!DispatchQueue.main.sync { Overlay.shared.isVisible })")

        commandDown(); usleep(5000); tab(); usleep(150_000)
        show("next ⌘Tab starts as set")
        key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand); usleep(50_000)
        commandUp(); usleep(100_000)
    }

    /// The Spaces view: every window has a place and arrows go by position. Run with
    /// FLICK_ALLSPACES=1. Focus stays put.
    private func spacesTest() {
        sleep(1)
        let clicks = CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown)
        defer { say("real clicks during this test: \(CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown) &- clicks)") }
        var movesBefore: UInt32 = 0
        Switcher.shared.press(reverse: false, at: now())
        usleep(200_000)
        let items = Switcher.shared.openItems
        let spots = (0..<items.count).compactMap { i in DispatchQueue.main.sync { Overlay.shared.tileCenter(i) } }

        // Cells stay exactly where they are, however many windows they hold.
        let cells = DispatchQueue.main.sync { Overlay.shared.sectionFrames }
        let inside = DispatchQueue.main.sync {
            (0..<items.count).allSatisfy { i in cells.contains { $0.contains(Overlay.shared.tileFrame(i)) } }
        }
        let fewer = DispatchQueue.main.sync { () -> [CGRect] in
            Overlay.shared.prepare(Array(items.prefix(2)), index: 0)
            let frames = Overlay.shared.sectionFrames
            Overlay.shared.prepare(items, index: 1)
            return frames
        }
        say("cells \(cells.count), every tile inside one \(inside), same with 2 windows \(cells == fewer)")
        say("sizes \(Set(cells.map { "\(Int($0.width))x\(Int($0.height))" }))")

        // Tiles sit by the windows' real positions, however recently each was used.
        let moved = DispatchQueue.main.sync { () -> Int in
            func places(_ list: [Item]) -> [CGWindowID: CGRect] {
                Overlay.shared.prepare(list, index: 0)
                return Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1.id, Overlay.shared.tileFrame($0)) })
            }
            let forward = places(items), backward = places(items.reversed()), shuffled = places(items.shuffled())
            Overlay.shared.prepare(items, index: 1)
            return items.filter { forward[$0.id] != backward[$0.id] || forward[$0.id] != shuffled[$0.id] }.count
        }
        say("tiles that moved when the recent order changed: \(moved), want 0")
        say("keys \(Store.shared.spaceList.map { String($0.key.prefix(8)) })")

        // Every window's picture has to reach the window's true size.
        let sizes = DispatchQueue.main.sync { () -> [(name: String, ratio: Double, needed: Double)] in
            let result = Overlay.shared.closedSizes()
            Overlay.shared.prepare(items, index: 1)
            Overlay.shared.reveal()
            return result
        }
        // And when a busy Space makes the tiles tiny.
        let crowded = DispatchQueue.main.sync { () -> [(name: String, ratio: Double, needed: Double)] in
            let many = Array(repeating: items, count: 6).flatMap { $0 }
            Overlay.shared.prepare(many, index: 1)
            let result = Overlay.shared.closedSizes()
            Overlay.shared.prepare(items, index: 1)
            Overlay.shared.reveal()
            return result
        }
        let tightest = crowded.max { $0.needed < $1.needed }
        say(String(format: "crowded: needs up to %.1fx, smallest reached %.0f%%", tightest?.needed ?? 0, (crowded.map(\.ratio).min() ?? 0) * 100))
        let short = sizes.filter { abs($0.ratio - 1) > 0.01 }
        say("full size check: \(sizes.count) windows, \(short.count) wrong: " + sizes.map { String(format: "%@ needs %.1fx, gets %.0f%%", $0.name, $0.needed, $0.ratio * 100) }.joined(separator: "; "))

        // Names, order, hiding and columns, then put them back.
        let saved = Prefs.current.layout
        let keys = Spaces.arranged(Store.shared.spaceList, saved).map(\.key)
        var edited = saved
        edited.names[keys[0]] = "Work"
        edited.order = [keys[1], keys[0]] + keys.dropFirst(2)
        edited.hidden = [keys[keys.count - 1]]
        edited.columns = 2
        Prefs.save(edited)
        usleep(250_000)
        let titles = DispatchQueue.main.sync { () -> [String] in
            Overlay.shared.prepare(items, index: 1)
            return Overlay.shared.sectionTitles
        }
        let columns = Set(DispatchQueue.main.sync { Overlay.shared.sectionFrames }.map(\.minX)).count
        say("edited: \(titles), \(columns) columns")
        if saved == Prefs.SpaceLayout() { UserDefaults.standard.removeObject(forKey: "spaceLayout") } else { Prefs.save(saved) }
        usleep(250_000)
        DispatchQueue.main.sync { Overlay.shared.prepare(items, index: 1) }

        for n in 1...3 {
            Switcher.shared.spaceKey(1)
            usleep(40_000)
            say("key 1, press \(n): window \(Switcher.shared.selectedIndex) \(Switcher.shared.openItems[Switcher.shared.selectedIndex].appName)")
        }
        say("\(items.count) windows on \(Set(items.map(\.space)).count) Spaces, \(Store.shared.spaceList.count) Spaces in all")
        say("tiles overlap: \(Set(spots.map { "\(Int($0.x)),\(Int($0.y))" }).count != spots.count)")
        func step(_ dx: Int, _ dy: Int, _ name: String) {
            var moved = 0, wrong = 0
            for _ in 0..<items.count {
                let from = Switcher.shared.selectedIndex
                Switcher.shared.arrow(dx: dx, dy: dy)
                usleep(40_000)
                let to = Switcher.shared.selectedIndex
                if to == from { break }
                moved += 1
                let a = spots[from], b = spots[to]
                if (b.x - a.x) * CGFloat(dx) + (b.y - a.y) * CGFloat(dy) <= 0 { wrong += 1 }
            }
            say("\(name): \(moved) moves, \(wrong) wrong way")
        }
        say("still open before the arrows: \(Switcher.shared.isActive)")
        movesBefore = CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved)
        step(1, 0, "right"); step(-1, 0, "left"); step(0, 1, "down"); step(0, -1, "up")
        say("real mouse moves during the arrows: \(CGEventSource.counterForEventType(.hidSystemState, eventType: .mouseMoved) &- movesBefore)")
        Switcher.shared.cancel()
    }

    /// Flick's own window in the list, and W closing it. Focus stays put.
    private func settingsTest() {
        sleep(1)
        let title = "Flick Settings"
        func listed() -> Bool { Store.shared.snapshot.contains { $0.title == title } }
        say("before opening: listed \(listed()), want false")
        DispatchQueue.main.sync { (NSApp.delegate as? AppDelegate)?.showSettings(activate: false) }
        usleep(700_000)
        say("open: listed \(listed()), want true")
        Switcher.shared.press(reverse: false, at: now())
        usleep(150_000)
        guard let i = Switcher.shared.openTitles.firstIndex(of: title) else { say("not in switcher"); Switcher.shared.cancel(); return }
        say("in switcher at \(i), has icon \(Switcher.shared.openItems[i].icon != nil)")
        Switcher.shared.select(i)
        usleep(50_000)
        Switcher.shared.quitSelected()
        usleep(800_000)
        DispatchQueue.main.sync { (NSApp.delegate as? AppDelegate)?.showOrganiser(activate: false) }
        usleep(400_000)
        let organiser = Store.shared.snapshot.first { $0.title == "Spaces" }
        say("organiser listed \(organiser != nil)")
        if let organiser {
            DispatchQueue.main.sync {
                (NSApp.delegate as? AppDelegate)?.closeOwn(organiser.id)
                (NSApp.delegate as? AppDelegate)?.closeOwn(0)
            }
            usleep(1_200_000)
            say("organiser closed \(!Store.shared.snapshot.contains { $0.title == "Spaces" })")
        }
        say("Q closed it: tile gone \(!Switcher.shared.openTitles.contains(title)), listed \(listed()), Flick alive true")
        Switcher.shared.cancel()
    }

    private func scenarios() {
        // Tests change settings as they go. Yours come back exactly as they were.
        let domain = Bundle.main.bundleIdentifier ?? "local.flick.app"
        let saved = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        defer {
            UserDefaults.standard.setPersistentDomain(saved, forName: domain)
            usleep(150_000)
        }
        // Each test sets up the mode it's checking, whatever yours is.
        UserDefaults.standard.set(false, forKey: "reducedMotion")
        usleep(200_000)
        if ProcessInfo.processInfo.environment["FLICK_SPACEPROBE"] != nil { spaceProbe(); return }
        if ProcessInfo.processInfo.environment["FLICK_PREFTEST"] != nil { prefTest(); return }
        if let shot = ProcessInfo.processInfo.environment["FLICK_FADETEST"] { fadeTest(shot); return }
        if let helper = ProcessInfo.processInfo.environment["FLICK_STICKYTEST"] { stickyTest(helper); return }
        if let fixture = ProcessInfo.processInfo.environment["FLICK_EARLYTEST"] { earlyTest(fixture); return }
        if ProcessInfo.processInfo.environment["FLICK_SETTINGSTEST"] != nil { settingsTest(); return }
        if ProcessInfo.processInfo.environment["FLICK_SPACESTEST"] != nil { spacesTest(); return }
        if ProcessInfo.processInfo.environment["FLICK_FLIPTEST"] != nil { flipTest(); return }
        if let state = ProcessInfo.processInfo.environment["FLICK_PERFSTATE"] { perfState(state); return }
        if ProcessInfo.processInfo.environment["FLICK_CHANGETEST"] != nil { changeTest(); return }
        if let fixture = ProcessInfo.processInfo.environment["FLICK_PICKTEST"] { pickTest(fixture); return }
        if ProcessInfo.processInfo.environment["FLICK_JUMPTEST"] != nil { jumpTest(); return }
        if let movie = ProcessInfo.processInfo.environment["FLICK_RECORDTEST"] { recordTest(movie); return }
        if ProcessInfo.processInfo.environment["FLICK_COLDTEST"] != nil { coldTest(); return }
        if ProcessInfo.processInfo.environment["FLICK_TOUCHTEST"] != nil { touchTest(); return }
        if let fixture = ProcessInfo.processInfo.environment["FLICK_MOVETEST"] { moveTest(fixture); return }
        if ProcessInfo.processInfo.environment["FLICK_REDUCEDTEST"] != nil { reducedTest(); return }
        if ProcessInfo.processInfo.environment["FLICK_SWIPETEST"] != nil { swipeTest(); return }
        if let prefix = ProcessInfo.processInfo.environment["FLICK_OPENTEST"] { openTest(prefix); return }
        if ProcessInfo.processInfo.environment["FLICK_BENCH"] != nil {
            sleep(4)
            say(Store.shared.bench())
            say(Thumbs.shared.bench(Store.shared.snapshot))
            func footprint() -> String {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                _ = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
                }
                return String(format: "%.1f MB", Double(info.phys_footprint) / 1_048_576)
            }
            say("footprint \(footprint())")
            // What using the grid costs, once it's all settled.
            func cpu() -> Double { Double(clock()) / Double(CLOCKS_PER_SEC) * 1000 }
            for n in 1...3 {
                let before = cpu()
                Switcher.shared.openGrid()
                usleep(900_000)
                Switcher.shared.cancel()
                sleep(2)
                say(String(format: "grid open \(n): %.0f ms of CPU, memory after \(footprint())", cpu() - before))
            }
            let before = cpu()
            Switcher.shared.press(reverse: false, at: now())
            usleep(400_000)
            Switcher.shared.cancel()
            sleep(2)
            say(String(format: "⌘Tab held open: %.0f ms of CPU, memory after \(footprint())", cpu() - before))
            return
        }
        if ProcessInfo.processInfo.environment["FLICK_REVEALTEST"] != nil {
            // Opens and cancels the switcher directly: no keys posted, focus never moves.
            sleep(1)
            for _ in 0..<12 {
                Switcher.shared.press(reverse: false, at: now())
                usleep(130_000)
                Switcher.shared.cancel()
                usleep(120_000)
            }
            usleep(100_000)
            say("done, \(Store.shared.snapshot.count) windows")
            return
        }
        if let fixture = ProcessInfo.processInfo.environment["FLICK_CLOSETEST"] { closeTest(fixture); return }
        if let fixture = ProcessInfo.processInfo.environment["FLICK_FIXTURE"] { fixtureRun(fixture); return }
        let items = Store.shared.snapshot
        say("windows \(items.count)")
        for (i, it) in items.enumerated() {
            say("  \(i) [\(it.id)] \(it.appName): \(it.title) space=\(it.space) min=\(it.minimized) hidden=\(it.hidden)")
        }
        say("visible spaces \(Spaces.visible().sorted())")
        say("thumbs enabled \(Thumbs.shared.enabled), cached \(items.filter { Thumbs.shared.image($0.id) != nil }.count)")
        say("preflight \(CGPreflightScreenCaptureAccess()), hide pref \(UserDefaults.standard.bool(forKey: "hideThumbnails"))")
        for it in items.prefix(9) {
            let s0 = now(); let img = Priv.capture(it.id); let t = ms(since: s0)
            say("  capture \(it.appName) sp\(it.space): \(img.map { "\($0.width)x\($0.height)" } ?? "nil") \(String(format: "%.1f", t))ms")
        }

        let here = Spaces.visible()
        let local = items.filter { here.contains($0.space) && !$0.minimized && !$0.hidden }
        guard local.count >= 2 else { say("need two windows on this Space"); return }

        // Quick taps: each one should land on the previous window.
        var times: [Double] = []
        var correct = 0
        let taps = 8
        for _ in 0..<taps {
            let order = Store.shared.snapshot
            guard order.count > 1 else { break }
            let target = order[1]
            commandDown(); usleep(4000); tab(); usleep(25000)
            let start = now()
            commandUp()
            if let t = waitForTop(target.id) { times.append(t); correct += 1; say("  \(target.appName) \(String(format: "%.1f", t))ms") } else { say("  miss: wanted \(target.appName), top is \(topWindow()?.owner ?? "?")") }
            _ = start
            usleep(150_000)
        }
        say("quick taps \(correct)/\(taps), release→window on top: \(summary(times))")
        if ProcessInfo.processInfo.environment["FLICK_BASELINE"] != nil { return }

        // Very fast repeated taps must not lose their place.
        let first = Store.shared.snapshot
        for _ in 0..<4 {
            commandDown(); usleep(2000); tab(); usleep(3000); commandUp(); usleep(30_000)
        }
        usleep(300_000)
        let after = Store.shared.snapshot
        say("4 rapid taps: returned to start \(first.first?.id == after.first?.id)")

        // Hold and step: third window.
        if local.count >= 3 {
            let order = Store.shared.snapshot
            let target = order[2]
            commandDown(); usleep(4000); tab(); usleep(120_000); tab(); usleep(120_000)
            commandUp()
            let t = waitForTop(target.id)
            say("hold, Tab twice → \(target.appName): \(t.map { String(format: "%.1fms", $0) } ?? "miss")")
            usleep(200_000)
        }

        // Escape leaves everything alone.
        let before = topWindow()?.id
        commandDown(); usleep(4000); tab(); usleep(120_000)
        key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand); usleep(30_000)
        commandUp(); usleep(250_000)
        say("escape kept window \(before == topWindow()?.id)")

        // Instant Space jump.
        let startSpace = Spaces.visible()
        if let away = Store.shared.snapshot.first(where: { $0.space != 0 && !startSpace.contains($0.space) && !$0.minimized && !$0.hidden }),
           let home = Store.shared.snapshot.first(where: { startSpace.contains($0.space) && !$0.minimized && !$0.hidden }) {
            var jumps: [Double] = []
            var ok = 0
            for round in 0..<3 {
                for item in [away, home] {
                    let start = now()
                    let landed = Spaces.jump(to: item.space)
                    if landed { jumps.append(ms(since: start)); ok += 1 }
                    if let psn = item.psn { Priv.front(psn: psn, window: item.id) }
                    usleep(350_000)
                    _ = round
                }
            }
            say("space jumps \(ok)/6: \(summary(jumps)), back home \(Spaces.visible() == startSpace)")
        } else {
            say("no window on another Space to test")
        }
    }

    // MARK: Runs against throwaway windows from a fixture app

    private var fixtures: [Process] = []

    private func launch(_ path: String, _ name: String, _ windows: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [name, String(windows)]
        try? p.run()
        fixtures.append(p)
    }

    private func item(_ title: String) -> Item? { Store.shared.snapshot.first { $0.title == title } }

    private func waitFor(_ titles: [String], timeout: Double = 8000) -> Bool {
        let start = now()
        while ms(since: start) < timeout {
            if titles.allSatisfy({ item($0) != nil }) { return true }
            usleep(20_000)
        }
        return false
    }

    private func bring(_ title: String) {
        guard let it = item(title) else { return }
        Store.shared.committed(it.id, pid: it.pid)
        Focuser.focus(it, at: now())
        _ = waitForTop(it.id, timeout: 800)
        usleep(120_000)
    }

    private var holdMs: UInt32 { UInt32(ProcessInfo.processInfo.environment["FLICK_HOLDMS"] ?? "") ?? 30 }

    /// Takes over focus. Checks that starting a switch early can always be undone.
    private func earlyTest(_ path: String) {
        let home = Store.shared.snapshot.first
        defer {
            fixtures.forEach { $0.terminate() }
            usleep(150_000)
            if let home {
                Store.shared.committed(home.id, pid: home.pid)
                Focuser.focus(home, at: now())
            }
            usleep(200_000)
        }
        launch(path, "FixA", 1)
        launch(path, "FixB", 2)
        launch(path, "FixH", 1)
        guard waitFor(["FixA 1", "FixB 1", "FixB 2", "FixH 1"]) else { say("fixtures not seen"); return }
        usleep(400_000)
        func name(_ id: CGWindowID?) -> String { Store.shared.snapshot.first { $0.id == id }?.title ?? "other" }
        func watch(_ limit: Double, _ into: inout [String]) {
            let start = now()
            while ms(since: start) < limit {
                let top = name(topWindow()?.id)
                if into.last != top { into.append(top) }
                usleep(1000)
            }
        }
        func quickFlip() { commandDown(); usleep(5000); tab(); usleep(90_000); commandUp(); usleep(350_000) }
        func ordered() { bring("FixH 1"); bring("FixB 1"); bring("FixA 1") }

        ordered()
        var seen: [String] = []
        commandDown(); usleep(5000); tab()
        watch(250, &seen)
        key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand)
        watch(250, &seen)
        commandUp(); usleep(200_000)
        say("Esc: \(seen.joined(separator: " > ")), back on A \(name(topWindow()?.id) == "FixA 1")")
        quickFlip()
        say("then ⌘Tab goes to B \(name(topWindow()?.id) == "FixB 1")")

        ordered()
        seen = []
        commandDown(); usleep(5000); tab()
        watch(150, &seen)
        tab()
        watch(60, &seen)
        commandUp()
        watch(300, &seen)
        say("past first: \(seen.joined(separator: " > ")), on H \(name(topWindow()?.id) == "FixH 1")")
        quickFlip()
        say("then ⌘Tab goes back to A \(name(topWindow()?.id) == "FixA 1")")

        ordered()
        commandDown(); usleep(5000)
        for _ in 0..<4 { tab(); usleep(12_000); commandUp(); usleep(12_000); commandDown(); usleep(5000) }
        commandUp(); usleep(500_000)
        say("4 rapid taps end on A \(name(topWindow()?.id) == "FixA 1"), top \(name(topWindow()?.id))")

        ordered()
        quickFlip()
        say("quick tap lands on B \(name(topWindow()?.id) == "FixB 1")")
        quickFlip()
        say("and back to A \(name(topWindow()?.id) == "FixA 1")")

        // Two windows of one app.
        bring("FixB 2"); bring("FixB 1")
        seen = []
        commandDown(); usleep(5000); tab()
        watch(250, &seen)
        key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand)
        watch(250, &seen)
        commandUp(); usleep(200_000)
        say("same app Esc: \(seen.joined(separator: " > ")), back on B1 \(name(topWindow()?.id) == "FixB 1")")
        quickFlip()
        say("same app tap lands on B2 \(name(topWindow()?.id) == "FixB 2")")

        // Flick's own Settings window, reached with real keys.
        let title = "Flick Settings"
        DispatchQueue.main.sync { (NSApp.delegate as? AppDelegate)?.showSettings(activate: false) }
        usleep(500_000)
        ordered()
        commandDown(); usleep(5000); tab(); usleep(160_000)
        guard let tile = Switcher.shared.openTitles.firstIndex(of: title) else {
            commandUp(); say("Settings not in switcher"); return
        }
        for _ in 1..<max(tile, 1) { tab(); usleep(40_000) }
        commandUp(); usleep(600_000)
        let (active, keyTitle) = DispatchQueue.main.sync { (NSApp.isActive, NSApp.keyWindow?.title ?? "none") }
        say("Settings tile \(tile): Flick active \(active), key window \(keyTitle)")
        quickFlip()
        say("⌘Tab out of Settings: top \(name(topWindow()?.id)), Flick active \(DispatchQueue.main.sync { NSApp.isActive })")
        quickFlip()
        let back = DispatchQueue.main.sync { (NSApp.isActive, NSApp.keyWindow?.title ?? "none") }
        say("⌘Tab back: Flick active \(back.0), key window \(back.1)")
        DispatchQueue.main.sync { (NSApp.delegate as? AppDelegate)?.closeSettings() }
        usleep(300_000)
    }

    private func flips(_ count: Int, _ titles: [String]) -> ([Double], Int) {
        var times: [Double] = []
        var good = 0
        var want = 0
        for flip in 1...count {
            // Aim at whichever window isn't on top, so one miss counts as one miss.
            if item(titles[want])?.id == topWindow()?.id { want = 1 - want }
            guard let target = item(titles[want]) else { break }
            commandDown(); usleep(5000); tab(); usleep(holdMs * 1000)
            let start = now()
            commandUp()
            let deadline = 700.0
            var landed: Double?
            while ms(since: start) < deadline {
                if topWindow()?.id == target.id { landed = ms(since: start); break }
                usleep(500)
            }
            if let landed {
                times.append(landed)
                good += 1
                if landed > 100 { say(String(format: "  flip %d slow: %.1fms", flip, landed)) }
                Log.write(String(format: "flip %d landed %.1fms", flip, landed))
            } else {
                say("  flip \(flip) miss: wanted \(titles[want]), top is \(topWindow()?.owner ?? "?")")
                Log.write("flip \(flip) missed")
            }
            want = 1 - want
            usleep(170_000)
        }
        return (times, good)
    }

    /// Each setting that changes behaviour, live. Every test cancels, so focus never moves.
    private func prefTest() {
        let d = UserDefaults.standard
        func settle() { usleep(120_000) }
        func opened() -> [Item] {
            let start = now()
            Switcher.shared.press(reverse: false, at: start)
            usleep(40_000)
            let titles = Switcher.shared.openItems
            Switcher.shared.cancel()
            usleep(60_000)
            return titles
        }
        d.set(false, forKey: "currentSpaceOnly"); settle()
        let waited = now()
        while Store.shared.snapshot.count < 4, ms(since: waited) < 10_000 { usleep(100_000) }
        let all = opened()
        say("default lists \(all.count)")

        // Shortcuts, with real posted keys.
        for (hold, code, flag, name) in [(0, CGKeyCode(55), CGEventFlags.maskCommand, "⌘"), (1, 58, .maskAlternate, "⌥"), (2, 59, .maskControl, "⌃")] {
            d.set(hold, forKey: "holdKey"); usleep(400_000)
            key(code, down: true, flags: flag); usleep(5000)
            key(48, down: true, flags: flag); key(48, down: false, flags: flag); usleep(60_000)
            let on = Switcher.shared.isActive
            if on { key(53, down: true, flags: flag); key(53, down: false, flags: flag); usleep(30_000) }
            key(code, down: false, flags: []); usleep(80_000)
            say("hold \(name): opened \(on), closed \(!Switcher.shared.isActive)")
        }
        d.set(1, forKey: "holdKey"); settle()
        key(55, down: true, flags: .maskCommand); usleep(5000)
        key(48, down: true, flags: .maskCommand); key(48, down: false, flags: .maskCommand); usleep(60_000)
        let wrong = Switcher.shared.isActive
        key(55, down: false, flags: []); usleep(80_000)
        if wrong { Switcher.shared.cancel() }
        say("with ⌥ set, ⌘Tab leaves Flick closed: \(!wrong)")
        d.removeObject(forKey: "holdKey"); settle()

        // Filters.
        if let app = all.first(where: { $0.bundleID != nil })?.bundleID {
            d.set([app], forKey: "ignoredApps"); settle()
            let less = opened()
            say("ignored \(app): \(all.count)→\(less.count), gone \(!less.contains { $0.bundleID == app })")
            d.removeObject(forKey: "ignoredApps"); settle()
        }
        d.set(true, forKey: "currentSpaceOnly"); settle()
        let here = Spaces.visible()
        let local = opened()
        say("current Space: \(all.count)→\(local.count), all local \(local.allSatisfy { here.contains($0.space) || $0.space == 0 })")
        d.removeObject(forKey: "currentSpaceOnly"); settle()

        // Delay holds the overlay back only when asked.
        d.set(100, forKey: "delayMs"); settle()
        Switcher.shared.press(reverse: false, at: now())
        usleep(50_000)
        let early = Switcher.shared.isRevealed
        usleep(110_000)
        say("100 ms delay: hidden at 50 ms \(!early), shown at 160 ms \(Switcher.shared.isRevealed)")
        Switcher.shared.cancel()
        d.removeObject(forKey: "delayMs"); settle()
        Switcher.shared.press(reverse: false, at: now())
        usleep(15_000)
        say("no delay: shown at 15 ms \(Switcher.shared.isRevealed)")
        Switcher.shared.cancel()
    }

    /// Closes a background window through the same call as the W key. Leaves focus alone.
    private func closeTest(_ path: String) {
        launch(path, "FixC", 2)
        defer { fixtures.forEach { $0.terminate() } }
        let seen = waitFor(["FixC 2"])
        say("seen \(seen)")
        if let p = fixtures.first?.processIdentifier, let a = NSRunningApplication(processIdentifier: p) {
            say("policy \(a.activationPolicy.rawValue) launched \(a.isFinishedLaunching)")
        }
        guard item("FixC 2") != nil else { say("no window"); return }
        // Same path as the W key, with the refresh that used to race it: open, wait, close.
        Switcher.shared.press(reverse: false, at: now())
        usleep(125_000)
        guard let i = Switcher.shared.openTitles.firstIndex(of: "FixC 2") else { say("not in switcher"); return }
        Switcher.shared.select(i)
        Switcher.shared.closeSelected()
        usleep(800_000)
        say("listed: \(item("FixC 2") != nil), tile: \(Switcher.shared.openTitles.contains("FixC 2")), FixC 1 kept: \(item("FixC 1") != nil)")
        Switcher.shared.cancel()
    }

    private func fixtureRun(_ path: String) {
        let baseline = ProcessInfo.processInfo.environment["FLICK_BASELINE"]
        let home = Store.shared.snapshot.first
        defer {
            fixtures.forEach { $0.terminate() }
            usleep(150_000)
            if let home {
                Store.shared.committed(home.id, pid: home.pid)
                Focuser.focus(home, at: now())
            }
            usleep(200_000)
        }
        launch(path, "FixA", 1)
        launch(path, "FixB", 2)
        launch(path, "FixH", 1)
        let titles = ["FixA 1", "FixB 1", "FixB 2", "FixH 1"]
        guard waitFor(titles) else { say("fixtures not seen: \(Store.shared.snapshot.map(\.title))"); return }
        usleep(400_000)

        bring("FixB 1")
        bring("FixA 1")
        let (times, good) = flips(14, ["FixB 1", "FixA 1"])
        say("\(baseline ?? "flick") flips \(good)/14, release→window on top: \(summary(times))")
        if baseline != nil { return }

        if ProcessInfo.processInfo.environment["FLICK_SHORT"] != nil {
            bring("FixB 2"); bring("FixB 1"); bring("FixA 1")
            let before = Store.shared.snapshot.count
            if let i = Store.shared.snapshot.firstIndex(where: { $0.title == "FixB 2" }) {
                commandDown(); usleep(5000); tab(); usleep(110_000)
                for _ in 1..<max(i, 1) { tab(); usleep(30_000) }
                key(13, down: true, flags: .maskCommand); key(13, down: false, flags: .maskCommand); usleep(200_000)
                key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand); usleep(30_000)
                commandUp(); usleep(400_000)
                say("W key closed FixB 2: \(item("FixB 2") == nil), windows \(before)→\(Store.shared.snapshot.count), FixB 1 kept: \(item("FixB 1") != nil)")
            }
            return
        }

        // Same-app windows.
        bring("FixB 2"); bring("FixB 1")
        if let target = item("FixB 2") {
            commandDown(); usleep(5000); tab(); usleep(30_000); commandUp()
            say("same-app switch: \(waitForTop(target.id).map { String(format: "%.1fms", $0) } ?? "MISS")")
        }
        usleep(200_000)

        // Three-step hold, back with shift.
        bring("FixH 1"); bring("FixA 1"); bring("FixB 1")
        var order = Store.shared.snapshot
        let third = order[2]
        commandDown(); usleep(5000); tab(); usleep(110_000); tab(); usleep(60_000); tab(); usleep(60_000)
        tab(flags: [.maskCommand, .maskShift]); usleep(60_000); commandUp()
        say("hold + Tab Tab Tab ⇧Tab → \(third.title): \(waitForTop(third.id).map { String(format: "%.1fms", $0) } ?? "MISS")")
        usleep(200_000)

        // Arrow keys.
        order = Store.shared.snapshot
        commandDown(); usleep(5000); tab(); usleep(110_000)
        key(124, down: true, flags: .maskCommand); key(124, down: false, flags: .maskCommand); usleep(50_000); commandUp()
        say("arrow → \(order[2].title): \(waitForTop(order[2].id).map { String(format: "%.1fms", $0) } ?? "MISS")")
        usleep(200_000)

        // Escape.
        let before = topWindow()?.id
        commandDown(); usleep(5000); tab(); usleep(110_000)
        key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand); usleep(30_000)
        commandUp(); usleep(260_000)
        say("escape kept window: \(before == topWindow()?.id)")

        // Mouse click on a tile.
        order = Store.shared.snapshot
        commandDown(); usleep(5000); tab(); usleep(160_000)
        var centre: CGPoint?
        DispatchQueue.main.sync { centre = Overlay.shared.tileCenter(2) }
        let saved = CGEvent(source: nil)?.location
        if let c = centre {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(40_000)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        usleep(30_000)
        commandUp()
        say("click tile → \(order[2].title): \(waitForTop(order[2].id).map { String(format: "%.1fms", $0) } ?? "MISS")")
        if let saved { CGWarpMouseCursorPosition(saved) }
        usleep(200_000)

        // Hung app: stop FixH's main thread, then switch to and away from it.
        bring("FixH 1"); bring("FixA 1")
        let hung = fixtures[2]
        kill(hung.processIdentifier, SIGUSR1)
        usleep(150_000)
        bring("FixB 1")
        if let a = item("FixA 1") {
            let start = now()
            commandDown(); usleep(5000); tab(); usleep(30_000); commandUp()
            say("switching with a hung app running: \(waitForTop(a.id).map { String(format: "%.1fms", $0) } ?? "MISS") (from \(String(format: "%.0f", ms(since: start)))ms)")
        }
        usleep(200_000)
        if let h = item("FixH 1") {
            let start = now()
            Store.shared.committed(h.id, pid: h.pid)
            Focuser.focus(h, at: start)
            usleep(120_000)
            commandDown(); usleep(5000); tab(); usleep(30_000); commandUp()
            usleep(150_000)
            say("after choosing hung app, next ⌘Tab still answered: top is \(topWindow()?.owner ?? "?")")
        }
        usleep(200_000)

        // Close and quit from the switcher.
        bring("FixB 2"); bring("FixB 1"); bring("FixA 1")
        let countBefore = Store.shared.snapshot.count
        if let i = Store.shared.snapshot.firstIndex(where: { $0.title == "FixB 2" }) {
            commandDown(); usleep(5000); tab(); usleep(110_000)
            for _ in 1..<max(i, 1) { tab(); usleep(30_000) }
            key(13, down: true, flags: .maskCommand); key(13, down: false, flags: .maskCommand); usleep(200_000)
            key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand); usleep(30_000)
            commandUp(); usleep(350_000)
            say("W closed FixB 2: \(item("FixB 2") == nil), windows \(countBefore)→\(Store.shared.snapshot.count)")
        }
        if let i = Store.shared.snapshot.firstIndex(where: { $0.title == "FixB 1" }) {
            commandDown(); usleep(5000); tab(); usleep(110_000)
            for _ in 1..<max(i, 1) { tab(); usleep(30_000) }
            key(12, down: true, flags: .maskCommand); key(12, down: false, flags: .maskCommand); usleep(250_000)
            key(53, down: true, flags: .maskCommand); key(53, down: false, flags: .maskCommand); usleep(30_000)
            commandUp(); usleep(400_000)
            say("Q quit FixB: \(!fixtures[1].isRunning)")
        }

        // Password fields switch taps off. The hot key has to catch ⌘Tab instead.
        bring("FixA 1")
        EnableSecureEventInput()
        usleep(100_000)
        commandDown(); usleep(5000); tab(); usleep(50_000)
        say("secure input: ⌘Tab seen \(Switcher.shared.isActive), secure on \(IsSecureEventInputEnabled())")
        commandUp(); usleep(150_000)
        say("secure input: release seen \(!Switcher.shared.isActive)")
        if Switcher.shared.isActive { Switcher.shared.cancel() }
        DisableSecureEventInput()
    }

    private func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        return String(format: "median %.1fms, max %.1fms", sorted[sorted.count / 2], sorted.last!)
    }
}
