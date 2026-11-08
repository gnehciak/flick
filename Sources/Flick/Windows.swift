import Cocoa
import os

struct Item {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    let appName: String
    let icon: CGImage?
    let ax: AXUIElement?
    let psn: ProcessSerialNumber?
    let space: UInt64
    let home: UInt64      // the desktop it belongs to in the grid, 0 if it has none
    var minimized: Bool
    let hidden: Bool
    let size: CGSize
    let frame: CGRect
    let bundleID: String?
}

struct AppInfo {
    let process: NSRunningApplication
    let name: String
    let bundleID: String?
    var icon: CGImage?
    let psn: ProcessSerialNumber?
}

/// The window list, kept current in the background so pressing ⌘Tab reads memory
/// and never asks the WindowServer or an app for anything.
final class Store {
    static let shared = Store()

    let q = DispatchQueue(label: "flick.model", qos: .userInitiated)

    private struct State {
        var items: [Item] = []
        var mru: [CGWindowID] = []
        var frontPid: pid_t = 0
        var lastCommit: UInt64 = 0
        var visible = Set<UInt64>()
        var activated: pid_t = 0
        var spaces: [Spaces.Info] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    // Store.q only
    private var trackers: [pid_t: Tracker] = [:]
    private var apps: [pid_t: AppInfo] = [:]
    private var reconcileQueued = false
    private var ignoredPids = Set<pid_t>()
    private var homes: [CGWindowID: UInt64] = [:]

    var snapshot: [Item] { state.withLock { $0.items } }
    var frontPid: pid_t { state.withLock { $0.frontPid } }
    var visibleSpaces: Set<UInt64> { state.withLock { $0.visible } }
    var lastActivated: pid_t { state.withLock { $0.activated } }
    var spaceList: [Spaces.Info] { state.withLock { $0.spaces } }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let refresh: (Notification) -> Void = { [weak self] note in
            Log.write("workspace \(note.name.rawValue)")
            self?.schedule()
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncApps()
            // An app opening in the background sends nothing when its first window appears.
            for delay in [0.4, 1.2, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.syncApps() }
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncApps()
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(app.processIdentifier)
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main, using: refresh)
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }
        state.withLock { $0.frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        syncApps()
    }

    /// NSWorkspace only updates on the main run loop, so app facts are read here.
    private func syncApps() {
        var fresh: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy != .prohibited {
            fresh[app.processIdentifier] = app
        }
        q.async { [self] in
            ignoredPids = ignoredPids.filter { kill($0, 0) == 0 }
            for pid in apps.keys where fresh[pid] == nil {
                apps[pid] = nil
                trackers[pid]?.stop()
                trackers[pid] = nil
            }
            for (pid, app) in fresh where apps[pid] == nil {
                ignoredPids.remove(pid)
                apps[pid] = AppInfo(process: app,
                                    name: app.localizedName ?? "",
                                    bundleID: app.bundleIdentifier,
                                    psn: Priv.psn(of: pid))
            }
            schedule()
        }
    }

    /// AX only lists the current Space, so this is when windows it couldn't see turn up.
    func spaceChanged() {
        q.async { [self] in
            let spaces = Spaces.list()
            state.withLock {
                $0.spaces = spaces
                $0.visible = Set(spaces.filter(\.current).map(\.id))
            }
            for tracker in trackers.values where tracker.hasUnresolved { tracker.scan() }
            schedule()
        }
    }

    /// Trackers made before access was granted have no observer and never get one.
    func accessGranted() {
        q.async { [self] in
            trackers.values.forEach { $0.stop() }
            trackers = [:]
            schedule(after: 0)
        }
    }

    private func appActivated(_ pid: pid_t) {
        Log.write("activated \(pid)")
        state.withLock {
            $0.frontPid = pid
            $0.activated = pid
        }
        q.async { [self] in
            trackers[pid]?.reportFocusedWindow()
            schedule(after: 0.15)
        }
    }

    func schedule(after delay: Double = 0.03) {
        q.async { [self] in
            guard !reconcileQueued else { return }
            reconcileQueued = true
            q.asyncAfter(deadline: .now() + delay) { [self] in
                reconcileQueued = false
                reconcile()
            }
        }
    }

