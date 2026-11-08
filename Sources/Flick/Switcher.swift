import Cocoa
import Carbon.HIToolbox
import os

/// The switch itself. Every step here reads memory and hands off to other threads,
/// so it's safe to run inside the event tap.
final class Switcher {
    static let shared = Switcher()

    private struct Session {
        var active = false
        var items: [Item] = []
        var index = 0
        var token = 0
        var revealed = false
        var early: Item?      // already brought forward at the press
        var origin: Item?     // the window that was in front before that
        var all = false       // showing every Space, whatever the setting says
        var sticky = false    // opened by a swipe, so no held key ends it
        var touch = false     // held open by three fingers, which end it when lifted
    }
    private let session = OSAllocatedUnfairLock(initialState: Session())

    var isActive: Bool { session.withLock { $0.active } }
    /// Open and waiting for the hold key to be let go.
    var isHeld: Bool { session.withLock { $0.active && !$0.sticky && !$0.touch } }
    var isTouching: Bool { session.withLock { $0.active && $0.touch } }
    var isSticky: Bool { session.withLock { $0.active && $0.sticky } }
    var openTitles: [String] { session.withLock { $0.items.map(\.title) } }
    var openItems: [Item] { session.withLock { $0.items } }
    var selectedIndex: Int { session.withLock { $0.index } }
    /// What the next ⌘Tab will show.
    var restingItems: [Item] { visibleItems(all: !Prefs.current.currentSpaceOnly) }
    var showingAll: Bool { session.withLock { $0.all } }
    var isRevealed: Bool { session.withLock { $0.active && $0.revealed } }

    private var touchNext = false   // touch thread only, read inside the next press

    /// Three fingers started a sideways swipe. Same as ⌘Tab, held by the fingers.
    func pressTouch(reverse: Bool) -> Bool {
        guard !isActive else { return false }
        touchNext = true
        press(reverse: reverse, at: now())
        touchNext = false
        return isTouching
    }

