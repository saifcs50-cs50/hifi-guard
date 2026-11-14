import AppKit

/// The HiFi Guard mark: an earbud with sound waves beside it. Drawn from paths on an
/// 18-point grid, so it is equally crisp in the menu bar and in the 1024 px app icon.
public enum BrandGlyph {
    /// Waves shown for each state: none when the quality guard is off, two normally,
    /// three while a call's duck is being cancelled.
    public enum Waves: Int, Sendable {
        case none = 0, normal = 2, boosted = 3
    }

    private static let grid: CGFloat = 18
    private static let budCenter = CGPoint(x: 6.6, y: 11.2)
    private static let budRadius: CGFloat = 4.4
    private static let stem = CGRect(x: 3.5, y: 1.3, width: 3.5, height: 9.5)
    /// The stem leans back like a worn earbud; upright, the mark reads as a letter "P".
    private static let stemTilt: CGFloat = -16
    private static let waveCenter = CGPoint(x: 8.9, y: 11.2)
    private static let firstWaveRadius: CGFloat = 3.9
    private static let waveSpacing: CGFloat = 2.35
    private static let waveSweep: CGFloat = 42
    private static let waveWidth: CGFloat = 1.45

    public static func draw(in rect: CGRect, color: NSColor, waves: Waves) {
        let unit = min(rect.width, rect.height) / grid
        let origin = CGPoint(x: rect.midX - grid * unit / 2, y: rect.midY - grid * unit / 2)
        let point = { (x: CGFloat, y: CGFloat) in CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }

        color.setFill()
        color.setStroke()

        let bud = CGRect(
            x: point(budCenter.x - budRadius, 0).x,
            y: point(0, budCenter.y - budRadius).y,
            width: budRadius * 2 * unit,
            height: budRadius * 2 * unit
        )
        NSBezierPath(ovalIn: bud).fill()

        let stemRect = CGRect(origin: point(stem.minX, stem.minY), size: CGSize(width: stem.width * unit, height: stem.height * unit))
        let stemPath = NSBezierPath(roundedRect: stemRect, xRadius: stem.width * unit / 2, yRadius: stem.width * unit / 2)
        let pivot = point(budCenter.x, budCenter.y)
        var tilt = AffineTransform(translationByX: pivot.x, byY: pivot.y)
        tilt.rotate(byDegrees: stemTilt)
        tilt.translate(x: -pivot.x, y: -pivot.y)
        stemPath.transform(using: tilt)
        stemPath.fill()

        for index in 0..<waves.rawValue {
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: point(waveCenter.x, waveCenter.y),
                radius: (firstWaveRadius + CGFloat(index) * waveSpacing) * unit,
                startAngle: -waveSweep,
                endAngle: waveSweep
            )
            arc.lineWidth = waveWidth * unit
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    /// A template image for the menu bar, tinted by macOS for light and dark menus.
    public static func menuBarImage(waves: Waves) -> NSImage {
        let image = NSImage(size: NSSize(width: grid, height: grid), flipped: false) { rect in
            draw(in: rect, color: .black, waves: waves)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "HiFi Guard"
        return image
    }
}