    /// A closing window stays on screen for up to about 0.6 seconds, and nothing else
    /// says when it has gone.
    func lookAgainSoon() {
        for delay in [0.12, 0.45, 0.9] {
            q.asyncAfter(deadline: .now() + delay) { [self] in schedule(after: 0) }
        }
    }

    private func reconcile() {
        let start = now()
        // Most entries are menu bar and system windows, so they aren't worth converting
        // to Swift dictionaries.
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as NSArray?
        else { return }

        struct Candidate {
            let id: CGWindowID
            let pid: pid_t
            let name: String
            let frame: CGRect
            var size: CGSize { frame.size }
            let onScreen: Bool
        }
        var candidates: [Candidate] = []
        var unknownOwner = false
        for case let w as NSDictionary in raw {
            guard (w[kCGWindowLayer] as? Int) == 0,
                  let id = w[kCGWindowNumber] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID] as? pid_t else { continue }
            if apps[pid] == nil {
                // An app can change from background to regular after it launches.
                if pid != getpid(), !ignoredPids.contains(pid) {
                    ignoredPids.insert(pid)
                    unknownOwner = true
                }
                continue
            }
            guard let bounds = w[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width >= 60, rect.height >= 60,
                  (w[kCGWindowAlpha] as? Double ?? 1) > 0 else { continue }
            candidates.append(Candidate(id: id, pid: pid,
                                        name: w[kCGWindowName] as? String ?? "",
                                        frame: rect,
                                        onScreen: w[kCGWindowIsOnscreen] as? Bool ?? false))
        }

        if unknownOwner { DispatchQueue.main.async { [weak self] in self?.syncApps() } }

        let byPid = Dictionary(grouping: candidates, by: \.pid)
        for (pid, windows) in byPid {
            let tracker = trackers[pid] ?? {
                let t = Tracker(pid: pid)
                trackers[pid] = t
                t.start()
                return t
            }()
            tracker.prune(keeping: Set(windows.map(\.id)))
            let unseen = windows.map(\.id).filter { !tracker.seen.contains($0) }
            if !unseen.isEmpty {
                Log.write("unseen \(apps[pid]?.name ?? "?") \(unseen.count)")
                tracker.scan(looking: Set(unseen))
            }
        }
        for (pid, tracker) in trackers where byPid[pid] == nil { tracker.prune(keeping: []) }

        var items: [Item] = []
        var frontWindow: CGWindowID?
        let spaceList = Spaces.list()
        let visible = Set(spaceList.filter(\.current).map(\.id))
        let desktops = Set(spaceList.filter { !$0.fullScreen }.map(\.id))
        let front = frontPid
        let hiddenPids = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier))

        for c in candidates {
            guard let tracker = trackers[c.pid], var app = apps[c.pid] else { continue }
            let hidden = hiddenPids.contains(c.pid)
            let info = tracker.windows[c.id]
            if let info {
                guard info.isStandard else { continue }
                // Background tabs and parked windows are ordered out but aren't minimized.
                if !info.minimized, !hidden, !Priv.isOrderedIn(c.id) { continue }
            } else if c.onScreen {
                // Apps with no usable accessibility: take real-looking visible windows only.
                guard tracker.axUnavailable, c.size.width >= 200, c.size.height >= 150 else { continue }
            } else {
                // A titled window on another Space that AX couldn't reach yet.
                guard !c.name.isEmpty, c.size.width >= 200, c.size.height >= 150, Priv.isOrderedIn(c.id) else { continue }
            }
            // A window on every Space lists them all. 0 means there's nowhere to go.
            let spaces = Priv.spaces(of: c.id)
            let space = spaces.count == 1 ? spaces[0] : 0
            // On a Space you can see, not minimized, yet not on screen: it's been closed.
            if !c.onScreen, !hidden, !(info?.minimized ?? false), visible.contains(space) || space == 0 { continue }
            let title = !c.name.isEmpty ? c.name : (info?.title ?? "")
            if app.icon == nil {
                app.icon = Icons.image(for: app.process)
                apps[c.pid] = app
            }
            // Minimized, hidden and full-screen windows report no desktop, so they stay
            // in the one they were last on.
            if desktops.contains(space) { homes[c.id] = space }
            items.append(Item(id: c.id, pid: c.pid,
                              title: title.isEmpty ? app.name : title,
                              appName: app.name, icon: app.icon, ax: info?.element, psn: app.psn,
                              space: space, home: homes[c.id] ?? 0, minimized: info?.minimized ?? false,
                              hidden: hidden, size: c.size, frame: c.frame, bundleID: app.bundleID))
            if frontWindow == nil, c.onScreen, c.pid == front, !(info?.minimized ?? false) { frontWindow = c.id }
        }

        let alive = Set(items.map(\.id))
        homes = homes.filter { alive.contains($0.key) }
        let found = items, front0 = frontWindow
        state.withLock { s in
            s.visible = visible
            s.spaces = spaceList
            let known = Set(found.map(\.id))
            s.mru.removeAll { !known.contains($0) }
            let inMRU = Set(s.mru)
            s.mru.append(contentsOf: found.map(\.id).filter { !inMRU.contains($0) })
            // The z-order is the backstop for apps that don't report focus changes.
            if let front0, now() &- s.lastCommit > 400_000_000, let i = s.mru.firstIndex(of: front0), i != 0 {
                s.mru.remove(at: i)
                s.mru.insert(front0, at: 0)
            }
            var rank: [CGWindowID: Int] = [:]
            for (i, id) in s.mru.enumerated() { rank[id] = i }
            s.items = found.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        }
        Log.write("reconcile \(items.count) windows in \(String(format: "%.1f", ms(since: start)))ms")
        Thumbs.shared.forget(keeping: Set(found.map(\.id)))
        Thumbs.shared.refresh(Thumbs.shared.missing(found))
        Switcher.shared.modelChanged()
    }

    /// For the self test: what a refresh costs and what's held in memory.
    func bench() -> String {
        q.sync {
            var times: [Double] = []
            for _ in 0..<60 {
                let start = now()
                reconcile()
                times.append(ms(since: start))
            }
            times.sort()
            let icons = apps.values.compactMap(\.icon).reduce(0) { $0 + $1.bytesPerRow * $1.height }
            return String(format: "reconcile median %.2fms, max %.2fms; %d apps, icons %.1f MB", times[30], times[59], apps.count, Double(icons) / 1e6)
        }
    }

    /// Called the moment a switch is committed, so a second ⌘Tab a few milliseconds
    /// later already sees the new order.
    func committed(_ id: CGWindowID, pid: pid_t) {
        // Later, not now: asking the WindowServer for pixels would compete with the switch.
        if let left = promoteLocked(id, commit: true, pid: pid) { Thumbs.shared.refresh(left, after: 0.35) }
    }

    func focused(_ id: CGWindowID) {
        if let left = promoteLocked(id, commit: false, pid: nil) { Thumbs.shared.refresh(left, after: 0.35) }
    }

    private func promoteLocked(_ id: CGWindowID, commit: Bool, pid: pid_t?) -> CGWindowID? {
        state.withLock { s in
            if commit {
                s.lastCommit = now()
                if let pid { s.frontPid = pid }
            } else if now() &- s.lastCommit < 150_000_000, s.mru.first != id {
                return nil
            }
            let previous = s.mru.first
            guard previous != id else { return nil }
            s.mru.removeAll { $0 == id }
            s.mru.insert(id, at: 0)
            if let i = s.items.firstIndex(where: { $0.id == id }) {
                let item = s.items.remove(at: i)
                s.items.insert(item, at: 0)
            }
            return previous
        }
    }

    func demote(_ id: CGWindowID) {
        state.withLock { s in
            guard s.mru.contains(id) else { return }
            s.mru.removeAll { $0 == id }
            s.mru.append(id)
            if let i = s.items.firstIndex(where: { $0.id == id }) {
                var item = s.items.remove(at: i)
                item.minimized = true
                s.items.append(item)
            }
        }
    }

    func setTitle(_ title: String, of id: CGWindowID) {
        state.withLock { s in
            if let i = s.items.firstIndex(where: { $0.id == id }), !title.isEmpty { s.items[i].title = title }
        }
        Switcher.shared.modelChanged()
    }

    func tracker(for pid: pid_t, _ body: @escaping (Tracker) -> Void) {
        q.async { [self] in if let t = trackers[pid] { body(t) } }
    }
}