    func press(reverse: Bool, at start: UInt64) {
        var early: Item?
        let opened: (items: [Item], index: Int, token: Int, all: Bool)? = session.withLock { s in
            if s.active {
                step(&s, by: reverse ? -1 : 1)
                return nil
            }
            s.all = !Prefs.current.currentSpaceOnly
            s.sticky = false
            s.touch = touchNext
            let items = visibleItems(all: s.all)
            s.active = true
            s.items = items
            s.token += 1
            s.revealed = false
            // The first row is the window you're on, unless something else took focus.
            let onFirst = items.first?.pid == Store.shared.frontPid
            let first = onFirst ? 1 : 0
            let count = max(items.count, 1)
            s.index = reverse ? (count - 1) : min(first, count - 1)
            s.early = nil
            s.origin = nil
            if !reverse, onFirst, items.count > 1, canStartEarly(items[s.index]), canStartEarly(items[0]) {
                s.early = items[s.index]
                s.origin = items[0]
                early = s.early
            }
            return (items, s.index, s.token, s.all)
        }
        if let early { Focuser.focus(early, at: start) }
        guard let opened else {
            // Decided on the main thread, so a click that just ended the session can't
            // have this show the overlay again after it was hidden.
            DispatchQueue.main.async { [self] in
                guard let current = session.withLock({ $0.active ? ($0.index, $0.token) : nil }) else { return }
                Overlay.shared.select(current.0)
                reveal(current.1, start)
            }
            return
        }

        let token = opened.token
        let delay = Prefs.current.delay
        DispatchQueue.main.async { [self] in
            Overlay.shared.prepare(opened.items, index: opened.index, grid: opened.all)
            if delay == 0 { reveal(token, start) }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in reveal(token, start) }
        }
        // Refreshing can wait until the overlay is up, and quick taps never need it.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.12) { [self] in
            guard session.withLock({ $0.active && $0.token == token }) else { return }
            Store.shared.schedule(after: 0)
            Thumbs.shared.refresh(Array(opened.items.prefix(12)))
        }
    }

    private func reveal(_ token: Int, _ start: UInt64) {
        let show = session.withLock { s -> Bool in
            guard s.active, s.token == token, !s.revealed else { return false }
            s.revealed = true
            return true
        }
        guard show else { return }
        Overlay.shared.reveal()
        Log.write("overlay on screen \(String(format: "%.2f", ms(since: start)))ms after key")
    }

    /// W or Q may have closed the window that was in front when the switcher opened.
    private func liveOrigin(_ s: Session) -> Item? {
        s.items.contains { $0.id == s.origin?.id } ? s.origin : nil
    }

    /// A quick tap nearly always goes to the previous window, so the slow part can run
    /// while the key is still down. Never for anything that would move or animate.
    private func canStartEarly(_ item: Item) -> Bool {
        guard Prefs.current.earlySwitch, !item.hidden, !item.minimized else { return false }
        return item.space == 0 || Store.shared.visibleSpaces.contains(item.space)
    }

    private func visibleItems(all: Bool) -> [Item] {
        let prefs = Prefs.current
        var items = Store.shared.snapshot
        if !prefs.ignored.isEmpty { items.removeAll { $0.bundleID.map(prefs.ignored.contains) ?? false } }
        if !prefs.showMinimized { items.removeAll(where: \.minimized) }
        if !prefs.showHidden { items.removeAll(where: \.hidden) }
        if !all {
            let spaces = Store.shared.visibleSpaces
            items.removeAll { !spaces.contains($0.space) && $0.space != 0 }
        } else if !prefs.layout.hidden.isEmpty {
            let hidden = Set(Store.shared.spaceList.filter { prefs.layout.hidden.contains($0.key) }.map(\.id))
            items.removeAll { hidden.contains($0.home) }
        }
        return items
    }

    private func step(_ s: inout Session, by delta: Int) {
        guard !s.items.isEmpty else { return }
        s.index = (s.index + delta + s.items.count) % s.items.count
    }

    /// `clamp` stops at the first and last window instead of wrapping round, for a finger
    /// sliding across the trackpad.
    func move(by delta: Int, clamp: Bool = false) {
        let index = session.withLock { s -> Int? in
            guard s.active, !s.items.isEmpty else { return nil }
            if clamp {
                s.index = min(max(s.index + delta, 0), s.items.count - 1)
            } else {
                step(&s, by: delta)
            }
            return s.index
        }
        if let index { DispatchQueue.main.async { Overlay.shared.select(index) } }
    }

    /// In the Spaces view, arrows go by position. Tab keeps going by most recent.
    func arrow(dx: Int, dy: Int) {
        guard showingAll else { move(by: dx + dy); return }
        DispatchQueue.main.async { [self] in
            if let i = Overlay.shared.neighbour(dx: dx, dy: dy) { select(i) }
        }
    }

    /// A swipe up: the grid, open until something is picked or Esc. With `following`,
    /// it waits at closed for the finger to move it.
    @discardableResult
    func openGrid(following: Bool = false) -> Bool {
        let opened = session.withLock { s -> (items: [Item], token: Int)? in
            guard !s.active else { return nil }
            s.all = true
            s.sticky = true
            s.active = true
            s.items = visibleItems(all: true)
            s.index = 0
            s.token += 1
            s.revealed = true
            s.early = nil
            s.origin = nil
            return (s.items, s.token)
        }
        guard let opened else { return false }
        DispatchQueue.main.async {
            Overlay.shared.prepare(opened.items, index: 0, grid: true)
            if following { Overlay.shared.beginScrub(at: 0) } else { Overlay.shared.reveal(animated: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            guard session.withLock({ $0.active && $0.token == opened.token }) else { return }
            Store.shared.schedule(after: 0)
            Thumbs.shared.refresh(Array(opened.items.prefix(12)))
        }
        return true
    }

    /// The mouse went down on a tile in the grid. Only for a window that's a plain switch
    /// away, and only if the window you're on is known, so it can be undone.
    func startPick(_ index: Int) {
        guard ProcessInfo.processInfo.environment["FLICK_SELFTEST"] == nil || ProcessInfo.processInfo.environment["FLICK_PICKTEST"] != nil else { return }
        let visible = Store.shared.visibleSpaces, front = Store.shared.frontPid
        let pick = session.withLock { s -> Item? in
            guard s.active, s.early == nil, s.items.indices.contains(index) else { return nil }
            let item = s.items[index]
            guard item.pid != getpid(), !item.minimized, !item.hidden, item.space == 0 || visible.contains(item.space),
                  let origin = s.items.first(where: { $0.pid == front && ($0.space == 0 || visible.contains($0.space)) }),
                  origin.id != item.id else { return nil }
            s.early = item
            s.origin = origin
            return item
        }
        if let pick { Focuser.focus(pick, at: now()) }
    }

    /// It turned out to be a drag, or the button came up somewhere else.
    func undoPick() {
        let origin = session.withLock { s -> Item? in
            defer {
                s.early = nil
                s.origin = nil
            }
            return s.early == nil ? nil : liveOrigin(s)
        }
        if let origin {
            Store.shared.committed(origin.id, pid: origin.pid)
            Focuser.focus(origin, at: now())
        }
    }

    /// S while the switcher is open: between the current Space and the grid, for this
    /// time only. The same window stays selected if it's in the new view.
    func toggleView() {
        let flipped = session.withLock { s -> (items: [Item], index: Int, all: Bool, token: Int)? in
            guard s.active else { return nil }
            let selected = s.items.indices.contains(s.index) ? s.items[s.index].id : 0
            s.all.toggle()
            s.items = visibleItems(all: s.all)
            s.index = s.items.firstIndex { $0.id == selected } ?? min(1, max(s.items.count - 1, 0))
            return (s.items, s.index, s.all, s.token)
        }
        guard let flipped else { return }
        DispatchQueue.main.async { [self] in
            let open = session.withLock { s -> Bool in
                guard s.active, s.token == flipped.token else { return false }
                s.revealed = true
                return true
            }
            guard open else { return }
            Overlay.shared.prepare(flipped.items, index: flipped.index, grid: flipped.all)
            Overlay.shared.reveal()
            Thumbs.shared.refresh(Array(flipped.items.prefix(12)))
        }
    }

    /// 1 to 9 in the Spaces view: that Space's windows, most recent first.
    func spaceKey(_ number: Int) {
        guard showingAll else { return }
        DispatchQueue.main.async { [self] in
            if let i = Overlay.shared.nextWindow(inSection: number - 1) { select(i) }
        }
    }

    /// A Space with no windows has nothing to switch to, so go there directly.
    func go(to space: UInt64) {
        cancel()
        Focuser.jump(to: space)
    }

    func select(_ index: Int) {
        session.withLock { s in
            if s.active, s.items.indices.contains(index) { s.index = index }
        }
        DispatchQueue.main.async { Overlay.shared.select(index) }
    }

    func commit(at start: UInt64 = now()) {
        let ended = session.withLock { s -> (item: Item?, early: Item?, origin: Item?)? in
            guard s.active else { return nil }
            s.active = false
            return (s.items.indices.contains(s.index) ? s.items[s.index] : nil, s.early, liveOrigin(s))
        }
        DispatchQueue.main.async { Overlay.shared.closeInto(ended?.item) }
        guard let ended, let item = ended.item else { return }
        // Went past the window started early: the one you left is still the previous one.
        if ended.early?.id != item.id, let origin = ended.origin { Store.shared.committed(origin.id, pid: origin.pid) }
        Store.shared.committed(item.id, pid: item.pid)
        if ended.early?.id != item.id { Focuser.focus(item, at: start) }
    }

    func cancel() {
        let origin = session.withLock { s -> Item? in
            defer { s.active = false }
            return s.active ? liveOrigin(s) : nil
        }
        DispatchQueue.main.async { Overlay.shared.dismiss() }
        if let origin {
            Store.shared.committed(origin.id, pid: origin.pid)
            Focuser.focus(origin, at: now())
        }
    }

    func closeSelected() { act { item in
        if item.pid == getpid() {
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.closeOwn(item.id) }
        } else if let ax = item.ax {
            Store.shared.tracker(for: item.pid) { $0.close(ax) }
        } else {
            return
        }
        // The app decides whether it closes (it may ask to save), so look again shortly
        // after instead of assuming. An open switcher drops the tile when it goes.
        Store.shared.lookAgainSoon()
    } }

    func quitSelected() { act { item in
        // The tile is Flick's own Settings. Closing it shouldn't take the switcher down too.
        if item.pid == getpid() { closeSelected(); return }
        // Not on the key thread: a slow answer here would hold up every keypress.
        DispatchQueue.global(qos: .userInitiated).async {
            NSRunningApplication(processIdentifier: item.pid)?.terminate()
        }
    } }

    private func act(_ body: (Item) -> Void) {
        let item = session.withLock { s -> Item? in
            s.active && s.items.indices.contains(s.index) ? s.items[s.index] : nil
        }
        if let item { body(item) }
    }

    /// The model moved under an open switcher: keep the same window selected.
    func modelChanged() {
        let update = session.withLock { s -> ([Item], Int, Bool)? in
            guard s.active else { return nil }
            let fresh = visibleItems(all: s.all)
            let selected = s.items.indices.contains(s.index) ? s.items[s.index].id : 0
            // Order stays fixed while open. Only drop what closed and add what opened.
            let current = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var merged = s.items.compactMap { current[$0.id] }
            let have = Set(merged.map(\.id))
            merged.append(contentsOf: fresh.filter { !have.contains($0.id) })
            let changed = merged.map(\.id) != s.items.map(\.id) || zip(merged, s.items).contains { $0.title != $1.title || $0.home != $1.home }
            s.items = merged   // a window may have moved Space or become reachable by AX
            guard changed else { return nil }
            s.index = merged.firstIndex { $0.id == selected } ?? min(s.index, max(merged.count - 1, 0))
            return (merged, s.index, s.all)
        }
        if let update { DispatchQueue.main.async { Overlay.shared.prepare(update.0, index: update.1, grid: update.2) } }
    }
}

