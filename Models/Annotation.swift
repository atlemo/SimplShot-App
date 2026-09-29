import SwiftUI
import CoreText
import Vision

// MARK: - Tool Types

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case textSelect
    case arrow
    case freeDraw
    case highlight
    case measurement
    case angle
    case rectangle
    case circle
    case triangle
    case star
    case line
    case text
    case pixelate
    case spotlight
    case numberedStep
    case sticker
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select:       return String(localized: "Select")
        case .textSelect:   return String(localized: "Select Text")
        case .arrow:        return String(localized: "Arrow")
        case .freeDraw:     return String(localized: "Free Drawing")
        case .highlight:    return String(localized: "Highlight")
        case .measurement:  return String(localized: "Measurement")
        case .angle:        return String(localized: "Angle")
        case .rectangle:    return String(localized: "Rectangle")
        case .circle:       return String(localized: "Circle")
        case .triangle:     return String(localized: "Triangle")
        case .star:         return String(localized: "Star")
        case .line:         return String(localized: "Line")
        case .text:         return String(localized: "Text")
        case .pixelate:     return String(localized: "Pixelate")
        case .spotlight:    return String(localized: "Spotlight")
        case .numberedStep: return String(localized: "Steps")
        case .sticker:      return String(localized: "Sticker")
        case .crop:         return String(localized: "Crop")
        }
    }

    var systemImage: String {
        switch self {
        case .select:       return "cursorarrow"
        case .textSelect:   return "character.cursor.ibeam"
        case .arrow:        return "arrow.up.right"
        case .freeDraw:     return "pencil.and.scribble"
        case .highlight:    return "highlighter"
        case .measurement:  return "ruler"
        case .angle:        return "angle"
        case .rectangle:    return "rectangle"
        case .circle:       return "circle"
        case .triangle:     return "triangle"
        case .star:         return "star"
        case .line:         return "line.diagonal"
        case .text:         return "textformat"
        case .pixelate:     return ""       // uses customImageName instead
        case .spotlight:    return "light.overhead.left"
        case .numberedStep: return "1.circle.fill"
        case .sticker:      return "face.smiling"
        case .crop:         return "crop"
        }
    }

    /// Asset catalog image name for tools that use a custom icon instead of an SF Symbol.
    var customImageName: String? {
        switch self {
        case .pixelate: return "PixelateIcon"
        default:        return nil
        }
    }

    /// True for the four shape tools that share the shapes group button.
    var isShapeTool: Bool {
        self == .rectangle || self == .circle || self == .triangle || self == .star
    }
}

// MARK: - Arrow Style

enum ArrowStyle: String, CaseIterable {
    case chevron   // open V arrowhead (default)
    case triangle  // filled solid triangle tip
    case curved    // arc shaft with filled triangle tip
    case double    // filled triangle tips at both ends; straight until bent via mid handle
    case sketch    // hand-drawn: gritty ink ribbon (S-curve shaft, wide chevron flicks)

    var label: String {
        switch self {
        case .chevron:  return String(localized: "Arrow")
        case .triangle: return String(localized: "Filled")
        case .curved:   return String(localized: "Curved")
        case .double:   return String(localized: "Double")
        case .sketch:   return String(localized: "Sketch")
        }
    }

    /// Styles whose shaft bow is user-editable via the mid-curve handle.
    var supportsCurvature: Bool {
        self == .curved || self == .double
    }
}

// MARK: - Arrow Geometry

/// All curved/double arrow math in one place so the SwiftUI overlay, the CG
/// export renderer, and canvas hit-testing share identical geometry.
/// Coordinates are image-pixel space (top-left origin, y-down).
///
/// Curvature lives in the start→end local frame as a CGVector:
///   dx — position of the quad-bezier control point along the segment (0.5 = middle)
///   dy — perpendicular offset as a fraction of the segment length
///        (perpendicular axis = (d.y, −d.x) for segment direction d)
/// Because it is relative to the endpoints, the bow survives every whole-image
/// point transform (padding shift, crop remap, resize, rotate, straighten)
/// without any extra bookkeeping.
enum ArrowGeometry {
    /// Bow of the Curved style before the user drags the mid handle
    /// (matches the original hardcoded control-point formula).
    static let defaultCurvedBow: CGFloat = 0.3

    /// Head size/angle for the filled-triangle heads of curved/double arrows.
    static let headHalfAngle: CGFloat = .pi / 5

    static func headLength(lineWidth: CGFloat) -> CGFloat {
        max(lineWidth * 5, 16)
    }

