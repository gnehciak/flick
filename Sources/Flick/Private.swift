import Cocoa

/// Private WindowServer and Accessibility calls, resolved at launch so a missing
/// symbol on a future macOS degrades instead of stopping the app from starting.
enum Priv {
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let anyImage = UnsafeMutableRawPointer(bitPattern: -2)

    private static func load<T>(_ names: String...) -> T? {
        for name in names {
            if let p = dlsym(sky, name) ?? dlsym(anyImage, name) {
                return unsafeBitCast(p, to: T.self)
            }
        }
        return nil
    }

    private static let mainConnection: (@convention(c) () -> Int32)? = load("SLSMainConnectionID", "CGSMainConnectionID")
    static let cid: Int32 = mainConnection?() ?? 0

    private static let copyDisplaySpaces: (@convention(c) (Int32, CFString?) -> Unmanaged<CFArray>?)? =
        load("SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces")
    private static let copySpacesForWindows: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?)? =
        load("SLSCopySpacesForWindows", "CGSCopySpacesForWindows")
    private static let setSymbolicHotKey: (@convention(c) (Int32, Bool) -> Int32)? =
        load("CGSSetSymbolicHotKeyEnabled", "SLSSetSymbolicHotKeyEnabled")
    private static let setFront: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32)? =
        load("_SLPSSetFrontProcessWithOptions")
    private static let postRecord: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32)? =
        load("SLPSPostEventRecordTo")
    private static let hwCapture: (@convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32) -> Unmanaged<CFArray>?)? =
        load("SLSHWCaptureWindowList", "CGSHWCaptureWindowList")
    private static let orderedIn: (@convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> Int32)? =
        load("SLSWindowIsOrderedIn", "CGSWindowIsOrderedIn")
    private static let bestDisplay: (@convention(c) (Int32, CGPoint) -> Unmanaged<CFString>?)? =
        load("SLSCopyBestManagedDisplayForPoint", "CGSCopyBestManagedDisplayForPoint")
    private static let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError)? =
        load("_AXUIElementGetWindow")
    private static let axFromToken: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?)? =
        load("_AXUIElementCreateWithRemoteToken")
    private static let psnForPid: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32)? =
        load("GetProcessForPID")

    static let setI: (@convention(c) (CGEvent, UInt32, Int64) -> Void)? = load("CGEventSetIntegerValueField")
    static let getI: (@convention(c) (CGEvent, UInt32) -> Int64)? = load("CGEventGetIntegerValueField")
    static let getD: (@convention(c) (CGEvent, UInt32) -> Double)? = load("CGEventGetDoubleValueField")
    static let setD: (@convention(c) (CGEvent, UInt32, Double) -> Void)? = load("CGEventSetDoubleValueField")

    static func displaySpaces() -> [[String: Any]] {
        (copyDisplaySpaces?(cid, nil)?.takeRetainedValue() as? [[String: Any]]) ?? []
    }

    static func spaces(of window: CGWindowID) -> [UInt64] {
        let list = [NSNumber(value: window)] as CFArray
        return (copySpacesForWindows?(cid, 7, list)?.takeRetainedValue() as? [UInt64]) ?? []
    }

    static func nativeSwitcher(enabled: Bool) {
        // 1 = ⌘Tab, 2 = ⇧⌘Tab
        _ = setSymbolicHotKey?(1, enabled)
        _ = setSymbolicHotKey?(2, enabled)
    }

    static func isOrderedIn(_ window: CGWindowID) -> Bool {
        guard let orderedIn else { return true }
        var value: UInt8 = 0
        return orderedIn(cid, window, &value) == 0 ? value != 0 : true
    }

    static func displayUnderCursor() -> String? {
        let point = CGEvent(source: nil)?.location ?? .zero
        return bestDisplay?(cid, point)?.takeRetainedValue() as String?
    }

    static func psn(of pid: pid_t) -> ProcessSerialNumber? {
        var psn = ProcessSerialNumber()
        return psnForPid?(pid, &psn) == 0 ? psn : nil
    }

    /// Brings a window's process forward and gives the window key focus. Both go
    /// straight to the WindowServer, so they don't wait on the target app.
    static func front(psn value: ProcessSerialNumber, window: CGWindowID) {
        var psn = value
        let t0 = now()
        _ = setFront?(&psn, window, 0x200)
        let t1 = ms(since: t0)
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x3a] = 0x10
        withUnsafeBytes(of: window) { record.replaceSubrange(0x3c..<0x40, with: $0) }
        for i in 0x20..<0x30 { record[i] = 0xff }
        record[0x08] = 0x01
        _ = postRecord?(&psn, &record)
        record[0x08] = 0x02
        _ = postRecord?(&psn, &record)
        Log.write("setFront \(String(format: "%.2f", t1))ms, total \(String(format: "%.2f", ms(since: t0)))ms")
    }

    /// Moves a window to another Space without switching there. The usual SLS calls fail
    /// with SIP on, but macOS 27 has this bridged operation, found by InstantSpaceSwitcher
    /// (MIT). It runs on the main run loop, so it does nothing without one.
    static func move(_ window: CGWindowID, to space: UInt64) -> Bool {
        typealias Init = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
        typealias Run = @convention(c) (AnyObject, Selector) -> Void
        let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        let runSelector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let initMethod = class_getInstanceMethod(type, initSelector),
              let runMethod = class_getInstanceMethod(type, runSelector),
              signature(initMethod) == "@@:@Q", signature(runMethod) == "v@:",
              let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return false }
        let build = unsafeBitCast(method_getImplementation(initMethod), to: Init.self)
        guard let operation = build(allocated, initSelector, [NSNumber(value: window)], space)?.takeRetainedValue() else { return false }
        unsafeBitCast(method_getImplementation(runMethod), to: Run.self)(operation, runSelector)
        return true
    }

    /// Makes a Space current on its display with no animation. The same family of bridged
    /// operations as `move`, in the order InstantSpaceSwitcher verified: show the target,
    /// hide the others, set it current. Main thread only, as they run on its run loop.
    static func activate(_ space: UInt64, display: String, among all: [UInt64]) -> Bool {
        typealias Build = @convention(c) (AnyObject, Selector, NSArray) -> Unmanaged<AnyObject>?
        typealias BuildCurrent = @convention(c) (AnyObject, Selector, NSString, UInt64) -> Unmanaged<AnyObject>?
        typealias Run = @convention(c) (AnyObject, Selector) -> Void
        let spacesSelector = NSSelectorFromString("initWithSpaces:")
        let currentSelector = NSSelectorFromString("initWithDisplayIdentifier:spaceID:")
        let runSelector = NSSelectorFromString("performWithWMBridgeDelegate")
        func allocate(_ type: AnyClass) -> AnyObject? { (type as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() }
        func spacesOperation(_ name: String, _ ids: [UInt64]) -> AnyObject? {
            guard let type = NSClassFromString(name), let method = class_getInstanceMethod(type, spacesSelector),
                  signature(method) == "@@:@", let allocated = allocate(type) else { return nil }
            let list = ids.map { NSNumber(value: $0) } as NSArray
            return unsafeBitCast(method_getImplementation(method), to: Build.self)(allocated, spacesSelector, list)?.takeRetainedValue()
        }
        guard let show = spacesOperation("SLSBridgedShowSpacesOperation", [space]),
              let hide = spacesOperation("SLSBridgedHideSpacesOperation", all.filter { $0 != space }),
              let type = NSClassFromString("SLSBridgedManagedDisplaySetCurrentSpaceOperation"),
              let method = class_getInstanceMethod(type, currentSelector), signature(method) == "@@:@Q",
              let allocated = allocate(type),
              let current = unsafeBitCast(method_getImplementation(method), to: BuildCurrent.self)(allocated, currentSelector, display as NSString, space)?.takeRetainedValue()
        else { return false }
        for operation in [show, hide, current] {
            guard let run = class_getMethodImplementation(object_getClass(operation), runSelector) else { return false }
            unsafeBitCast(run, to: Run.self)(operation, runSelector)
        }
        return true
    }

    /// A method's type encoding without its offsets, so a changed signature is never called.
    private static func signature(_ method: Method) -> String {
        guard let encoding = method_getTypeEncoding(method) else { return "" }
        return String(cString: encoding).filter { !$0.isNumber }
    }

    /// `full` is every Retina pixel, for the zoom. Otherwise it's a quarter as many, which
    /// is plenty for a thumbnail and much less to shrink.
    static func capture(_ window: CGWindowID, full: Bool = true) -> CGImage? {
        var id = window
        // ignore global clip shape | best or nominal resolution
        let images = hwCapture?(cid, &id, 1, (1 << 11) | (full ? 1 << 8 : 1 << 9))?.takeRetainedValue() as? [CGImage]
        return images?.first
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: UInt32 = 0
        return axGetWindow?(element, &id) == .success && id != 0 ? id : nil
    }

    /// AX only lists windows on the current Space. Windows elsewhere can be reached
    /// by asking for the element directly with a remote token.
    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        var bytes = Data(count: 20)
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: 0x636f_636f, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
        }
        return axFromToken?(bytes as CFData)?.takeRetainedValue()
    }
}

/// Restores the system switcher however the app goes down, so ⌘Tab is never left dead.
enum NativeSwitcherGuard {
    /// The system ⌘Tab back, and the pointer free if a three-finger switch was holding it.
    private static func restore() {
        Priv.nativeSwitcher(enabled: true)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    static func install() {
        atexit { NativeSwitcherGuard.restoreFromC() }
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { number in
                NativeSwitcherGuard.restoreFromC()
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }

    fileprivate static func restoreFromC() { restore() }
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(since start: UInt64) -> Double { Double(now() &- start) / 1_000_000 }
