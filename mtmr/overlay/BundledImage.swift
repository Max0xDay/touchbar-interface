import Cocoa

/// Loads an image shipped in the app bundle's Resources folder (replaces Xcode asset-catalogue image literals).
private let templateImageNames: Set<String> = [
    "StatusImage", "brightnessDown", "brightnessUp", "dark-mode-off", "dark-mode-on",
    "dnd-off", "ill_down", "ill_up", "nightShiftOff",
]

func bundledImage(_ name: String) -> NSImage {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else {
        fatalError("missing bundled image: \(name)")
    }
    image.isTemplate = templateImageNames.contains(name)
    return image
}