    /// Quad-bezier control point for the given local-frame curvature.
    static func controlPoint(start: CGPoint, end: CGPoint, curvature: CGVector) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return CGPoint(x: start.x + curvature.dx * dx + curvature.dy * dy,
                       y: start.y + curvature.dx * dy - curvature.dy * dx)
    }

    /// The point on the curve at t = 0.5 — where the mid-curve handle sits.
    static func midPoint(start: CGPoint, end: CGPoint, curvature: CGVector) -> CGPoint {
        let c = controlPoint(start: start, end: end, curvature: curvature)
        return CGPoint(x: 0.25 * start.x + 0.5 * c.x + 0.25 * end.x,
                       y: 0.25 * start.y + 0.5 * c.y + 0.25 * end.y)
    }

    /// Local-frame curvature that makes the curve pass through `mid` at t = 0.5.
    /// Used when the user drags the mid handle: the curve stays under the cursor.
    static func curvature(start: CGPoint, end: CGPoint, passingThrough mid: CGPoint) -> CGVector {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0.001 else { return CGVector(dx: 0.5, dy: 0) }
        // Control point with B(0.5) == mid, expressed relative to start.
        let rx = 2 * mid.x - (start.x + end.x) / 2 - start.x
        let ry = 2 * mid.y - (start.y + end.y) / 2 - start.y
        return CGVector(dx: (rx * dx + ry * dy) / lenSq,
                        dy: (rx * dy - ry * dx) / lenSq)
    }

    /// The complete arrow — stroked-outline shaft plus filled head triangle(s) —
    /// as a single path to be painted with ONE fill. One paint op means no
    /// shaft/head seam and no double-darkening with translucent colors, and
    /// both the live preview and the export draw this exact path.
    static func fillPath(start: CGPoint, end: CGPoint, curvature: CGVector,
                         doubleEnded: Bool, lineWidth: CGFloat) -> CGPath {
        let control = controlPoint(start: start, end: end, curvature: curvature)
        let headLen = headLength(lineWidth: lineWidth)
        let depth = headLen * cos(headHalfAngle)

        func unit(from a: CGPoint, to b: CGPoint) -> CGPoint? {
            let d = hypot(b.x - a.x, b.y - a.y)
            guard d > 0.001 else { return nil }
            return CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d)
        }

        // Outward tip directions from the bezier tangents (t=1: end−control,
        // t=0: start−control), falling back to the chord for degenerate cases.
        let chord = unit(from: start, to: end) ?? CGPoint(x: 1, y: 0)
        let endDir = unit(from: control, to: end) ?? chord
        let startDir = unit(from: control, to: start) ?? CGPoint(x: -chord.x, y: -chord.y)

        // Trim the shaft to the head base(s) so the round cap sits inside the
        // triangle instead of bulging past the tip.
        let shaftEnd = CGPoint(x: end.x - endDir.x * depth, y: end.y - endDir.y * depth)
        let shaftStart = doubleEnded
            ? CGPoint(x: start.x - startDir.x * depth, y: start.y - startDir.y * depth)
            : start

        var result: CGPath
        let trimmedLength = hypot(end.x - start.x, end.y - start.y) - depth * (doubleEnded ? 2 : 1)
        if trimmedLength > 0.5 {
            let centerline = CGMutablePath()
            centerline.move(to: shaftStart)
            centerline.addQuadCurve(to: shaftEnd, control: control)
            result = centerline.copy(strokingWithWidth: lineWidth, lineCap: .round,
                                     lineJoin: .round, miterLimit: 10)
        } else {
            // Arrow too short for a shaft — heads only.
            result = CGMutablePath()
        }

        result = result.union(headPath(tip: end, direction: endDir, headLength: headLen), using: .winding)
        if doubleEnded {
            result = result.union(headPath(tip: start, direction: startDir, headLength: headLen), using: .winding)
        }
        return result
    }

    private static func headPath(tip: CGPoint, direction: CGPoint, headLength: CGFloat) -> CGPath {
        let angle = atan2(direction.y, direction.x)
        let p1 = CGPoint(x: tip.x - headLength * cos(angle - headHalfAngle),
                         y: tip.y - headLength * sin(angle - headHalfAngle))
        let p2 = CGPoint(x: tip.x - headLength * cos(angle + headHalfAngle),
                         y: tip.y - headLength * sin(angle + headHalfAngle))
        let head = CGMutablePath()
        head.move(to: tip)
        head.addLine(to: p1)
        head.addLine(to: p2)
        head.closeSubpath()
        return head
    }

    // MARK: Sketch style (gritty ink ribbon)

    /// Deterministic PRNG (SplitMix64). The sketch arrow's grit is generated
    /// from the annotation's seed, so it is stable across frames and identical
    /// in preview and export — no shimmer, no parity drift.
    private struct SketchRandom {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> CGFloat {   // uniform [0, 1)
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return CGFloat(z >> 11) / CGFloat(UInt64(1) << 53)
        }
        mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            lo + (hi - lo) * next()
        }
    }

    /// The whole sketch arrow — hand-drawn ink/charcoal look — as a single
    /// fillable path (paint with ONE fill, .winding). Instead of a uniform
    /// stroke, the shaft and head barbs are variable-width "ribbons": the width
    /// tapers like a real pen stroke and both edges wobble with smooth seeded
    /// noise. A thin offset overdraw strand adds charcoal-style striation.
    static func sketchPath(start: CGPoint, end: CGPoint, lineWidth: CGFloat, seed: UInt64) -> CGPath {
        let path = CGMutablePath()
        let len = hypot(end.x - start.x, end.y - start.y)
        guard len > 1 else {
            path.addEllipse(in: CGRect(x: start.x - lineWidth / 2, y: start.y - lineWidth / 2,
                                       width: lineWidth, height: lineWidth))
            return path
        }

        var rng = SketchRandom(seed: seed)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let dirX = cos(angle), dirY = sin(angle)
        let perpX = -dirY, perpY = dirX

        // Smooth ±1 pseudo-noise: two seeded sinusoids per channel.
        func makeWobble(_ rng: inout SketchRandom) -> (CGFloat) -> CGFloat {
            let f1 = rng.range(5, 8), p1 = rng.range(0, 2 * .pi)
            let f2 = rng.range(11, 16), p2 = rng.range(0, 2 * .pi)
            return { t in sin(t * f1 + p1) * 0.6 + sin(t * f2 + p2) * 0.4 }
        }
        let posWobble = makeWobble(&rng)     // edge roughness (position)
        let widthWobble = makeWobble(&rng)   // ink flow (width)

        func cubicPoint(_ t: CGFloat, _ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint) -> CGPoint {
            let mt = 1 - t
            let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x,
                           y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
        }

        // Closed variable-width polygon around a sampled centerline. All
        // ribbons are built with the same traversal (forward on +normal, back
        // on −normal) so their winding matches and overlaps fill solid.
        func addRibbon(centers: [CGPoint], widths: [CGFloat]) {
            guard centers.count >= 2 else { return }
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in centers.indices {
                let prev = centers[max(i - 1, 0)], next = centers[min(i + 1, centers.count - 1)]
                let dx = next.x - prev.x, dy = next.y - prev.y
                let d = max(hypot(dx, dy), 0.0001)
                let nx = -dy / d, ny = dx / d
                let h = widths[i] / 2
                left.append(CGPoint(x: centers[i].x + nx * h, y: centers[i].y + ny * h))
                right.append(CGPoint(x: centers[i].x - nx * h, y: centers[i].y - ny * h))
            }
            path.move(to: left[0])
            for pt in left.dropFirst() { path.addLine(to: pt) }
            for pt in right.reversed() { path.addLine(to: pt) }
            path.closeSubpath()
        }

        // Shaft: the classic subtle S-curve, with per-arrow bow variation.
        let bow1 = len * rng.range(0.05, 0.09)
        let bow2 = -len * rng.range(0.03, 0.07)
        let cp1 = CGPoint(x: start.x + dirX * len * 0.3 + perpX * bow1,
                          y: start.y + dirY * len * 0.3 + perpY * bow1)
        let cp2 = CGPoint(x: start.x + dirX * len * 0.7 + perpX * bow2,
                          y: start.y + dirY * len * 0.7 + perpY * bow2)
        let tip = CGPoint(x: end.x + perpX * lineWidth * rng.range(-0.2, 0.2),
                          y: end.y + perpY * lineWidth * rng.range(-0.2, 0.2))

        let posAmp = lineWidth * 0.22
        let shaftSamples = 28
        var centers: [CGPoint] = [], widths: [CGFloat] = []
        for i in 0...shaftSamples {
            let t = CGFloat(i) / CGFloat(shaftSamples)
            var pt = cubicPoint(t, start, cp1, cp2, tip)
            let jitter = posAmp * posWobble(t)
            pt.x += perpX * jitter
            pt.y += perpY * jitter
            // Ink profile: thin touch-down, fuller middle, easing off at the tip.
            let profile = 0.45 + 0.65 * pow(sin(.pi * (0.08 + 0.84 * t)), 0.9)
            let w = lineWidth * profile * (1 + 0.35 * widthWobble(t))
            centers.append(pt)
            widths.append(min(max(w, lineWidth * 0.25), lineWidth * 1.8))
        }
        addRibbon(centers: centers, widths: widths)

        // Overdraw strand: a thin second pass hugging the shaft — the parallel
        // striation that reads as charcoal/dry ink.
        let overWobble = makeWobble(&rng)
        let t0 = rng.range(0.06, 0.18), t1 = rng.range(0.72, 0.92)
        let side: CGFloat = rng.next() < 0.5 ? -1 : 1
        let strandOffset = side * lineWidth * rng.range(0.45, 0.8)
        var oCenters: [CGPoint] = [], oWidths: [CGFloat] = []
        let overSamples = 20
        for i in 0...overSamples {
            let u = CGFloat(i) / CGFloat(overSamples)
            let t = t0 + (t1 - t0) * u
            var pt = cubicPoint(t, start, cp1, cp2, tip)
            let jitter = strandOffset + posAmp * 0.7 * overWobble(t)
            pt.x += perpX * jitter
            pt.y += perpY * jitter
            // Taper the strand out at both ends so it fades in/out of the stroke.
            let taper = sin(.pi * u)
            oCenters.append(pt)
            oWidths.append(max(lineWidth * 0.3 * taper * (1 + 0.4 * overWobble(u + 3)), 0.1))
        }
        addRibbon(centers: oCenters, widths: oWidths)

        // Head barbs: wide chevron, each a tapered flick with its own angle,
        // length and bow jitter, anchored near (not exactly at) the tip.
        let headLen = max(lineWidth * 7, 20)
        for sign in [CGFloat(-1), 1] {
            let ha = (.pi / 5) * rng.range(0.85, 1.15)
            let bl = headLen * rng.range(0.9, 1.1)
            let barbAngle = angle + .pi + (-sign) * ha   // backward from tip, fanned out
            let bDirX = cos(barbAngle), bDirY = sin(barbAngle)
            let bPerpX = -bDirY, bPerpY = bDirX
            let root = CGPoint(x: tip.x + perpX * lineWidth * rng.range(-0.3, 0.3),
                               y: tip.y + perpY * lineWidth * rng.range(-0.3, 0.3))
            let bowAmt = bl * rng.range(-0.08, 0.08)
            let barbWobble = makeWobble(&rng)
            var bCenters: [CGPoint] = [], bWidths: [CGFloat] = []
            let barbSamples = 12
            for i in 0...barbSamples {
                let t = CGFloat(i) / CGFloat(barbSamples)
                // Quadratic bow via midpoint offset, plus edge roughness.
                let bow = bowAmt * 4 * t * (1 - t)
                let jitter = bow + lineWidth * 0.15 * barbWobble(t)
                let pt = CGPoint(x: root.x + bDirX * bl * t + bPerpX * jitter,
                                 y: root.y + bDirY * bl * t + bPerpY * jitter)
                // Flick: thickest where it leaves the tip, tapering outward.
                let w = lineWidth * (0.85 - 0.55 * t) * (1 + 0.3 * barbWobble(t + 5))
                bCenters.append(pt)
                bWidths.append(min(max(w, lineWidth * 0.2), lineWidth * 1.4))
            }
            addRibbon(centers: bCenters, widths: bWidths)
        }

        return path
    }
}

