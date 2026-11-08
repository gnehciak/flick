import Cocoa
import os

/// Moves between Spaces with no slide. Posts the same Dock swipe a trackpad would,
/// with a near-zero distance and a huge velocity, so there's nothing to animate.
/// The technique and the macOS 27 event layout come from InstantSpaceSwitcher
/// by jurplel (MIT).
enum Spaces {
    struct Display {
        let id: String
        let current: UInt64
        let spaces: [UInt64]
    }

    struct Info {
        let id: UInt64
        let key: String
        let display: String
        let title: String
        let fullScreen: Bool
        let current: Bool
    }

    /// The Spaces the grid shows, in your order. Full-screen apps come and go, so they
    /// never get a cell of their own: the grid has to stay put.
    static func arranged(_ all: [Info], _ layout: Prefs.SpaceLayout) -> [Info] {
        let desktops = all.filter { !$0.fullScreen && !layout.hidden.contains($0.key) }
        let rank = Dictionary(layout.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return desktops.enumerated().sorted {
            (rank[$0.element.key] ?? layout.order.count + $0.offset) < (rank[$1.element.key] ?? layout.order.count + $1.offset)
        }.map(\.element)
    }

    static func name(_ space: Info, _ layout: Prefs.SpaceLayout) -> String {
        let name = layout.names[space.key]?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? space.title : name
    }

    /// Every Space, in Mission Control's order.
    static func list() -> [Info] {
        let all = Priv.displaySpaces()
        var result: [Info] = []
        for (n, d) in all.enumerated() {
            let current = (d["Current Space"] as? [String: Any])?["id64"] as? UInt64 ?? 0
            let display = d["Display Identifier"] as? String ?? "\(n)"
            var desktop = 0
            for space in d["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["id64"] as? UInt64 else { continue }
                let fullScreen = space["type"] as? Int == 4
                if !fullScreen { desktop += 1 }
                let name = fullScreen ? "Full Screen" : "Desktop \(desktop)"
                let uuid = space["uuid"] as? String ?? ""
                result.append(Info(id: id, key: uuid.isEmpty ? "\(display)#\(desktop)" : uuid, display: display,
                                   title: all.count > 1 ? "Display \(n + 1), \(name)" : name,
                                   fullScreen: fullScreen, current: id == current))
            }
        }
        return result
    }

    static func displays() -> [Display] {
        Priv.displaySpaces().compactMap { d in
            guard let id = d["Display Identifier"] as? String,
                  let list = d["Spaces"] as? [[String: Any]] else { return nil }
            let current = (d["Current Space"] as? [String: Any])?["id64"] as? UInt64 ?? 0
            return Display(id: id, current: current, spaces: list.compactMap { $0["id64"] as? UInt64 })
        }
    }

    static func visible() -> Set<UInt64> { Set(displays().map(\.current)) }

    /// While Flick posts its own swipes, so Instant Spaces lets them through.
    private static let postingUntil = OSAllocatedUnfairLock(initialState: UInt64(0))
    static var isPosting: Bool { postingUntil.withLock { now() < $0 } }

    private static let isSupported: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    private static var naturalScrolling: Bool {
        var valid: DarwinBoolean = false
        let value = CFPreferencesGetAppBooleanValue("com.apple.swipescrolldirection" as CFString,
                                                    kCFPreferencesAnyApplication, &valid)
        return !valid.boolValue || value
    }

    /// Lands on `space` before returning. If that can't be done instantly it returns
    /// and the normal focus call brings the Space over with the system animation.
    /// The direct route, instead of swipes: 8 to 19 ms at any distance, against 44 to 170.
    /// Swipes are still there for full-screen Spaces, and if this ever doesn't land.
    static var direct = true

    @discardableResult
    static func jump(to space: UInt64, timeout: Double = 250) -> Bool {
        let all = displays()
        guard let display = all.first(where: { $0.spaces.contains(space) }) else { return false }
        if display.current == space { return true }
        let info = list()
        let plain = !info.contains { ($0.id == space || $0.id == display.current) && $0.fullScreen }
        if direct, plain {
            let began = now()
            var sent = false
            DispatchQueue.main.sync { sent = Priv.activate(space, display: display.id, among: display.spaces) }
            if sent {
                while ms(since: began) < 150 {
                    if displays().first(where: { $0.id == display.id })?.current == space {
                        Log.write("direct jump in \(String(format: "%.1f", ms(since: began)))ms")
                        return true
                    }
                    usleep(500)
                }
            }
            Log.write("direct jump didn't land, using swipes")
        }
        guard isSupported,
              let from = display.spaces.firstIndex(of: display.current),
              let to = display.spaces.firstIndex(of: space) else { return false }
        if all.count > 1, Priv.displayUnderCursor() != display.id { return false }

        let right = to > from
        var sign: Double = right ? -1 : 1
        if !naturalScrolling { sign = -sign }
        let start = now()
        let steps = abs(to - from)
        postingUntil.withLock { $0 = now() + UInt64(steps * 40 + 150) * 1_000_000 }
        defer { postingUntil.withLock { $0 = now() + 150_000_000 } }
        for _ in 0..<steps {
            for phase: Int64 in [1, 2, 4] {
                guard post(phase: phase, sign: sign) else { return false }
                // The Dock drops phases sent back to back on macOS 27. A dropped one meant
                // waiting out the timeout and then the system's slide.
                usleep(10_000)
            }
        }

        while ms(since: start) < timeout {
            if displays().first(where: { $0.id == display.id })?.current == space {
                Log.write("swipe jump in \(String(format: "%.1f", ms(since: start)))ms")
                return true
            }
            usleep(500)
        }
        Log.write("swipe jump timed out")
        return false
    }

    /// For the self test: a vertical swipe, as the trackpad sends it. `release: false`
    /// keeps the fingers down, and a later call without a begin carries on from there.
    private static var midSwipe = false

    static func postVertical(sign: Double, amounts: [Double] = [0.02, 0.08, 0.2, 0.45], gap: UInt32 = 8000, release: Bool = true) {
        if !midSwipe { _ = post(phase: 1, sign: sign, motion: 2, amount: 0, tap: .cghidEventTap) }
        midSwipe = !release
        for amount in amounts {
            usleep(gap)
            _ = post(phase: 2, sign: sign, motion: 2, amount: amount, tap: .cghidEventTap)
        }
        guard release else { return }
        usleep(gap)
        _ = post(phase: 4, sign: sign, motion: 2, amount: amounts.last ?? 0, tap: .cghidEventTap)
    }

    /// For the self test: a sideways swipe between Spaces. No amounts is a quick flick
    /// that only has a speed when the fingers lift.
    static func postHorizontal(sign: Double, amounts: [Double] = [0.02, 0.08]) {
        _ = post(phase: 1, sign: sign, motion: 1, amount: 0, tap: .cghidEventTap)
        for amount in amounts {
            usleep(8000)
            _ = post(phase: 2, sign: sign, motion: 1, amount: amount, tap: .cghidEventTap)
        }
        usleep(8000)
        _ = post(phase: 4, sign: sign, motion: 1, amount: amounts.last ?? 0, tap: .cghidEventTap)
    }

    private static func post(phase: Int64, sign: Double, motion: Int64 = 1, amount: Double = 0.000016, tap: CGEventTapLocation? = nil) -> Bool {
        guard let setI = Priv.setI, let setD = Priv.setD, let raw = CGEvent(source: nil) else { return false }
        let velocity = phase == 4 ? sign * 9999 : 0
        let progress = sign * amount

        setI(raw, 55, 30)    // event type: dock control
        setI(raw, 110, 23)   // HID type: dock swipe
        setI(raw, 132, phase)
        setI(raw, 123, motion)   // 1 horizontal, 2 vertical
        setD(raw, 124, progress)
        setI(raw, 134, phase)
        setD(raw, 138, 3)
        setD(raw, 169, Double(mach_absolute_time()))
        setD(raw, 125, 0.1)
        if phase == 4 { setD(raw, 129, velocity) }

        guard let event = augmented(raw, phase: phase, progress: progress, velocity: velocity, motion: motion),
              let companion = CGEvent(source: nil) else { return false }
        setI(companion, 55, 29)
        if stampPid { setI(event, 41, Int64(getpid())); setI(companion, 41, Int64(getpid())) }
        event.post(tap: tap ?? postTap)
        companion.post(tap: tap ?? postTap)
        return true
    }

    /// Stamped with our pid so a tool that intercepts real trackpad swipes, like
    /// InstantSpaceSwitcher's swipe override, lets these through.
    static var postTap: CGEventTapLocation = .cgSessionEventTap
    static var stampPid = true

    private static func fixed(_ value: Double) -> Int32 {
        let f = Int32(value * 65536)
        return f == 0 && value != 0 ? (value > 0 ? 1 : -1) : f
    }

    /// macOS 27 only honours a synthetic swipe that carries the raw IOHID payload.
    private static func augmented(_ event: CGEvent, phase: Int64, progress: Double, velocity: Double, motion: Int64) -> CGEvent? {
        guard let data = event.data as Data?, data.count >= 4,
              data[data.startIndex + 3] == 2, data[data.startIndex] == 0 else { return nil }

        var p = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { p.append(contentsOf: $0) } }
        let withVelocity = phase == 4

        put(UInt64(event.timestamp == 0 ? mach_absolute_time() : event.timestamp))
        put(UInt64(0))                       // sender
        put(UInt32(0))                       // options
        put(UInt32(0))                       // attribute length
        put(UInt32(withVelocity ? 2 : 1))    // event count

        put(UInt32(40)); put(UInt32(23)); put(UInt32((UInt32(phase) & 0xff) << 24))
        put(UInt32(0))                       // depth + reserved
        put(fixed(0.1)); put(Int32(0)); put(Int32(0))
        put(UInt32(0))                       // swipe mask
        put(UInt16(motion))
        put(UInt16(3))                       // flavor: dock primary
        put(fixed(progress))

        if withVelocity {
            put(UInt32(28)); put(UInt32(9)); put(UInt32(0))
            put(UInt32(1))                   // depth 1 + reserved
            put(fixed(velocity)); put(Int32(0)); put(Int32(0))
        }

        var out = data
        out.append(UInt8((p.count >> 8) & 0xff))
        out.append(UInt8(p.count & 0xff))
        out.append(UInt8((4205 >> 8) & 0xff))
        out.append(UInt8(4205 & 0xff))
        out.append(p)
        return CGEvent(withDataAllocator: nil, data: out as CFData)
    }
}
