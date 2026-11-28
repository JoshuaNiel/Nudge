import SwiftUI

/// "Rolling Hills": a row of little "n" arches on a baseline drifts left under the ball, which
/// rides over each one. The drift slows as the ball nears a crest, rests there a beat, then
/// speeds up down the far side and across the flat. Seamless loop; the ends fade out.
/// Reduce Motion: the row stands still with the ball on a crest, its opacity swelling slowly.
enum RollingHillsLoading {
    private static let baseline: CGFloat = 0.80
    private static let hillRadius: CGFloat = 0.30
    private static let flat: CGFloat = 0.30
    private static let stroke: CGFloat = 0.14
    private static let ballGap: CGFloat = 0.015

    private static var spacing: CGFloat { hillRadius * 2 + flat }

    static func draw(_ c: LoadingDrawContext) {
        let ballX = c.width / 2
        let ballRadius: CGFloat = c.isSmall ? 0.15 : 0.14

        let offset: CGFloat
        if c.reduceMotion {
            offset = 0
        } else {
            let p = LoadingMath.phase(c.time, period: LoadingIndicatorStyle.rollingHills.period)
            // Rest on the crest, then ease to the next one.
            offset = spacing * CGFloat(LoadingMath.easeInOutSine(LoadingMath.window(p, 0.18, 1)))
        }

        // Hill centers: one sits under the ball when offset == 0.
        let centers = (-3...3).map { ballX + CGFloat($0) * spacing - offset }

        var track = Path()
        track.move(to: CGPoint(x: -0.2, y: baseline))
        for cx in centers where cx > -spacing && cx < c.width + spacing {
            track.addLine(to: CGPoint(x: cx - hillRadius, y: baseline))
            track.addArc(tangent1End: CGPoint(x: cx - hillRadius, y: baseline - hillRadius),
                         tangent2End: CGPoint(x: cx, y: baseline - hillRadius),
                         radius: hillRadius)
            track.addArc(tangent1End: CGPoint(x: cx + hillRadius, y: baseline - hillRadius),
                         tangent2End: CGPoint(x: cx + hillRadius, y: baseline),
                         radius: hillRadius)
        }
        track.addLine(to: CGPoint(x: c.width + 0.2, y: baseline))

        // Fade both ends so hills drift in and out rather than pop.
        let solid = c.palette.solid
        let fade = Gradient(stops: [
            .init(color: solid.opacity(0), location: 0),
            .init(color: solid, location: 0.24),
            .init(color: solid, location: 0.76),
            .init(color: solid.opacity(0), location: 1),
        ])
        c.gc.stroke(track,
                    with: .linearGradient(fade, startPoint: .zero, endPoint: CGPoint(x: c.width, y: 0)),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))

        // The ball rests on whatever is highest under it: the flat, or a hill's outer edge.
        let reach = hillRadius + stroke / 2 + ballGap + ballRadius
        var ballY = baseline - stroke / 2 - ballGap - ballRadius
        for cx in centers {
            let dx = ballX - cx
            if abs(dx) < reach {
                ballY = min(ballY, baseline - sqrt(reach * reach - dx * dx))
            }
        }

        c.drawBall(at: CGPoint(x: ballX, y: ballY),
                   radius: ballRadius,
                   opacity: c.reduceMotion ? c.calmOpacity() : 1)
    }
}
