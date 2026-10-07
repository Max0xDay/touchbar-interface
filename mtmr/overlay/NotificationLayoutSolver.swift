import Foundation

struct NotificationLayoutOptions: Decodable, Equatable {
    let padding: Double
    let minWidth: Double
    let maxWidth: Double?
    let fadeSeconds: Double
    /// Shown as a notification whenever the bar is brought up (launch, layout load, back from Apple's bar).
    let welcome: String?
    /// Mirror macOS notifications into the area (see NotificationMirror.swift); nil = off.
    let mirror: NotificationMirrorOptions?

    init(padding: Double = 16, minWidth: Double? = nil, maxWidth: Double? = nil, fadeSeconds: Double = 0.35, maxChars: Int = 40, welcome: String? = nil, mirror: NotificationMirrorOptions? = nil) {
        self.fadeSeconds = fadeSeconds
        self.welcome = welcome
        self.mirror = mirror
        self.padding = padding.rounded()
        self.minWidth = (minWidth ?? NotificationTextMetrics.preferredWidth(maxChars: maxChars)).rounded(.up)
        self.maxWidth = maxWidth?.rounded(.down)
    }

    private enum CodingKeys: String, CodingKey {
        case padding
        case minWidth
        case maxWidth
        case fadeSeconds
        case maxChars
        case welcome
        case mirror
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? 16
        let maxChars = try container.decodeIfPresent(Int.self, forKey: .maxChars) ?? 40
        guard (1...1000).contains(maxChars) else {
            throw DecodingError.dataCorruptedError(forKey: .maxChars, in: container, debugDescription: "maxChars must be between 1 and 1000")
        }
        let minWidth = try container.decodeIfPresent(Double.self, forKey: .minWidth) ?? NotificationTextMetrics.preferredWidth(maxChars: maxChars)
        let maxWidth = try container.decodeIfPresent(Double.self, forKey: .maxWidth)
        guard padding.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .padding, in: container, debugDescription: "padding must be finite")
        }
        guard padding >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .padding, in: container, debugDescription: "padding must not be negative")
        }
        guard minWidth.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .minWidth, in: container, debugDescription: "minWidth must be finite")
        }
        guard minWidth >= 120 else {
            throw DecodingError.dataCorruptedError(forKey: .minWidth, in: container, debugDescription: "notification minWidth must be at least 120")
        }
        if let maxWidth = maxWidth {
            guard maxWidth.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .maxWidth, in: container, debugDescription: "maxWidth must be finite")
            }
            // #COMPLETION_DRIVE: Reject a cap below the minimum rather than silently choosing between contradictory options.
            // #SUGGEST_VERIFY: Keep maxWidth >= minWidth; revise this validation if smaller caps are intended.
            guard maxWidth.rounded(.down) >= minWidth.rounded(.up) else {
                throw DecodingError.dataCorruptedError(forKey: .maxWidth, in: container, debugDescription: "maxWidth must be at least minWidth after rounding")
            }
        }
        let fadeSeconds = try container.decodeIfPresent(Double.self, forKey: .fadeSeconds) ?? 0.35
        guard fadeSeconds.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .fadeSeconds, in: container, debugDescription: "fadeSeconds must be finite")
        }
        guard (0...2).contains(fadeSeconds) else {
            throw DecodingError.dataCorruptedError(forKey: .fadeSeconds, in: container, debugDescription: "fadeSeconds must be between 0 and 2")
        }
        let welcome = try container.decodeIfPresent(String.self, forKey: .welcome)
        let mirror = try container.decodeIfPresent(NotificationMirrorOptions.self, forKey: .mirror)
        self.init(padding: padding, minWidth: minWidth, maxWidth: maxWidth, fadeSeconds: fadeSeconds, welcome: welcome, mirror: mirror)
    }
}

/// Layout options for mirroring macOS notifications. Kept here (pure data) so the solver tests compile alone.
/// App ids compare lower-cased, as Notification Center stores them.
struct NotificationMirrorOptions: Decodable, Equatable {
    /// Apps whose notifications stay `stickySeconds` instead of the default (Teams, Outlook).
    let stickyApps: [String]
    let stickySeconds: Double
    /// Apps shown with the lob icon (lob sessions notify through kitty).
    let lobApps: [String]
    let ignoreApps: [String]

