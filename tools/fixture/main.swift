import Cocoa

// A throwaway app for the self test: `fixture <name> <window count>`.
// SIGUSR1 stops its main thread for three seconds, like a hung app.
let name = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 1

final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ note: Notification) {
        for i in 1...count {
            let w = NSWindow(contentRect: NSRect(x: 180 + i * 40 + abs(name.hashValue % 200), y: 300 + i * 30, width: 420, height: 260),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "\(name) \(i)"
            w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        if name != "FixC" { NSApp.activate(ignoringOtherApps: true) }
    }
}

let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
signal(SIGUSR1, SIG_IGN)
source.setEventHandler { Thread.sleep(forTimeInterval: 3) }
source.resume()

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
