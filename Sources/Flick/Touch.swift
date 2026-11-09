import Cocoa
import os

/// Three fingers sideways switches windows, as on Windows. A quick swipe goes to the
/// previous window; keep the fingers down and the switcher opens, and moving them moves
/// the selection; lift to switch, or add a fourth finger to cancel.
///
/// The system's three finger sideways gesture is off on this Mac, so there's no event for
/// it. This reads the trackpad's raw touches from the private MultitouchSupport framework.
final class TouchSwipe {
    static let shared = TouchSwipe()

    typealias Frame = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Frame) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void

    private let library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private var devices: [UnsafeMutableRawPointer] = []   // main thread only
    private var running = false                           // main thread only

    // Gesture state: touch thread only.
    private var tracking = false, engaged = false, ignored = false
    private var startX = 0.0, startY = 0.0, lastStep = 0.0

    /// Three fingers moving mostly sideways, or a switch they started. The up and down
    /// gesture leaves those alone, as a slanted swipe also moves a little up or down.
    private let sidewaysState = OSAllocatedUnfairLock(initialState: false)
    var isSideways: Bool { sidewaysState.withLock { $0 } }
    private func setSideways(_ on: Bool) { sidewaysState.withLock { $0 = on } }

    /// How slanted a swipe can be and still count as sideways: up to about 50°.
    private static let slant = 0.8
    /// How long a changed finger count must last to end the gesture, in ms.
    private static let liftAfter = 80.0, cancelAfter = 40.0
    private var offSince: UInt64 = 0                      // touch thread only

    /// Fraction of the trackpad's width, at normal sensitivity. Higher sensitivity needs less.
    static let engageAt = 0.06, stepAt = 0.09
    private var engage: Double { Self.engageAt / Prefs.current.touchSensitivity }
    private var step: Double { Self.stepAt / Prefs.current.touchSensitivity }
    /// One finger contact in the framework's frame data, laid out as every tool using it
    /// has found it: the normalized position is two floats, 32 bytes in.
    private static let stride = 96, positionOffset = 32

    func apply() {
        // Real fingers would mix with a test's made-up ones.
        let testing = ProcessInfo.processInfo.environment["FLICK_SELFTEST"] != nil
        let on = Prefs.current.touchSwitch && KeyTap.shared.isRunning && !testing
        on ? start() : stop()
    }

    private func start() {
        guard !running, let library,
              let create = dlsym(library, "MTDeviceCreateList").map({ unsafeBitCast($0, to: CreateList.self) }),
              let register = dlsym(library, "MTRegisterContactFrameCallback").map({ unsafeBitCast($0, to: Register.self) }),
              let begin = dlsym(library, "MTDeviceStart").map({ unsafeBitCast($0, to: Start.self) }),
              let list = create()?.takeRetainedValue() as? [AnyObject] else { return }
        for device in list {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            register(pointer, touchFrame)
            _ = begin(pointer, 0)
            devices.append(pointer)
        }
        running = !devices.isEmpty
        Log.write("touch: \(devices.count) trackpads")
    }

    private func stop() {
        guard running, let library,
              let halt = dlsym(library, "MTDeviceStop").map({ unsafeBitCast($0, to: Stop.self) }) else { return }
        devices.forEach { halt($0) }
        devices = []
        running = false
    }

    /// Called for every frame of touches, about 90 a second while anything touches the pad.
    func frame(_ data: UnsafeMutableRawPointer?, count: Int) {
        guard count == 3, let data else {
            // All fingers off: switch now. A finger that drops out for a moment, or a
            // fourth that brushes the pad, is common on a slow swipe: only a count that
            // stays changed ends it, or it would switch and reopen over and over.
            if count == 0 || !tracking {
                offSince = 0
                finish(cancel: false)
                return
            }
            if offSince == 0 { offSince = now() }
            if ms(since: offSince) >= (count > 3 ? Self.cancelAfter : Self.liftAfter) {
                offSince = 0
                finish(cancel: count > 3)
            }
            return
        }
        offSince = 0
        var x = 0.0, y = 0.0
        for i in 0..<3 {
            let px = Double(data.load(fromByteOffset: i * Self.stride + Self.positionOffset, as: Float.self))
            let py = Double(data.load(fromByteOffset: i * Self.stride + Self.positionOffset + 4, as: Float.self))
            // A layout that ever changed would show up as nonsense here. Never act on that.
            guard px.isFinite, py.isFinite, (-0.1...1.1).contains(px), (-0.1...1.1).contains(py) else { return }
            x += px / 3
            y += py / 3
        }
        feed(x: x, y: y)
    }

    /// The gesture itself, apart from where the touches come from, so tests can drive it.
    func feed(x: Double, y: Double) {
        if !tracking {
            tracking = true
            startX = x
            startY = y
            return
        }
        guard !ignored else { return }
        let dx = x - startX, dy = y - startY
        if !engaged {
            let mostlySideways = abs(dx) >= abs(dy) * Self.slant
            setSideways(mostlySideways && abs(dx) > 0.015)
            if abs(dx) > engage, mostlySideways {
                engaged = Switcher.shared.pressTouch(reverse: dx < 0)
                lastStep = x
                setSideways(engaged)
                Log.write("touch: switcher opened \(dx < 0 ? "backwards" : "forwards")")
            } else if abs(dy) > max(engage, 0.04), abs(dy) > abs(dx) * 1.25 {
                ignored = true          // clearly up or down: Swipe Up or the system's, not this
                setSideways(false)
            }
            return
        }
        let step = self.step
        while x - lastStep > step { Switcher.shared.move(by: 1, clamp: true); lastStep += step }
        while lastStep - x > step { Switcher.shared.move(by: -1, clamp: true); lastStep -= step }
    }

    /// Fingers lifted: switch. A fourth finger: cancel.
    func finish(cancel: Bool) {
        defer {
            tracking = false
            engaged = false
            ignored = false
            setSideways(false)
        }
        guard engaged, Switcher.shared.isTouching else { return }
        if cancel { Switcher.shared.cancel() } else { Switcher.shared.commit() }
    }
}

private func touchFrame(_ device: Int32, _ data: UnsafeMutableRawPointer?, _ count: Int32, _ time: Double, _ frame: Int32) -> Int32 {
    TouchSwipe.shared.frame(data, count: Int(count))
    return 0
}
