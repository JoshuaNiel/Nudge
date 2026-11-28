// Nudge app-icon renderer.
//
// Usage:
//   swift render.swift                          # all concepts, all variants, + contact sheets
//   swift render.swift --concept 1 --variant dark
//   swift render.swift --variant all --sheet --out ./out
//
// Flags:
//   --concept 1|2|3|all   (default all)
//   --variant light|dark|tinted|all   (default all)
//   --out <dir>           (default: directory of this script / cwd)
//   --size <px>           (default 1024)
//   --sheet               also (re)build contact-sheet.png and variants-sheet.png
//   --no-sheet            skip sheets (default when --concept or --variant is passed)
//
// Output: concept-N.png (light), concept-N-dark.png, concept-N-tinted.png
// All icon PNGs are opaque sRGB squares with no corner rounding (iOS applies the mask).
//
// Geometry is authored on a 1024-unit canvas with a top-left origin (y grows down).
// Every color lives in a per-concept Palette chosen by Variant, so new variants only
// need a new palette entry.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Color helpers

struct RGBA {
    var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ hex: UInt32, alpha: CGFloat = 1) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
        a = alpha
    }
    init(gray: CGFloat, alpha: CGFloat = 1) { r = gray; g = gray; b = gray; a = alpha }
    func with(alpha: CGFloat) -> RGBA { var c = self; c.a = alpha; return c }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(RGBA, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB,
               colors: stops.map { $0.0.cg } as CFArray,
               locations: stops.map { $0.1 })!
}

func gradient(_ a: RGBA, _ b: RGBA) -> CGGradient { gradient([(a, 0), (b, 1)]) }

// MARK: - Geometry helpers (top-left origin, angles in degrees clockwise from 12 o'clock)

let U: CGFloat = 1024 // authoring units

func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }

/// Point on a circle, angle measured clockwise from 12 o'clock (screen space, y down).
func polar(_ c: CGPoint, _ r: CGFloat, _ deg: CGFloat) -> CGPoint {
    CGPoint(x: c.x + r * sin(rad(deg)), y: c.y - r * cos(rad(deg)))
}

/// Arc path from `from` to `to` degrees (clockwise on screen, 12 o'clock = 0).
func arcPath(_ c: CGPoint, _ r: CGFloat, from: CGFloat, to: CGFloat) -> CGPath {
    let p = CGMutablePath()
    // In a y-down space, increasing math angle runs clockwise on screen.
    p.addArc(center: c, radius: r, startAngle: rad(from - 90), endAngle: rad(to - 90), clockwise: false)
    return p
}

func circlePath(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func rotated(_ path: CGPath, around c: CGPoint, deg: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: rad(deg)).translatedBy(x: -c.x, y: -c.y)
    return path.copy(using: &t)!
}

// MARK: - Drawing helpers

/// Fill `path` with a linear gradient between two points.
func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: RGBA) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setFillColor(color.cg)
    ctx.fillPath()
    ctx.restoreGState()
}

/// Soft drop shadow cast by `path`. The shape is filled with a throwaway color; the real
/// fill drawn afterwards covers it, leaving only the shadow visible.
/// `dy` is in top-left units (positive = down); CG shadow offsets are in device space (y up).
func shadow(_ ctx: CGContext, _ path: CGPath, color: RGBA, blur: CGFloat, dy: CGFloat, scale: CGFloat) {
    guard color.a > 0 else { return }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: color.cg)
    ctx.addPath(path)
    ctx.setFillColor(RGBA(0x000000, alpha: 1).cg)
    ctx.fillPath()
    ctx.restoreGState()
}

/// Background: diagonal linear gradient plus a soft radial glow, edge to edge.
struct Background {
    var top: RGBA          // top-left
    var bottom: RGBA       // bottom-right
    var glow: RGBA         // radial highlight (alpha used as strength)
    var glowCenter = CGPoint(x: 300, y: 220)
    var glowRadius: CGFloat = 760
}

