// Draws the Cosign app icon: an obsidian council squircle with a luminous brass roundtable,
// four distinct persona nodes, and a central gold co-sign checkmark seal.
// Run: swift Tools/make-icon.swift <Assets.xcassets-dir>
import AppKit
import Foundation

let outRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Assets.xcassets")

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func renderMasterIcon(dev: Bool) -> NSBitmapImageRep {
    let size = 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.translateBy(x: 0, y: CGFloat(size))
    cg.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 32, color: rgb(0, 0, 0, 0.45).cgColor)
    rgb(0.05, 0.06, 0.10).setFill()
    rounded(body, 185).fill()
    cg.restoreGState()

    rounded(body, 185).addClip()
    NSGradient(colors: [rgb(0.07, 0.09, 0.15), rgb(0.11, 0.14, 0.23)])!.draw(in: body, angle: -90)

    // Warm radial brass aura in center
    let center = CGPoint(x: 512, y: 500)
    if let radial = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(0.96, 0.62, 0.04, 0.26).cgColor, rgb(0.96, 0.62, 0.04, 0.0).cgColor] as CFArray,
        locations: [0.0, 1.0]
    ) {
        cg.drawRadialGradient(radial, startCenter: center, startRadius: 20, endCenter: center, endRadius: 340, options: [])
    }

    // Outer brass council ring
    let ringRadius: CGFloat = 248
    let ringRect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
    let ringPath = NSBezierPath(ovalIn: ringRect)
    ringPath.lineWidth = 14
    rgb(0.96, 0.68, 0.16, 0.40).setStroke()
    ringPath.stroke()

    // Subtle spokes from 4 council seats into the central verdict seal
    let seatColors = [
        rgb(0.98, 0.75, 0.14), // Vera (Chair - Top)
        rgb(0.20, 0.83, 0.60), // Marcus (Right)
        rgb(0.96, 0.25, 0.37), // Sable (Bottom)
        rgb(0.38, 0.65, 0.98), // Orion (Left)
    ]
    let angles: [CGFloat] = [-.pi / 2, 0, .pi / 2, .pi]

    for (idx, angle) in angles.enumerated() {
        let px = center.x + cos(angle) * ringRadius
        let py = center.y + sin(angle) * ringRadius

        let spoke = NSBezierPath()
        spoke.move(to: center)
        spoke.line(to: CGPoint(x: px, y: py))
        spoke.lineWidth = 8
        seatColors[idx].withAlphaComponent(0.35).setStroke()
        spoke.stroke()
    }

    // Central Gold Co-Sign Medallion
    let sealRect = CGRect(x: center.x - 118, y: center.y - 118, width: 236, height: 236)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 8), blur: 24, color: rgb(0.96, 0.62, 0.04, 0.45).cgColor)
    let sealPath = NSBezierPath(ovalIn: sealRect)
    NSGradient(colors: [rgb(0.99, 0.78, 0.22), rgb(0.92, 0.54, 0.05)])!.draw(in: sealPath, angle: 90)
    cg.restoreGState()

    // Crisp Checkmark inside central medallion
    let check = NSBezierPath()
    check.move(to: CGPoint(x: center.x - 52, y: center.y + 4))
    check.line(to: CGPoint(x: center.x - 12, y: center.y + 44))
    check.line(to: CGPoint(x: center.x + 56, y: center.y - 34))
    check.lineWidth = 28
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    rgb(0.06, 0.08, 0.13).setStroke()
    check.stroke()

    // Four glowing persona nodes around the ring
    for (idx, angle) in angles.enumerated() {
        let px = center.x + cos(angle) * ringRadius
        let py = center.y + sin(angle) * ringRadius
        let nodeRect = CGRect(x: px - 46, y: py - 46, width: 92, height: 92)

        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 18, color: seatColors[idx].withAlphaComponent(0.65).cgColor)
        rgb(0.09, 0.12, 0.19).setFill()
        NSBezierPath(ovalIn: nodeRect).fill()
        cg.restoreGState()

        let innerRect = nodeRect.insetBy(dx: 14, dy: 14)
        seatColors[idx].setFill()
        NSBezierPath(ovalIn: innerRect).fill()

        let border = NSBezierPath(ovalIn: nodeRect.insetBy(dx: 3, dy: 3))
        border.lineWidth = 6
        seatColors[idx].withAlphaComponent(0.85).setStroke()
        border.stroke()
    }

    // Specular outer rim
    let rim = rounded(body.insetBy(dx: 2, dy: 2), 183)
    rim.lineWidth = 4
    rgb(1, 1, 1, 0.12).setStroke()
    rim.stroke()

    if dev {
        let band = CGRect(x: 100, y: 760, width: 824, height: 164)
        rgb(0.95, 0.42, 0.10).setFill()
        NSBezierPath(rect: band).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 106, weight: .heavy),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
            .kern: 16,
        ]
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flipped
        ("DEV" as NSString).draw(in: CGRect(x: 100, y: 778, width: 824, height: 140), withAttributes: attrs)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func resize(_ master: NSBitmapImageRep, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let img = NSImage(size: NSSize(width: 1024, height: 1024))
    img.addRepresentation(master)
    img.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: url)
}

func writeIconSet(name: String, dev: Bool) throws {
    let dir = outRoot.appendingPathComponent("\(name).appiconset", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let master = renderMasterIcon(dev: dev)

    let specs: [(pt: Int, scale: Int, file: String)] = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png"),
    ]

    var imagesJSON: [[String: String]] = []
    for s in specs {
        try resize(master, pixels: s.pt * s.scale, to: dir.appendingPathComponent(s.file))
        imagesJSON.append([
            "filename": s.file,
            "idiom": "mac",
            "scale": "\(s.scale)x",
            "size": "\(s.pt)x\(s.pt)"
        ])
    }

    let contents: [String: Any] = [
        "images": imagesJSON,
        "info": ["author": "xcode", "version": 1]
    ]
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: dir.appendingPathComponent("Contents.json"))
}

try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
let rootContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try rootContents.write(to: outRoot.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try writeIconSet(name: "AppIcon", dev: false)
try writeIconSet(name: "AppIconDev", dev: true)
print("Generated AppIcon & AppIconDev in \(outRoot.path)")
