// The app's icon, drawn in code so it's sharp at every size and needs no image files: a waveform
// turning into caption lines, with a red "live" dot, on an indigo-to-violet tile.
import AppKit

/// The Dock icon. Drawn on a 1024-point canvas laid out like Apple's macOS icons (an 824-point
/// rounded square inset by 100, with a soft shadow), and scaled to whatever size it's shown at.
/// Shadows and glows are drawn as shapes, not NSShadow, whose blur doesn't shrink with the icon.
func overhearIcon() -> NSImage {
    NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { canvas in
        let s = canvas.width / 1024
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
        }
        func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
            let radius = min(w, h) / 2 * s
            return NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius)
        }

        // The tile's shadow: faint layers growing outward, a little below it.
        for grow in stride(from: 16.0, through: 2, by: -2) {
            NSColor.black.withAlphaComponent(0.035).setFill()
            NSBezierPath(roundedRect: rect(100 - grow, 100 - grow - 10, 824 + 2 * grow, 824 + 2 * grow),
                         xRadius: (185 + grow) * s, yRadius: (185 + grow) * s).fill()
        }

        // The tile: indigo → violet, with a faint highlight along the top.
        let tile = NSBezierPath(roundedRect: rect(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
        let indigo = NSColor(srgbRed: 0.26, green: 0.22, blue: 0.79, alpha: 1)  // #4338CA
        let violet = NSColor(srgbRed: 0.49, green: 0.23, blue: 0.93, alpha: 1)  // #7C3AED
        NSGradient(starting: indigo, ending: violet)!.draw(in: tile, angle: -45)
        NSGradient(colorsAndLocations: (.white.withAlphaComponent(0.18), 0), (.white.withAlphaComponent(0), 0.55))!
            .draw(in: tile, angle: -90)

        // Waveform on the left, then caption lines (newest at the bottom, brightest) on the right.
        NSColor.white.setFill()
        for (i, height) in [130.0, 250, 360, 230, 150].enumerated() {
            capsule(214 + CGFloat(i) * 64, 512 - height / 2, 42, height).fill()
        }
        for (y, width, alpha) in [(612.0, 236.0, 0.45), (512, 280, 0.7), (412, 196, 1)] {
            NSColor.white.withAlphaComponent(alpha).setFill()
            capsule(570, y - 22, width, 44).fill()
        }

        // The "live" dot, with a red glow fading out around it.
        let red = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)  // #FF453A
        // From the dot's edge (radius 48 of 100) out to nothing.
        NSGradient(colorsAndLocations: (red.withAlphaComponent(0.5), 0.48), (red.withAlphaComponent(0.15), 0.75),
                   (red.withAlphaComponent(0), 1))!
            .draw(in: NSBezierPath(ovalIn: rect(684, 684, 200, 200)), relativeCenterPosition: .zero)
        red.setFill()
        NSBezierPath(ovalIn: rect(736, 736, 96, 96)).fill()
        return true
    }
}
