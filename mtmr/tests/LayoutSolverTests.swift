import Foundation

@main
struct LayoutSolverTests {
    private static let currentLeft = [
        NotificationLayoutButton(width: 30, fixed: true),
        NotificationLayoutButton(width: 1, fixed: true),
        NotificationLayoutButton(width: 75),
        NotificationLayoutButton(width: 75),
        NotificationLayoutButton(width: 75)
    ]
    private static let currentRight = [NotificationLayoutButton(width: 100), NotificationLayoutButton(width: 100)]

    static func main() {
        do {
            checkCurrentLayout()
            checkBarWidthChanges()
            checkProportionalShrink()
            checkAutoSizeOrder()
            checkBelowMinimumAndFloor()
            checkTinyWidths()
            checkEmptyAndOneSidedGroups()
            try checkOptions()
            try checkTextCapacityAndFadeOptions()
            print("Layout solver checks passed")
        } catch {
            NSLog("Layout solver tests failed: %@", String(describing: error))
            exit(1)
        }
    }

    private static func checkTextCapacityAndFadeOptions() throws {
        for (width, expectedCapacity) in [(477.0, 40), (311, 31), (120, 10), (24, 0), (10, 0), (33, 1)] {
            precondition(NotificationTextMetrics.capacity(width: width, inset: 12, glyphWidth: 9, maxChars: 40) == expectedCapacity)
        }
        precondition(NotificationTextMetrics.capacity(width: 477, inset: 12, glyphWidth: 9, maxChars: 8) == 8)
        precondition(NotificationTextMetrics.truncated("abcdef", capacity: 4) == "abc…")
        precondition(NotificationTextMetrics.truncated("abcdef", capacity: 1) == "…")
        precondition(NotificationTextMetrics.truncated("abcdef", capacity: 0) == "")
        precondition(NotificationTextMetrics.truncated("abcd", capacity: 4) == "abcd")
        precondition(NotificationLayoutOptions().fadeSeconds == 0.35)
        for seconds in [0.0, 0.35, 2] {
            let options = try JSONDecoder().decode(NotificationLayoutOptions.self, from: Data("{\"fadeSeconds\":\(seconds)}".utf8))
            precondition(options.fadeSeconds == seconds)
        }
        for invalidOptions in [#"{"fadeSeconds":-0.1}"#, #"{"fadeSeconds":2.1}"#, #"{"fadeSeconds":"bad"}"#, #"{"fadeSeconds":1e999}"#] {
            do {
                _ = try JSONDecoder().decode(NotificationLayoutOptions.self, from: Data(invalidOptions.utf8))
                preconditionFailure("Invalid fadeSeconds accepted")
            } catch {
                print("Rejected invalid fadeSeconds: \(error)")
            }
        }
        let fourButtons = currentLeft + [NotificationLayoutButton(width: 75)]
        let fourSolution = NotificationLayoutSolver.solve(barWidth: 1085, left: fourButtons, right: currentRight)
        precondition(fourSolution.left.compactMap { $0?.width } == [30, 1, 64, 64, 65, 65])
        precondition(fourSolution.notification == NotificationLayoutFrame(x: 345, width: 395))
        precondition(fourSolution.right.compactMap { $0?.width } == [100, 100])
        precondition(fourSolution.right.last??.maxX == 1085)
        checkGeometry(fourSolution, barWidth: 1085)
        precondition(NotificationLayoutOptions().minWidth == 395)
        let smallBudget = try JSONDecoder().decode(NotificationLayoutOptions.self, from: Data(#"{"maxChars":20}"#.utf8))
        precondition(smallBudget.minWidth == 210)
        print("Four left icons: N=395 margins=345/345 widths=64,64,65,65")
    }

    private static func checkCurrentLayout() {
        let solution = NotificationLayoutSolver.solve(barWidth: 1085, left: currentLeft, right: currentRight)
        precondition(solution.left.compactMap { $0?.x } == [0, 38, 47, 130, 213])
        precondition(solution.left.last??.maxX == 288)
        precondition(solution.right.compactMap { $0?.x } == [877, 985])
        precondition(solution.right.last??.maxX == 1085)
        precondition(solution.notification == NotificationLayoutFrame(x: 304, width: 477))
        precondition(1085 - solution.notification.maxX == 304)
        precondition(!solution.isBelowMinimum)
        precondition(!solution.hasHiddenItems)
        checkGeometry(solution, barWidth: 1085)
        print("Current layout: W=1085 Lw=288 Rw=208 padding=16 N=477 margins=304/304 gaps=16/96")
    }

    private static func checkBarWidthChanges() {
        for barWidth in [1085.0, 1000, 900, 780, 1085.5] {
            let solution = NotificationLayoutSolver.solve(barWidth: barWidth, left: currentLeft, right: currentRight)
            precondition(solution.right.last??.maxX == barWidth, "Trailing edge must follow runtime W")
            checkGeometry(solution, barWidth: barWidth)
        }
    }

    private static func checkProportionalShrink() {
        let left = [NotificationLayoutButton(width: 200), NotificationLayoutButton(width: 100)]
        let solution = NotificationLayoutSolver.solve(barWidth: 800, left: left, right: [], options: NotificationLayoutOptions(minWidth: 240))
        precondition(solution.left.compactMap { $0?.width } == [171, 85], "Shrink must apportion available reductions proportionally")
        precondition(solution.notification.width == 240)
        checkGeometry(solution, barWidth: 800)
        let sixButtons = Array(currentLeft.prefix(2)) + Array(repeating: NotificationLayoutButton(width: 75), count: 6)
        let resized = NotificationLayoutSolver.solve(barWidth: 1085, left: sixButtons, right: currentRight)
        precondition(resized.left.compactMap { $0?.width } == [30, 1, 45, 45, 45, 45, 45, 45])
        precondition(resized.left.last??.maxX == 357)
        precondition(resized.right.compactMap { $0?.width } == [100, 100], "Right must stay full-sized if shrinking left suffices")
        precondition(resized.notification == NotificationLayoutFrame(x: 373, width: 339))
        precondition(NotificationTextMetrics.capacity(width: 339, inset: 12, glyphWidth: NotificationTextMetrics.glyphWidth, maxChars: 40) == 33)
        checkGeometry(resized, barWidth: 1085)
        print("Six left icons: Lw=357 Rw=208 N=339 margins=373/373 widths=45,45,45,45,45,45")
        let explicitMinima = [NotificationLayoutButton(width: 200, minWidth: 190), NotificationLayoutButton(width: 100, minWidth: 10)]
        let explicitSolution = NotificationLayoutSolver.solve(barWidth: 800, left: explicitMinima, right: [], options: NotificationLayoutOptions(minWidth: 240))
        precondition(explicitSolution.left.compactMap { $0?.width } == [196, 60])
        checkGeometry(explicitSolution, barWidth: 800)
    }

    private static func checkAutoSizeOrder() {
        let left = [NotificationLayoutButton(width: 100), NotificationLayoutButton(width: 100)]
        let right = [NotificationLayoutButton(width: 140, minWidth: 0), NotificationLayoutButton(width: 140, minWidth: 0)]
        let solution = NotificationLayoutSolver.solve(barWidth: 800, left: left, right: right)
        precondition(solution.left.compactMap { $0?.width } == [100, 100], "Shrinking left below right cannot help")
        precondition(solution.right.compactMap { $0?.width } == [140, 140])
        precondition(solution.notification.width == 192)
        let dominatedLeft = [NotificationLayoutButton(width: 200), NotificationLayoutButton(width: 200)]
        let stopped = NotificationLayoutSolver.solve(barWidth: 800, left: dominatedLeft, right: right)
        precondition(stopped.left.compactMap { $0?.width } == [140, 140], "Stop shrinking when Lw equals Rw")
        precondition(stopped.notification.width == 192)
        checkGeometry(stopped, barWidth: 800)
        checkGeometry(solution, barWidth: 800)
        let fixed = NotificationLayoutButton(width: 30, minWidth: 0, fixed: true)
        precondition(fixed.minWidth == 30, "Exit/spacer widths are fixed even with a smaller explicit minimum")
        precondition(NotificationLayoutButton(width: 75).minWidth == 45)
        precondition(NotificationLayoutButton(width: 76).minWidth == 46)
        precondition(NotificationLayoutButton(width: 75, minWidth: 70).minWidth == 70)
        precondition(NotificationLayoutButton(width: 75, minWidth: 100).minWidth == 75, "A minimum cannot enlarge a button")
    }

    private static func checkBelowMinimumAndFloor() {
        let left = Array(repeating: NotificationLayoutButton(width: 150), count: 3)
        let reduced = NotificationLayoutSolver.solve(barWidth: 780, left: left, right: currentRight)
        precondition(reduced.left.compactMap { $0?.width } == [90, 90, 90])
        precondition(reduced.right.compactMap { $0?.width } == [100, 100])
        precondition(reduced.notification.width == 176)
        precondition(reduced.isBelowMinimum)
        precondition(!reduced.hasHiddenItems)
        checkGeometry(reduced, barWidth: 780)
        let floor = NotificationLayoutSolver.solve(barWidth: 700, left: left, right: currentRight)
        precondition(floor.notification.width == 120)
        precondition(floor.isBelowMinimum)
        precondition(floor.hasHiddenItems, "Infeasible minima must not produce overlapping frames")
        precondition(floor.left.compactMap { $0?.width } == [90, 90])
        precondition(floor.left[2] == nil)
        precondition(floor.right.last??.maxX == 700)
        checkGeometry(floor, barWidth: 700)
    }

    private static func checkTinyWidths() {
        for barWidth in [0.0, 1, 30, 119, 120, 121, 160, 300, 500, 700] {
            let solution = NotificationLayoutSolver.solve(barWidth: barWidth, left: currentLeft, right: currentRight)
            checkGeometry(solution, barWidth: barWidth)
            if barWidth >= 120 {
                precondition(solution.notification.width >= 120)
            } else {
                precondition(solution.notification.width == barWidth)
                precondition(solution.hasHiddenItems)
            }
            for frame in solution.left.prefix(2).compactMap({ $0 }) {
                precondition([30.0, 1].contains(frame.width), "Fixed items may be hidden, never narrowed")
            }
        }
        for barWidth in stride(from: 0.0, through: 1400, by: 7) {
            let crowded = Array(repeating: NotificationLayoutButton(width: 75), count: 12)
            checkGeometry(NotificationLayoutSolver.solve(barWidth: barWidth, left: crowded, right: currentRight), barWidth: barWidth)
        }
    }

    private static func checkEmptyAndOneSidedGroups() {
        let empty = NotificationLayoutSolver.solve(barWidth: 1085, left: [], right: [])
        precondition(empty.notification == NotificationLayoutFrame(x: 16, width: 1053))
        checkGeometry(empty, barWidth: 1085)
        let leftOnly = NotificationLayoutSolver.solve(barWidth: 1085, left: currentLeft, right: [])
        precondition(leftOnly.notification == NotificationLayoutFrame(x: 304, width: 477))
        precondition(leftOnly.left.first??.x == 0)
        checkGeometry(leftOnly, barWidth: 1085)
        let rightOnly = NotificationLayoutSolver.solve(barWidth: 1085, left: [], right: currentRight)
        precondition(rightOnly.notification == NotificationLayoutFrame(x: 224, width: 637))
        precondition(rightOnly.right.last??.maxX == 1085)
        checkGeometry(rightOnly, barWidth: 1085)
    }

    private static func checkOptions() throws {
        let defaults = try JSONDecoder().decode(NotificationLayoutOptions.self, from: Data("{}".utf8))
        precondition(defaults == NotificationLayoutOptions(padding: 16, minWidth: 395))
        let options = try JSONDecoder().decode(NotificationLayoutOptions.self, from: Data(#"{"padding":24,"minWidth":300,"maxWidth":400}"#.utf8))
        let capped = NotificationLayoutSolver.solve(barWidth: 1085, left: currentLeft, right: currentRight, options: options)
        precondition(capped.notification == NotificationLayoutFrame(x: 343, width: 399), "Round capped N down to preserve whole-point centring")
        checkGeometry(capped, barWidth: 1085)
        let floorCap = NotificationLayoutSolver.solve(barWidth: 1085, left: [], right: [], options: NotificationLayoutOptions(minWidth: 120, maxWidth: 120))
        precondition(floorCap.notification == NotificationLayoutFrame(x: 482.5, width: 120), "Preserve centre and hard floor when integral origins are impossible")
        checkGeometry(floorCap, barWidth: 1085)
        for invalidOptions in [#"{"padding":-1}"#, #"{"minWidth":119}"#, #"{"maxWidth":239}"#, #"{"padding":"bad"}"#] {
            do {
                _ = try JSONDecoder().decode(NotificationLayoutOptions.self, from: Data(invalidOptions.utf8))
                preconditionFailure("Invalid layout options were accepted: \(invalidOptions)")
            } catch {
                print("Rejected invalid layout options: \(error)")
            }
        }
    }

    private static func rightGroupCannotFit(_ frames: [NotificationLayoutFrame], barWidth: Double) -> Bool {
        guard frames.map({ $0.width }) == [100, 100] else { return false }
        return barWidth < 2 * (208 + 16) + 120
    }

    private static func checkGeometry(_ solution: NotificationLayoutSolution, barWidth: Double) {
        let visibleLeft = solution.left.compactMap { $0 }
        let visibleRight = solution.right.compactMap { $0 }
        if rightGroupCannotFit(visibleRight, barWidth: barWidth) {
            precondition(visibleRight.last?.maxX == barWidth)
            precondition(solution.notification.x == barWidth - solution.notification.maxX)
            return
        }
        let orderedFrames = visibleLeft + [solution.notification] + visibleRight
        precondition(solution.notification.x + solution.notification.width / 2 == barWidth / 2)
        precondition(solution.notification.x == barWidth - solution.notification.maxX, "Notification margins must be equal")
        for frame in orderedFrames {
            precondition(frame.width >= 0)
            precondition(frame.width == frame.width.rounded())
            precondition(frame.height == 30)
            precondition(frame.x >= 0)
            precondition(frame.maxX <= barWidth)
        }
        for (previous, following) in zip(orderedFrames, orderedFrames.dropFirst()) {
            precondition(previous.maxX <= following.x, "Frames must never overlap")
        }
        if let leadingFrame = visibleLeft.first { precondition(leadingFrame.x == 0) }
        if let trailingFrame = visibleRight.last { precondition(trailingFrame.maxX == barWidth) }
        for group in [visibleLeft, visibleRight] {
            for (previous, following) in zip(group, group.dropFirst()) {
                precondition(following.x - previous.maxX == 8)
            }
        }
    }
}