func drawBackground(_ ctx: CGContext, _ bg: Background) {
    let full = CGRect(x: 0, y: 0, width: U, height: U)
    ctx.setFillColor(bg.bottom.cg)
    ctx.fill(full)
    ctx.drawLinearGradient(gradient(bg.top, bg.bottom),
                           start: CGPoint(x: 120, y: 0), end: CGPoint(x: 904, y: U), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    if bg.glow.a > 0 {
        ctx.drawRadialGradient(gradient(bg.glow, bg.glow.with(alpha: 0)),
                               startCenter: bg.glowCenter, startRadius: 0,
                               endCenter: bg.glowCenter, endRadius: bg.glowRadius, options: [])
    }
}

// MARK: - Variants

enum Variant: String, CaseIterable {
    case light, dark, tinted
    var suffix: String { self == .light ? "" : "-\(rawValue)" }
}

protocol Concept {
    var number: Int { get }
    func draw(_ ctx: CGContext, variant: Variant, scale: CGFloat)
}

// MARK: - Concept 1: Ring + nudge

struct RingConcept: Concept {
    let number = 1

    struct Palette {
        var bg: Background
        var track: RGBA
        var ringA: RGBA, ringB: RGBA     // progress gradient (top -> bottom)
        var dotA: RGBA, dotB: RGBA       // nudge dot gradient
        var shadow: RGBA
        var motion: RGBA
    }

    static func palette(_ v: Variant) -> Palette {
        switch v {
        case .light:
            return Palette(
                bg: Background(top: RGBA(0x5B3BF5), bottom: RGBA(0x1F1466), glow: RGBA(0xA48BFF, alpha: 0.35)),
                track: RGBA(0xFFFFFF, alpha: 0.16),
                ringA: RGBA(0xFFFFFF), ringB: RGBA(0xE4DCFF),
                dotA: RGBA(0xFFB36B), dotB: RGBA(0xFF6A55),
                shadow: RGBA(0x0B0630, alpha: 0.45),
                motion: RGBA(0xFFFFFF, alpha: 0.55))
        case .dark:
            return Palette(
                bg: Background(top: RGBA(0x1C1540), bottom: RGBA(0x07051A), glow: RGBA(0x5B3BF5, alpha: 0.30)),
                track: RGBA(0xFFFFFF, alpha: 0.10),
                ringA: RGBA(0xC9BBFF), ringB: RGBA(0x8E74FF),
                dotA: RGBA(0xFFC07A), dotB: RGBA(0xFF7660),
                shadow: RGBA(0x000000, alpha: 0.5),
                motion: RGBA(0xC9BBFF, alpha: 0.55))
        case .tinted:
            return Palette(
                bg: Background(top: RGBA(0x000000), bottom: RGBA(0x000000), glow: RGBA(0x000000, alpha: 0)),
                track: RGBA(gray: 1, alpha: 0.18),
                ringA: RGBA(gray: 0.80), ringB: RGBA(gray: 0.72),
                dotA: RGBA(gray: 1), dotB: RGBA(gray: 1),
                shadow: RGBA(0x000000, alpha: 0),
                motion: RGBA(gray: 1, alpha: 0.6))
        }
    }

    // Geometry
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 290
    let width: CGFloat = 116
    let startDeg: CGFloat = 0
    let progress: CGFloat = 0.76
    let dotRadius: CGFloat = 64
    let dotGap: CGFloat = 12

    func draw(_ ctx: CGContext, variant: Variant, scale: CGFloat) {
        let p = Self.palette(variant)
        drawBackground(ctx, p.bg)

        // Track (full ring)
        let track = circlePath(center, radius).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
        fill(ctx, track, p.track)

        // Progress arc
        let endDeg = startDeg + 360 * progress
        let arc = arcPath(center, radius, from: startDeg, to: endDeg)
            .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
        shadow(ctx, arc, color: p.shadow, blur: 40, dy: 16, scale: scale)
        fill(ctx, arc, gradient(p.ringA, p.ringB), from: CGPoint(x: 512, y: 200), to: CGPoint(x: 512, y: 830))

        // Nudge dot: sits just ahead of the leading cap, tangent to the ring path.
        let capDeg = (width / 2) / radius * 180 / .pi
        let dotDeg = endDeg + capDeg + (dotRadius + dotGap) / radius * 180 / .pi
        let dotC = polar(center, radius, dotDeg)
        let dot = circlePath(dotC, dotRadius)
        shadow(ctx, dot, color: p.shadow, blur: 26, dy: 10, scale: scale)
        fill(ctx, dot, gradient(p.dotA, p.dotB),
             from: CGPoint(x: dotC.x - dotRadius, y: dotC.y - dotRadius),
             to: CGPoint(x: dotC.x + dotRadius, y: dotC.y + dotRadius))

        // Speed lines trailing the dot, concentric with the ring: the dot is moving
        // toward the leading end, i.e. giving the ring a nudge.
        let degPerUnit = 180 / .pi / radius
        let trailStart = dotDeg + (dotRadius + 22) * degPerUnit
        for (offset, len) in [(CGFloat(-26), CGFloat(70)), (CGFloat(26), CGFloat(46))] {
            let arc = arcPath(center, radius + offset, from: trailStart, to: trailStart + len * degPerUnit)
            fill(ctx, arc.copy(strokingWithWidth: motionWidth, lineCap: .round, lineJoin: .round, miterLimit: 1), p.motion)
        }
    }

    let motionWidth: CGFloat = 16
}

// MARK: - Concept 2: Two friends (speech bubbles)

struct FriendsConcept: Concept {
    let number = 2

    struct Palette {
        var bg: Background
        var big: RGBA, bigB: RGBA        // left bubble gradient
        var small: RGBA, smallB: RGBA    // right bubble gradient
        var mark: RGBA                   // clock hands inside the big bubble
        var seam: RGBA                   // unused when gap is knocked out to background
        var shadow: RGBA
    }

    static func palette(_ v: Variant) -> Palette {
        switch v {
        case .light:
            return Palette(
                bg: Background(top: RGBA(0xFF8A5C), bottom: RGBA(0xE0336E), glow: RGBA(0xFFC58A, alpha: 0.35)),
                big: RGBA(0xFFFFFF), bigB: RGBA(0xFFEDE6),
                small: RGBA(0x4A1D5E), smallB: RGBA(0x2E0F40),
                mark: RGBA(0xF0506A),
                seam: RGBA(0x000000, alpha: 0),
                shadow: RGBA(0x5A0B2E, alpha: 0.35))
        case .dark:
            return Palette(
                bg: Background(top: RGBA(0x2A1020), bottom: RGBA(0x10060C), glow: RGBA(0xE0336E, alpha: 0.22)),
                big: RGBA(0xFF9A70), bigB: RGBA(0xF2557A),
                small: RGBA(0xFFE3D6), smallB: RGBA(0xFFC9B5),
                mark: RGBA(0x2A1020),
                seam: RGBA(0x000000, alpha: 0),
                shadow: RGBA(0x000000, alpha: 0.5))
        case .tinted:
            return Palette(
                bg: Background(top: RGBA(0x000000), bottom: RGBA(0x000000), glow: RGBA(0x000000, alpha: 0)),
                big: RGBA(gray: 1), bigB: RGBA(gray: 0.92),
                small: RGBA(gray: 0.62), smallB: RGBA(gray: 0.56),
                mark: RGBA(gray: 0.0),
                seam: RGBA(0x000000, alpha: 0),
                shadow: RGBA(0x000000, alpha: 0))
        }
    }

    /// Round speech bubble: circle + swept tail, softened by inflating with a round stroke.
    /// `tailDeg` is where the tail points; `sweep` = +1 sweeps clockwise, -1 counter-clockwise.
    func bubble(center c: CGPoint, r: CGFloat, tailDeg: CGFloat, tailLen: CGFloat, sweep: CGFloat) -> CGPath {
        let soften: CGFloat = 12
        let rr = r - soften
        let circle = circlePath(c, rr)
        let p1 = polar(c, rr * 0.92, tailDeg - 30 * sweep)
        let p2 = polar(c, rr * 0.92, tailDeg + 14 * sweep)
        let tip = polar(c, rr + tailLen, tailDeg + 10 * sweep)
        let tail = CGMutablePath()
        tail.move(to: p1)
        // Outer edge: gently convex, continuing the circle's silhouette.
        tail.addQuadCurve(to: tip, control: polar(c, rr + tailLen * 0.62, tailDeg - 12 * sweep))
        // Inner edge: concave scoop back into the circle.
        tail.addQuadCurve(to: p2, control: polar(c, rr + tailLen * 0.08, tailDeg + 8 * sweep))
        tail.closeSubpath()
        let body = circle.union(tail)
        return body.union(body.copy(strokingWithWidth: 2 * soften, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }

    // Geometry
    let bigC = CGPoint(x: 414, y: 574), bigR: CGFloat = 232
    let smallC = CGPoint(x: 678, y: 364), smallR: CGFloat = 146
    let leanDeg: CGFloat = -12
    let seamWidth: CGFloat = 22

    func draw(_ ctx: CGContext, variant: Variant, scale: CGFloat) {
        let p = Self.palette(variant)
        drawBackground(ctx, p.bg)

        // Big bubble ("you"), tail bottom-left.
        let big = bubble(center: bigC, r: bigR, tailDeg: 222, tailLen: 84, sweep: 1)

        // Small bubble ("friend"), tail bottom-right, leaning into the big one's shoulder.
        let small = rotated(bubble(center: smallC, r: smallR, tailDeg: 142, tailLen: 60, sweep: -1),
                            around: smallC, deg: leanDeg)

        // Knock a seam out of the big bubble where the small one overlaps it.
        let seam = small.copy(strokingWithWidth: 2 * seamWidth, lineCap: .round, lineJoin: .round, miterLimit: 1).union(small)
        let bigCut = big.subtracting(seam)

        shadow(ctx, bigCut, color: p.shadow, blur: 44, dy: 18, scale: scale)
        fill(ctx, bigCut, gradient(p.big, p.bigB), from: CGPoint(x: 260, y: 330), to: CGPoint(x: 620, y: 820))

        // Clock hands inside the big bubble: the daily-limit mark.
        let handC = CGPoint(x: bigC.x - 10, y: bigC.y + 14)
        let hands = CGMutablePath()
        hands.move(to: polar(handC, 112, 0))
        hands.addLine(to: handC)
        hands.addLine(to: polar(handC, 80, 118))
        fill(ctx, hands.copy(strokingWithWidth: 48, lineCap: .round, lineJoin: .round, miterLimit: 1), p.mark)

        shadow(ctx, small, color: p.shadow, blur: 34, dy: 14, scale: scale)
        fill(ctx, small, gradient(p.small, p.smallB), from: CGPoint(x: 580, y: 210), to: CGPoint(x: 800, y: 520))
    }
}

// MARK: - Concept 3: Tipping point (lowercase "n" arch with a ball on its crest)

struct TippingConcept: Concept {
    let number = 3

    struct Palette {
        var bg: Background
        var glyph: RGBA, glyphB: RGBA    // the "n" (top -> bottom)
        var ballA: RGBA, ballB: RGBA
        var shadow: RGBA
    }

    static func palette(_ v: Variant) -> Palette {
        switch v {
        case .light:
            return Palette(
                bg: Background(top: RGBA(0x19C6A7), bottom: RGBA(0x0B5E78), glow: RGBA(0x8CF2D8, alpha: 0.30)),
                glyph: RGBA(0xFFFBF2), glyphB: RGBA(0xFFEBCC),
                ballA: RGBA(0xFFD25A), ballB: RGBA(0xFF9F2E),
                shadow: RGBA(0x032E3B, alpha: 0.40))
        case .dark:
            return Palette(
                bg: Background(top: RGBA(0x0C2A2C), bottom: RGBA(0x041214), glow: RGBA(0x19C6A7, alpha: 0.20)),
                glyph: RGBA(0x7FF3D8), glyphB: RGBA(0x2CC9AE),
                ballA: RGBA(0xFFD866), ballB: RGBA(0xFFA436),
                shadow: RGBA(0x000000, alpha: 0.5))
        case .tinted:
            return Palette(
                bg: Background(top: RGBA(0x000000), bottom: RGBA(0x000000), glow: RGBA(0x000000, alpha: 0)),
                glyph: RGBA(gray: 0.80), glyphB: RGBA(gray: 0.72),
                ballA: RGBA(gray: 1), ballB: RGBA(gray: 1),
                shadow: RGBA(0x000000, alpha: 0))
        }
    }

    // Geometry
    let archC = CGPoint(x: 512, y: 520)
    let archR: CGFloat = 182          // centerline radius of the arch
    let stroke: CGFloat = 140
    let stemBottom: CGFloat = 800     // centerline y where the stems end (round caps add stroke/2)
    let spur: CGFloat = 0.0           // extra left-stem height above the arch spring (fraction of archR)
    let ballR: CGFloat = 68
    let ballDeg: CGFloat = 26         // how far the ball has been nudged off the crest
    let ballGap: CGFloat = 6

    func glyphPath() -> CGPath {
        let x0 = archC.x - archR, x1 = archC.x + archR
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x0, y: stemBottom))
        p.addLine(to: CGPoint(x: x0, y: archC.y))
        p.addArc(center: archC, radius: archR, startAngle: .pi, endAngle: 0, clockwise: false)
        p.addLine(to: CGPoint(x: x1, y: stemBottom))
        var body = p.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 1)
        if spur > 0 {
            let s = CGMutablePath()
            s.move(to: CGPoint(x: x0, y: archC.y))
            s.addLine(to: CGPoint(x: x0, y: archC.y - archR * spur))
            body = body.union(s.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 1))
        }
        return body
    }

    func draw(_ ctx: CGContext, variant: Variant, scale: CGFloat) {
        let p = Self.palette(variant)
        drawBackground(ctx, p.bg)

        let glyph = glyphPath()
        shadow(ctx, glyph, color: p.shadow, blur: 44, dy: 18, scale: scale)
        fill(ctx, glyph, gradient(p.glyph, p.glyphB),
             from: CGPoint(x: 0, y: archC.y - archR - stroke / 2), to: CGPoint(x: 0, y: stemBottom + stroke / 2))

        // The ball rests on the outer edge of the arch, nudged past the crest.
        let ballC = polar(archC, archR + stroke / 2 + ballGap + ballR, ballDeg)
        let ball = circlePath(ballC, ballR)
        shadow(ctx, ball, color: p.shadow, blur: 28, dy: 12, scale: scale)
        fill(ctx, ball, gradient(p.ballA, p.ballB),
             from: CGPoint(x: ballC.x - ballR, y: ballC.y - ballR), to: CGPoint(x: ballC.x + ballR, y: ballC.y + ballR))
    }
}