enum Focuser {
    private static let q = DispatchQueue(label: "flick.focus", qos: .userInteractive)
    // Concurrent, so one hung app can't hold up the next switch.
    private static let raiseQ = DispatchQueue(label: "flick.raise", qos: .userInteractive, attributes: .concurrent)

    /// Logging only: when the window really reaches the top, and when its app takes over.
    private static func watchTop(_ item: Item, from start: UInt64) {
        DispatchQueue.global(qos: .utility).async {
            var top: Double?, active: Double?
            let view = Switcher.shared.showingAll ? "grid" : "panel"
            while ms(since: start) < 1000, top == nil || active == nil {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? ?? []
                for case let w as NSDictionary in list where (w[kCGWindowLayer] as? Int) == 0 {
                    if top == nil, (w[kCGWindowNumber] as? CGWindowID) == item.id { top = ms(since: start) }
                    break
                }
                if active == nil, Store.shared.lastActivated == item.pid { active = ms(since: start) }
                usleep(1500)
            }
            Log.write("landed \(item.appName) \(view): on top \(top.map { String(format: "%.0f", $0) } ?? "never")ms, app active \(active.map { String(format: "%.0f", $0) } ?? "never")ms")
        }
    }

    /// For the self test: where a step would go, instead of going there.
    static var dryRun: ((Int, UInt64?) -> Void)?

