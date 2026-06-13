#!/usr/bin/env swift
// scripts/generate-appicon.swift
//
// Renders the ntakker macOS app icon from scratch using Core Graphics
// and writes a complete `Resources/AppIcon.iconset/` directory ready
// for `iconutil -c icns`.
//
// Why pure CoreGraphics instead of an SVG → PNG pipeline?
//   * No external dependencies (rsvg-convert / inkscape are not
//     installed on the build machine — Swift is).
//   * Pixel-perfect rendering at every iconset size; we tune small
//     sizes to drop fine details (the REC specular, the transcript
//     caret) so the icon still reads at 16×16.
//   * The icon design references the same palette the live UI uses
//     (mint-green mic, frosted-violet system audio), so keeping the
//     source in Swift lets future tweaks share constants if desired.
//
// Design — "Ntakker Pulse":
//   * Squircle background — diagonal gradient (indigo → violet → pink)
//     with a soft top-left specular highlight and a faint bottom-right
//     vignette for depth.
//   * Capital "N" letterform built from three elements:
//       - Left vertical bar  → mint-green (the mic capture source).
//       - Right vertical bar → white→violet (the system audio source).
//       - Diagonal connector → pearl white (the transcript flow that
//                              binds the two channels into one record).
//   * Small red "REC" dot with a halo in the upper-right interior —
//     the live-recording marker (also recognisable at 16×16).
//   * A subtle horizontal "transcript baseline" sitting under the N,
//     ending in a tiny caret dot — only visible at 64px+.
//
// Usage:
//   swift scripts/generate-appicon.swift
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// Output:
//   Resources/AppIcon.iconset/icon_16x16.png         (16×16)
//   Resources/AppIcon.iconset/icon_16x16@2x.png      (32×32)
//   Resources/AppIcon.iconset/icon_32x32.png         (32×32)
//   Resources/AppIcon.iconset/icon_32x32@2x.png      (64×64)
//   Resources/AppIcon.iconset/icon_128x128.png       (128×128)
//   Resources/AppIcon.iconset/icon_128x128@2x.png    (256×256)
//   Resources/AppIcon.iconset/icon_256x256.png       (256×256)
//   Resources/AppIcon.iconset/icon_256x256@2x.png    (512×512)
//   Resources/AppIcon.iconset/icon_512x512.png       (512×512)
//   Resources/AppIcon.iconset/icon_512x512@2x.png    (1024×1024)

import AppKit
import CoreGraphics
import Foundation

// MARK: - Iconset sizes

struct IconVariant {
    let pixels: Int
    let fileName: String
}

let variants: [IconVariant] = [
    IconVariant(pixels: 16,   fileName: "icon_16x16.png"),
    IconVariant(pixels: 32,   fileName: "icon_16x16@2x.png"),
    IconVariant(pixels: 32,   fileName: "icon_32x32.png"),
    IconVariant(pixels: 64,   fileName: "icon_32x32@2x.png"),
    IconVariant(pixels: 128,  fileName: "icon_128x128.png"),
    IconVariant(pixels: 256,  fileName: "icon_128x128@2x.png"),
    IconVariant(pixels: 256,  fileName: "icon_256x256.png"),
    IconVariant(pixels: 512,  fileName: "icon_256x256@2x.png"),
    IconVariant(pixels: 512,  fileName: "icon_512x512.png"),
    IconVariant(pixels: 1024, fileName: "icon_512x512@2x.png"),
]

// MARK: - Color helpers

@inline(__always)
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(
        red:   CGFloat(r) / 255.0,
        green: CGFloat(g) / 255.0,
        blue:  CGFloat(b) / 255.0,
        alpha: a
    )
}

// MARK: - Squircle path
//
// Approximation of the macOS superellipse using four cubic Beziers per
// corner. The control-point offset (radius × 0.55) gives a curve that's
// noticeably squarer than a quarter-circle (~0.5523) — closer to
// Apple's actual squircle than a plain rounded rect.

