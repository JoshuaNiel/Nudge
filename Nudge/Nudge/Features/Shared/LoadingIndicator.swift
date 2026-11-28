import SwiftUI

// Nudge-branded loading indicator (docs/specs/phase-2-dashboard.md §V7). The app's one
// indeterminate spinner: use it everywhere instead of `ProgressView()`.
//
//   NudgeLoadingIndicator()                         // full screen / list / empty state (64pt)
//   NudgeLoadingIndicator(size: .small)             // inline in a row or toolbar (22pt)
//   Text("Save").replacedByLoadingIndicator(while: isSaving, tone: .onFilled)  // button label
//   Text("Saving…").prefixedByLoadingIndicator(while: isSaving)                 // beside a label
//
// Tipping Point is the style. Rolling Hills is kept for possible later use; each style's
// drawing lives in its own `LoadingIndicator+<Style>.swift` file.
//
// Cost: one `Canvas` driven by `TimelineView(.animation)`, pure math per frame. The timeline
// only ticks while the view is on screen, pauses in the background, and drops to 20 fps for
// the Reduce Motion fallback (a slow opacity change only). No timers, no state.

// MARK: - Brand colours

/// Brand colours from the shipped app icon, concept 3 "Tipping point"
/// (`design/app-icon/render.swift`, `TippingConcept.palette`). Light-mode teals are
/// deepened slightly so the shapes keep their contrast on white and grouped backgrounds.
enum NudgeBrand {
    // Teal. Icon light background runs 0x19C6A7 -> 0x0B5E78; icon dark glyph runs 0x7FF3D8 -> 0x2CC9AE.
    static let tealLight = rgb(0x19C6A7)       // icon light bg (top)
    static let tealDeepLight = rgb(0x0C8C86)   // between icon light bg top and bottom (0x0B5E78)
    static let tealSolidLight = rgb(0x11A592)
    static let tealDark = rgb(0x7FF3D8)        // icon dark glyph (top)
    static let tealDeepDark = rgb(0x2CC9AE)    // icon dark glyph (bottom)
    static let tealSolidDark = rgb(0x4FDDC0)

    // Yellow ball. Icon light ball 0xFFD25A -> 0xFF9F2E; dark ball 0xFFD866 -> 0xFFA436.
    static let ballLight = rgb(0xFFCC4D)       // icon light ball, a touch deeper to read on white
    static let ballDeepLight = rgb(0xFF9A2A)
    static let ballDark = rgb(0xFFD866)        // icon dark ball
    static let ballDeepDark = rgb(0xFFA436)

    /// An sRGB colour from a 0xRRGGBB literal.
    static func rgb(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: opacity)
    }
}

// MARK: - Public API

enum LoadingIndicatorStyle {
    /// The app icon come alive: the ball climbs the "n", pauses at the top, and tips over.
    /// The app's loading indicator.
    case tippingPoint
    /// A row of little "n" hills drifts by while the ball crests one, then the next.
    /// Not used yet; kept for later.
    case rollingHills

    /// Width / height of the drawing.
    var aspectRatio: CGFloat {
        switch self {
        case .tippingPoint: 1
        case .rollingHills: 1.6
        }
    }

    /// Length of one loop, in seconds.
    var period: Double {
        switch self {
        case .tippingPoint: 2.4
        case .rollingHills: 2.0
        }
    }

    fileprivate func draw(_ c: LoadingDrawContext) {
        switch self {
        case .tippingPoint: TippingPointLoading.draw(c)
        case .rollingHills: RollingHillsLoading.draw(c)
        }
    }
}

enum LoadingIndicatorSize {
    /// Inline: in a row, a toolbar or a button label.
    case small
    /// Full screen, a list, or an empty state, centered.
    case large

    var height: CGFloat {
        switch self {
        case .small: 22
        case .large: 64
        }
    }
}

enum LoadingIndicatorTone {
    /// Teal and yellow, for system and grouped backgrounds and non-filled buttons.
    case brand
    /// Monochrome white, for a filled (accent-coloured) button.
    case onFilled
}