// MARK: - Angle (Protractor) Geometry

/// Shared math for the .angle tool so the SwiftUI overlay, the CG export
/// renderer, and hit-testing draw identical geometry.
/// Coordinates are image-pixel space (top-left origin, y-down).
///
/// An angle annotation is two rays from a vertex (`points[0]`) to
/// `startPoint` and `endPoint`; the measured value is the interior angle
/// (0–180°) between the rays, with the arc and label on the interior side.
enum AngleGeometry {
    /// Signed sweep (radians, shortest way) from ray vertex→a to ray vertex→b.
    /// Magnitude is the interior angle; sign gives the arc direction.
    static func sweep(a: CGPoint, vertex: CGPoint, b: CGPoint) -> CGFloat {
        let ang1 = atan2(a.y - vertex.y, a.x - vertex.x)
        let ang2 = atan2(b.y - vertex.y, b.x - vertex.x)
        let delta = atan2(sin(ang2 - ang1), cos(ang2 - ang1))
        // Near-collinear the interior side is numerically ambiguous: ±180°
        // flips with sub-pixel jitter (e.g. while the creation drag holds the
        // vertex at the exact midpoint), making the arc and label flicker
        // between sides. Canonicalize to +π for a stable side.
        if delta < 0, delta < -(.pi - 0.006) { return .pi }
        return delta
    }

    /// Interior angle in degrees, rounded for display.
    static func degrees(a: CGPoint, vertex: CGPoint, b: CGPoint) -> Int {
        Int((abs(sweep(a: a, vertex: vertex, b: b)) * 180 / .pi).rounded())
    }

    /// Arc radius: proportional to the shorter ray, kept clear of the vertex dot.
    static func arcRadius(a: CGPoint, vertex: CGPoint, b: CGPoint, lineWidth: CGFloat) -> CGFloat {
        let lenA = hypot(a.x - vertex.x, a.y - vertex.y)
        let lenB = hypot(b.x - vertex.x, b.y - vertex.y)
        let shorter = min(lenA, lenB)
        return min(max(shorter * 0.4, lineWidth * 6), shorter * 0.9)
    }

    /// Unit vector along the interior-angle bisector (where arc label goes).
    static func bisector(a: CGPoint, vertex: CGPoint, b: CGPoint) -> CGPoint {
        let ang1 = atan2(a.y - vertex.y, a.x - vertex.x)
        let mid = ang1 + sweep(a: a, vertex: vertex, b: b) / 2
        return CGPoint(x: cos(mid), y: sin(mid))
    }

