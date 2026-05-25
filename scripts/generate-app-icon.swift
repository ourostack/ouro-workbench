#!/usr/bin/env swift
import AppKit
import Foundation

struct IconSpec {
    var baseSize: Int
    var scale: Int

    var pixels: Int {
        baseSize * scale
    }

    var filename: String {
        scale == 1 ? "icon_\(baseSize)x\(baseSize).png" : "icon_\(baseSize)x\(baseSize)@2x.png"
    }
}

let specs = [
    IconSpec(baseSize: 16, scale: 1),
    IconSpec(baseSize: 16, scale: 2),
    IconSpec(baseSize: 32, scale: 1),
    IconSpec(baseSize: 32, scale: 2),
    IconSpec(baseSize: 128, scale: 1),
    IconSpec(baseSize: 128, scale: 2),
    IconSpec(baseSize: 256, scale: 1),
    IconSpec(baseSize: 256, scale: 2),
    IconSpec(baseSize: 512, scale: 1),
    IconSpec(baseSize: 512, scale: 2),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-app-icon.swift OUTPUT.icns\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("ouro-workbench-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = tempRoot.appendingPathComponent("OuroWorkbench.iconset", isDirectory: true)

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer {
    try? fileManager.removeItem(at: tempRoot)
}

for spec in specs {
    let data = try drawIconPNG(pixelSize: spec.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(spec.filename), options: [.atomic])
}

try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try? fileManager.removeItem(at: outputURL)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0, fileManager.fileExists(atPath: outputURL.path) else {
    FileHandle.standardError.write(Data("Failed to create app icon at \(outputURL.path)\n".utf8))
    exit(1)
}

private func drawIconPNG(pixelSize: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.featureUnsupported)
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw CocoaError(.featureUnsupported)
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let size = CGFloat(pixelSize)
    drawIcon(in: CGRect(x: 0, y: 0, width: size, height: size))

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

private func drawIcon(in rect: CGRect) {
    let side = min(rect.width, rect.height)
    let scale = side / 1024

    func scaled(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    NSColor.clear.setFill()
    rect.fill()

    let outer = NSBezierPath(roundedRect: rect.insetBy(dx: scaled(52), dy: scaled(52)), xRadius: scaled(222), yRadius: scaled(222))
    NSGradient(colors: [
        NSColor(calibratedRed: 0.045, green: 0.055, blue: 0.070, alpha: 1),
        NSColor(calibratedRed: 0.075, green: 0.100, blue: 0.125, alpha: 1),
    ])?.draw(in: outer, angle: -40)

    NSColor(calibratedWhite: 1.0, alpha: 0.10).setStroke()
    outer.lineWidth = scaled(18)
    outer.stroke()

    let terminalRect = CGRect(x: scaled(150), y: scaled(238), width: scaled(724), height: scaled(548))
    let terminal = NSBezierPath(roundedRect: terminalRect, xRadius: scaled(56), yRadius: scaled(56))
    NSColor(calibratedWhite: 0.0, alpha: 0.98).setFill()
    terminal.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
    terminal.lineWidth = scaled(8)
    terminal.stroke()

    let lightY = terminalRect.maxY - scaled(76)
    drawCircle(center: CGPoint(x: terminalRect.minX + scaled(72), y: lightY), radius: scaled(22), color: NSColor(calibratedRed: 1.0, green: 0.21, blue: 0.28, alpha: 1))
    drawCircle(center: CGPoint(x: terminalRect.minX + scaled(132), y: lightY), radius: scaled(22), color: NSColor(calibratedRed: 1.0, green: 0.77, blue: 0.05, alpha: 1))
    drawCircle(center: CGPoint(x: terminalRect.minX + scaled(192), y: lightY), radius: scaled(22), color: NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.32, alpha: 1))

    let loopRect = CGRect(x: terminalRect.midX - scaled(132), y: terminalRect.midY - scaled(128), width: scaled(264), height: scaled(264))
    let loop = NSBezierPath(ovalIn: loopRect)
    NSColor(calibratedRed: 0.0, green: 0.86, blue: 0.86, alpha: 1).setStroke()
    loop.lineWidth = scaled(54)
    loop.stroke()

    let gap = NSBezierPath()
    gap.move(to: CGPoint(x: loopRect.maxX - scaled(34), y: loopRect.midY + scaled(102)))
    gap.line(to: CGPoint(x: loopRect.maxX + scaled(66), y: loopRect.midY + scaled(150)))
    NSColor(calibratedWhite: 0.0, alpha: 1).setStroke()
    gap.lineWidth = scaled(82)
    gap.stroke()

    let prompt = NSBezierPath()
    prompt.move(to: CGPoint(x: terminalRect.minX + scaled(130), y: terminalRect.minY + scaled(208)))
    prompt.line(to: CGPoint(x: terminalRect.minX + scaled(214), y: terminalRect.minY + scaled(274)))
    prompt.line(to: CGPoint(x: terminalRect.minX + scaled(130), y: terminalRect.minY + scaled(340)))
    NSColor(calibratedRed: 0.43, green: 0.32, blue: 1.0, alpha: 1).setStroke()
    prompt.lineWidth = scaled(38)
    prompt.lineJoinStyle = .round
    prompt.lineCapStyle = .round
    prompt.stroke()

    let cursor = NSBezierPath(roundedRect: CGRect(x: terminalRect.minX + scaled(252), y: terminalRect.minY + scaled(195), width: scaled(58), height: scaled(170)), xRadius: scaled(14), yRadius: scaled(14))
    NSColor(calibratedRed: 0.58, green: 0.84, blue: 1.0, alpha: 1).setFill()
    cursor.fill()

    let underline = NSBezierPath(roundedRect: CGRect(x: terminalRect.minX + scaled(356), y: terminalRect.minY + scaled(218), width: scaled(302), height: scaled(38)), xRadius: scaled(19), yRadius: scaled(19))
    NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.32, alpha: 1).setFill()
    underline.fill()
}

private func drawCircle(center: CGPoint, radius: CGFloat, color: NSColor) {
    let rect = CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    )
    color.setFill()
    NSBezierPath(ovalIn: rect).fill()
}
