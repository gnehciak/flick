import Cocoa

/// Takes trackpad swipes before the Dock sees them: three fingers up for the Spaces
/// grid, and the sideways swipe between Spaces for Instant Spaces. No tap exists until
/// one of those is on, because this one sees every trackpad gesture.
/// The approach comes from InstantSpaceSwitcher's swipe override by jurplel (MIT).
final class GestureTap: Thread {
    static let shared = GestureTap()

    private var tap: CFMachPort?
    private var began = false              // main thread only
    private var first: CGEvent?            // held until the direction shows

    private enum Mode { case idle, undecided, opening, closing, swallow }
    // Tap thread only.
    private var mode = Mode.idle
    private var sideways = false           // a sideways swipe we've taken
    private var sidewaysFired = false
    private var up = 1
    private var level = 0.0                // how open the grid is, 0 to 1
    private var recent: [(level: Double, time: UInt64)] = []
    private let ready = DispatchSemaphore(value: 0)
    private let acceptPosted = ProcessInfo.processInfo.environment["FLICK_SELFTEST"] != nil

    private static let fullSwipe = 0.6     // how far a swipe goes to open the grid fully
    private static let flick = 1.6         // in openings per second
    private static let gentle = 0.5        // the same, for a small relaxed swipe
    private static let gesture: Int64 = 29, dockControl: Int64 = 30
    private static let kind: UInt32 = 55, source: UInt32 = 41, hidType: UInt32 = 110, motion: UInt32 = 123
    private static let progress: UInt32 = 124, velocityX: UInt32 = 129, velocityY: UInt32 = 130, phase: UInt32 = 132

    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func apply() {
        let on = (Prefs.current.swipeUp || Prefs.current.instantSpaces) && KeyTap.shared.isRunning
        if on, !began {
            began = true
            name = "flick.gestures"
            qualityOfService = .userInteractive
            start()
            ready.wait()
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    override func main() {
        let mask = CGEventMask(1 << 29 | 1 << 30)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask,
                                callback: { proxy, type, event, _ in GestureTap.shared.handle(proxy, type.rawValue, event) },
                                userInfo: nil)
        guard let tap else { ready.signal(); return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()
        CFRunLoopRun()
    }

    private func handle(_ proxy: CGEventTapProxy, _ type: UInt32, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == CGEventType.tapDisabledByTimeout.rawValue || type == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap, Prefs.current.swipeUp || Prefs.current.instantSpaces { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard let get = Priv.getI, let getD = Priv.getD else { return pass }
        let kind = get(event, Self.kind)
        guard kind == Self.gesture || kind == Self.dockControl else { return pass }
        // A real trackpad has no process. Anything else is software, like a Space jump.
        guard acceptPosted || get(event, Self.source) == 0 else { return pass }
        if kind == Self.gesture { return mode == .idle && !sideways ? pass : nil }
        guard get(event, Self.hidType) == 23 else { return pass }
        let motion = get(event, Self.motion)
        if motion == 1 || sideways { return across(event, phase: get(event, Self.phase), getD) }
        guard motion == 2, Prefs.current.swipeUp || mode != .idle else { return pass }

        switch get(event, Self.phase) {
        case 1:
            mode = .undecided
            first = event.copy()
            return nil

        case 2:
            guard mode != .idle else { return pass }
            let value = getD(event, Self.progress)
            Log.write("swipe \(String(format: "%.4f", value))")
            if mode == .undecided, abs(value) > 0.01 {
                decide(value > 0 ? 1 : -1)
                if mode == .idle {
                    // Swipe down isn't ours: hand the whole gesture back for App Exposé.
                    if !acceptPosted { first?.tapPostEvent(proxy) }
                    first = nil
                    return acceptPosted ? nil : pass
                }
            }
            follow(value)
            return nil

        case 4:
            guard mode != .idle else { return pass }
            Log.write("swipe end \(String(format: "%.4f %.4f", getD(event, Self.velocityX), getD(event, Self.velocityY)))")
            release()
            // The Dock needs this to close its gesture, with nothing left to act on.
            if let set = Priv.setD {
                for field in [Self.progress, Self.velocityX, Self.velocityY] { set(event, field, 0) }
            }
            return pass

        case 8:
            if mode == .opening { finish(open: false) } else if mode == .closing { finish(open: true) }
            mode = .idle
            first = nil
            return nil

        default:
            return mode == .idle ? pass : nil
        }
    }

    /// Instant Spaces: the sideways swipe between Spaces, taken whole. The first sign of
    /// a direction jumps straight to the Space beside this one, as InstantSpaceSwitcher
    /// does, so there's no slide to wait for.
    private func across(_ event: CGEvent, phase: Int64, _ getD: @convention(c) (CGEvent, UInt32) -> Double) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // Flick's own swipes, from a jump to a full-screen Space.
        if Spaces.isPosting { return pass }
        switch phase {
        case 1:
            guard Prefs.current.instantSpaces, !Switcher.shared.isActive else { return pass }
            sideways = true
            sidewaysFired = false
            return nil
        case 2:
            guard sideways else { return pass }
            if !sidewaysFired {
                let value = getD(event, Self.progress)
                if value != 0 { step(value) }
            }
            return nil
        case 4:
            guard sideways else { return pass }
            if !sidewaysFired {
                let value = getD(event, Self.velocityX)
                if value != 0 { step(value) }
            }
            sideways = false
            sidewaysFired = false
            // The Dock needs the end to close its gesture, with nothing left to act on.
            if let set = Priv.setD {
                for field in [Self.progress, Self.velocityX, Self.velocityY] { set(event, field, 0) }
            }
            return pass
        case 8:
            guard sideways else { return pass }
            sideways = false
            sidewaysFired = false
            return nil
        default:
            return sideways ? nil : pass
        }
    }

    private func step(_ value: Double) {
        sidewaysFired = true
        Log.write("instant spaces: swipe \(value > 0 ? "right" : "left")")
        Focuser.step(value > 0 ? 1 : -1)
    }

    /// Which sign means up isn't documented, so the first swipe after turning this on
    /// settles it.
    private func decide(_ sign: Int) {
        let learned = Prefs.current.swipeSign
        up = learned == 0 ? sign : learned
        level = 0
        recent = []
        if Switcher.shared.isSticky {
            if sign == up {
                Switcher.shared.cancel()
                mode = .swallow
            } else {
                mode = .closing
                level = 1
                DispatchQueue.main.async { Overlay.shared.beginScrub(at: 1) }
            }
        } else if Switcher.shared.isActive {
            Switcher.shared.cancel()
            mode = .swallow
        } else if sign == up {
            if learned == 0 { UserDefaults.standard.set(sign, forKey: "swipeSign") }
            mode = Switcher.shared.openGrid(following: true) ? .opening : .swallow
        } else {
            mode = .idle
        }
    }

    private func follow(_ value: Double) {
        guard mode == .opening || mode == .closing else { return }
        // Moving towards open counts up in both directions, so the two share everything below.
        let along = value * Double(up) / Self.fullSwipe
        let level = min(1, max(0, mode == .opening ? along : 1 + along))
        self.level = level
        recent.append((level, now()))
        recent.removeAll { ms(since: $0.time) > 100 }
        DispatchQueue.main.async {
            // Esc may have ended it partway. Nothing left to follow then.
            if Switcher.shared.isSticky { Overlay.shared.scrub(to: level) }
        }
    }

    private func release() {
        defer {
            mode = .idle
            first = nil
        }
        guard mode == .opening || mode == .closing else { return }
        let speed = currentSpeed()
        if mode == .opening {
            // Easy to open: real swipes are often small. Pulling back still cancels.
            let open = speed > -Self.gentle && (level > 0.2 || (level > 0.05 && speed > Self.gentle))
            finish(open: open, velocity: speed)
        } else {
            // A quick flick counts whatever the distance, as it does for Mission Control.
            finish(open: abs(speed) > Self.flick ? speed > 0 : level > 0.5, velocity: speed)
        }
    }

    /// Over the last moments of the swipe, as events can arrive in bursts. Fingers that
    /// stopped before lifting have no speed at all.
    private func currentSpeed() -> Double {
        guard let newest = recent.last, let oldest = recent.first, ms(since: newest.time) < 60 else { return 0 }
        let seconds = Double(newest.time &- oldest.time) / 1e9
        return seconds > 0.02 ? (newest.level - oldest.level) / seconds : 0
    }

    private func finish(open: Bool, velocity: Double = 0) {
        DispatchQueue.main.async {
            if Switcher.shared.isSticky { Overlay.shared.endScrub(open: open, velocity: velocity) }
        }
    }
}
