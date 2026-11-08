import Cocoa

// Two offset rounded squares on a blue tile.
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.56, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.36, blue: 0.9, alpha: 1))?.draw(in: tile, angle: -90)
    NSColor.white.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect: NSRect(x: 240, y: 400, width: 400, height: 330), xRadius: 56, yRadius: 56).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 384, y: 290, width: 400, height: 330), xRadius: 56, yRadius: 56).fill()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