enum Icons {
    /// Drawn once at the largest size a tile uses, only for apps that have a window.
    /// The system's image can be 1024 pixels wide and would stay that big in memory.
    static func image(for app: NSRunningApplication) -> CGImage? {
        guard let icon = app.icon else { return nil }
        let side = 320
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}

/// Runs AX observers for every app on one background run loop.
final class AXThread: Thread {
    static let shared: AXThread = {
        let t = AXThread()
        t.name = "flick.ax"
        t.qualityOfService = .userInitiated
        t.start()
        t.ready.wait()
        return t
    }()
    private let ready = DispatchSemaphore(value: 0)
    private(set) var loop: CFRunLoop!

    override func main() {
        loop = CFRunLoopGetCurrent()
        var context = CFRunLoopSourceContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil, equal: nil, hash: nil,
            schedule: nil, cancel: nil, perform: { _ in })
        let keep = CFRunLoopSourceCreate(nil, 0, &context)
        CFRunLoopAddSource(loop, keep, .defaultMode)
        ready.signal()
        CFRunLoopRun()
    }
}

/// One app's windows as Accessibility sees them. Each app gets its own queue, so
/// a hung app only ever holds up its own entry.
final class Tracker {
    struct Info {
        let element: AXUIElement
        var title: String
        let subrole: String
        var minimized: Bool
        var isStandard: Bool { subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole }
    }