// MARK: - Rendering / IO

func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Failed to write \(path)") }
}

func loadImage(_ path: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

func renderIcon(_ concept: Concept, _ variant: Variant, px: Int) -> CGImage {
    let ctx = makeContext(px)
    let s = CGFloat(px) / U
    // Flip to top-left origin in 1024 authoring units.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    concept.draw(ctx, variant: variant, scale: s)
    return ctx.makeImage()!
}

// MARK: - Contact sheets (review only; masked)

func iosMask(_ rect: CGRect) -> CGPath {
    // Approximate the iOS squircle with a continuous-ish rounded rect (radius ~22.37%).
    let r = rect.width * 0.2237
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

func drawMasked(_ ctx: CGContext, _ img: CGImage, in rect: CGRect) {
    ctx.saveGState()
    ctx.addPath(iosMask(rect))
    ctx.clip()
    ctx.interpolationQuality = .high
    // ctx is flipped (top-left); flip locally so the image is upright.
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
}

func drawLabel(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat, color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .semibold),
        .foregroundColor: color,
    ]
    NSAttributedString(string: text, attributes: attrs).draw(at: p)
    NSGraphicsContext.restoreGraphicsState()
}

func flippedContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func buildContactSheet(_ images: [CGImage], path: String) {
    let big: CGFloat = 1024, pad: CGFloat = 96, labelH: CGFloat = 110
    let smallRow: CGFloat = 120
    let colW = big
    let panelH = pad + labelH + big + 56 + smallRow + pad
    let W = Int(pad + CGFloat(images.count) * (colW + pad))
    let H = Int(panelH * 2)
    let ctx = flippedContext(width: W, height: H)
    let themes: [(bg: RGBA, fg: NSColor, name: String)] = [
        (RGBA(0xF2F2F7), NSColor(white: 0.1, alpha: 1), "Light"),
        (RGBA(0x0E0E10), NSColor(white: 0.92, alpha: 1), "Dark"),
    ]
    for (ti, theme) in themes.enumerated() {
        let y0 = CGFloat(ti) * panelH
        ctx.setFillColor(theme.bg.cg)
        ctx.fill(CGRect(x: 0, y: y0, width: CGFloat(W), height: panelH))
        for (i, img) in images.enumerated() {
            let x = pad + CGFloat(i) * (colW + pad)
            drawLabel(ctx, "\(i + 1)", at: CGPoint(x: x, y: y0 + pad - 10), size: 84, color: theme.fg)
            drawLabel(ctx, theme.name, at: CGPoint(x: x + 90, y: y0 + pad + 30), size: 34, color: theme.fg.withAlphaComponent(0.5))
            let bigRect = CGRect(x: x, y: y0 + pad + labelH, width: big, height: big)
            drawMasked(ctx, img, in: bigRect)
            let sy = bigRect.maxY + 56
            drawMasked(ctx, img, in: CGRect(x: x, y: sy, width: 120, height: 120))
            drawMasked(ctx, img, in: CGRect(x: x + 120 + 48, y: sy + 30, width: 60, height: 60))
            drawMasked(ctx, img, in: CGRect(x: x + 120 + 48 + 60 + 48, y: sy + 40, width: 40, height: 40))
            drawLabel(ctx, "120 · 60 · 40 px", at: CGPoint(x: x + 360, y: sy + 38), size: 34, color: theme.fg.withAlphaComponent(0.5))
        }
    }
    savePNG(ctx.makeImage()!, path)
}

