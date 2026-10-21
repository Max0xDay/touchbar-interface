#!/usr/bin/env swift
import AppKit

struct LogoError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func roundedRectangle(_ rectangle: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rectangle, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillRoundedRectangle(_ context: CGContext, _ rectangle: CGRect, radius: CGFloat) {
    context.addPath(roundedRectangle(rectangle, radius: radius))
    context.fillPath()
}

func drawBell(_ context: CGContext) {
    context.move(to: CGPoint(x: 49, y: 12))
    context.addLine(to: CGPoint(x: 51, y: 15))
    context.addLine(to: CGPoint(x: 51, y: 19))
    context.addCurve(to: CGPoint(x: 59, y: 19), control1: CGPoint(x: 51, y: 25),
                     control2: CGPoint(x: 59, y: 25))
    context.addLine(to: CGPoint(x: 59, y: 15))
    context.addLine(to: CGPoint(x: 61, y: 12))
    context.closePath()
    context.fillPath()
    context.fillEllipse(in: CGRect(x: 53, y: 8, width: 4, height: 3))
}

func drawBar(_ context: CGContext, coloured: Bool) {
    let barPath = roundedRectangle(CGRect(x: 2, y: 3, width: 84, height: 26), radius: 7)
    if coloured {
        context.setFillColor(NSColor(calibratedWhite: 0.10, alpha: 1).cgColor)
        context.addPath(barPath)
        context.fillPath()
    }
    context.setStrokeColor(coloured
        ? NSColor(calibratedWhite: 0.36, alpha: 1).cgColor : NSColor.black.cgColor)
    context.setLineWidth(coloured ? 1 : 3)
    context.addPath(barPath)
    context.strokePath()
    let iconColours: [NSColor] = coloured ? [
        NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1),
        NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 1),
        NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 1)
    ] : Array(repeating: .black, count: 4)
    context.setFillColor(iconColours[0].cgColor)
    context.fillEllipse(in: CGRect(x: 10, y: 12, width: 8, height: 8))
    context.setFillColor(iconColours[1].cgColor)
    fillRoundedRectangle(context, CGRect(x: 25, y: 14.5, width: 16, height: 3), radius: 1.5)
    context.fillEllipse(in: CGRect(x: 32, y: 12, width: 8, height: 8))
    context.setFillColor(iconColours[2].cgColor)
    drawBell(context)
    context.setFillColor(iconColours[3].cgColor)
    fillRoundedRectangle(context, CGRect(x: 70, y: 11, width: 10, height: 10), radius: 2)
}

func drawAppIcon(_ context: CGContext) throws {
    let background = roundedRectangle(CGRect(x: 100, y: 100, width: 824, height: 824), radius: 184)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
    context.setFillColor(NSColor(calibratedWhite: 0.22, alpha: 1).cgColor)
    context.addPath(background)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(background)
    context.clip()
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(calibratedWhite: 0.32, alpha: 1).cgColor,
        NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1]) else {
        throw LogoError(message: "Cannot create background gradient")
    }
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()
    context.translateBy(x: 116, y: 368)
    context.scaleBy(x: 9, y: 9)
    drawBar(context, coloured: true)
}

func writePng(to destination: URL, pixels: Int, status: Bool = false) throws {
    let width = status ? 88 : pixels
    let height = status ? 32 : pixels
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw LogoError(message: "Cannot create drawing context for \(destination.path)")
    }
    if status {
        drawBar(context, coloured: false)
    } else {
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        try drawAppIcon(context)
    }
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw LogoError(message: "Cannot encode PNG for \(destination.path)")
    }
    try png.write(to: destination)
}

func createIconArchive(in outputDirectory: URL, iconsetDirectory: URL) throws {
    let iconUtility = Process()
    iconUtility.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconUtility.arguments = ["-c", "icns", iconsetDirectory.path, "-o",
                             outputDirectory.appendingPathComponent("AppIcon.icns").path]
    let finished = DispatchSemaphore(value: 0)
    iconUtility.terminationHandler = { _ in finished.signal() }
    try iconUtility.run()
    guard finished.wait(timeout: .now() + 30) == .success else {
        iconUtility.terminate()
        throw LogoError(message: "iconutil exceeded 30 seconds")
    }
    guard iconUtility.terminationStatus == 0 else {
        throw LogoError(message: "iconutil failed with status \(iconUtility.terminationStatus)")
    }
}

func generateLogo() throws {
    guard CommandLine.arguments.count == 2 else {
        throw LogoError(message: "Usage: swift mtmr/branding/make-logo.swift <outputDir>")
    }
    let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let iconsetDirectory = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)
    try writePng(to: outputDirectory.appendingPathComponent("StatusImage.png"), pixels: 32, status: true)
    try writePng(to: outputDirectory.appendingPathComponent("AppIcon.png"), pixels: 1024)
    for size in [16, 32, 128, 256, 512] {
        try writePng(to: iconsetDirectory.appendingPathComponent("icon_\(size)x\(size).png"), pixels: size)
        try writePng(to: iconsetDirectory.appendingPathComponent("icon_\(size)x\(size)@2x.png"), pixels: size * 2)
    }
    try createIconArchive(in: outputDirectory, iconsetDirectory: iconsetDirectory)
}

do {
    try generateLogo()
} catch {
    fputs("make-logo.swift: \(error.localizedDescription)\n", stderr)
    exit(1)
}