func squirclePath(rect: CGRect, radius r: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let x = rect.origin.x
    let y = rect.origin.y
    let w = rect.size.width
    let h = rect.size.height
    let c = r * 0.55 // squircle-ish curvature

    path.move(to: CGPoint(x: x, y: y + r))
    // Top-left
    path.addCurve(
        to: CGPoint(x: x + r, y: y),
        control1: CGPoint(x: x, y: y + r - c),
        control2: CGPoint(x: x + r - c, y: y)
    )
    path.addLine(to: CGPoint(x: x + w - r, y: y))
    // Top-right
    path.addCurve(
        to: CGPoint(x: x + w, y: y + r),
        control1: CGPoint(x: x + w - r + c, y: y),
        control2: CGPoint(x: x + w, y: y + r - c)
    )
    path.addLine(to: CGPoint(x: x + w, y: y + h - r))
    // Bottom-right
    path.addCurve(
        to: CGPoint(x: x + w - r, y: y + h),
        control1: CGPoint(x: x + w, y: y + h - r + c),
        control2: CGPoint(x: x + w - r + c, y: y + h)
    )
    path.addLine(to: CGPoint(x: x + r, y: y + h))
    // Bottom-left
    path.addCurve(
        to: CGPoint(x: x, y: y + h - r),
        control1: CGPoint(x: x + r - c, y: y + h),
        control2: CGPoint(x: x, y: y + h - r + c)
    )
    path.closeSubpath()
    return path
}

// MARK: - Vertical-bar helper

func drawVerticalBar(
    _ ctx: CGContext,
    x: CGFloat,
    width: CGFloat,
    top: CGFloat,
    bottom: CGFloat,
    topColor: CGColor,
    bottomColor: CGColor
) {
    let rect = CGRect(x: x, y: top, width: width, height: bottom - top)
    let path = CGPath(
        roundedRect: rect,
        cornerWidth: width / 2,
        cornerHeight: width / 2,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: nil,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: x, y: top),
        end:   CGPoint(x: x, y: bottom),
        options: []
    )
    ctx.restoreGState()
}

// MARK: - Main drawing routine
//
// All drawing happens in a logical 1024×1024 coordinate space; the
// outer `drawIcon` applies a uniform scale to render at any iconset
// size. `smallFeatures` toggles details that don't survive at 16/32
// (REC inner specular, transcript baseline + caret).

