// Renders the web app icons: the menu-bar book symbol, white on brand blue.
import AppKit

let out = CommandLine.arguments[1]
let brand = NSColor(srgbRed: 0x23 / 255.0, green: 0x46 / 255.0, blue: 0xD1 / 255.0, alpha: 1)

for size in [180, 192, 512] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    brand.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.42, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon-\(size).png"))
}
print("icons written to \(out)")