    /// The arc spanning the interior angle, as a sampled polyline path.
    /// (Sampling sidesteps CGContext/SwiftUI clockwise-convention mismatches
    /// in the flipped annotation space — both sides get the same points.)
    static func arcPath(a: CGPoint, vertex: CGPoint, b: CGPoint, radius: CGFloat) -> CGPath {
        let ang1 = atan2(a.y - vertex.y, a.x - vertex.x)
        let delta = sweep(a: a, vertex: vertex, b: b)
        let path = CGMutablePath()
        let steps = max(Int(abs(delta) * 24 / .pi), 4)   // ~24 segments per 180°
        for i in 0...steps {
            let ang = ang1 + delta * CGFloat(i) / CGFloat(steps)
            let pt = CGPoint(x: vertex.x + radius * cos(ang), y: vertex.y + radius * sin(ang))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    /// Both rays as one strokable path.
    static func raysPath(a: CGPoint, vertex: CGPoint, b: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: vertex)
        path.addLine(to: b)
        return path
    }

    /// Filled dots at the three defining points (vertex slightly larger).
    static func dotsPath(a: CGPoint, vertex: CGPoint, b: CGPoint, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let outerR = lineWidth * 2
        let vertexR = lineWidth * 2.6
        for (pt, r) in [(a, outerR), (b, outerR), (vertex, vertexR)] {
            path.addEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
        }
        return path
    }

    /// Label anchor on the bisector. labelDistance 0 = centered ON the arc
    /// (the pill caps the dashed arc); positive values push it outward.
    static func labelCenter(a: CGPoint, vertex: CGPoint, b: CGPoint,
                            radius: CGFloat, labelDistance: CGFloat) -> CGPoint {
        let dir = bisector(a: a, vertex: vertex, b: b)
        return CGPoint(x: vertex.x + dir.x * (radius + labelDistance),
                       y: vertex.y + dir.y * (radius + labelDistance))
    }

    // MARK: Shift-snapping (45° steps)

    /// The shift-snap increment: 45°.
    private static let snapIncrement: CGFloat = .pi / 4

    /// Shift-drag on an outer point: rotate it about the vertex so the angle
    /// to the other ray snaps to the nearest 45° multiple (0…180°), preserving
    /// the dragged ray's length.
    static func snapOuterPoint(_ dragged: CGPoint, vertex: CGPoint, other: CGPoint) -> CGPoint {
        let len = hypot(dragged.x - vertex.x, dragged.y - vertex.y)
        guard len > 0.001 else { return dragged }
        let sw = sweep(a: other, vertex: vertex, b: dragged)
        let target = (sw / snapIncrement).rounded() * snapIncrement
        let angOther = atan2(other.y - vertex.y, other.x - vertex.x)
        let newAng = angOther + target
        return CGPoint(x: vertex.x + len * cos(newAng),
                       y: vertex.y + len * sin(newAng))
    }

    /// Shift-drag on the vertex: move it to the nearest point where the
    /// interior angle is a 45° multiple (45…180° — 0° is geometrically
    /// impossible for a vertex between two fixed points). The locus of
    /// vertices seeing the chord a–b at a fixed angle θ is a circular arc
    /// through a and b (inscribed-angle theorem), so the snap is a projection
    /// onto the circle for the nearest 45° target; the 180° locus degenerates
    /// to the segment itself.
    static func snapVertex(_ v: CGPoint, a: CGPoint, b: CGPoint) -> CGPoint {
        let abX = b.x - a.x, abY = b.y - a.y
        let abLen = hypot(abX, abY)
        guard abLen > 0.001 else { return v }

        let current = abs(sweep(a: a, vertex: v, b: b))
        var target = (current / snapIncrement).rounded() * snapIncrement
        target = min(max(target, snapIncrement), .pi)

        if target > .pi - 0.001 {
            // 180°: closest point on the segment a–b.
            let t = max(0, min(1, ((v.x - a.x) * abX + (v.y - a.y) * abY) / (abLen * abLen)))
            return CGPoint(x: a.x + t * abX, y: a.y + t * abY)
        }

        let mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2
        // Unit normal to a–b on the vertex's current side.
        var nx = -abY / abLen, ny = abX / abLen
        if (v.x - mx) * nx + (v.y - my) * ny < 0 { nx = -nx; ny = -ny }
        let half = abLen / 2
        let radius = half / sin(target)
        // Signed chord→center distance: center sits on the vertex's side for
        // θ < 90° (major arc) and on the opposite side for θ > 90° (minor arc).
        let h = half * cos(target) / sin(target)
        let cx = mx + nx * h, cy = my + ny * h
        let dvx = v.x - cx, dvy = v.y - cy
        let dLen = hypot(dvx, dvy)
        guard dLen > 0.001 else { return v }
        return CGPoint(x: cx + dvx / dLen * radius, y: cy + dvy / dLen * radius)
    }
}

// MARK: - Text Bubble Geometry

/// The one place the text pill's width is derived. The drawn resize handles,
/// the handle hit test, the body hit test and the resize drag must ALL go
/// through this — they used to measure independently and drift apart.
///
/// ⚠️ The pill is laid out on screen at `fontSize * scale`, and the system
/// font's tracking table is **not linear in point size**, so
/// `naturalWidth(fontSize) * scale != naturalWidth(fontSize * scale)`.
/// Measuring the natural width at the stored (image-space) `fontSize` and then
/// scaling it put the hit target up to ~15pt away from the drawn dot at fit
/// zoom — past `handleHitRadius`, so pressing the dot fell through to the body
/// hit test and moved the whole bubble instead of resizing it. Every natural
/// width is therefore measured at the **displayed** size and converted back.
enum TextBubbleGeometry {
    /// Horizontal padding inside the pill, in the same space as `fontSize`.
    static func horizontalPadding(fontSize: CGFloat) -> CGFloat { fontSize * 0.55 }

    /// Natural (wrap-free) pill width for `text` rendered at `fontSize`.
    /// The result is in whatever space `fontSize` is expressed in.
    static func naturalWidth(text: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let maxLineW = text.components(separatedBy: .newlines)
            .map { ($0.isEmpty ? " " : $0 as NSString).size(withAttributes: attrs).width }
            .max() ?? 0
        return maxLineW + horizontalPadding(fontSize: fontSize) * 2
    }

    /// Pill width in **view points** at zoom `scale` — where the handles are drawn.
    static func displayWidth(for annotation: Annotation, scale: CGFloat) -> CGFloat {
        if let w = annotation.textWidth { return w * scale }
        return naturalWidth(text: annotation.text,
                            fontSize: annotation.style.fontSize * scale)
    }

    /// Paragraph style shared by the inline editor and the height
    /// measurement below, matching `AnnotationRenderer.drawText`'s line
    /// spacing so a bubble keeps its height across the edit.
    static func paragraphStyle(fontSize: CGFloat) -> NSMutableParagraphStyle {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let lineHeight = font.ascender + abs(font.descender)
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineSpacing = max(0, fontSize * 0.22 - (lineHeight - fontSize))
        return p
    }

    /// Laid-out size of `text` inside a container `containerWidth` wide, using
    /// the very same text system the inline editor's `NSTextView` uses. The
    /// editor frames itself from this **synchronously**: asking the text view
    /// for its size and feeding it back through `@State` lands a frame late,
    /// which is visible as a blink when edit mode opens.
    static func layoutSize(text: String, fontSize: CGFloat, containerWidth: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let storage = NSTextStorage(string: text, attributes: [
            .font: font,
            .paragraphStyle: paragraphStyle(fontSize: fontSize),
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, containerWidth),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var used = layout.usedRect(for: container)
        // A trailing newline (or empty text) lays out no glyphs on the last
        // line — the text view still needs room for it, and so does the
        // committed pill, which counts that empty line too.
        if layout.extraLineFragmentTextContainer != nil {
            used = used.union(layout.extraLineFragmentRect)
        }
        return CGSize(width: ceil(used.width),
                      height: ceil(max(used.height, font.ascender + abs(font.descender))))
    }

    /// Pill width in **image-pixel space** at zoom `scale` — where hit testing
    /// and the resize drag work. Exactly `displayWidth / scale`.
    static func imageWidth(for annotation: Annotation, scale: CGFloat) -> CGFloat {
        if let w = annotation.textWidth { return w }
        guard scale > 0 else { return naturalWidth(text: annotation.text, fontSize: annotation.style.fontSize) }
        return naturalWidth(text: annotation.text,
                            fontSize: annotation.style.fontSize * scale) / scale
    }
}

// MARK: - Sticker (Emoji) Geometry

/// Sizing for the emoji sticker tool.
///
/// A sticker is stored as a **rect** (`startPoint`/`endPoint` = opposite
/// corners, exactly like the shape tools) rather than as a centre point plus a
/// font size. That way the bounding-box hit test, the four corner-resize
/// handles and every whole-image point transform (padding shift, crop remap,
/// resize, rotate, straighten) all work with no sticker-specific code.
///
/// The point size that fills that box is derived **here and only here**, so the
/// SwiftUI preview and the Core Graphics export lay the glyph out identically.
enum StickerGeometry {
    /// The emoji a freshly opened picker offers, and the fallback for a
    /// sticker whose emoji somehow went missing.
    static let defaultEmoji = "\u{1F44D}"