    private enum CodingKeys: String, CodingKey { case stickyApps, stickySeconds, lobApps, ignoreApps }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stickyApps = (try container.decodeIfPresent([String].self, forKey: .stickyApps) ?? []).map { $0.lowercased() }
        stickySeconds = try container.decodeIfPresent(Double.self, forKey: .stickySeconds) ?? 600
        guard stickySeconds.isFinite, stickySeconds > 0, stickySeconds <= 86400 else {
            throw DecodingError.dataCorruptedError(forKey: .stickySeconds, in: container, debugDescription: "stickySeconds must be 0...86400")
        }
        lobApps = (try container.decodeIfPresent([String].self, forKey: .lobApps) ?? []).map { $0.lowercased() }
        ignoreApps = (try container.decodeIfPresent([String].self, forKey: .ignoreApps) ?? []).map { $0.lowercased() }
    }
}

enum NotificationTextMetrics {
    static let fontSize: Double = 15
    static let innerInset: Double = 12
    // #COMPLETION_DRIVE: This is the measured advance of the 15 pt regular monospaced system font on macOS 14.7.6.
    // #SUGGEST_VERIFY: The AppKit harness checks this against NSFont; remeasure if the system font changes.
    static let glyphWidth: Double = 9.2724609375

    static func preferredWidth(maxChars: Int) -> Double {
        return max(120, ceil(Double(maxChars) * glyphWidth + 2 * innerInset))
    }

    static func capacity(width: Double, inset: Double, glyphWidth: Double, maxChars: Int) -> Int {
        guard glyphWidth > 0 else { return 0 }
        let fittingCharacters = floor(max(0, width - 2 * inset) / glyphWidth)
        return Int(min(Double(max(0, maxChars)), fittingCharacters))
    }

    static func truncated(_ text: String, capacity: Int) -> String {
        guard capacity > 0 else { return "" }
        return text.count > capacity ? String(text.prefix(capacity - 1)) + "…" : text
    }
}

enum NotificationSwipe {
    static func offset(horizontal: Double, vertical: Double) -> Int {
        // Verified on the real bar (MTMR-notif log, 2026-10-06): the Touch Bar reports no vertical movement, so swipes are horizontal.
        // #COMPLETION_DRIVE: 20 pt of dominant horizontal movement counts as a swipe (real swipes logged 20-85 pt).
        guard abs(horizontal) >= 20 else { return 0 }
        guard abs(horizontal) > abs(vertical) else { return 0 }
        return horizontal < 0 ? 1 : -1
    }
}

struct NotificationLayoutButton: Equatable {
    let width: Double
    let minWidth: Double

    init(width: Double, minWidth: Double? = nil, fixed: Bool = false) {
        self.width = max(0, width.rounded())
        self.minWidth = fixed ? self.width : min(self.width, max(0, (minWidth ?? self.width * 0.6).rounded()))
    }
}

struct NotificationLayoutFrame: Equatable {
    let x: Double
    let width: Double
    var maxX: Double { return x + width }
    var height: Double { return 30 }
}

struct NotificationLayoutSolution: Equatable {
    let left: [NotificationLayoutFrame?]
    let right: [NotificationLayoutFrame?]
    let notification: NotificationLayoutFrame
    let isBelowMinimum: Bool
    let hasHiddenItems: Bool
}

enum NotificationLayoutSolver {
    private static let spacing: Double = 8
    private static let floorWidth: Double = 120