    /// Instant Spaces: the Space beside this one, on the display under the pointer. In
    /// the queue with every other jump, so quick swipes in a row each go one further.
    static func step(_ delta: Int) {
        q.async {
            let all = Spaces.displays()
            let under = Priv.displayUnderCursor()
            guard let display = all.first(where: { $0.id == under }) ?? all.first,
                  let i = display.spaces.firstIndex(of: display.current) else { return }
            let target = display.spaces.indices.contains(i + delta) ? display.spaces[i + delta] : nil
            if let dryRun { dryRun(delta, target); return }
            guard let target else { return }   // already at the first or last Space
            let began = now()
            let landed = Spaces.jump(to: target)
            Log.write("instant spaces: \(landed ? "landed" : "missed") in \(String(format: "%.1f", ms(since: began)))ms")
            Store.shared.spaceChanged()
        }
    }

    static func jump(to space: UInt64) {
        q.async {
            Spaces.jump(to: space)
            Store.shared.spaceChanged()
        }
    }

    static func focus(_ item: Item, at start: UInt64) {
        if item.pid == getpid() {
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.showOwn(item.id) }
            return
        }
        q.async {
            if item.hidden { NSRunningApplication(processIdentifier: item.pid)?.unhide() }
            var landed = true
            // Already showing, the usual case: no need to ask the WindowServer.
            if item.space != 0, !Store.shared.visibleSpaces.contains(item.space) {
                landed = Spaces.jump(to: item.space)
                Store.shared.spaceChanged()
            }
            let spaceDone = ms(since: start)
            if let psn = item.psn {
                Priv.front(psn: psn, window: item.id)
            } else {
                NSRunningApplication(processIdentifier: item.pid)?.activate(options: [])
            }
            if let ax = item.ax {
                raiseQ.async {
                    let asked = now()
                    AXUIElementSetMessagingTimeout(ax, 0.25)
                    if item.minimized { AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
                    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                    Log.write("raise \(item.appName) answered in \(String(format: "%.1f", ms(since: asked)))ms")
                }
            }
            Log.write("focus \(item.appName): space \(landed ? "ok" : "fallback") \(String(format: "%.2f", spaceDone))ms, front \(String(format: "%.2f", ms(since: start)))ms after release")
            if Log.path != nil { watchTop(item, from: start) }
        }
    }
}

