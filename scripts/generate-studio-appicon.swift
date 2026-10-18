#!/usr/bin/env swift
// scripts/generate-studio-appicon.swift — 2026-10-18.
//
// Renders the ntakker studio app icon with Core Graphics and writes
// `Resources/StudioAppIcon.iconset/` for `iconutil -c icns`. Same
// approach as `generate-appicon.swift` (ntakker's icon): no external
// tools, every size drawn from the same 1024 design.
//
// Design — "Listen & Read", a sibling of ntakker's "Pulse" icon:
//   * The same squircle, top-left highlight and vignette, in a cooler
//     midnight → ocean blue → teal gradient, so the two apps read as a
//     family but are told apart in the Dock.
//   * A frosted-glass panel: the studio's recording view.
//   * Top of the panel: a waveform. The part already played is ntakker's
//     mint (the mic colour); the rest is soft white. A red playhead —
//     ntakker's REC red — marks where you are listening.
//   * Bottom: three transcript lines, each led by a speaker dot (mint /
//     violet, ntakker's mic and system colours); the line being played is
//     highlighted, as in the studio.
//   * At 16 and 32 px the panel and the lines are dropped and the
//     waveform with its playhead fills the icon.
//
// Usage:
//   swift scripts/generate-studio-appicon.swift
//   iconutil -c icns Resources/StudioAppIcon.iconset -o Resources/StudioAppIcon.icns
//   (scripts/package-ntakker-studio-app.sh does both when the .icns is missing)

import AppKit
import CoreGraphics
import Foundation

struct IconVariant { let pixels: Int; let fileName: String }

let variants: [IconVariant] = [
    IconVariant(pixels: 16, fileName: "icon_16x16.png"),
    IconVariant(pixels: 32, fileName: "icon_16x16@2x.png"),
    IconVariant(pixels: 32, fileName: "icon_32x32.png"),
    IconVariant(pixels: 64, fileName: "icon_32x32@2x.png"),
    IconVariant(pixels: 128, fileName: "icon_128x128.png"),
    IconVariant(pixels: 256, fileName: "icon_128x128@2x.png"),
    IconVariant(pixels: 256, fileName: "icon_256x256.png"),
    IconVariant(pixels: 512, fileName: "icon_256x256@2x.png"),
    IconVariant(pixels: 512, fileName: "icon_512x512.png"),
    IconVariant(pixels: 1024, fileName: "icon_512x512@2x.png"),
]

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: locations)!
}

// The squircle used by ntakker's icon (cubic corners, offset r × 0.55).
func squirclePath(rect: CGRect, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height, c = r * 0.55
    p.move(to: CGPoint(x: x, y: y + r))
    p.addCurve(to: CGPoint(x: x + r, y: y), control1: CGPoint(x: x, y: y + r - c), control2: CGPoint(x: x + r - c, y: y))
    p.addLine(to: CGPoint(x: x + w - r, y: y))
    p.addCurve(to: CGPoint(x: x + w, y: y + r), control1: CGPoint(x: x + w - r + c, y: y), control2: CGPoint(x: x + w, y: y + r - c))
    p.addLine(to: CGPoint(x: x + w, y: y + h - r))
    p.addCurve(to: CGPoint(x: x + w - r, y: y + h), control1: CGPoint(x: x + w, y: y + h - r + c), control2: CGPoint(x: x + w - r + c, y: y + h))
    p.addLine(to: CGPoint(x: x + r, y: y + h))
    p.addCurve(to: CGPoint(x: x, y: y + h - r), control1: CGPoint(x: x + r - c, y: y + h), control2: CGPoint(x: x, y: y + h - r + c))
    p.closeSubpath()
    return p
}

func pill(_ ctx: CGContext, _ rect: CGRect, fill: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}

