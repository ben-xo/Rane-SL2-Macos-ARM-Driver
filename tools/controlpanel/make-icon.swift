// make-icon.swift <output.iconset> — draw the SL 2 Control Panel's app icon (the SL 2 box itself) at every
// size an .iconset needs. build-app.sh compiles and runs it, then turns the .iconset into AppIcon.icns
// with iconutil.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// A projective map from the unit square — u across the box from left to right, v from its front edge to its
// back edge — onto a quadrilateral, so the box's top face can be drawn flat and seen in perspective.
struct Projection {
    let a, b, c, d, e, f, g, h: CGFloat
    // p0 front left, p1 front right, p2 back right, p3 back left.
    init(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) {
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y
        let den = dx1 * dy2 - dx2 * dy1
        g = (dx3 * dy2 - dx2 * dy3) / den
        h = (dx1 * dy3 - dx3 * dy1) / den
        a = p1.x - p0.x + g * p1.x; b = p3.x - p0.x + h * p3.x; c = p0.x
        d = p1.y - p0.y + g * p1.y; e = p3.y - p0.y + h * p3.y; f = p0.y
    }
    func callAsFunction(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        let w = g * u + h * v + 1
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }
    func quad(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [self(u0, v0), self(u1, v0), self(u1, v1), self(u0, v1)])
        path.closeSubpath()
        return path
    }
}

// A polyline in the top face's (u, v) coordinates, with rounded corners, for the lettering.
struct Strokes {
    var points: [(CGFloat, CGFloat)] = []
    mutating func line(_ u: CGFloat, _ v: CGFloat) { points.append((u, v)) }
    // A quarter turn of radius r about (cu, cv), from angle a0 to a1 (radians).
    mutating func arc(_ cu: CGFloat, _ cv: CGFloat, _ ru: CGFloat, _ rv: CGFloat, _ a0: CGFloat, _ a1: CGFloat) {
        for i in 0...8 {
            let a = a0 + (a1 - a0) * CGFloat(i) / 8
            points.append((cu + ru * cos(a), cv + rv * sin(a)))
        }
    }
    func path(_ p: Projection) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { p($0.0, $0.1) })
        return path
    }
    // The outline of these strokes, `width` wide, laid on the top face so that it narrows and foreshortens
    // with the box. The strokes are widened on a flat top face of the box's true proportions (`size`, in the
    // same units as `width`), and the outline is then projected.
    func outline(_ p: Projection, width: CGFloat, size: CGSize) -> CGPath {
        let flat = CGMutablePath()
        flat.addLines(between: points.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) })
        let stroked = flat.copy(strokingWithWidth: width, lineCap: .square, lineJoin: .miter, miterLimit: 10)
        func project(_ q: CGPoint) -> CGPoint { p(q.x / size.width, q.y / size.height) }
        let path = CGMutablePath()
        stroked.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: path.move(to: project(e.points[0]))
            case .addLineToPoint: path.addLine(to: project(e.points[0]))
            case .addQuadCurveToPoint: path.addQuadCurve(to: project(e.points[1]), control: project(e.points[0]))
            case .addCurveToPoint:
                path.addCurve(to: project(e.points[2]), control1: project(e.points[0]), control2: project(e.points[1]))
            case .closeSubpath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// The letters S, L and 2, wide and geometric, in a box from (u0, v0) to (u1, v1) on the top face.
