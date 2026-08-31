import SwiftUI

// MARK: - Tool Types

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case textSelect
    case arrow
    case freeDraw
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
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select:       return String(localized: "Select")
        case .textSelect:   return String(localized: "Select Text")
        case .arrow:        return String(localized: "Arrow")
        case .freeDraw:     return String(localized: "Free Drawing")
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
        case .crop:         return String(localized: "Crop")
        }
    }

    var systemImage: String {
        switch self {
        case .select:       return "cursorarrow"
        case .textSelect:   return "character.cursor.ibeam"
        case .arrow:        return "arrow.up.right"
        case .freeDraw:     return "pencil.and.scribble"
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

    /// Pill width in **image-pixel space** at zoom `scale` — where hit testing
    /// and the resize drag work. Exactly `displayWidth / scale`.
    static func imageWidth(for annotation: Annotation, scale: CGFloat) -> CGFloat {
        if let w = annotation.textWidth { return w }
        guard scale > 0 else { return naturalWidth(text: annotation.text, fontSize: annotation.style.fontSize) }
        return naturalWidth(text: annotation.text,
                            fontSize: annotation.style.fontSize * scale) / scale
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
        guard let ns = NSColor(strokeColor).usingColorSpace(.deviceRGB) else { return false }
        // sRGB relative luminance (WCAG formula)
        func linearize(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linearize(ns.redComponent)
        let g = linearize(ns.greenComponent)
        let b = linearize(ns.blueComponent)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.4
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
    var text: String           // only meaningful for .text tool
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
        if tool == .freeDraw, !points.isEmpty {
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
