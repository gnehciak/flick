import SwiftUI

/// Arranges the Spaces view: the same grid, with names you can type over and cells
/// you can drag. Everything saves as you go and shows on the next ⌘Tab.
struct SpacesEditor: View {
    @State private var layout = Prefs.current.layout
    @State private var spaces: [Spaces.Info] = []
    @State private var windows: [UInt64: [Item]] = [:]

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var shown: [Spaces.Info] { Spaces.arranged(spaces, layout) }
    private var hidden: [Spaces.Info] { spaces.filter { !$0.fullScreen && layout.hidden.contains($0.key) } }

    private var columnCount: Int {
        let count = max(shown.count, 1)
        return layout.columns > 0 ? min(layout.columns, count) : Int(Double(count).squareRoot().rounded(.up))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Columns", selection: $layout.columns) {
                    Text("Auto").tag(0)
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
            }

            let rows = max((shown.count + columnCount - 1) / columnCount, 1)
            GeometryReader { box in
                let height = (box.size.height - CGFloat(rows - 1) * 10) / CGFloat(rows)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount), spacing: 10) {
                    ForEach(shown, id: \.key) { space in
                        cell(space).frame(height: max(height, 80))
                    }
                }
            }

            if !hidden.isEmpty {
                HStack {
                    ForEach(hidden, id: \.key) { space in
                        Button { toggle(space) } label: {
                            Label(Spaces.name(space, layout), systemImage: "eye.slash")
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .onAppear(perform: load)
        .onReceive(refresh) { _ in load() }
        .onChange(of: layout) { Prefs.save($0) }
    }

    private func cell(_ space: Spaces.Info) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField(space.title, text: name(space))
                    .textFieldStyle(.plain)
                    .font(.headline)
                Button { toggle(space) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
            }
            ForEach((windows[space.id] ?? []).prefix(6), id: \.id) { item in
                HStack(spacing: 6) {
                    if let icon = item.icon {
                        Image(nsImage: NSImage(cgImage: icon, size: NSSize(width: 16, height: 16)))
                    }
                    Text(item.title).lineLimit(1).font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(space.current ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .draggable(space.key)
        .dropDestination(for: String.self) { keys, _ in
            guard let key = keys.first else { return false }
            swap(key, space.key)
            return true
        }
    }

    private func name(_ space: Spaces.Info) -> Binding<String> {
        Binding(get: { layout.names[space.key] ?? "" },
                set: { layout.names[space.key] = $0.isEmpty ? nil : $0 })
    }

    private func toggle(_ space: Spaces.Info) {
        if layout.hidden.remove(space.key) == nil { layout.hidden.insert(space.key) }
    }

    /// Swapped, not shifted, so nothing else in the grid moves.
    private func swap(_ a: String, _ b: String) {
        guard a != b else { return }
        var order = Spaces.arranged(spaces, Prefs.SpaceLayout(order: layout.order)).map(\.key)
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return }
        order.swapAt(i, j)
        layout.order = order
    }

    private func load() {
        spaces = Store.shared.spaceList
        let current = spaces.first(where: \.current)?.id ?? 0
        windows = Dictionary(grouping: Store.shared.snapshot) { $0.home == 0 ? current : $0.home }
    }
}