/// A vertical pill filled with a top → bottom gradient.
func gradientBar(_ ctx: CGContext, _ rect: CGRect, top: CGColor, bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width / 2, cornerHeight: rect.width / 2, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(gradient([top, bottom], [0, 1]),
                           start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    ctx.restoreGState()
}

// Waveform shape: relative bar heights (0…1), a recognisable speech-like
// envelope rather than a symmetric pattern.
let waveHeights: [CGFloat] = [0.30, 0.52, 0.78, 0.46, 0.92, 0.64, 1.00, 0.58, 0.84, 0.40, 0.70, 0.48, 0.26]
/// Fewer, thicker bars for 16 / 32 px, where thin bars blur together.
let smallWaveHeights: [CGFloat] = [0.40, 0.78, 0.56, 1.00, 0.66, 0.86, 0.42]

/// Waveform across [x0, x1], centred on `midY`, bars up to `maxHeight`.
/// Bars left of `playX` are "played" (mint), the rest soft white; the red
/// playhead is drawn at `playX`.
func drawWaveform(_ ctx: CGContext, heights: [CGFloat] = waveHeights, x0: CGFloat, x1: CGFloat, midY: CGFloat, maxHeight: CGFloat,
                  barWidth: CGFloat, playIndex: Int, playheadTop: CGFloat, playheadBottom: CGFloat,
                  playheadWidth: CGFloat, knob: CGFloat) {
    let n = heights.count
    let gap = (x1 - x0 - CGFloat(n) * barWidth) / CGFloat(n - 1)
    var playX: CGFloat = 0
    for (i, h) in heights.enumerated() {
        let x = x0 + CGFloat(i) * (barWidth + gap)
        let height = max(barWidth, maxHeight * h)
        let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
        if i < playIndex {
            gradientBar(ctx, rect, top: rgb(0xE0, 0xFF, 0xF3), bottom: rgb(0x3C, 0xFF, 0xB6))
        } else {
            gradientBar(ctx, rect, top: rgb(0xFF, 0xFF, 0xFF, 0.78), bottom: rgb(0xD6, 0xE4, 0xFF, 0.62))
        }
        if i == playIndex - 1 { playX = x + barWidth + gap / 2 }
    }
    // Playhead: a glow, the line, and a knob on top.
    let glowCenter = CGPoint(x: playX, y: (playheadTop + playheadBottom) / 2)
    ctx.drawRadialGradient(gradient([rgb(0xFF, 0x3B, 0x30, 0.22), rgb(0xFF, 0x3B, 0x30, 0)], [0, 1]),
                           startCenter: glowCenter, startRadius: 0, endCenter: glowCenter,
                           endRadius: (playheadBottom - playheadTop) * 0.36, options: [])
    pill(ctx, CGRect(x: playX - playheadWidth / 2, y: playheadTop, width: playheadWidth, height: playheadBottom - playheadTop),
         fill: rgb(0xFF, 0x3B, 0x30))
    ctx.setFillColor(rgb(0xFF, 0x3B, 0x30))
    ctx.fillEllipse(in: CGRect(x: playX - knob, y: playheadTop - knob, width: knob * 2, height: knob * 2))
    ctx.setFillColor(rgb(0xFF, 0xFF, 0xFF, 0.85))
    ctx.fillEllipse(in: CGRect(x: playX - knob * 0.42, y: playheadTop - knob * 0.42, width: knob * 0.84, height: knob * 0.84))
}

func drawAt1024(_ ctx: CGContext, smallFeatures: Bool) {
    let size: CGFloat = 1024
    ctx.saveGState()
    ctx.addPath(squirclePath(rect: CGRect(x: 0, y: 0, width: size, height: size), radius: 230))
    ctx.clip()

    // 1. Background: midnight → ocean blue → teal.
    ctx.drawLinearGradient(
        gradient([rgb(0x0A, 0x10, 0x3A), rgb(0x1E, 0x4F, 0xD8), rgb(0x12, 0xC2, 0xB0)], [0, 0.55, 1]),
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024), options: [])
    // 2. Top-left highlight and 3. bottom-right vignette (as ntakker's).
    ctx.drawRadialGradient(gradient([rgb(0xFF, 0xFF, 0xFF, 0.18), rgb(0xFF, 0xFF, 0xFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 300, y: 240), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 240), endRadius: 900, options: [])
    ctx.drawRadialGradient(gradient([rgb(0, 0, 0, 0), rgb(0x04, 0x10, 0x28, 0.16)], [0, 1]),
                           startCenter: CGPoint(x: 880, y: 880), startRadius: 360,
                           endCenter: CGPoint(x: 880, y: 880), endRadius: 980, options: [])

    guard smallFeatures else {
        // 16 / 32 px: the waveform and playhead alone, large.
        drawWaveform(ctx, heights: smallWaveHeights, x0: 150, x1: 874, midY: 540, maxHeight: 560, barWidth: 76,
                     playIndex: 4, playheadTop: 230, playheadBottom: 850, playheadWidth: 40, knob: 64)
        ctx.restoreGState()
        return
    }

    // 4. Frosted panel with a soft shadow.
    let panel = CGRect(x: 168, y: 216, width: 688, height: 600)
    let panelPath = CGPath(roundedRect: panel, cornerWidth: 84, cornerHeight: 84, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 60, color: rgb(0x02, 0x08, 0x24, 0.45))
    ctx.addPath(panelPath)
    ctx.setFillColor(rgb(0x0B, 0x1C, 0x52, 0.38))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(panelPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFF, 0xFF, 0xFF, 0.26), rgb(0xFF, 0xFF, 0xFF, 0.08)], [0, 1]),
                           start: CGPoint(x: panel.minX, y: panel.minY), end: CGPoint(x: panel.maxX, y: panel.maxY), options: [])
    ctx.restoreGState()
    ctx.addPath(panelPath)
    ctx.setStrokeColor(rgb(0xFF, 0xFF, 0xFF, 0.34))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // 5. Waveform with the playhead.
    drawWaveform(ctx, x0: 236, x1: 788, midY: 404, maxHeight: 236, barWidth: 30, playIndex: 7,
                 playheadTop: 262, playheadBottom: 548, playheadWidth: 14, knob: 26)

    // 6. Divider, then transcript lines with speaker dots; the second line
    //    (the one being played) highlighted.
    pill(ctx, CGRect(x: 236, y: 584, width: 552, height: 4), fill: rgb(0xFF, 0xFF, 0xFF, 0.22))
    let lines: [(y: CGFloat, width: CGFloat, dot: CGColor, current: Bool)] = [
        (626, 440, rgb(0x3C, 0xFF, 0xB6), false),
        (684, 380, rgb(0xC9, 0xA6, 0xFF), true),
        (742, 300, rgb(0x3C, 0xFF, 0xB6), false),
    ]
    for line in lines {
        if line.current {
            pill(ctx, CGRect(x: 214, y: line.y - 24, width: 596, height: 48), fill: rgb(0xFF, 0xFF, 0xFF, 0.16))
        }
        ctx.setFillColor(line.dot)
        ctx.fillEllipse(in: CGRect(x: 244, y: line.y - 12, width: 24, height: 24))
        pill(ctx, CGRect(x: 292, y: line.y - 11, width: line.width, height: 22),
             fill: rgb(0xFF, 0xFF, 0xFF, line.current ? 0.95 : 0.62))
    }

    ctx.restoreGState()
}

func renderIcon(pixels px: Int) -> CGImage {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not allocate CGContext at \(px)×\(px)")
    }
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    let scale = CGFloat(px) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    drawAt1024(ctx, smallFeatures: px >= 64)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "generate-studio-appicon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed for \(path)"])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/StudioAppIcon.iconset"
try? FileManager.default.removeItem(atPath: outDir)
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for v in variants {
    try writePNG(renderIcon(pixels: v.pixels), to: "\(outDir)/\(v.fileName)")
    print("wrote \(outDir)/\(v.fileName) (\(v.pixels)×\(v.pixels))")
}
print("done — now run: iconutil -c icns \(outDir) -o Resources/StudioAppIcon.icns")
