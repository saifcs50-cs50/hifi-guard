import AppKit
import HiFiGuardCore

/// Renders the app icon set, plus menu-bar previews for design review.
/// Usage: HiFiGuardIcon <iconset-dir> [preview-dir]
let arguments = Array(CommandLine.arguments.dropFirst())
guard let iconsetPath = arguments.first else {
    FileHandle.standardError.write(Data("usage: HiFiGuardIcon <iconset-dir> [preview-dir]\n".utf8))
    exit(2)
}

/// macOS app icons sit on an 824 px rounded square inside a 1024 px canvas.
enum IconStyle {
    static let canvas: CGFloat = 1024
    static let tile: CGFloat = 824
    static let cornerRatio: CGFloat = 0.2237
    static let glyphRatio: CGFloat = 0.62
    static let top = NSColor(srgbRed: 0.33, green: 0.27, blue: 0.95, alpha: 1)
    static let bottom = NSColor(srgbRed: 0.07, green: 0.05, blue: 0.24, alpha: 1)
}

func render(pixels: Int, _ draw: (CGRect) -> Void) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

func drawAppIcon(in rect: CGRect) {
    let scale = rect.width / IconStyle.canvas
    let tileSize = IconStyle.tile * scale
    let tile = CGRect(x: rect.midX - tileSize / 2, y: rect.midY - tileSize / 2, width: tileSize, height: tileSize)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tileSize * IconStyle.cornerRatio, yRadius: tileSize * IconStyle.cornerRatio)
    NSGradient(starting: IconStyle.top, ending: IconStyle.bottom)?.draw(in: shape, angle: -90)
    let glyphSize = tileSize * IconStyle.glyphRatio
    let glyph = CGRect(x: tile.midX - glyphSize / 2, y: tile.midY - glyphSize / 2, width: glyphSize, height: glyphSize)
    BrandGlyph.draw(in: glyph, color: .white, waves: .normal)
}

func write(_ data: Data?, to path: String) throws {
    guard let data else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: URL(fileURLWithPath: path))
}

do {
    try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try write(render(pixels: points * scale, drawAppIcon), to: "\(iconsetPath)/\(name)")
        }
    }
    if arguments.count > 1 {
        let previews = arguments[1]
        try FileManager.default.createDirectory(atPath: previews, withIntermediateDirectories: true)
        for waves in [BrandGlyph.Waves.none, .normal, .boosted] {
            let menuBar = render(pixels: 144) { rect in
                NSColor.white.setFill()
                rect.fill()
                BrandGlyph.draw(in: rect.insetBy(dx: 16, dy: 16), color: .black, waves: waves)
            }
            try write(menuBar, to: "\(previews)/menubar-\(waves.rawValue)-waves.png")
        }
        try write(render(pixels: 512, drawAppIcon), to: "\(previews)/appicon.png")
    }
    print("Wrote \(iconsetPath)")
} catch {
    FileHandle.standardError.write(Data("Icon render failed: \(error)\n".utf8))
    exit(1)
}
