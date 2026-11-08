import SwiftUI

/// The tabs along the top of Settings.
enum SettingsPage: Int, CaseIterable {
    case general, appearance, windows, spaces, gestures, about

    var title: String {
        ["General", "Appearance", "Windows", "Spaces", "Gestures", "About"][rawValue]
    }

    var symbol: String {
        ["gearshape", "paintbrush", "macwindow.on.rectangle", "square.grid.2x2", "hand.draw", "info.circle"][rawValue]
    }

    static let width: CGFloat = 560

    var height: CGFloat {
        [470, 650, 550, 810, 640, 610][rawValue]
    }

    var view: AnyView {
        let page: AnyView
        switch self {
        case .general: page = AnyView(GeneralPage())
        case .appearance: page = AnyView(AppearancePage())
        case .windows: page = AnyView(WindowsPage())
        case .spaces: page = AnyView(SpacesPage())
        case .gestures: page = AnyView(GesturesPage())
        case .about: page = AnyView(AboutPage())
        }
        return AnyView(page.frame(width: Self.width, height: height))
    }
}

private var flick: AppDelegate? { NSApp.delegate as? AppDelegate }

/// Where Flick lives online. Empty hides the button.
enum Links {
    static let coffee = URL(string: "")
    static let source = URL(string: "https://github.com/gnehciak/flick")
}

/// A setting's name with a line under it saying what it does, as System Settings has.
struct Labelled: View {
    let title: String
    var detail: String?

    init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Something macOS needs to allow, with its state.
private struct Permission: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Labelled(title, detail)
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Button("Open System Settings…", action: open)
            }
        }
    }
}

/// A yellow note with a way to fix it.
private struct Warning: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action)
        }
    }
}

// MARK: General

private struct GeneralPage: View {
    @AppStorage("holdKey") private var hold = 0
    @AppStorage("delayMs") private var delay = 0
    @AppStorage("earlySwitch") private var earlySwitch = true
    @AppStorage("menuBarIcon") private var menuBarIcon = true

    @State private var openAtLogin = false
    @State private var trusted = AXIsProcessTrusted()
    @State private var canCapture = CGPreflightScreenCaptureAccess()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker(selection: $hold) {
                    Text("⌘ Tab").tag(0)
                    Text("⌥ Tab").tag(1)
                    Text("⌃ Tab").tag(2)
                } label: {
                    Labelled("Shortcut", hold == 0 ? "Takes over from the system app switcher." : "The system ⌘ Tab keeps working.")
                }
                Picker(selection: $delay) {
                    Text("None").tag(0)
                    Text("50 ms").tag(50)
                    Text("100 ms").tag(100)
                    Text("200 ms").tag(200)
                } label: {
                    Labelled("Delay", "A quick tap switches without showing the switcher.")
                }
                Toggle(isOn: $earlySwitch) {
                    Labelled("Early Switch", "Starts switching as you press, so quick taps land sooner.")
                }
            }

            Section {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { flick?.setOpenAtLogin($0) }
                Toggle(isOn: $menuBarIcon) {
                    Labelled("Menu Bar Icon", menuBarIcon ? nil : "Open Flick from Applications to come back here.")
                }
            }

            Section("Permissions") {
                Permission(symbol: "accessibility", title: "Accessibility",
                           detail: "Needed for the shortcut and switching.", granted: trusted) {
                    flick?.openAccessibility()
                }
                Permission(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                           detail: "Shows window previews instead of app icons.", granted: canCapture) {
                    flick?.requestScreen()
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear(perform: load)
        .onReceive(tick) { _ in
            trusted = AXIsProcessTrusted()
            canCapture = CGPreflightScreenCaptureAccess()
        }
    }

    private func load() {
        openAtLogin = flick?.isOpenAtLogin ?? false
        trusted = AXIsProcessTrusted()
        canCapture = CGPreflightScreenCaptureAccess()
    }
}

// MARK: Appearance

private struct AppearancePage: View {
    @AppStorage("clearGlass") private var clearGlass = true
    @AppStorage("useTint") private var useTint = false
    @AppStorage("tint") private var tint = "0.0,0.0,0.0,0.25"
    @AppStorage("useHighlight") private var useHighlight = false
    @AppStorage("highlight") private var highlight = "0.0,0.48,1.0,1.0"
    @AppStorage("tileSize") private var size = 1.0
    @AppStorage("corners") private var corners = 24.0
    @AppStorage("thumbnails") private var thumbnails = true
    @AppStorage("titles") private var titles = true
    @AppStorage("appIcons") private var icons = true
    @AppStorage("mainDisplay") private var mainDisplay = false