    let pid: pid_t
    private let app: AXUIElement
    private let q: DispatchQueue
    private var observer: AXObserver?          // q only
    private var watched = Set<CGWindowID>()    // q only
    private var scanQueued = false             // q only
    private var wanted = Set<CGWindowID>()     // q only
    private var titlesPending = Set<AXUIElement>() // q only

    // Store.q only
    var windows: [CGWindowID: Info] = [:]
    var seen = Set<CGWindowID>()
    var axUnavailable = false

    init(pid: pid_t) {
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        q = DispatchQueue(label: "flick.app.\(pid)", qos: .utility)
        AXUIElementSetMessagingTimeout(app, 0.25)
        axUnavailable = isSelf
    }

    /// Flick's own Settings window. Asking ourselves through AX would wait on the main thread.
    private var isSelf: Bool { pid == getpid() }

    func start() {
        q.async { [self] in
            guard !isSelf, AXIsProcessTrusted() else { return }
            var made: AXObserver?
            let callback: AXObserverCallback = { _, element, name, refcon in
                guard let refcon else { return }
                Unmanaged<Tracker>.fromOpaque(refcon).takeUnretainedValue().notified(element, name as String)
            }
            guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
            observer = made
            CFRunLoopAddSource(AXThread.shared.loop, AXObserverGetRunLoopSource(made), .defaultMode)
            subscribe(tries: 10)
        }
    }

