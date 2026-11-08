import Cocoa
import os

/// Settings, cached so the key thread reads memory and not UserDefaults.
enum Prefs {
    enum Hold: Int {
        case command, option, control

        var flag: CGEventFlags {
            switch self {
            case .command: return .maskCommand
            case .option: return .maskAlternate
            case .control: return .maskControl
            }
        }

        var others: CGEventFlags {
            switch self {
            case .command: return [.maskAlternate, .maskControl]
            case .option: return [.maskCommand, .maskControl]
            case .control: return [.maskCommand, .maskAlternate]
            }
        }
    }

    /// How the Spaces view is arranged. Keyed by Space so it survives restarts.
    struct SpaceLayout: Codable, Equatable {
        var columns = 0                 // 0 picks a square-ish grid
        var order: [String] = []
        var names: [String: String] = [:]
        var hidden: Set<String> = []
    }

    struct Values {
        var hold = Hold.command
        var delay = 0.0
        var currentSpaceOnly = true
        var showMinimized = true
        var showHidden = true
        var ignored = Set<String>()
        var thumbnails = true
        var titles = true
        var icons = true
        var size = 1.0
        var corners = 24.0
        var clearGlass = true
        var tint: NSColor?
        var highlight: NSColor?
        var mainDisplay = false
        var menuBarIcon = true
        var earlySwitch = true
        var layout = SpaceLayout()
        var swipeUp = false
        var instantSpaces = true
        var reducedMotion = false
        var touchSwitch = true
        var touchSensitivity = 1.0
        var swipeSign = 0
    }

    static let defaults: [String: Any] = [
        "holdKey": 0, "delayMs": 0, "currentSpaceOnly": true, "showMinimized": true, "showHidden": true,
        "thumbnails": true, "titles": true, "appIcons": true, "tileSize": 1.0, "corners": 24.0,
        "clearGlass": true, "useTint": false, "tint": "0.0,0.0,0.0,0.25",
        "useHighlight": false, "highlight": "0.0,0.48,1.0,1.0", "mainDisplay": false, "menuBarIcon": true, "earlySwitch": true, "swipeUp": false, "instantSpaces": true, "reducedMotion": false, "touchSwitch": true, "touchSensitivity": 1.0,
    ]

    /// Most self tests promise not to move focus, and early switching would.
    private static let testEarly: Bool? = {
        let env = ProcessInfo.processInfo.environment
        guard env["FLICK_SELFTEST"] != nil else { return nil }
        return env["FLICK_EARLY"] != nil || env["FLICK_EARLYTEST"] != nil
    }()

    private static let cache = OSAllocatedUnfairLock(initialState: Values())
    static var current: Values { cache.withLock { $0 } }

    static func start() {
        UserDefaults.standard.register(defaults: defaults)
        reload()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            reload()
        }
    }

    private static func reload() {
        let d = UserDefaults.standard
        var v = Values()
        v.hold = Hold(rawValue: d.integer(forKey: "holdKey")) ?? .command
        v.delay = Double(d.integer(forKey: "delayMs")) / 1000
        v.currentSpaceOnly = ProcessInfo.processInfo.environment["FLICK_ALLSPACES"] != nil ? false : d.bool(forKey: "currentSpaceOnly")
        v.showMinimized = d.bool(forKey: "showMinimized")
        v.showHidden = d.bool(forKey: "showHidden")
        v.ignored = Set(d.stringArray(forKey: "ignoredApps") ?? [])
        v.thumbnails = d.bool(forKey: "thumbnails")
        v.titles = d.bool(forKey: "titles")
        v.icons = d.bool(forKey: "appIcons")
        v.size = d.double(forKey: "tileSize")
        v.corners = d.double(forKey: "corners")
        v.clearGlass = d.bool(forKey: "clearGlass")
        v.tint = d.bool(forKey: "useTint") ? color(d.string(forKey: "tint")) : nil
        v.highlight = d.bool(forKey: "useHighlight") ? color(d.string(forKey: "highlight")) : nil
        v.mainDisplay = d.bool(forKey: "mainDisplay")
        v.menuBarIcon = d.bool(forKey: "menuBarIcon")
        v.earlySwitch = testEarly ?? d.bool(forKey: "earlySwitch")
        v.swipeUp = ProcessInfo.processInfo.environment["FLICK_SWIPETEST"] != nil || d.bool(forKey: "swipeUp")
        v.swipeSign = d.integer(forKey: "swipeSign")
        v.instantSpaces = d.bool(forKey: "instantSpaces")
        v.touchSwitch = d.bool(forKey: "touchSwitch")
        v.touchSensitivity = min(max(d.double(forKey: "touchSensitivity"), 0.5), 3)
        v.reducedMotion = ProcessInfo.processInfo.environment["FLICK_REDUCEDTEST"] != nil || d.bool(forKey: "reducedMotion")
        if let data = d.data(forKey: "spaceLayout"), let saved = try? JSONDecoder().decode(SpaceLayout.self, from: data) { v.layout = saved }

        let before = current, values = v
        cache.withLock { $0 = values }
        if before.hold != v.hold { KeyTap.shared.applyHold() }
        Overlay.shared.applyStyle()
        GestureTap.shared.apply()
        TouchSwipe.shared.apply()
        (NSApp.delegate as? AppDelegate)?.prefsChanged()
    }

    static func save(_ layout: SpaceLayout) {
        UserDefaults.standard.set(try? JSONEncoder().encode(layout), forKey: "spaceLayout")
    }

    static func color(_ text: String?) -> NSColor? {
        let p = (text ?? "").split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return NSColor(srgbRed: p[0], green: p[1], blue: p[2], alpha: p[3])
    }

    static func text(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return "\(c.redComponent),\(c.greenComponent),\(c.blueComponent),\(c.alphaComponent)"
    }

    static func reset() {
        let d = UserDefaults.standard
        for key in defaults.keys { d.removeObject(forKey: key) }
        d.removeObject(forKey: "ignoredApps")
        d.removeObject(forKey: "spaceLayout")
        d.removeObject(forKey: "swipeSign")
    }
}