    @State private var canCapture = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section {
                SwitcherPreview(style: .init(size: size, corners: corners, clear: clearGlass,
                                             tint: useTint ? Prefs.color(tint) : nil,
                                             highlight: useHighlight ? Prefs.color(highlight) : nil,
                                             thumbnails: thumbnails && canCapture, titles: titles, icons: icons))
                    .listRowInsets(EdgeInsets())
            }

            Section {
                if #available(macOS 26.0, *) {
                    Picker("Glass", selection: $clearGlass) {
                        Text("Clear").tag(true)
                        Text("Regular").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                colorRow("Tint", on: $useTint, color: $tint)
                colorRow("Highlight", on: $useHighlight, color: $highlight)
                Slider(value: $size, in: 0.6...1.5) { Text("Size") }
                Slider(value: $corners, in: 8...40) { Text("Corners") }
            }

            Section {
                if canCapture {
                    Toggle("Window Previews", isOn: $thumbnails)
                } else {
                    LabeledContent {
                        Button("Allow…") { flick?.requestScreen() }
                    } label: {
                        Labelled("Window Previews", "Needs Screen Recording. Until then, tiles show app icons.")
                    }
                }
                Toggle("Titles", isOn: $titles)
                Toggle("App Icons", isOn: $icons)
                Picker(selection: $mainDisplay) {
                    Text("With the Pointer").tag(false)
                    Text("Main Display").tag(true)
                } label: {
                    Labelled("Show On")
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear { canCapture = CGPreflightScreenCaptureAccess() }
    }

    private func colorRow(_ title: String, on: Binding<Bool>, color: Binding<String>) -> some View {
        HStack {
            Toggle(title, isOn: on)
            if on.wrappedValue {
                ColorPicker(title, selection: Binding(
                    get: { Color(nsColor: Prefs.color(color.wrappedValue) ?? .black) },
                    set: { color.wrappedValue = Prefs.text(NSColor($0)) }
                ), supportsOpacity: true)
                .labelsHidden()
            }
        }
    }
}

// MARK: Windows

private struct WindowsPage: View {
    @AppStorage("currentSpaceOnly") private var currentSpaceOnly = true
    @AppStorage("showMinimized") private var showMinimized = true
    @AppStorage("showHidden") private var showHidden = true
    @State private var ignored: [String] = []

    var body: some View {
        Form {
            Section {
                SpacesChoice(currentOnly: $currentSpaceOnly)
            } header: {
                Text("⌘ Tab Shows")
            } footer: {
                Text("Press S in the switcher to flip to the other one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Include") {
                Toggle("Minimized Windows", isOn: $showMinimized)
                Toggle("Hidden Apps", isOn: $showHidden)
            }

            Section {
                if ignored.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(ignored, id: \.self) { id in
                    HStack {
                        Image(nsImage: Self.icon(id)).resizable().frame(width: 20, height: 20)
                        Text(Self.name(id))
                        Spacer()
                        Button { remove(id) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Show this app again")
                    }
                }
            } header: {
                HStack {
                    Text("Ignored Apps")
                    Spacer()
                    Button("Add App…", action: add)
                        .controlSize(.small)
                }
            } footer: {
                Text("Their windows never appear in the switcher.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in load() }
    }

    private func load() {
        let saved = UserDefaults.standard.stringArray(forKey: "ignoredApps") ?? []
        if saved != ignored { ignored = saved }
    }

    private func save() { UserDefaults.standard.set(ignored, forKey: "ignoredApps") }

    private func remove(_ id: String) {
        ignored.removeAll { $0 == id }
        save()
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !ignored.contains(id) { ignored.append(id) }
        }
        save()
    }

    private static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    private static func name(_ id: String) -> String {
        url(id).map { $0.deletingPathExtension().lastPathComponent } ?? id
    }

    private static func icon(_ id: String) -> NSImage {
        url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }
}

// MARK: Spaces

private struct SpacesPage: View {
    @AppStorage("reducedMotion") private var reducedMotion = false
    @AppStorage("instantSpaces") private var instantSpaces = true
    @State private var noSpaceSwipe = false
    @State private var otherSwitcher: NSRunningApplication?
    private static let instantSpaceSwitcher = "com.interversehq.InstantSpaceSwitcher"

    var body: some View {
        Form {
            Section {
                SpacesMap()
                    .listRowInsets(EdgeInsets())
            }
            Section {
                LabeledContent {
                    Button("Organise…") { flick?.openOrganiser() }
                } label: {
                    Labelled("Arrange the Grid", "Name, reorder or hide Spaces, and set the columns.")
                }
                Toggle(isOn: $reducedMotion) {
                    Labelled("Reduced Motion", "The grid fades in and out instead of zooming.")
                }
            }
            Section {
                Toggle(isOn: $instantSpaces) {
                    Labelled("Instant Spaces", "Swiping between Spaces jumps straight there, with no slide.")
                }
                if instantSpaces {
                    InstantPreview()
                    if let other = otherSwitcher {
                        Warning(text: "InstantSpaceSwitcher is running too. Flick does the same now.", button: "Quit It") {
                            other.terminate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { check() }
                        }
                    }
                    if noSpaceSwipe {
                        Warning(text: "Turn on swiping between full-screen apps.", button: "Trackpad Settings…", action: openTrackpadSettings)
                    }
                }
            }
            Section("In the Grid") {
                Tip(symbol: "hand.point.up.left", text: "Drag a window onto another Space to move it there.")
                Tip(symbol: "cursorarrow.click", text: "Click an empty part of a Space to go to it.")
                Tip(symbol: "number", text: "Press 1 to 9 for that Space's windows.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func check() {
        noSpaceSwipe = trackpadSetting("TrackpadThreeFingerHorizSwipeGesture") != 2 && trackpadSetting("TrackpadFourFingerHorizSwipeGesture") != 2
        otherSwitcher = NSRunningApplication.runningApplications(withBundleIdentifier: Self.instantSpaceSwitcher).first
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(text)
        }
    }
}

// MARK: Gestures

private struct GesturesPage: View {
    @AppStorage("touchSwitch") private var touchSwitch = true
    @AppStorage("touchSensitivity") private var touchSensitivity = 1.0
    @AppStorage("swipeUp") private var swipeUp = false

    @State private var sidewaysTaken = false
    @State private var upNotThree = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $touchSwitch) {
                    Labelled("Three Finger Switch", "Swipe sideways to switch windows. Lift to choose, or add a fourth finger to cancel.")
                }
                if touchSwitch {
                    SidewaysPreview(sensitivity: touchSensitivity)
                    Slider(value: $touchSensitivity, in: 0.5...3) {
                        Labelled("Sensitivity", "Higher needs less finger travel.")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "hare").foregroundStyle(.secondary)
                    }
                    if sidewaysTaken {
                        Warning(text: "macOS uses three fingers sideways too.", button: "Trackpad Settings…", action: Self.openTrackpad)
                    }
                }
            }

            Section {
                Toggle(isOn: $swipeUp) {
                    Labelled("Swipe Up for Spaces", "Three fingers up opens the Spaces grid instead of Mission Control. Swipe down to close it.")
                }
                .onChange(of: swipeUp) { _ in UserDefaults.standard.removeObject(forKey: "swipeSign") }
                if swipeUp {
                    UpPreview()
                    if upNotThree {
                        Warning(text: "Set Mission Control to three fingers.", button: "Trackpad Settings…", action: Self.openTrackpad)
                    }
                }
            }

        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func check() {
        sidewaysTaken = Self.trackpad("TrackpadThreeFingerHorizSwipeGesture") != 0 || Self.trackpad("TrackpadThreeFingerDrag") != 0
        upNotThree = Self.trackpad("TrackpadThreeFingerVertSwipeGesture") != 2
    }

    /// The built-in trackpad's setting, or a Magic Trackpad's.
    private static func trackpad(_ key: String) -> Int { trackpadSetting(key) }
    private static func openTrackpad() { openTrackpadSettings() }
}

/// The built-in trackpad's setting, or a Magic Trackpad's.
private func trackpadSetting(_ key: String) -> Int {
    for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
        if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int { return value }
    }
    return 0
}

private func openTrackpadSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
}

// MARK: About

private struct AboutPage: View {
    @AppStorage("holdKey") private var hold = 0
    @State private var confirmReset = false

    private var key: String { ["⌘", "⌥", "⌃"][min(max(hold, 0), 2)] }
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Flick").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let coffee = Links.coffee {
                        Button {
                            NSWorkspace.shared.open(coffee)
                        } label: {
                            Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                        }
                        .help("Flick is free. If it saves you time, a coffee keeps it going.")
                    }
                }
                .padding(.vertical, 4)
                if let source = Links.source {
                    LabeledContent {
                        Button("View on GitHub") { NSWorkspace.shared.open(source) }
                    } label: {
                        Labelled("Free and Open Source", "MIT licence.")
                    }
                }
            }

            Section("In the Switcher") {
                keys("Next, previous", "\(key) Tab   ⇧\(key) Tab")
                keys("Switch", "Release \(key), Return")
                keys("Move", "Arrow keys")
                keys("Current Space or all", "S")
                keys("A Space's windows", "1 to 9")
                keys("Close window", "W")
                keys("Quit app", "Q")
                keys("Cancel", "Esc")
            }

            Section {
                HStack {
                    Button("Reset All Settings…") { confirmReset = true }
                    Spacer()
                    Button("Quit Flick") { flick?.quitFromSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Prefs.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Space names, the grid's order and ignored apps are cleared too.")
        }
    }

    private func keys(_ action: String, _ keys: String) -> some View {
        LabeledContent(action) {
            Text(keys).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