/// Grid of every concept x variant at 240px plus 60px, on a mid-gray backdrop.
func buildVariantsSheet(_ grid: [[CGImage]], path: String) {
    let cell: CGFloat = 240, pad: CGFloat = 48, small: CGFloat = 60
    let cols = grid.first?.count ?? 0
    let W = Int(pad + CGFloat(cols) * (cell + small + pad * 2))
    let H = Int(pad + CGFloat(grid.count) * (cell + pad) + 60)
    let ctx = flippedContext(width: W, height: H)
    ctx.setFillColor(RGBA(0x2C2C2E).cg)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for (ci, name) in ["light", "dark", "tinted"].prefix(cols).enumerated() {
        drawLabel(ctx, name, at: CGPoint(x: pad + CGFloat(ci) * (cell + small + pad * 2), y: 14), size: 30, color: .white)
    }
    for (r, row) in grid.enumerated() {
        for (c, img) in row.enumerated() {
            let x = pad + CGFloat(c) * (cell + small + pad * 2)
            let y = 60 + CGFloat(r) * (cell + pad)
            drawMasked(ctx, img, in: CGRect(x: x, y: y, width: cell, height: cell))
            drawMasked(ctx, img, in: CGRect(x: x + cell + pad / 2, y: y + cell - small, width: small, height: small))
        }
    }
    savePNG(ctx.makeImage()!, path)
}