    /// Box side (image pixels) for a click-placed sticker.
    static let defaultSize: CGFloat = 100
    /// Smallest box a corner drag may produce.
    static let minimumSize: CGFloat = 16

    /// Typographic size of an emoji glyph at `fontSize`. Measured through Core
    /// Text rather than hardcoded: every emoji resolves to the same colour-emoji
    /// fallback face, so one reference glyph covers them all — and nothing here
    /// names a font by its PostScript name (which would silently fall back to
    /// Helvetica if that name were missing).
    private static func layoutSize(fontSize: CGFloat) -> CGSize {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "\u{1F600}",
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        ))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: width, height: ascent + descent)
    }

    /// Nominal layout size per point, from one reference measurement.
    private static let ratio: CGSize = {
        let reference: CGFloat = 100
        let size = layoutSize(fontSize: reference)
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1.08, height: 1.18) }
        return CGSize(width: size.width / reference, height: size.height / reference)
    }()

    /// Point size at which the emoji's layout box fits inside `box`.
    /// `box` and the result are in the same space (image pixels or view points).
    ///
    /// ⚠️ The colour-emoji face rounds its **advance up to a whole point**, so
    /// the advance-per-point is not constant — it is 1.08 at 100pt but 1.5 at
    /// 8pt. Scaling by the nominal ratio alone therefore overflows the box at
    /// small sizes (a 17pt box came out 4pt too wide), which shows up as the
    /// glyph spilling past its own selection rectangle and resize handles. The
    /// first guess is corrected against a real measurement; rounding means one
    /// pass can leave a sliver, so it repeats a couple of times. Correcting can
    /// only ever shrink, so it is safe to stop early.
    static func fontSize(forBox box: CGSize) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 1 }
        var size = max(1, min(box.width / ratio.width, box.height / ratio.height))
        for _ in 0..<3 {
            let measured = layoutSize(fontSize: size)
            let overflow = max(measured.width / box.width, measured.height / box.height)
            guard overflow > 1.0001, size > 1 else { break }
            size = max(1, size / overflow)
        }
        return size
    }
}

// MARK: - Annotation Style

struct AnnotationStyle: Equatable {
    var strokeColor: Color = .red
    var strokeWidth: CGFloat = 3
    var fontSize: CGFloat = 48
    var pixelationScale: CGFloat = 20
    var arrowStyle: ArrowStyle = .chevron
    /// Fill color for shape tools (rectangle, circle, triangle, star).
    /// nil = outline-only; a Color value = fill with that color.
    var fillColor: Color? = nil
    var spotlightOpacity: CGFloat = 0.5
    var spotlightFeather: CGFloat = 0

    /// CGColor for use in Core Graphics rendering.
    var cgStrokeColor: CGColor {
        NSColor(strokeColor).cgColor
    }

    /// CGColor fill for shape tools. nil when no fill is set.
    var cgFillColor: CGColor? {
        guard let fillColor else { return nil }
        return NSColor(fillColor).cgColor
    }

    /// Whether the stroke color is perceptually light (luminance > 0.4).
    /// Used to decide whether to place dark or light text on top.
    var isLight: Bool {
        (strokeColor.relativeLuminance ?? 0) > 0.4
    }

    /// Foreground color for text labels placed on top of the stroke color.
    /// Light-colored bubbles (white, yellow, etc.) use dark text; dark bubbles use white text.
    var textBubbleForeground: Color {
        isLight ? .black : .white
    }

    var cgTextBubbleForeground: CGColor {
        NSColor(textBubbleForeground).cgColor
    }

    /// Background color for text pills and step badges.
    var textBubbleBackground: Color {
        strokeColor
    }

    var cgTextBubbleBackground: CGColor {
        NSColor(textBubbleBackground).cgColor
    }
}

extension Color {
    /// The colour's linear-light sRGB components, resolved in a **fixed light
    /// appearance**.
    ///
    /// ⚠️ System colours are dynamic: `NSColor(Color.blue)` resolves to
    /// (0, 0.478, 1) in Aqua and (0.039, 0.518, 1) in Dark Aqua, and
    /// `usingColorSpace` picks whichever appearance happens to be current.
    /// Measured, that moved blue's legibility luminance from 0.190 to 0.218 —
    /// across the highlighter's knock-out threshold — so the same saved
    /// annotation would have flipped its text in one appearance and not the
    /// other. Pinning the evaluation makes the decision a property of the
    /// colour alone.
    private var linearComponents: (r: CGFloat, g: CGFloat, b: CGFloat)? {
        var resolved: NSColor?
        let appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(self).usingColorSpace(.deviceRGB)
        }
        guard let resolved else { return nil }
        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return (linearize(resolved.redComponent),
                linearize(resolved.greenComponent),
                linearize(resolved.blueComponent))
    }

    /// WCAG relative luminance, 0 (black) to 1 (white), or nil if the colour
    /// has no RGB representation.
    var relativeLuminance: CGFloat? {
        guard let c = linearComponents else { return nil }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// Luminance with the **blue term dropped** and the remaining weights
    /// renormalised — how much of the colour the eye can actually resolve an
    /// edge against.
    ///
    /// WCAG luminance cannot tell red from blue: measured, `.red` is 0.244 and
    /// `.blue` is 0.248, yet black text is comfortable on red and poor on blue.
    /// The reason is physiological — S-cones contribute essentially nothing to
    /// the luminance channel or to spatial acuity, and the eye cannot focus
    /// short wavelengths well, so a saturated blue or violet gives far less
    /// edge signal than its luminance implies. Dropping the blue term
    /// exaggerates that real effect enough to separate the two: red 0.260,
    /// blue 0.190, purple 0.160.
    ///
    /// This is an approximation chosen to match what the colours look like, not
    /// a published model — which is why the numbers above are recorded here.
    var legibilityLuminance: CGFloat? {
        guard let c = linearComponents else { return nil }
        return (0.2126 * c.r + 0.7152 * c.g) / (0.2126 + 0.7152)
    }
}

