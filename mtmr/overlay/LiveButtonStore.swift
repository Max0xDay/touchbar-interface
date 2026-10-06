import Cocoa

struct LiveButtonDefinition: Decodable {
    let id: String?
    let icon: String?
    let iconPath: String?
    let tint: String?
    let keepSlotWhenHidden: Bool

    private enum CodingKeys: String, CodingKey { case id, icon, iconPath, tint, keepSlotWhenHidden }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decodeIfPresent(String.self, forKey: .id)
        icon = try fields.decodeIfPresent(String.self, forKey: .icon)
        iconPath = try fields.decodeIfPresent(String.self, forKey: .iconPath)
        tint = try fields.decodeIfPresent(String.self, forKey: .tint)
        keepSlotWhenHidden = try fields.decodeIfPresent(Bool.self, forKey: .keepSlotWhenHidden) ?? false
        if let id = id { try LiveButtonStore.validateId(id) }
        var values: [String: Any] = [:]
        if let icon = icon { values["icon"] = icon }
        if let iconPath = iconPath { values["iconPath"] = iconPath }
        if let tint = tint { values["tint"] = tint }
        try LiveButtonStore.validateFields(values)
    }
}

struct LiveButtonError: LocalizedError {
    let message: String
    var errorDescription: String? { return message }
}

final class LiveButtonStore {
    static let shared = LiveButtonStore()
    static let visibilityChanged = Notification.Name("MTMRLiveButtonVisibilityChanged")

    private final class Binding {
        weak var view: NSView?
        let defaults: [String: Any]
        let defaultImage: NSImage?
        let defaultBackground: NSColor?
        let apply: (NSImage?, NSColor?, NSColor?, Bool) -> Void

        init(view: NSView, defaults: [String: Any], image: NSImage?, background: NSColor?, apply: @escaping (NSImage?, NSColor?, NSColor?, Bool) -> Void) {
            self.view = view
            self.defaults = defaults
            defaultImage = image
            defaultBackground = background
            self.apply = apply
        }
    }

    private var bindings: [String: Binding] = [:]
    private var overrides: [String: [String: Any]] = [:]

    static func validateId(_ id: String) throws {
        guard id.range(of: "^[a-z0-9-]{1,32}$", options: .regularExpression) != nil else {
            throw LiveButtonError(message: "id must match [a-z0-9-]{1,32}")
        }
    }

    static func validateFields(_ fields: [String: Any]) throws {
        if hasConflictingIcons(fields) {
            throw LiveButtonError(message: "icon and iconPath are alternatives")
        }
        for name in ["icon", "iconPath", "tint", "background"] {
            guard let value = fields[name] else { continue }
            if value is NSNull { continue }
            guard let text = value as? String else { throw LiveButtonError(message: "\(name) must be a string or null") }
            switch name {
            case "icon":
                guard symbol(text) != nil else { throw LiveButtonError(message: "unknown icon") }
            case "iconPath":
                guard readablePng(text) else {
                    throw LiveButtonError(message: "iconPath must be an absolute readable PNG path")
                }
            default:
                guard color(text) != nil else { throw LiveButtonError(message: "\(name) must be #rrggbb or null") }
            }
        }
        if let visible = fields["visible"] {
            if visible is NSNull { return }
            guard let number = visible as? NSNumber else { throw LiveButtonError(message: "visible must be a boolean or null") }
            guard CFGetTypeID(number) == CFBooleanGetTypeID() else { throw LiveButtonError(message: "visible must be a boolean or null") }
        }
    }

    private static func hasConflictingIcons(_ fields: [String: Any]) -> Bool {
        return fields["icon"] is String && fields["iconPath"] is String
    }

    private static func readablePng(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        guard path.lowercased().hasSuffix(".png") else { return false }
        do {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard bytes.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
            return NSImage(contentsOfFile: path) != nil
        } catch {
            NSLog("MTMR live button PNG rejected: %@", String(describing: error))
            return false
        }
    }