/// Keyboard input on its own high-priority thread, so nothing else in the app can
/// delay a keypress.
final class KeyTap: Thread {
    static let shared = KeyTap()
    private static let digits = [kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
                                 kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9]

    private(set) var tap: CFMachPort?
    private let ready = DispatchSemaphore(value: 0)
    private var swallowedUps = Set<Int64>()     // tap thread only
    private var loop: CFRunLoop?
    private var lastPress: UInt64 = 0
    private var hotKeys: [EventHotKeyRef?] = []
    private var backstop: CFRunLoopTimer?

    var isRunning: Bool { tap != nil }

    func begin() -> Bool {
        if isRunning { return true }
        qualityOfService = .userInteractive
        threadPriority = 1
        name = "flick.keys"
        start()
        ready.wait()
        guard tap != nil else { return false }
        installHotKeyHandler()
        applyHold()
        return true
    }

    override func main() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask),
                                callback: { _, type, event, _ in KeyTap.shared.handle(type, event) },
                                userInfo: nil)
        guard let tap else { ready.signal(); return }
        loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // A missed key-up must never leave the switcher stuck open. This is only a
        // backstop: the flag state can lag, so it has to read released several times.
        var releasedReads = 0
        let selfTest = ProcessInfo.processInfo.environment["FLICK_SELFTEST"] != nil   // posted keys don't set hardware state
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e9, 0.016, 0, 0) { timer in
            guard Switcher.shared.isHeld else {
                // Sleeps until the next session, so the app costs nothing when idle.
                CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + 1e9)
                releasedReads = 0
                return
            }
            guard !selfTest,
                  !CGEventSource.flagsState(.hidSystemState).contains(Prefs.current.hold.flag),
                  !CGEventSource.flagsState(.combinedSessionState).contains(Prefs.current.hold.flag) else {
                releasedReads = 0
                return
            }
            releasedReads += 1
            if releasedReads >= 4 {
                releasedReads = 0
                Log.write("commit from backstop")
                Switcher.shared.commit()
            }
        }
        CFRunLoopAddTimer(loop, timer, .commonModes)
        backstop = timer
        ready.signal()
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let start = now()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return .passUnretained(event)

        case .flagsChanged:
            if Switcher.shared.isHeld, !event.flags.contains(Prefs.current.hold.flag) {
                Log.write("commit from flags \(event.flags.rawValue) key \(event.getIntegerValueField(.keyboardEventKeycode))")
                Switcher.shared.commit(at: start)
            }
            return .passUnretained(event)

        case .keyDown:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let hold = Prefs.current.hold
            if key == kVK_Tab, flags.contains(hold.flag), flags.isDisjoint(with: hold.others) {
                swallowedUps.insert(key)
                triggered(reverse: flags.contains(.maskShift), at: start)
                return nil
            }
            guard Switcher.shared.isActive else { return .passUnretained(event) }
            swallowedUps.insert(key)
            switch Int(key) {
            case kVK_Escape: Switcher.shared.cancel()
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: Switcher.shared.commit(at: start)
            case kVK_LeftArrow: Switcher.shared.arrow(dx: -1, dy: 0)
            case kVK_RightArrow: Switcher.shared.arrow(dx: 1, dy: 0)
            case kVK_UpArrow: Switcher.shared.arrow(dx: 0, dy: -1)
            case kVK_DownArrow: Switcher.shared.arrow(dx: 0, dy: 1)
            case kVK_ANSI_W: Switcher.shared.closeSelected()
            case kVK_ANSI_Q: Switcher.shared.quitSelected()
            case kVK_ANSI_S: Switcher.shared.toggleView()
            case kVK_Tab: Switcher.shared.move(by: flags.contains(.maskShift) ? -1 : 1)
            default:
                if let number = Self.digits[Int(key)] { Switcher.shared.spaceKey(number) }
            }
            return nil

        case .keyUp:
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowedUps.remove(key) != nil ? nil : .passUnretained(event)

        default:
            return .passUnretained(event)
        }
    }

    private func triggered(reverse: Bool, at start: UInt64) {
        lastPress = start
        if let backstop { CFRunLoopTimerSetNextFireDate(backstop, CFAbsoluteTimeGetCurrent() + 0.016) }
        Log.write("press via \(Thread.isMainThread ? "hot key" : "tap")")
        Switcher.shared.press(reverse: reverse, at: start)
    }

    /// Event taps go deaf while a password field has secure input on. Hot keys still
    /// arrive then, so the shortcut keeps working there too.
    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let start = now()
            let tap = KeyTap.shared
            if start &- tap.lastPress > 8_000_000 { tap.triggered(reverse: id.id == 2, at: start) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// The system ⌘Tab only needs to step aside when Flick is using ⌘Tab itself.
    func applyHold() {
        guard isRunning else { return }
        let hold = Prefs.current.hold
        Priv.nativeSwitcher(enabled: hold != .command)
        hotKeys.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        hotKeys = []
        let modifier: Int
        switch hold {
        case .command: modifier = cmdKey
        case .option: modifier = optionKey
        case .control: modifier = controlKey
        }
        for (id, modifiers) in [(UInt32(1), modifier), (UInt32(2), modifier | shiftKey)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(kVK_Tab), UInt32(modifiers), EventHotKeyID(signature: 0x466c_636b, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }
}
