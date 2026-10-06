// Renders the Minote app icon (an off-white page with a monospaced "m" and the
// blue caret) into Resources/AppIcon.icns (SwiftPM builds) and
// Resources/Assets.xcassets/AppIcon.appiconset (Xcode builds, macOS + iOS).
//
//   swift scripts/make-icon.swift
//
// Requires Resources/Fonts/IBMPlexMono-Regular.ttf.

import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fontURL = root.appendingPathComponent("Resources/Fonts/IBMPlexMono-Regular.ttf")
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")

var registrationError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &registrationError) else {
    fatalError("Couldn't register \(fontURL.path)")
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Apple's macOS icon body: a superellipse ("squircle") on the 1024 grid.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = center.x + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = center.y + b * copysign(pow(abs(s), 2 / exponent), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// `fullBleed` draws the iOS variant: an opaque square the system rounds itself.
func renderIcon(pixels: Int, fullBleed: Bool = false) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        // App Store Connect rejects iOS icons with an alpha channel.
        space: space, bitmapInfo: (fullBleed ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
    )!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Body with a soft drop shadow.
    let body = fullBleed ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = fullBleed ? CGPath(rect: body, transform: nil) : squirclePath(in: body)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, alpha: 0.28))
    context.addPath(shape)
    context.setFillColor(color(0xF6F6F6))
    context.fillPath()
    context.restoreGState()

    // Paper gradient.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0xFCFCFC), color(0xEDEDED)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    context.restoreGState()

    // Hairline edge.
    if !fullBleed {
        context.addPath(shape)
        context.setStrokeColor(color(0x000000, alpha: 0.08))
        context.setLineWidth(2)
        context.strokePath()
    }

    // "m" followed by the caret, centered as a group.
    let fontSize: CGFloat = fullBleed ? 560 : 470
    let font = CTFontCreateWithName("IBMPlexMono" as CFString, fontSize, nil)
    let glyphText = NSAttributedString(string: "m", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(0x161616),
    ])
    let line = CTLineCreateWithAttributedString(glyphText)
    let ink = CTLineGetImageBounds(line, context)
    let xHeight = CTFontGetXHeight(font)

    let scaleUp: CGFloat = fullBleed ? 560.0 / 470.0 : 1
    let caretWidth: CGFloat = 36 * scaleUp
    let caretHeight: CGFloat = 400 * scaleUp
    let gap: CGFloat = 34 * scaleUp
    let groupWidth = ink.width + gap + caretWidth
    let groupLeft = 512 - groupWidth / 2
    let baseline = 512 - xHeight / 2 - 8

    context.textPosition = CGPoint(x: groupLeft - ink.minX, y: baseline)
    CTLineDraw(line, context)

    let caret = CGRect(
        x: groupLeft + ink.width + gap,
        y: baseline + xHeight / 2 - caretHeight / 2,
        width: caretWidth,
        height: caretHeight
    )
    context.setFillColor(color(0x01C2FC))
    context.fill(caret)

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try writePNG(renderIcon(pixels: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(renderIcon(pixels: size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try writePNG(renderIcon(pixels: 1024), to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

// Asset catalog for Xcode: the macOS sizes plus one 1024 px iOS icon.
let appIconSet = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.removeItem(at: appIconSet)
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "mac-\(size)@\(scale)x.png"
        try writePNG(renderIcon(pixels: size * scale), to: appIconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
try writePNG(renderIcon(pixels: 1024, fullBleed: true), to: appIconSet.appendingPathComponent("ios-1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ios-1024.png"])
let catalogInfo = ["author": "xcode", "version": 1] as [String: Any]
let iconJSON = try JSONSerialization.data(withJSONObject: ["images": images, "info": catalogInfo], options: [.prettyPrinted, .sortedKeys])
try iconJSON.write(to: appIconSet.appendingPathComponent("Contents.json"))
let rootJSON = try JSONSerialization.data(withJSONObject: ["info": catalogInfo], options: [.prettyPrinted, .sortedKeys])
try rootJSON.write(to: root.appendingPathComponent("Resources/Assets.xcassets/Contents.json"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
