import Cocoa

/// One icon size for the whole bar. Every icon is drawn aspect-fit and centred in the same square, so icons
/// in equal boxes look equal and share one centre line (raw SF Symbols differ in size and baseline).
/// The Touch Bar ignores NSButton.contentTintColor, so a tint is baked into the image instead.
enum TouchBarIcon {
    /// Symbol glyphs (mic, play, skip, ...).
    static let symbolBox: CGFloat = 18
    /// App icons and text badges (App Controls switcher and picker).
    static let appBox: CGFloat = 24
    /// The App Controls switcher: a borderless app icon at full bar height.
    static let switcherBox: CGFloat = 30

    static func symbol(_ name: String, box: CGFloat = symbolBox, tint: NSColor? = nil) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let large = glyph.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)) ?? glyph
        return fitted(large, box: box, tint: tint, template: true)
    }

    /// `image` scaled to fit `box` x `box` and centred. `template` (glyphs) renders white on the bar unless tinted;
    /// pass false for full-colour images such as app icons.
    static func fitted(_ image: NSImage, box: CGFloat, tint: NSColor? = nil, template: Bool) -> NSImage {
        let size = image.size
        // Wide glyphs (skip arrows) may use up to 1.4 x the box width; otherwise they read smaller than square ones.
        let maximumWidth = box * 1.4
        let scale = size.width > 0 && size.height > 0 ? min(maximumWidth / size.width, box / size.height) : 1
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        let result = NSImage(size: NSSize(width: max(box, ceil(drawn.width)), height: box), flipped: false) { rect in
            let target = NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
            if let tint = tint {
                tint.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        result.isTemplate = template && tint == nil
        return result
    }
}
