#!/usr/bin/env swift
//
// Tracer — generate_app_icon.swift
//
// Programmatic app-icon generator. Renders the Tracer brand mark at every
// .icns size, then invokes `iconutil` to compose the final `.icns`.
// Produces a crisp, deterministic icon from a single source: a tiny
// CoreGraphics draw routine, no external image assets required.
//
// The design: a dark gradient rounded-rect tile, three concentric rings
// (decay pattern), a bright centre "tracer dot", and a diagonal dashed
// sweep that evokes a radiotracer trajectory through a scanner bore.
//
// Usage:
//   swift scripts/generate_app_icon.swift                 → writes Resources/AppIcon.icns
//   swift scripts/generate_app_icon.swift Path/To/Out.icns → writes to a custom path

import CoreGraphics
import Foundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

// MARK: - Brand colours

struct Brand {
    // Dark navy → midnight vertical gradient for the tile.
    static let bgTop     = CGColor(red: 0.10, green: 0.14, blue: 0.26, alpha: 1)
    static let bgBottom  = CGColor(red: 0.04, green: 0.06, blue: 0.14, alpha: 1)
    /// Accent — a bright cyan-teal that reads as "radiology" without being
    /// the obvious Apple system blue.
    static let accent    = CGColor(red: 0.22, green: 0.72, blue: 0.94, alpha: 1)
    static let accentDim = CGColor(red: 0.22, green: 0.72, blue: 0.94, alpha: 0.55)
    static let accentFaint = CGColor(red: 0.22, green: 0.72, blue: 0.94, alpha: 0.28)
    static let glow      = CGColor(red: 0.68, green: 0.92, blue: 1.00, alpha: 1)
}

// MARK: - Icon renderer

func renderTracerIcon(size: CGFloat) -> CGImage {
    let scale: CGFloat = 1
    let pixelSize = Int(size * scale)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not build CGContext for size \(size)")
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: scale, y: scale)

    // 1. Rounded-rect tile with a vertical gradient.
    let radius = size * 0.22
    let tile = CGRect(x: 0, y: 0, width: size, height: size)
    let tilePath = CGPath(roundedRect: tile,
                          cornerWidth: radius,
                          cornerHeight: radius,
                          transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [Brand.bgTop, Brand.bgBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: size / 2, y: size),
        end: CGPoint(x: size / 2, y: 0),
        options: []
    )
    ctx.restoreGState()

    // 2. Subtle vignette — darkens the corners so the rings feel centred.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let vignette = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        vignette,
        startCenter: CGPoint(x: size / 2, y: size / 2),
        startRadius: size * 0.25,
        endCenter: CGPoint(x: size / 2, y: size / 2),
        endRadius: size * 0.75,
        options: []
    )
    ctx.restoreGState()

    // 3. Three concentric rings. Widest, fainter outer ring; narrow, bright
    //    inner ring.
    let centre = CGPoint(x: size / 2, y: size / 2)
    let ringDiameters: [CGFloat] = [0.74, 0.56, 0.38]
    let ringColours: [CGColor] = [Brand.accentFaint, Brand.accentDim, Brand.accent]
    for (i, diameter) in ringDiameters.enumerated() {
        ctx.setLineWidth(max(1.0, size * (0.018 - CGFloat(i) * 0.003)))
        ctx.setStrokeColor(ringColours[i])
        let r = size * diameter / 2
        ctx.strokeEllipse(in: CGRect(
            x: centre.x - r, y: centre.y - r,
            width: r * 2, height: r * 2
        ))
    }

    // 4. Glow behind the centre dot — simulate a hot uptake spot.
    let glowGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            Brand.glow,
            Brand.accent,
            Brand.accent.copy(alpha: 0)!
        ] as CFArray,
        locations: [0, 0.35, 1]
    )!
    ctx.drawRadialGradient(
        glowGradient,
        startCenter: centre, startRadius: size * 0.01,
        endCenter: centre, endRadius: size * 0.24,
        options: []
    )

    // 5. Solid centre dot.
    let dotRadius = size * 0.085
    ctx.setFillColor(Brand.glow)
    ctx.fillEllipse(in: CGRect(
        x: centre.x - dotRadius, y: centre.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2
    ))

    // 6. Diagonal dashed tracer path — lower-left to upper-right.
    ctx.saveGState()
    ctx.setStrokeColor(Brand.accent.copy(alpha: 0.55)!)
    ctx.setLineWidth(size * 0.018)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [size * 0.04, size * 0.04])
    ctx.move(to: CGPoint(x: size * 0.17, y: size * 0.22))
    ctx.addLine(to: CGPoint(x: size * 0.83, y: size * 0.78))
    ctx.strokePath()
    ctx.restoreGState()

    // 7. Subtle inner highlight stroke at the tile edge.
    ctx.setLineWidth(max(1, size * 0.004))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.addPath(tilePath)
    ctx.strokePath()

    guard let image = ctx.makeImage() else {
        fatalError("Failed to snapshot icon at size \(size)")
    }
    return image
}

// MARK: - PNG writer

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "TracerIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination at \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "TracerIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Finalize failed for \(url.path)"])
    }
}

// MARK: - .iconset composer

/// iconset layout required by `iconutil`. Each size is produced at 1x and
/// 2x; the 2x variant gets the `@2x` suffix.
let iconsetSpecs: [(baseName: String, size: CGFloat)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",     128),
    ("icon_128x128@2x",  256),
    ("icon_256x256",     256),
    ("icon_256x256@2x",  512),
    ("icon_512x512",     512),
    ("icon_512x512@2x",  1024),
]

// MARK: - Main

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputURL: URL = {
    if CommandLine.arguments.count >= 2 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    return repoRoot.appendingPathComponent("Resources/AppIcon.icns")
}()

let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("TracerIconGen-\(UUID().uuidString)", isDirectory: true)
let iconsetDir = tempDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: tempDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

print("→ Rendering PNGs into \(iconsetDir.path)")
for (baseName, size) in iconsetSpecs {
    let image = renderTracerIcon(size: size)
    let url = iconsetDir.appendingPathComponent("\(baseName).png")
    try writePNG(image, to: url)
    print("  \(baseName).png  (\(Int(size))×\(Int(size)))")
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

print("→ Composing .icns via iconutil")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    "-o", outputURL.path,
    iconsetDir.path
]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("✓ Wrote \(outputURL.path)")
    try? FileManager.default.removeItem(at: tempDir)
} else {
    print("✗ iconutil exited \(process.terminationStatus); iconset left at \(iconsetDir.path)")
    exit(Int32(process.terminationStatus))
}