    static func solve(barWidth: Double, left: [NotificationLayoutButton], right: [NotificationLayoutButton], options: NotificationLayoutOptions = NotificationLayoutOptions()) -> NotificationLayoutSolution {
        let barWidth = max(0, barWidth)
        var leftWidths = left.map { $0.width }
        let rightWidths = right.map { $0.width }
        let groupLimit = ((barWidth - options.minWidth - 2 * options.padding) / 2).rounded(.down)
        if availableWidth(barWidth, leftWidths, rightWidths, options.padding) < options.minWidth {
            leftWidths = shrink(left, to: max(groupLimit, groupWidth(rightWidths)))
        }
        let available = availableWidth(barWidth, leftWidths, rightWidths, options.padding)
        var notificationWidth = centredWidth(min(available, options.maxWidth ?? available), barWidth: barWidth)
        var visibleLeft = leftWidths.map { Optional($0) }
        let visibleRight = rightWidths.map { Optional($0) }
        if notificationWidth < floorWidth {
            // #COMPLETION_DRIVE: At impossible widths preserve the right group and centred floor, hiding only overflowing left items; right may overlap or be clipped.
            // #SUGGEST_VERIFY: Keep W >= 2*(Rw+padding)+120; right preservation, a centred floor and no overlap cannot all hold below that.
            notificationWidth = centredWidth(min(121, options.maxWidth ?? 121), barWidth: barWidth)
            let remainingMargin = max(0, (barWidth - notificationWidth) / 2)
            let edgePadding = min(options.padding, remainingMargin)
            let edgeLimit = (remainingMargin - edgePadding).rounded(.down)
            visibleLeft = fittingWidths(leftWidths, limit: edgeLimit)
        }
        return NotificationLayoutSolution(
            left: frames(visibleLeft, start: 0),
            right: frames(visibleRight, start: barWidth - groupWidth(visibleRight.compactMap { $0 })),
            notification: NotificationLayoutFrame(x: (barWidth - notificationWidth) / 2, width: notificationWidth),
            isBelowMinimum: notificationWidth < options.minWidth,
            hasHiddenItems: hasHiddenItems(visibleLeft, visibleRight)
        )
    }

    private static func hasHiddenItems(_ left: [Double?], _ right: [Double?]) -> Bool {
        return left.contains(nil) || right.contains(nil)
    }

    private static func groupWidth(_ widths: [Double]) -> Double {
        return widths.reduce(0, +) + spacing * Double(max(0, widths.count - 1))
    }

    private static func availableWidth(_ barWidth: Double, _ left: [Double], _ right: [Double], _ padding: Double) -> Double {
        return barWidth - 2 * max(groupWidth(left), groupWidth(right)) - 2 * padding
    }

    private static func shrink(_ buttons: [NotificationLayoutButton], to limit: Double) -> [Double] {
        let widths = buttons.map { $0.width }
        let capacities = buttons.map { $0.width - $0.minWidth }
        let totalCapacity = capacities.reduce(0, +)
        guard totalCapacity > 0 else { return widths }
        let reduction = min(totalCapacity, max(0, groupWidth(widths) - limit).rounded(.up))
        let proportional = capacities.map { $0 * reduction / totalCapacity }
        var reductions = proportional.map { $0.rounded(.down) }
        let remainders = zip(proportional, reductions).map { $0 - $1 }
        let indices = buttons.indices.sorted {
            if remainders[$0] == remainders[$1] { return $0 < $1 }
            return remainders[$0] > remainders[$1]
        }
        let remainingPoints = Int(reduction - reductions.reduce(0, +))
        for index in indices.prefix(remainingPoints) { reductions[index] += 1 }
        return zip(widths, reductions).map { $0 - $1 }
    }

    private static func centredWidth(_ limit: Double, barWidth: Double) -> Double {
        let width = max(0, min(barWidth, limit).rounded(.down))
        guard barWidth == barWidth.rounded() else { return width }
        let alignedWidth = width - (barWidth - width).truncatingRemainder(dividingBy: 2)
        // #COMPLETION_DRIVE: A 120 cap on odd W (or fractional W) requires fractional origins to preserve exact edges/centre and the floor.
        // #SUGGEST_VERIFY: Check fractional origins if using such widths; normal whole-point frames use N with the same parity as W.
        return alignedWidth >= floorWidth ? alignedWidth : width
    }

    private static func fittingWidths(_ widths: [Double], limit: Double) -> [Double?] {
        var visible = [Double?](repeating: nil, count: widths.count)
        let indices = widths.indices
        var usedWidth: Double = 0
        var visibleCount = 0
        for index in indices {
            let proposedWidth = usedWidth + widths[index] + (visibleCount > 0 ? spacing : 0)
            guard proposedWidth <= limit else { break }
            visible[index] = widths[index]
            usedWidth = proposedWidth
            visibleCount += 1
        }
        return visible
    }

    private static func frames(_ widths: [Double?], start: Double) -> [NotificationLayoutFrame?] {
        var position = start
        var visibleCount = 0
        return widths.map { width in
            guard let width = width else { return nil }
            if visibleCount > 0 { position += spacing }
            let frame = NotificationLayoutFrame(x: position, width: width)
            position += width
            visibleCount += 1
            return frame
        }
    }
}