    /// An app that's still starting up answers "cannot complete". Nothing would ask
    /// again, so its focus changes would go unseen until it restarted.
    private func subscribe(tries: Int) {
        guard let observer else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        var refused = false
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            if AXObserverAddNotification(observer, app, name as CFString, me) == .cannotComplete { refused = true }
        }
        Log.write("subscribe \(pid) \(refused ? "refused, \(tries) tries left" : "ok")")
        guard refused, tries > 0 else { return }
        q.asyncAfter(deadline: .now() + 0.5) { [self] in subscribe(tries: tries - 1) }
    }

    /// The observer holds a raw pointer to this object, so its source has to come off
    /// on the thread that calls back, or a late callback could outlive the tracker.
    func stop() {
        q.async { [self] in
            guard let observer else { return }
            self.observer = nil
            let loop = AXThread.shared.loop
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in
                CFRunLoopRemoveSource(loop, AXObserverGetRunLoopSource(observer), .defaultMode)
                _ = pid
            }
            CFRunLoopWakeUp(loop)
        }
    }

    var hasUnresolved: Bool { !seen.subtracting(windows.keys).isEmpty }

    func prune(keeping ids: Set<CGWindowID>) {
        seen.formIntersection(ids)
        windows = windows.filter { ids.contains($0.key) }
    }

    func scan(looking ids: Set<CGWindowID> = []) {
        seen.formUnion(ids)
        guard !isSelf else { return }
        q.async { [self] in
            wanted.formUnion(ids)
            guard !scanQueued else { return }
            scanQueued = true
            q.asyncAfter(deadline: .now() + 0.01) { [self] in
                scanQueued = false
                let looking = wanted
                wanted = []
                runScan(looking)
            }
        }
    }

    private func runScan(_ looking: Set<CGWindowID>) {
        var found: [CGWindowID: Info] = [:]
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        for element in value as? [AXUIElement] ?? [] {
            if let id = Priv.windowID(of: element), let info = describe(element) {
                found[id] = info
                watch(element, id)
            }
        }
        let unavailable = status == .cannotComplete || status == .apiDisabled || status == .notImplemented

        var missing = looking.subtracting(found.keys)
        if !missing.isEmpty, !unavailable {
            let deadline = now() + 300_000_000
            for elementID in UInt64(0)..<2048 {
                if now() > deadline || missing.isEmpty { break }
                guard let element = Priv.element(pid: pid, elementID: elementID) else { continue }
                AXUIElementSetMessagingTimeout(element, 0.05)
                guard let id = Priv.windowID(of: element), found[id] == nil, let info = describe(element) else { continue }
                found[id] = info
                missing.remove(id)
                watch(element, id)
            }
        }
        Store.shared.q.async { [self] in
            axUnavailable = unavailable
            windows.merge(found) { _, new in new }
            Store.shared.schedule(after: 0)
        }
    }

    private func describe(_ element: AXUIElement) -> Info? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        let names = [kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [Any], list.count == 3,
              let subrole = list[0] as? String else { return nil }
        return Info(element: element, title: list[1] as? String ?? "", subrole: subrole, minimized: list[2] as? Bool ?? false)
    }

    private func watch(_ element: AXUIElement, _ id: CGWindowID) {
        guard let observer, !watched.contains(id) else { return }
        watched.insert(id)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, me)
        }
    }

    private func notified(_ element: AXUIElement, _ name: String) {
        q.async { [self] in
            switch name {
            case kAXFocusedWindowChangedNotification:
                if Store.shared.frontPid == pid, let id = Priv.windowID(of: element) { Store.shared.focused(id) }
            case kAXWindowCreatedNotification:
                Log.write("created in \(pid)")
                scan()
            case kAXUIElementDestroyedNotification:
                Log.write("destroyed in \(pid)")
                Store.shared.schedule()
                Store.shared.lookAgainSoon()
            case kAXTitleChangedNotification:
                // Terminal spinners change a title ten times a second. One read is enough.
                guard titlesPending.insert(element).inserted else { return }
                q.asyncAfter(deadline: .now() + 1.5) { [self] in
                    titlesPending.remove(element)
                    var value: CFTypeRef?
                    guard let id = Priv.windowID(of: element),
                          AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
                          let title = value as? String else { return }
                    Log.write("title read \(id)")
                    Store.shared.setTitle(title, of: id)
                    Store.shared.q.async { [self] in windows[id]?.title = title }
                }
            case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
                let minimized = name == kAXWindowMiniaturizedNotification
                if let id = Priv.windowID(of: element) {
                    if minimized { Store.shared.demote(id) }
                    Store.shared.q.async { [self] in
                        windows[id]?.minimized = minimized
                        Store.shared.schedule()
                    }
                }
            default:
                break
            }
        }
    }

    /// Apps covered by the grid can be throttled, and slow to answer when picked. Asking
    /// for anything at all wakes them. Nothing visible happens.
    func wake() {
        guard !isSelf else { return }
        q.async { [self] in
            let began = now()
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            Log.write("woke \(pid) in \(String(format: "%.1f", ms(since: began)))ms")
        }
    }

    func reportFocusedWindow() {
        guard !isSelf else { return }
        q.async { [self] in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            if let id = Priv.windowID(of: value as! AXUIElement) { Store.shared.focused(id) }
        }
    }

    func close(_ element: AXUIElement) {
        q.async {
            AXUIElementSetMessagingTimeout(element, 0.5)
            var button: CFTypeRef?
            let got = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button)
            guard got == .success, let button, CFGetTypeID(button) == AXUIElementGetTypeID() else {
                Log.write("close: no button, error \(got.rawValue)")
                return
            }
            let pressed = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            Log.write("close: press \(pressed.rawValue)")
        }
    }
}