// MARK: - CLI

let concepts: [Concept] = [RingConcept(), FriendsConcept(), TippingConcept()]

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let conceptArg = flag("--concept") ?? "all"
let variantArg = flag("--variant") ?? "all"
let px = Int(flag("--size") ?? "1024") ?? 1024
let outDir = flag("--out") ?? FileManager.default.currentDirectoryPath
let explicitSelection = args.contains("--concept") || args.contains("--variant")
let wantSheet = args.contains("--sheet") || (!explicitSelection && !args.contains("--no-sheet"))

let selectedConcepts = conceptArg == "all" ? concepts : concepts.filter { "\($0.number)" == conceptArg }
let selectedVariants: [Variant] = variantArg == "all" ? Variant.allCases : [Variant(rawValue: variantArg)].compactMap { $0 }
guard !selectedConcepts.isEmpty, !selectedVariants.isEmpty else {
    FileHandle.standardError.write("Unknown --concept or --variant\n".data(using: .utf8)!)
    exit(2)
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func iconPath(_ n: Int, _ v: Variant) -> String { "\(outDir)/concept-\(n)\(v.suffix).png" }

for c in selectedConcepts {
    for v in selectedVariants {
        let path = iconPath(c.number, v)
        savePNG(renderIcon(c, v, px: px), path)
        print("wrote \(path)")
    }
}

if wantSheet {
    let lights = concepts.map { renderIcon($0, .light, px: 1024) }
    buildContactSheet(lights, path: "\(outDir)/contact-sheet.png")
    print("wrote \(outDir)/contact-sheet.png")
    let grid = concepts.map { c in Variant.allCases.map { renderIcon(c, $0, px: 512) } }
    buildVariantsSheet(grid, path: "\(outDir)/variants-sheet.png")
    print("wrote \(outDir)/variants-sheet.png")
}