// MARK: - Highlight Geometry

/// The one place a `.highlight` annotation's bands are converted between the
/// flat point list it stores and the rects everything draws and hit-tests.
///
/// Bands live in `Annotation.points` as **corner pairs** — `[b0.topLeft,
/// b0.bottomRight, b1.topLeft, b1.bottomRight, …]` — rather than in a rect
/// array of their own. `points` is already remapped by every whole-image
/// transform in `EditorView` (padding shift, crop remap, resize, rotate,
/// straighten, flip, nudge) and by the canvas body drag, so a multi-line
/// highlight follows the image with **no new code at any of those sites** —
/// the same reason the angle tool keeps its vertex in `points[0]`.
///
/// Pairs are normalised on the way out, so a transform that swaps which corner
/// is which (a quarter turn, a mirror) still describes the same band.
enum HighlightGeometry {
    /// Rounding of a band's ends, as a fraction of its height. Small enough to
    /// read as a marker stroke rather than a pill.
    static let cornerFraction: CGFloat = 0.12

    /// `Color.legibilityLuminance` at or below which a band **knocks the text
    /// out white** instead of multiplying into it.
    ///
    /// Multiply leaves black text black (0 × anything = 0), which is exactly
    /// right under a yellow marker and unreadable under a dark or saturated
    /// one — black on blue, purple or navy.
    ///
    /// The threshold is measured, not derived, and the values it separates are
    /// worth keeping because the obvious alternatives all get one of them
    /// wrong (light-appearance `legibilityLuminance`):
    ///
    ///     yellow 0.695   orange 0.434   green 0.448   rose 0.291
    ///     red    0.260   mid-blue 0.231  olive 0.214  ← keep black text
    ///     ───────────────────────────── 0.21 ─────────────────────────────
    ///     magenta 0.194  blue 0.190     purple 0.160  teal 0.147
    ///     iris   0.136   brown 0.105    cobalt 0.081  black 0  ← flip white
    ///
    /// It sits between **blue (0.190) and red (0.260)** on purpose: those two
    /// are indistinguishable by WCAG luminance (0.248 vs 0.244) but read very
    /// differently with black text on them. `isLight`'s 0.4 would flip red,
    /// where black scores 5.88:1 against white's 3.57:1 — strictly worse.
    static let knockOutLuminance: CGFloat = 0.21

    /// Whether a band of this colour inverts the content under it rather than
    /// multiplying into it.
    static func knocksOutText(_ color: Color) -> Bool {
        (color.legibilityLuminance ?? 1) <= knockOutLuminance
    }

    /// The ink's per-channel complement, `1 − C`.
    ///
    /// The knock-out is `result = 1 − (1 − C)·S`: multiply the page by this
    /// complement, then invert the result. Where the page is white (S = 1) it
    /// lands back exactly on `C`, so the band still shows the colour the user
    /// picked; where the page is black (S = 0) it lands on white, which is the
    /// text being flipped.
    static func complement(_ color: Color) -> Color {
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return .black }
        return Color(red: 1 - ns.redComponent,
                     green: 1 - ns.greenComponent,
                     blue: 1 - ns.blueComponent)
    }

    /// The marker's colour before the user picks one — yellow, the colour a
    /// highlighter is. Deliberately the same `Color.yellow` the sidebar's
    /// preset row offers, so an unset highlight shows that swatch as the
    /// current selection instead of leaving the picker looking empty.
    static let defaultColor: Color = .yellow

    /// Ink corner radius for one band. Shared by the preview and the export so
    /// the two round identically.
    static func cornerRadius(for rect: CGRect) -> CGFloat {
        max(0, min(rect.height * cornerFraction, rect.width / 2))
    }

    /// Thickness of a free-drawn marker band, in image pixels at 1× DPI, when
    /// the drag is flatter than this.
    ///
    /// The natural marker gesture is a horizontal swipe along a line, which has
    /// **no height of its own** — taken literally it inks a zero-height band,
    /// i.e. nothing at all. So a flat drag gets a nib's worth of thickness
    /// centred on it, and a drag the user deliberately gave some height keeps
    /// exactly the rectangle they drew.
    static let nibHeight: CGFloat = 18

    /// The band a free-drawn marker drag covers: the drag rectangle, thickened
    /// about its own centre line when it is flatter than the nib. Used when
    /// there is no text under the drag — a screenshot, a scanned page, a figure.
    static func markerBand(from start: CGPoint, to end: CGPoint,
                           dpiScaleFactor: CGFloat) -> CGRect {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let minimum = nibHeight * max(dpiScaleFactor, 1)
        guard rect.height < minimum else { return rect }
        return CGRect(x: rect.minX, y: rect.midY - minimum / 2,
                      width: rect.width, height: minimum)
    }

    static func rects(from points: [CGPoint]) -> [CGRect] {
        guard points.count >= 2 else { return [] }
        var result: [CGRect] = []
        result.reserveCapacity(points.count / 2)
        for i in stride(from: 0, to: points.count - 1, by: 2) {
            let a = points[i], b = points[i + 1]
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(b.x - a.x), height: abs(b.y - a.y))
            // Sub-pixel slivers come from empty selection lines; they would
            // paint as invisible hairlines but still count as hit targets.
            if rect.width > 0.5 && rect.height > 0.5 { result.append(rect) }
        }
        return result
    }

    static func points(from rects: [CGRect]) -> [CGPoint] {
        rects.flatMap {
            [CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.maxY)]
        }
    }

    static func bounds(of rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}

// MARK: - Recognized Text Layer (OCR)

/// The text found in a raster image, in that image's pixel space — what lets
/// the highlight tool snap to words on a screenshot, where there is no text
/// layer to ask.
///
/// It is the raster counterpart of `PDFPage.textHighlightBands`, and resolves a
/// drag with the same semantics: the swept lines, trimmed to the sweep on the
/// first and last, whole lines in between.
struct RecognizedTextLayer: Equatable {
    struct Line: Equatable {
        /// The band to ink — the recognized box, padded (see `linePadding`).
        let rect: CGRect
        /// Word boxes left to right, sharing the line's padded vertical extent.
        /// A sweep that touches any part of a word takes the whole word, which
        /// is what makes the highlight land on words rather than mid-glyph.
        let words: [CGRect]
    }

    let lines: [Line]
    /// The image-pixel size these rects are expressed in. A canvas re-compose
    /// changes that size, and the layer is stale the moment it does.
    let imagePixelSize: CGSize

    static let empty = RecognizedTextLayer(lines: [], imagePixelSize: .zero)
    var isEmpty: Bool { lines.isEmpty }

    /// Vision reports the box of the **ink**, not of the line: it stops at the
    /// glyph tops and bottoms, so a band drawn straight from it looks cramped
    /// and changes height from line to line depending on whether that line
    /// happens to contain an ascender or a descender. Measured against the
    /// rendered pixels, Vision's box for 40pt text was 36px tall where the line
    /// box is ~47px, so each side gains this fraction of the box height to
    /// approximate the line box a PDF hands over directly.
    static let linePadding: CGFloat = 0.14

