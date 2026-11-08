import Cocoa
import os

/// Window previews, captured in the background and read from memory when the
/// switcher opens.
final class Thumbs {
    static let shared = Thumbs()

    private let q = DispatchQueue(label: "flick.thumbs", qos: .utility)
    private let cache = OSAllocatedUnfairLock(initialState: [CGWindowID: CGImage]())
    private var inFlight = Set<CGWindowID>()   // q only
    private let fit = OSAllocatedUnfairLock(initialState: CGSize(width: 432, height: 284))

    var enabled: Bool {
        Prefs.current.thumbnails && CGPreflightScreenCaptureAccess()
    }

    func missing(_ items: [Item]) -> [Item] {
        cache.withLock { c in items.filter { c[$0.id] == nil && !$0.minimized && !$0.hidden } }
    }

    func image(_ id: CGWindowID) -> CGImage? { cache.withLock { $0[id] } }

    func refresh(_ id: CGWindowID, after delay: Double = 0) {
        q.asyncAfter(deadline: .now() + delay) { [self] in
            guard enabled, !inFlight.contains(id) else { return }
            inFlight.insert(id)
            defer { inFlight.remove(id) }
            let start = now()
            guard let source = bestSource(id), let small = shrink(source) else { return }
            Log.write("capture \(id) \(String(format: "%.1f", ms(since: start)))ms")
            accept(small, for: id)
        }
    }

    /// The smaller capture, unless the window is so small that it wouldn't fill the tile.
    private func bestSource(_ id: CGWindowID) -> CGImage? {
        let box = fit.withLock { $0 }
        guard let quick = Priv.capture(id, full: false) else { return nil }
        return CGFloat(quick.width) >= box.width || CGFloat(quick.height) >= box.height ? quick : Priv.capture(id) ?? quick
    }

    /// A window that hasn't changed captures to the same pixels, and shouldn't fade.
    func accept(_ new: CGImage, for id: CGWindowID) {
        if let old = image(id), old.width == new.width, old.height == new.height,
           old.dataProvider?.data == new.dataProvider?.data { return }
        cache.withLock { $0[id] = new }
        DispatchQueue.main.async { Overlay.shared.thumbnailChanged(id) }
    }

    func refresh(_ items: [Item]) {
        for item in items where !item.minimized && !item.hidden { refresh(item.id) }
    }

    /// For the self test.
    func bench(_ items: [Item]) -> String {
        var times: [Double] = []
        for item in items where !item.minimized && !item.hidden {
            let start = now()
            if let source = bestSource(item.id) { _ = shrink(source) }
            times.append(ms(since: start))
        }
        times.sort()
        let bytes = cache.withLock { $0.values.reduce(0) { $0 + $1.bytesPerRow * $1.height } }
        return String(format: "capture and shrink median %.1fms over %d; cache %.1f MB", times.isEmpty ? 0 : times[times.count / 2], times.count, Double(bytes) / 1e6)
    }

    /// The biggest a thumbnail is ever drawn, in pixels. Anything larger is wasted memory.
    func setFit(_ size: CGSize, items: [Item]) {
        // Only ever grows, so flipping views doesn't recapture everything each time.
        let changed = fit.withLock { old -> Bool in
            guard size.width > old.width else { return false }
            old = size
            return true
        }
        if changed { refresh(items) }
    }

    func forget(keeping ids: Set<CGWindowID>) {
        cache.withLock { $0 = $0.filter { ids.contains($0.key) } }
    }

    private func shrink(_ image: CGImage) -> CGImage? {
        guard image.width > 1, image.height > 1 else { return nil }
        let box = fit.withLock { $0 }
        let scale = min(1, box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = Int((CGFloat(image.width) * scale).rounded(.up)), h = Int((CGFloat(image.height) * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
