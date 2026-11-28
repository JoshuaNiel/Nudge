import SwiftUI

/// "Tipping Point": the app icon come alive. The yellow ball climbs the left shoulder of the
/// "n", slows to a stop on the crest, gets a small push (a little swell), then rolls down the
/// right side, picking up speed, and fades out. Reduce Motion: the icon's resting pose, with
/// the ball's opacity swelling slowly.
enum TippingPointLoading {
    // Geometry in the icon's 1024-unit authoring space (design/app-icon/render.swift,
    // `TippingConcept`), so the glyph matches the icon exactly.
    private static let archCenter = CGPoint(x: 512, y: 520)
    private static let archRadius: CGFloat = 182
    private static let stroke: CGFloat = 140
    private static let stemBottom: CGFloat = 800
    private static let ballGap: CGFloat = 6
    /// Icon pose: how far the ball sits past the crest.
    private static let restDegrees = 26.0

    /// The icon units that map onto the unit square (the glyph plus the ball's whole path).
    private static let viewCenter = CGPoint(x: 512, y: 498)
    private static let viewSpan: CGFloat = 760

    static func draw(_ c: LoadingDrawContext) {
        var c = c
        c.gc.translateBy(x: 0.5, y: 0.5)
        c.gc.scaleBy(x: 1 / viewSpan, y: 1 / viewSpan)
        c.gc.translateBy(x: -viewCenter.x, y: -viewCenter.y)

        let glyphTop = archCenter.y - archRadius - stroke / 2
        let glyphBottom = stemBottom + stroke / 2
        c.gc.stroke(glyphPath(),
                    with: c.palette.primaryShading(top: glyphTop, bottom: glyphBottom),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))

        // The ball is a little larger at the small size so it still reads at ~22pt.
        let ballRadius: CGFloat = c.isSmall ? 78 : 68
        let ballDistance = archRadius + stroke / 2 + ballGap + ballRadius

        guard !c.reduceMotion else {
            c.drawBall(at: LoadingMath.polar(archCenter, ballDistance, restDegrees),
                       radius: ballRadius,
                       opacity: c.calmOpacity())
            return
        }

        let p = LoadingMath.phase(c.time, period: LoadingIndicatorStyle.tippingPoint.period)
        let degrees: Double
        if p < 0.42 {
            // Climb: rolls in from the left shoulder, slowing to a stop on the crest.
            degrees = LoadingMath.lerp(-62, 0, LoadingMath.easeOutQuad(LoadingMath.window(p, 0, 0.42)))
        } else if p < 0.56 {
            degrees = 0 // the tipping point
        } else {
            // Over the edge: starts gently, picks up speed.
            degrees = LoadingMath.lerp(0, 68, LoadingMath.easeInQuad(LoadingMath.window(p, 0.56, 1)))
        }

        // The nudge: a small swell just before it tips.
        let nudge = sin(.pi * LoadingMath.window(p, 0.48, 0.6)) * 0.1
        let appear = LoadingMath.easeOutCubic(LoadingMath.window(p, 0, 0.12))
        let leave = 1 - LoadingMath.window(p, 0.8, 1)
        let scale = CGFloat((0.6 + 0.4 * appear) * (1 + nudge))

        c.drawBall(at: LoadingMath.polar(archCenter, ballDistance, degrees),
                   radius: ballRadius * scale,
                   opacity: appear * leave)
    }

    /// The "n": left stem, arch, right stem, as one centerline stroked with round caps.
    private static func glyphPath() -> Path {
        let left = archCenter.x - archRadius
        let right = archCenter.x + archRadius
        let top = archCenter.y - archRadius
        var path = Path()
        path.move(to: CGPoint(x: left, y: stemBottom))
        path.addLine(to: CGPoint(x: left, y: archCenter.y))
        path.addArc(tangent1End: CGPoint(x: left, y: top),
                    tangent2End: CGPoint(x: archCenter.x, y: top),
                    radius: archRadius)
        path.addArc(tangent1End: CGPoint(x: right, y: top),
                    tangent2End: CGPoint(x: right, y: archCenter.y),
                    radius: archRadius)
        path.addLine(to: CGPoint(x: right, y: stemBottom))
        return path
    }
}