    static func color(_ text: String) -> NSColor? {
        guard text.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { return nil }
        guard let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func symbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        // #COMPLETION_DRIVE: A 17 pt SF Symbol fits Apple's native 30 pt button height visually.
        // #SUGGEST_VERIFY: Compare mic sizing and template tint on the physical Touch Bar.
        let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)) ?? image
        configured.isTemplate = true
        return configured
    }

    func beginRebuild() {
        dispatchPrecondition(condition: .onQueue(.main))
        bindings.removeAll()
    }

    func bind(definition: LiveButtonDefinition, view: NSView, image: NSImage?, background: NSColor?, apply: @escaping (NSImage?, NSColor?, NSColor?, Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        var defaults: [String: Any] = ["visible": true, "icon": NSNull(), "iconPath": NSNull(), "tint": NSNull(), "background": NSNull()]
        defaults["icon"] = definition.icon ?? defaults["icon"]
        defaults["iconPath"] = definition.iconPath ?? defaults["iconPath"]
        defaults["tint"] = definition.tint ?? defaults["tint"]
        if let color = background?.usingColorSpace(.sRGB) {
            defaults["background"] = String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        }
        let binding = Binding(view: view, defaults: defaults, image: image, background: background, apply: apply)
        guard let id = definition.id else {
            render(binding, values: defaults)
            return
        }
        bindings[id] = binding
        let values = effective(id, binding: binding)
        render(binding, values: values)
        view.alphaValue = values["visible"] as? Bool == false ? 0 : 1
    }

    func buttons() -> [[String: Any]] {
        dispatchPrecondition(condition: .onQueue(.main))
        return bindings.keys.sorted().compactMap { id in
            guard let binding = bindings[id], binding.view != nil else { return nil }
            var values = effective(id, binding: binding)
            values["id"] = id
            return values
        }
    }

    func update(_ fields: [String: Any]) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let id = fields["id"] as? String else { throw LiveButtonError(message: "button requires id") }
        guard let binding = bindings[id], let view = binding.view else { throw LiveButtonError(message: "unknown button") }
        try Self.validateFields(fields)
        let wasVisible = effective(id, binding: binding)["visible"] as? Bool ?? true
        var changes = overrides[id] ?? [:]
        for name in ["icon", "iconPath", "tint", "background", "visible"] {
            guard let value = fields[name] else { continue }
            changes[name] = value is NSNull ? nil : value
        }
        applyIconOverrides(fields, to: &changes)
        overrides[id] = changes
        let values = effective(id, binding: binding)
        render(binding, values: values)
        let visible = values["visible"] as? Bool ?? true
        if visible != wasVisible {
            NotificationCenter.default.post(name: Self.visibilityChanged, object: view)
            view.alphaValue = visible ? 1 : 0
        }
    }

    private func applyIconOverrides(_ fields: [String: Any], to changes: inout [String: Any]) {
        if let icon = fields["icon"] as? String {
            changes["icon"] = icon
            changes["iconPath"] = NSNull()
            return
        }
        if let path = fields["iconPath"] as? String {
            changes["iconPath"] = path
            changes["icon"] = NSNull()
            return
        }
        if Self.hasIconReset(fields) {
            changes["icon"] = nil
            changes["iconPath"] = nil
        }
    }

    private static func hasIconReset(_ fields: [String: Any]) -> Bool {
        return fields["icon"] is NSNull || fields["iconPath"] is NSNull
    }

    private func effective(_ id: String, binding: Binding) -> [String: Any] {
        return binding.defaults.merging(overrides[id] ?? [:]) { _, override in override }
    }

    private func render(_ binding: Binding, values: [String: Any]) {
        var image = binding.defaultImage
        if let name = values["icon"] as? String { image = Self.symbol(name) }
        if let path = values["iconPath"] as? String {
            image = NSImage(contentsOfFile: path)
            image?.size = NSSize(width: 17, height: 17)
            image?.isTemplate = true
        }
        let tint = (values["tint"] as? String).flatMap(Self.color)
        let background = (values["background"] as? String).flatMap(Self.color) ?? binding.defaultBackground
        binding.apply(image, tint, background, values["visible"] as? Bool ?? true)
    }
}