func letterS(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat, _ ru: CGFloat, _ rv: CGFloat) -> Strokes {
    let vm = (v0 + v1) / 2, pi = CGFloat.pi
    var s = Strokes()
    s.line(u1, v1)
    s.arc(u0 + ru, v1 - rv, ru, rv, pi / 2, pi)
    s.arc(u0 + ru, vm + rv, ru, rv, pi, 3 * pi / 2)
    s.arc(u1 - ru, vm - rv, ru, rv, pi / 2, 0)
    s.arc(u1 - ru, v0 + rv, ru, rv, 0, -pi / 2)
    s.line(u0, v0)
    return s
}
func letterL(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> Strokes {
    var s = Strokes()
    s.line(u0, v1); s.line(u0, v0); s.line(u1, v0)
    return s
}
func letter2(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat, _ ru: CGFloat, _ rv: CGFloat) -> Strokes {
    let vm = (v0 + v1) / 2, pi = CGFloat.pi
    var s = Strokes()
    s.line(u0, v1)
    s.arc(u1 - ru, v1 - rv, ru, rv, pi / 2, 0)
    s.arc(u1 - ru, vm + rv, ru, rv, 0, -pi / 2)
    s.arc(u0 + ru, vm - rv, ru, rv, pi / 2, pi)
    s.line(u0, v0); s.line(u1, v0)
    return s
}

// Draws on a 1024 × 1024 canvas, origin bottom left; the caller scales the context for other sizes.
// The picture is the SL 2 itself, seen from above and in front: a black box with three panels on top,
// "SL2" on the middle one, and the RCA sockets and power light along its front edge.
func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func gradient(_ colours: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colours as CFArray, locations: nil)!
    }

    // The background: a light rounded square on the standard macOS icon grid (824 pt inside 1024 pt).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(0.85, 0.86, 0.88))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.96, 0.96, 0.97), rgb(0.78, 0.79, 0.82)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The box: its front face, and its top face in perspective above it.
    let left: CGFloat = 168, right: CGFloat = 856, frontBottom: CGFloat = 262, frontTop: CGFloat = 352
    let top = Projection(CGPoint(x: left, y: frontTop), CGPoint(x: right, y: frontTop),
                         CGPoint(x: right - 62, y: 760), CGPoint(x: left + 62, y: 760))
    let outline = CGMutablePath()
    outline.addLines(between: [CGPoint(x: left, y: frontBottom + 14), CGPoint(x: left, y: frontTop),
                               top(0, 1), top(1, 1), CGPoint(x: right, y: frontTop),
                               CGPoint(x: right, y: frontBottom + 14)])
    outline.addArc(tangent1End: CGPoint(x: right, y: frontBottom), tangent2End: CGPoint(x: left, y: frontBottom), radius: 14)
    outline.addArc(tangent1End: CGPoint(x: left, y: frontBottom), tangent2End: CGPoint(x: left, y: frontTop), radius: 14)
    outline.closeSubpath()

    // Its shadow on the background.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.5))
    ctx.addPath(outline)
    ctx.setFillColor(rgb(0.08, 0.08, 0.09))
    ctx.fillPath()
    ctx.restoreGState()

    // The front face.
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.17, 0.17, 0.19), rgb(0.07, 0.07, 0.08)]),
                           start: CGPoint(x: 512, y: frontTop), end: CGPoint(x: 512, y: frontBottom), options: [])
    ctx.restoreGState()

    // The top face, lighter towards the back, with a highlight along its front edge.
    ctx.saveGState()
    ctx.addPath(top.quad(0, 0, 1, 1))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0.11, 0.11, 0.12), rgb(0.20, 0.20, 0.22)]),
                           start: top(0.5, 0), end: top(0.5, 1), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgb(1, 1, 1, 0.28))
    ctx.setLineWidth(4)
    ctx.strokeLineSegments(between: [top(0, 0), top(1, 0)])

    // The three panels, each edged where it catches the light.
    for (v0, v1) in [(CGFloat(0.04), CGFloat(0.27)), (0.31, 0.69), (0.73, 0.96)] {
        ctx.addPath(top.quad(0.03, v0, 0.97, v1))
        ctx.setFillColor(rgb(0.10, 0.10, 0.11, 0.6))
        ctx.fillPath()
        ctx.addPath(top.quad(0.03, v0, 0.97, v1))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.16))
        ctx.setLineWidth(3)
        ctx.strokePath()
    }

    // The deck brackets on the front (outputs) and back (inputs) panels, their prongs pointing to the
    // sockets on the edge beside them.
    let sockets: [CGFloat] = [258, 346, 444, 532]
    let socketU = sockets.map { ($0 - left) / (right - left) }
    ctx.setLineWidth(3)
    for (v, lift) in [(CGFloat(0.13), CGFloat(0.05)), (0.84, -0.05)] {
        for (u0, u1) in [(socketU[0], socketU[1]), (socketU[2], socketU[3])] {
            var bracket = Strokes()
            bracket.line(u0, v - lift); bracket.line(u0, v); bracket.line(u1, v); bracket.line(u1, v - lift)
            ctx.addPath(bracket.path(top))
            ctx.setStrokeColor(rgb(0.92, 0.92, 0.93, 0.85))
            ctx.strokePath()
        }
        var join = Strokes()
        join.line(socketU[1], v); join.line(socketU[2], v)
        ctx.addPath(join.path(top))
        ctx.setStrokeColor(rgb(0.90, 0.20, 0.18))
        ctx.strokePath()
    }

    // "SL2", lying on the top face: S and L in white, 2 in red. The box is a little deeper than it is wide.
    let face = CGSize(width: 688, height: 640)
    let (v0, v1): (CGFloat, CGFloat) = (0.40, 0.60)
    let (ru, rv) = (26 / face.width, 26 / face.height)
    ctx.addPath(letterS(0.17, v0, 0.38, v1, ru, rv).outline(top, width: 24, size: face))
    ctx.addPath(letterL(0.44, v0, 0.62, v1).outline(top, width: 24, size: face))
    ctx.setFillColor(rgb(0.95, 0.95, 0.96))
    ctx.fillPath()
    ctx.addPath(letter2(0.68, v0, 0.86, v1, ru, rv).outline(top, width: 24, size: face))
    ctx.setFillColor(rgb(0.90, 0.20, 0.18))
    ctx.fillPath()

    // Along the front: four gold RCA sockets (white and red inserts), the yellow and blue lights, the USB socket.
    let socketY = (frontBottom + frontTop) / 2
    for (i, x) in sockets.enumerated() {
        ctx.setFillColor(rgb(0.04, 0.04, 0.04))
        ctx.fillEllipse(in: CGRect(x: x - 34, y: socketY - 34, width: 68, height: 68))
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: x - 29, y: socketY - 29, width: 58, height: 58))
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(1.0, 0.90, 0.62), rgb(0.78, 0.58, 0.24), rgb(0.55, 0.38, 0.13)]),
                               start: CGPoint(x: x - 20, y: socketY + 29), end: CGPoint(x: x + 20, y: socketY - 29),
                               options: [])
        ctx.restoreGState()
        ctx.setFillColor(i % 2 == 0 ? rgb(0.93, 0.93, 0.92) : rgb(0.86, 0.18, 0.16))
        ctx.fillEllipse(in: CGRect(x: x - 18, y: socketY - 18, width: 36, height: 36))
        ctx.setFillColor(rgb(0.05, 0.05, 0.05))
        ctx.fillEllipse(in: CGRect(x: x - 7, y: socketY - 7, width: 14, height: 14))
    }
    for (x, colour, glow) in [(CGFloat(652), rgb(0.98, 0.80, 0.20), false), (700, rgb(0.35, 0.55, 1.0), true)] {
        ctx.saveGState()
        if glow { ctx.setShadow(offset: .zero, blur: 26, color: rgb(0.30, 0.50, 1.0, 1)) }
        ctx.setFillColor(colour)
        ctx.fillEllipse(in: CGRect(x: x - 11, y: socketY - 11, width: 22, height: 22))
        ctx.restoreGState()
    }
    let usb = CGRect(x: 768, y: socketY - 16, width: 52, height: 32)
    ctx.addPath(CGPath(roundedRect: usb, cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.setFillColor(rgb(0.03, 0.03, 0.03))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: usb.insetBy(dx: 10, dy: 10), cornerWidth: 2, cornerHeight: 2, transform: nil))
    ctx.setFillColor(rgb(0.55, 0.56, 0.58))
    ctx.fillPath()
}

func writePNG(pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