/// The Nudge loading indicator, in place of `ProgressView()`. Reads as "Loading" to VoiceOver.
struct NudgeLoadingIndicator: View {
    var style: LoadingIndicatorStyle = .tippingPoint
    var size: LoadingIndicatorSize = .large
    var tone: LoadingIndicatorTone = .brand
    /// Forces Reduce Motion on or off, for previews. `nil` (the default) follows the system.
    var reduceMotion: Bool? = nil

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let still = reduceMotion ?? systemReduceMotion
        // The fallback only fades slowly, so 20 fps is plenty.
        TimelineView(.animation(minimumInterval: still ? 1.0 / 20 : nil,
                                paused: scenePhase == .background)) { timeline in
            LoadingIndicatorFrame(style: style,
                                  size: size,
                                  tone: tone,
                                  reduceMotion: still,
                                  time: timeline.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: size.height * style.aspectRatio, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

extension View {
    /// While `isLoading`, hides this button label and shows a small loading indicator over it.
    /// The label keeps its size, so the button never changes height, and VoiceOver reads the
    /// button as "Loading" instead of the hidden label. Use `.onFilled` on a filled button.
    func replacedByLoadingIndicator(while isLoading: Bool,
                                    tone: LoadingIndicatorTone = .brand) -> some View {
        modifier(LoadingLabelReplacement(isLoading: isLoading, tone: tone))
    }

    /// While `isLoading`, shows a small loading indicator before this label (like a spinner in
    /// an `HStack`) without making it taller. For labels that already say what is happening
    /// ("Saving…"), so the indicator is hidden from VoiceOver. Use `.onFilled` on a filled button.
    func prefixedByLoadingIndicator(while isLoading: Bool,
                                    tone: LoadingIndicatorTone = .brand) -> some View {
        modifier(LoadingLabelPrefix(isLoading: isLoading, tone: tone))
    }
}

private struct LoadingLabelReplacement: ViewModifier {
    let isLoading: Bool
    let tone: LoadingIndicatorTone

    func body(content: Content) -> some View {
        content
            .opacity(isLoading ? 0 : 1)
            .accessibilityHidden(isLoading)
            .overlay {
                if isLoading {
                    NudgeLoadingIndicator(size: .small, tone: tone)
                }
            }
    }
}

private struct LoadingLabelPrefix: ViewModifier {
    let isLoading: Bool
    let tone: LoadingIndicatorTone

    private static let spacing: CGFloat = 8

    func body(content: Content) -> some View {
        // Reserve the indicator's width only; as an overlay it adds no height.
        content
            .padding(.leading, isLoading ? LoadingIndicatorSize.small.height + Self.spacing : 0)
            .overlay(alignment: .leading) {
                if isLoading {
                    NudgeLoadingIndicator(size: .small, tone: tone)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// One still frame of an indicator at `time` (seconds). Pure: the same inputs draw the same
/// picture, which keeps it testable and snapshot-able.
struct LoadingIndicatorFrame: View {
    let style: LoadingIndicatorStyle
    let size: LoadingIndicatorSize
    let tone: LoadingIndicatorTone
    let reduceMotion: Bool
    let time: Double

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = LoadingPalette(colorScheme: colorScheme, tone: tone)
        Canvas { context, canvasSize in
            // Unit space: height 1, width = aspect ratio. Line widths scale with it.
            let unit = canvasSize.height
            guard unit > 0 else { return }
            context.scaleBy(x: unit, y: unit)
            style.draw(LoadingDrawContext(gc: context,
                                          width: canvasSize.width / unit,
                                          time: time,
                                          reduceMotion: reduceMotion,
                                          isSmall: size == .small,
                                          palette: palette))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Drawing support (shared by the styles)

struct LoadingPalette {
    let primary: Color       // top of the teal gradient
    let primaryDeep: Color   // bottom of the teal gradient
    let solid: Color         // single teal, for horizontal fades
    let ball: Color          // top-left of the ball
    let ballDeep: Color      // bottom-right of the ball

    init(colorScheme: ColorScheme, tone: LoadingIndicatorTone) {
        switch (tone, colorScheme) {
        case (.onFilled, _):
            primary = .white.opacity(0.8)
            primaryDeep = .white.opacity(0.7)
            solid = .white.opacity(0.75)
            ball = .white
            ballDeep = .white
        case (.brand, .dark):
            primary = NudgeBrand.tealDark
            primaryDeep = NudgeBrand.tealDeepDark
            solid = NudgeBrand.tealSolidDark
            ball = NudgeBrand.ballDark
            ballDeep = NudgeBrand.ballDeepDark
        default:
            primary = NudgeBrand.tealLight
            primaryDeep = NudgeBrand.tealDeepLight
            solid = NudgeBrand.tealSolidLight
            ball = NudgeBrand.ballLight
            ballDeep = NudgeBrand.ballDeepLight
        }
    }

    /// Vertical teal gradient across `top...bottom` (unit space).
    func primaryShading(top: CGFloat = 0, bottom: CGFloat = 1) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [primary, primaryDeep]),
                        startPoint: CGPoint(x: 0, y: top),
                        endPoint: CGPoint(x: 0, y: bottom))
    }
}

struct LoadingDrawContext {
    /// Already scaled so one unit is the indicator's height.
    var gc: GraphicsContext
    /// Drawing width in units (the style's aspect ratio).
    let width: CGFloat
    let time: Double
    let reduceMotion: Bool
    let isSmall: Bool
    let palette: LoadingPalette

    /// The yellow ball, lit from the top left.
    func drawBall(at center: CGPoint, radius: CGFloat, opacity: Double = 1) {
        guard radius > 0, opacity > 0 else { return }
        var g = gc
        g.opacity *= opacity
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        g.fill(Path(ellipseIn: rect),
               with: .linearGradient(Gradient(colors: [palette.ball, palette.ballDeep]),
                                     startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                     endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    /// Opacity for the Reduce Motion fallback: a slow, gentle swell between `low` and 1.
    func calmOpacity(low: Double = 0.65, period: Double = 2.8) -> Double {
        low + (1 - low) * LoadingMath.wave(time, period: period)
    }
}

enum LoadingMath {
    /// Position within a loop, 0..<1.
    static func phase(_ time: Double, period: Double) -> Double {
        let p = time.truncatingRemainder(dividingBy: period) / period
        return p < 0 ? p + 1 : p
    }

    /// Smooth 0 -> 1 -> 0 over one period.
    static func wave(_ time: Double, period: Double) -> Double {
        0.5 - 0.5 * cos(2 * .pi * phase(time, period: period))
    }

    /// Progress of `p` through the window `start...end`, clamped to 0...1.
    static func window(_ p: Double, _ start: Double, _ end: Double) -> Double {
        min(max((p - start) / (end - start), 0), 1)
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func easeInOutSine(_ t: Double) -> Double { 0.5 - 0.5 * cos(.pi * t) }
    static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func easeInQuad(_ t: Double) -> Double { t * t }
    static func easeOutQuad(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }

    /// Point on a circle; `degrees` run clockwise from 12 o'clock (y down).
    static func polar(_ center: CGPoint, _ radius: CGFloat, _ degrees: Double) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(r)), y: center.y - radius * CGFloat(cos(r)))
    }
}

// MARK: - Previews

#Preview("Tipping Point") {
    VStack(spacing: 28) {
        NudgeLoadingIndicator()
        NudgeLoadingIndicator(size: .small)
        Text("Save")
            .fontWeight(.semibold)
            .replacedByLoadingIndicator(while: true, tone: .onFilled)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    .padding(24)
}

#Preview("Dark, Reduce Motion") {
    VStack(spacing: 28) {
        NudgeLoadingIndicator(reduceMotion: true)
        NudgeLoadingIndicator(size: .small, reduceMotion: true)
    }
    .padding(24)
    .background(Color.black)
    .environment(\.colorScheme, .dark)
}

#Preview("Rolling Hills (kept for later)") {
    VStack(spacing: 28) {
        NudgeLoadingIndicator(style: .rollingHills)
        NudgeLoadingIndicator(style: .rollingHills, size: .small)
    }
    .padding(24)
}
