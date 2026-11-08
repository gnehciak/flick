import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var status: NSStatusItem!
    private var permissionTimer: Timer?
    private var settings: NSWindow?
    private var settingsTabs: NSTabViewController?
    private var lastSettingsPage = 0
    private var organiser: NSWindow?
    private var activity: NSObjectProtocol?
    private let agentLabel = "local.flick.app"

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if ProcessInfo.processInfo.environment["FLICK_REPLACE"] != nil {
            others.forEach { $0.terminate() }
            let start = now()
            while others.contains(where: { !$0.isTerminated }), ms(since: start) < 2000 { usleep(10_000) }
        } else if !others.isEmpty {
            exit(0)
        }

        NativeSwitcherGuard.install()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Answers ⌘Tab")

        Prefs.start()
        setupStatusItem()
        setupMainMenu()
        Overlay.shared.warmUp()
        Store.shared.start()

        if UserDefaults.standard.object(forKey: "openAtLogin") == nil {
            UserDefaults.standard.set(true, forKey: "openAtLogin")
            setOpenAtLogin(true)
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startListening()
        } else {
            // First run, or access was taken away: show what Flick needs.
            if ProcessInfo.processInfo.environment["FLICK_SELFTEST"] == nil {
                showSettings(activate: true, page: .general)
            }
            // Starts by itself the moment access is granted. No relaunch needed.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                Store.shared.accessGranted()
                self?.startListening()
            }
        }
    }

    private func startListening() {
        let baseline = ProcessInfo.processInfo.environment["FLICK_BASELINE"] != nil
        guard baseline || KeyTap.shared.begin() else { return }
        Store.shared.schedule(after: 0)
        GestureTap.shared.apply()
        TouchSwipe.shared.apply()
        watchTap()
        // Build the tiles now so the first ⌘Tab pays nothing either.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !Switcher.shared.isActive { Overlay.shared.prepare(Store.shared.snapshot, index: 0) }
        }
        if let path = ProcessInfo.processInfo.environment["FLICK_SELFTEST"] {
            SelfTest(path: path).run()
        }
        if let path = ProcessInfo.processInfo.environment["FLICK_SNAPSHOT"] {
            SelfTest.snapshot(to: path)
        }
        if let path = ProcessInfo.processInfo.environment["FLICK_ORGANISERSHOT"] {
            SelfTest.organiserShot(to: path)
        }
        if let path = ProcessInfo.processInfo.environment["FLICK_SETTINGSHOT"] {
            SelfTest.settingsShot(to: path)
        }
    }

    /// If access is taken away, hand ⌘Tab back to the system straight away.
    private func watchTap() {
        let watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            if !AXIsProcessTrusted() {
                Priv.nativeSwitcher(enabled: true)
                timer.invalidate()
                exit(0)
            }
        }
        watch.tolerance = 0.5
    }

    func applicationWillTerminate(_ note: Notification) {
        Priv.nativeSwitcher(enabled: true)
    }

    private func setupStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Flick")
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        status.isVisible = Prefs.current.menuBarIcon
    }

    /// Accessory apps have no menu bar of their own, but ⌘W and ⌘Q still need one.
    private func setupMainMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let quitItem = item("Quit Flick", #selector(quit))
        quitItem.keyEquivalent = "q"
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        root.addItem(appItem)
        NSApp.mainMenu = root
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            menu.addItem(item("Grant Accessibility…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item("Spaces…", #selector(openOrganiser)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Flick", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func prefsChanged() {
        status?.isVisible = Prefs.current.menuBarIcon
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc func openSettings() {
        showSettings(activate: true)
    }

    func showSettings(activate: Bool, page: SettingsPage? = nil) {
        if settings == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.canPropagateSelectedChildViewControllerTitle = false
            for page in SettingsPage.allCases {
                let host = NSHostingController(rootView: page.view)
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.label = page.title
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.title = "Flick Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            // Comes to the Space you're on, not back to the one it was last open on.
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            settings = window
            settingsTabs = tabs
            tabs.selectedTabViewItemIndex = lastSettingsPage
        }
        if let page { settingsTabs?.selectedTabViewItemIndex = page.rawValue }
        if let settings { present(settings, activate: activate) }
    }

    @objc func openOrganiser() { showOrganiser(activate: true) }

    func showOrganiser(activate: Bool) {
        if organiser == nil {
            let host = NSHostingController(rootView: SpacesEditor())
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "Spaces"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 720, height: 560))
            window.contentMinSize = NSSize(width: 480, height: 360)
            window.center()
            window.collectionBehavior = [.moveToActiveSpace]
            window.delegate = self
            organiser = window
        }
        if let organiser { present(organiser, activate: activate) }
    }

    private func present(_ window: NSWindow, activate: Bool) {
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        window.orderFrontRegardless()
        // macOS can refuse the activation above when another app is in front. Same call
        // as any other switch, which it doesn't refuse.
        if activate, let psn = Priv.psn(of: getpid()) {
            Priv.front(psn: psn, window: CGWindowID(truncatingIfNeeded: window.windowNumber))
        }
        Store.shared.schedule(after: 0.1)
    }

    /// Flick's own windows, reached from the switcher. A window that isn't on screen has
    /// a window number of -1, hence the truncating conversions.
    func showOwn(_ id: CGWindowID) {
        if let organiser, CGWindowID(truncatingIfNeeded: organiser.windowNumber) == id { openOrganiser() } else { openSettings() }
    }

    func closeOwn(_ id: CGWindowID) {
        NSApp.windows.first { CGWindowID(truncatingIfNeeded: $0.windowNumber) == id }?.close()
    }

    func closeSettings() { settings?.close() }

    func windowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === settings || window === organiser else { return }
        Store.shared.focused(CGWindowID(truncatingIfNeeded: window.windowNumber))
        Store.shared.schedule(after: 0.1)
    }

    func windowWillClose(_ note: Notification) {
        Store.shared.lookAgainSoon()
        // Its refresh timer has no reason to keep running.
        if (note.object as? NSWindow) === organiser {
            DispatchQueue.main.async { [self] in
                organiser?.contentViewController = nil
                organiser = nil
            }
        }
        // Nor do the previews' animations. It opens again on the same tab.
        if (note.object as? NSWindow) === settings {
            lastSettingsPage = settingsTabs?.selectedTabViewItemIndex ?? 0
            DispatchQueue.main.async { [self] in
                settings?.contentViewController = nil
                settings = nil
                settingsTabs = nil
            }
        }
    }

    func requestScreen() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    var isOpenAtLogin: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    /// A launch agent rather than a login item, so a crash brings ⌘Tab straight back.
    func setOpenAtLogin(_ on: Bool) {
        if on {
            guard let exe = Bundle.main.executablePath, exe.hasPrefix("/Applications/") else { return }
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: agentURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: agentURL)
        }
    }

    func quitFromSettings() { quit() }

    @objc private func quit() {
        Priv.nativeSwitcher(enabled: true)
        // Clean exit, so the launch agent doesn't bring it back.
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