    /// The bands a drag from `start` to `end` covers, or nil when it covers no
    /// text — the caller then falls back to a plain marker band.
    ///
    /// Same shape as the PDF path, including the rule that the resolved text
    /// has to be under the sweep. The sweep is inset outward first because a
    /// swipe along a line has zero height and `CGRect.intersects` is false for
    /// an empty rect.
    func bands(from start: CGPoint, to end: CGPoint) -> [CGRect]? {
        guard !lines.isEmpty else { return nil }
        let swept = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y))
            .insetBy(dx: -1, dy: -1)

        let covered = lines.filter { $0.rect.intersects(swept) }
            .sorted { $0.rect.minY < $1.rect.minY }
        guard !covered.isEmpty else { return nil }

        // Reading order runs from whichever end of the sweep is higher, so
        // dragging upward selects the same text as dragging downward.
        let upper = start.y <= end.y ? start : end
        let lower = start.y <= end.y ? end : start

        var bands: [CGRect] = []
        for (index, line) in covered.enumerated() {
            let low: CGFloat
            let high: CGFloat
            if covered.count == 1 {
                low = min(start.x, end.x)
                high = max(start.x, end.x)
            } else if index == 0 {
                low = upper.x
                high = .greatestFiniteMagnitude
            } else if index == covered.count - 1 {
                low = -.greatestFiniteMagnitude
                high = lower.x
            } else {
                low = -.greatestFiniteMagnitude
                high = .greatestFiniteMagnitude
            }

            let touched = line.words.filter { $0.maxX > low && $0.minX < high }
            if !touched.isEmpty {
                bands.append(HighlightGeometry.bounds(of: touched))
            } else if line.words.isEmpty {
                // No word boxes (Vision gave a line but no candidate): clip the
                // line itself rather than dropping it.
                let clipped = line.rect.intersection(
                    CGRect(x: low == -.greatestFiniteMagnitude ? line.rect.minX : low,
                           y: line.rect.minY,
                           width: high == .greatestFiniteMagnitude
                               ? line.rect.maxX - min(low, line.rect.minX)
                               : max(0, high - low),
                           height: line.rect.height))
                if !clipped.isNull, clipped.width > 0.5 { bands.append(clipped) }
            }
        }
        return bands.isEmpty ? nil : bands
    }
}

/// Runs Vision over an image and turns the result into a `RecognizedTextLayer`.
enum TextLayerRecognizer {

    /// ⚠️ **`.fast`, deliberately — `.accurate` silently finds NOTHING on a
    /// large screenshot.** Measured across sizes with the same 13pt-equivalent
    /// text: at 1440×900 both levels read every line, at 2560×1440 `.accurate`
    /// returned **zero** observations while `.fast` returned 63, and at
    /// 5120×2880 — an ordinary 2× capture of a 27" display — `.accurate` was
    /// empty again. `minimumTextHeight` makes no difference; the driver is how
    /// small the text is relative to the whole image, and `.fast` tolerates far
    /// more of it. `.fast` is also 2–3× quicker and its boxes are *tighter* to
    /// the rendered ink (within 1–2px, versus 2–5px for `.accurate`).
    ///
    /// Only the geometry is used, never the transcription, so language
    /// correction is off — it costs time and can only move the boxes.
    /// (The menu's Capture Text action still uses `.accurate`: it needs the
    /// words, and it is handed a region the user just drew, not a whole screen.)
    static func recognize(_ image: CGImage, imagePixelSize: CGSize) async -> RecognizedTextLayer {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return .empty }

        let observations: [VNRecognizedTextObservation] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                request.usesLanguageCorrection = false
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    continuation.resume(returning: request.results ?? [])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
        if Task.isCancelled { return .empty }

        let lines = observations.compactMap { observation -> RecognizedTextLayer.Line? in
            let box = Self.rect(observation.boundingBox, in: imagePixelSize)
            guard box.width > 0.5, box.height > 0.5 else { return nil }
            let padding = box.height * RecognizedTextLayer.linePadding
            let band = box.insetBy(dx: 0, dy: -padding)

            var words: [CGRect] = []
            if let candidate = observation.topCandidates(1).first {
                for range in Self.wordRanges(in: candidate.string) {
                    guard let observed = try? candidate.boundingBox(for: range) else { continue }
                    let word = Self.rect(observed.boundingBox, in: imagePixelSize)
                    guard word.width > 0.5 else { continue }
                    // Words share the line's vertical extent: a word with no
                    // ascender or descender has a shorter box of its own, and
                    // a highlight made of those reads as a ragged staircase.
                    words.append(CGRect(x: word.minX, y: band.minY,
                                        width: word.width, height: band.height))
                }
            }
            return RecognizedTextLayer.Line(rect: band, words: words.sorted { $0.minX < $1.minX })
        }
        return RecognizedTextLayer(lines: lines, imagePixelSize: imagePixelSize)
    }

    /// Vision reports normalized, bottom-left-origin boxes; annotations live in
    /// image pixels with a top-left origin.
    ///
    /// Mapping straight into `imagePixelSize` rather than into the CGImage's own
    /// dimensions is deliberate: the canvas only has an `NSImage`, and
    /// `cgImage(forProposedRect:)` can hand back a differently scaled bitmap.
    /// Normalized boxes make that impossible to get wrong.
    private static func rect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width,
               y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width,
               height: normalized.height * size.height)
    }

    private static func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = string.startIndex
        while index < string.endIndex {
            guard !string[index].isWhitespace else {
                index = string.index(after: index)
                continue
            }
            var end = index
            while end < string.endIndex, !string[end].isWhitespace {
                end = string.index(after: end)
            }
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }
}

// MARK: - Annotation

