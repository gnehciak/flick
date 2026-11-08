import Cocoa

// A window on every Space whose title changes ten times a second, for FLICK_STICKYTEST.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
window.collectionBehavior = [.canJoinAllSpaces]
window.title = "Sticky 0"
window.orderFrontRegardless()
var n = 0
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    n += 1
    window.title = "Sticky \(n)"
    if n >= 300 { exit(0) }
}
app.run()