func drawAt1024(_ ctx: CGContext, smallFeatures: Bool) {
    let size: CGFloat = 1024

    // ---- 1. Squircle clip + background gradient ----
    let squircle = squirclePath(
        rect: CGRect(x: 0, y: 0, width: size, height: size),
        radius: 230
    )
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgColors: [CGColor] = [
        rgb(0x1B, 0x0A, 0x40), // deep cosmic indigo
        rgb(0x6B, 0x27, 0xD4), // electric violet
        rgb(0xFF, 0x4D, 0x87)  // warm magenta-pink
    ]
    let bgGradient = CGGradient(
        colorsSpace: nil,
        colors: bgColors as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: 0),
        end:   CGPoint(x: 1024, y: 1024),
        options: []
    )

    // ---- 2. Top-left specular highlight ----
    // Softer + further from the corner so the falloff doesn't read as
    // a crescent crease on the gradient.
    let hlGradient = CGGradient(
        colorsSpace: nil,
        colors: [
            rgb(0xFF, 0xFF, 0xFF, 0.18),
            rgb(0xFF, 0xFF, 0xFF, 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        hlGradient,
        startCenter: CGPoint(x: 300, y: 240),
        startRadius: 0,
        endCenter:   CGPoint(x: 300, y: 240),
        endRadius: 900,
        options: []
    )

    // ---- 3. Bottom-right vignette (depth, very subtle) ----
    let vigGradient = CGGradient(
        colorsSpace: nil,
        colors: [
            rgb(0x00, 0x00, 0x00, 0.0),
            rgb(0x10, 0x05, 0x28, 0.12)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        vigGradient,
        startCenter: CGPoint(x: 880, y: 880),
        startRadius: 360,
        endCenter:   CGPoint(x: 880, y: 880),
        endRadius: 980,
        options: []
    )

    // ---- 4. Transcript baseline (only when big enough to read) ----
    if smallFeatures {
        let baselineY: CGFloat = 800
        let baseline = CGPath(
            roundedRect: CGRect(x: 310, y: baselineY, width: 380, height: 8),
            cornerWidth: 4, cornerHeight: 4, transform: nil
        )
        ctx.addPath(baseline)
        ctx.setFillColor(rgb(0xFF, 0xFF, 0xFF, 0.32))
        ctx.fillPath()
        ctx.setFillColor(rgb(0xFF, 0xFF, 0xFF, 0.90))
        ctx.fillEllipse(in: CGRect(x: 706, y: baselineY - 7, width: 22, height: 22))
    }

    // ---- 5. The "N" letterform ----
    // Geometry chosen so the N fills the visual center, leaves
    // breathing room top/bottom (~24% of canvas), and has equal
    // weight in left vs right legs.
    let barTop: CGFloat = 220
    let barBottom: CGFloat = 760
    let barWidth: CGFloat = 92
    let leftBarX: CGFloat = 296
    let rightBarX: CGFloat = 636

    // Left leg — mic (mint green → cyan-white at top)
    drawVerticalBar(
        ctx,
        x: leftBarX, width: barWidth,
        top: barTop, bottom: barBottom,
        topColor:    rgb(0xD8, 0xFF, 0xF0),
        bottomColor: rgb(0x3C, 0xFF, 0xB6)
    )

    // Right leg — system audio (white → frosted violet at bottom)
    drawVerticalBar(
        ctx,
        x: rightBarX, width: barWidth,
        top: barTop, bottom: barBottom,
        topColor:    rgb(0xFF, 0xFF, 0xFF),
        bottomColor: rgb(0xC9, 0xA6, 0xFF)
    )

    // Diagonal connector — a parallelogram going top-LEFT → bottom-RIGHT,
    // joining the inner top of the left leg to the inner bottom of the
    // right leg. Filled with a subtle pearl-white gradient so it reads
    // as light catching a connecting beam rather than a flat slab.
    let diag = CGMutablePath()
    diag.move(to:    CGPoint(x: 372, y: 232))
    diag.addLine(to: CGPoint(x: 472, y: 232))
    diag.addLine(to: CGPoint(x: 692, y: 748))
    diag.addLine(to: CGPoint(x: 592, y: 748))
    diag.closeSubpath()
    ctx.saveGState()
    ctx.addPath(diag)
    ctx.clip()
    let diagGrad = CGGradient(
        colorsSpace: nil,
        colors: [
            rgb(0xFF, 0xFF, 0xFF),
            rgb(0xEA, 0xDA, 0xFF)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        diagGrad,
        start: CGPoint(x: 372, y: 232),
        end:   CGPoint(x: 692, y: 748),
        options: []
    )
    ctx.restoreGState()

    // ---- 6. REC dot (live-recording marker) ----
    let recCenter = CGPoint(x: 820, y: 204)
    // Halo
    let recGlow = CGGradient(
        colorsSpace: nil,
        colors: [
            rgb(0xFF, 0x3B, 0x30, 0.65),
            rgb(0xFF, 0x3B, 0x30, 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        recGlow,
        startCenter: recCenter,
        startRadius: 0,
        endCenter:   recCenter,
        endRadius: 105,
        options: []
    )
    // Solid core
    ctx.setFillColor(rgb(0xFF, 0x3B, 0x30))
    ctx.fillEllipse(in: CGRect(
        x: recCenter.x - 40, y: recCenter.y - 40,
        width: 80, height: 80
    ))
    // Inner specular (omit at small sizes to prevent crushed pixels)
    if smallFeatures {
        ctx.setFillColor(rgb(0xFF, 0xFF, 0xFF, 0.70))
        ctx.fillEllipse(in: CGRect(
            x: recCenter.x - 22, y: recCenter.y - 28,
            width: 22, height: 22
        ))
    }

    ctx.restoreGState() // pop squircle clip
}

// MARK: - Rasterization

func renderIcon(pixels px: Int) -> CGImage {
    let bytesPerRow = px * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        fatalError("Could not allocate CGContext at \(px)×\(px)")
    }

    // Flip so (0,0) is top-left, matching the design coordinates above.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)

    // Scale logical 1024 design space → output pixel size.
    let scale = CGFloat(px) / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // Drop fine details at the smallest two sizes — at 16/32 they
    // alias into a few muddy pixels rather than read as features.
    drawAt1024(ctx, smallFeatures: px >= 64)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(
            domain: "generate-appicon", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "PNG encode failed for \(path)"]
        )
    }
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Entrypoint

let fm = FileManager.default
let outDir = "Resources/AppIcon.iconset"
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for v in variants {
    let img = renderIcon(pixels: v.pixels)
    let path = "\(outDir)/\(v.fileName)"
    try writePNG(img, to: path)
    print("wrote \(path) (\(v.pixels)×\(v.pixels))")
}

print("done — now run: iconutil -c icns \(outDir) -o Resources/AppIcon.icns")