/// A single annotation on the canvas.
/// Points are stored in **image-pixel coordinates** (matching the CGImage dimensions)
/// so they remain accurate regardless of view zoom or window size.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var startPoint: CGPoint    // image-pixel coordinates
    var endPoint: CGPoint      // image-pixel coordinates
    var points: [CGPoint]      // used by free-draw tool
    /// Arrow shaft bow in the start→end local frame (see ArrowGeometry).
    /// nil = the style's default (0.3 bow for .curved, straight for .double).
    var curvature: CGVector?
    var style: AnnotationStyle
    /// Body of a `.text` bubble — and the emoji of a `.sticker`. Reusing the
    /// one string field means the Option+drag duplicate, the undo snapshots and
    /// every cross-window copy carry the sticker's emoji for free.
    var text: String
    /// Fixed wrap width for a `.text` bubble, in image-pixel space.
    /// nil = natural (no wrapping); a value = the bubble wraps at that width.
    /// Per-annotation *geometry*, deliberately NOT part of `AnnotationStyle`:
    /// the sidebar replaces the whole style of the selection wholesale
    /// (`applyStyleToSelection`) and `currentStyle` is inherited by the next
    /// annotation, so a width living in the style was silently discarded by the
    /// next colour/font tweak and leaked into freshly placed bubbles.
    var textWidth: CGFloat?
    var stepNumber: Int        // only meaningful for .numberedStep tool

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        startPoint: CGPoint,
        endPoint: CGPoint,
        points: [CGPoint] = [],
        curvature: CGVector? = nil,
        style: AnnotationStyle = AnnotationStyle(),
        text: String = "",
        textWidth: CGFloat? = nil,
        stepNumber: Int = 0
    ) {
        self.id = id
        self.tool = tool
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.points = points
        self.curvature = curvature
        self.style = style
        self.text = text
        self.textWidth = textWidth
        self.stepNumber = stepNumber
    }

    /// Effective arrow curvature: the stored value, or the style's default bow.
    var arrowCurvature: CGVector {
        if let curvature { return curvature }
        return CGVector(dx: 0.5, dy: style.arrowStyle == .curved ? ArrowGeometry.defaultCurvedBow : 0)
    }

    /// Quad-bezier control point of the arrow shaft (image-pixel space).
    var arrowControlPoint: CGPoint {
        ArrowGeometry.controlPoint(start: startPoint, end: endPoint, curvature: arrowCurvature)
    }

    /// The on-curve midpoint where the curve handle sits (image-pixel space).
    var arrowMidPoint: CGPoint {
        ArrowGeometry.midPoint(start: startPoint, end: endPoint, curvature: arrowCurvature)
    }

    /// Vertex (corner point) of an .angle annotation. Stored in `points[0]`
    /// so every whole-image point transform (shift, crop remap, resize,
    /// rotate, straighten) maps it for free alongside start/end.
    var angleVertex: CGPoint {
        points.first ?? CGPoint(x: (startPoint.x + endPoint.x) / 2,
                                y: (startPoint.y + endPoint.y) / 2)
    }

    /// Ink colour of a `.highlight`.
    ///
    /// The marker is a **fill**, so it reads `style.fillColor` rather than
    /// `strokeColor` — which also keeps it out of the stroke tools' way: one
    /// `currentStyle` is shared by every tool and is replaced wholesale when an
    /// annotation is selected, so a highlighter sharing `strokeColor` would
    /// recolour the arrow tool every time the user picked a marker colour, and
    /// vice versa. Two fields, no contention.
    ///
    /// A nil fill means "no fill" for the shape tools, but a highlight with no
    /// fill is nothing at all — so here it resolves to the default marker
    /// colour instead of drawing an invisible band.
    var highlightColor: Color {
        style.fillColor ?? HighlightGeometry.defaultColor
    }

    var cgHighlightColor: CGColor {
        NSColor(highlightColor).cgColor
    }

    /// True when this highlight is dark enough that it inverts the content
    /// under it, flipping black text to white (see `HighlightGeometry`).
    var highlightKnocksOutText: Bool {
        HighlightGeometry.knocksOutText(highlightColor)
    }

    /// The bands of a `.highlight`, in image-pixel space. One band per text
    /// line on a PDF page; a single band for a free-drawn marker stroke.
    /// Stored as corner PAIRS in `points` (see HighlightGeometry) so every
    /// whole-image point transform maps them for free, exactly like the angle
    /// tool's vertex. Falls back to the start/end rect if `points` is empty.
    var highlightRects: [CGRect] {
        let rects = HighlightGeometry.rects(from: points)
        return rects.isEmpty ? [CGRect(x: min(startPoint.x, endPoint.x),
                                       y: min(startPoint.y, endPoint.y),
                                       width: abs(endPoint.x - startPoint.x),
                                       height: abs(endPoint.y - startPoint.y))]
                             : rects
    }

    /// Stable seed for the sketch arrow's grit, folded from the UUID bytes
    /// (NOT hashValue, which is randomized per process). Same arrow → same
    /// hand-drawn texture, every frame and in every export.
    var sketchSeed: UInt64 {
        let u = id.uuid
        return UInt64(u.0) << 56 | UInt64(u.1) << 48 | UInt64(u.2) << 40 | UInt64(u.3) << 32
             | UInt64(u.4) << 24 | UInt64(u.5) << 16 | UInt64(u.6) << 8 | UInt64(u.7)
    }

    /// The bounding rect of this annotation in image-pixel coordinates.
    var boundingRect: CGRect {
        if tool == .angle {
            let pts = [startPoint, endPoint, angleVertex]
            let xs = pts.map(\.x), ys = pts.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!,
                          width: max(xs.max()! - xs.min()!, 1),
                          height: max(ys.max()! - ys.min()!, 1))
        }
        if tool == .freeDraw || tool == .highlight, !points.isEmpty {
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            if let minX = xs.min(), let maxX = xs.max(),
               let minY = ys.min(), let maxY = ys.max() {
                return CGRect(
                    x: minX,
                    y: minY,
                    width: max(maxX - minX, 1),
                    height: max(maxY - minY, 1)
                )
            }
        }
        return CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}

// MARK: - Undo Support

/// Snapshot of the editor state for undo/redo.
/// Captures annotations, the rendered display image, the non-destructive crop rect,
/// and any photo adjustments so they can be reverted together.
struct EditorSnapshot {
    let annotations: [Annotation]
    let image: NSImage?
    let rawImage: NSImage?
    let selectedWallpaper: WallpaperSource?
    let imagePixelSize: CGSize
    let cropRect: CGRect?
    /// The current crop in raw screenshot pixel space (non-destructive crop state).
    let screenshotCropRect: CGRect?
    /// Photo adjustments at the time of the snapshot (exposure, contrast, etc.).
    let photoAdjustments: PhotoAdjustments
    /// Rotation (in 90° CW steps, modulo 4) at the time of the snapshot.
    let rotationSteps: Int
    /// Fine straighten angle (degrees) at the time of the snapshot.
    let straightenAngle: Double
    /// Mirror flags at the time of the snapshot (applied after the straighten,
    /// before the crop — see `EditorView.composeDisplayImage`).
    let flipHorizontal: Bool
    let flipVertical: Bool

    init(
        annotations: [Annotation],
        image: NSImage? = nil,
        rawImage: NSImage? = nil,
        selectedWallpaper: WallpaperSource? = nil,
        imagePixelSize: CGSize = .zero,
        cropRect: CGRect? = nil,
        screenshotCropRect: CGRect? = nil,
        photoAdjustments: PhotoAdjustments = .default,
        rotationSteps: Int = 0,
        straightenAngle: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) {
        self.annotations = annotations
        self.image = image
        self.rawImage = rawImage
        self.selectedWallpaper = selectedWallpaper
        self.imagePixelSize = imagePixelSize
        self.cropRect = cropRect
        self.screenshotCropRect = screenshotCropRect
        self.photoAdjustments = photoAdjustments
        self.rotationSteps = rotationSteps
        self.straightenAngle = straightenAngle
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}
