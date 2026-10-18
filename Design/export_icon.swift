// Exports Minuta's icon artwork as outlined SVG layers (Apple: vector layers, no background,
// outlines instead of strokes) for the Icon Composer file, plus the menu-bar template image.
// Geometry is the approved "S2, stroke 44" design.
//
//   swiftc -parse-as-library Design/export_icon.swift -o /tmp/export_icon && /tmp/export_icon <repo root>
import CoreGraphics
import Foundation

// MARK: Geometry (same math as the design drafts)

/// Uneven spoken swings, easing to flat, then a straight run.
func voicePath(in r: CGRect, amps: [CGFloat], waveFraction: CGFloat, taper: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let mid = r.midY, half = r.height / 2
    let waveW = r.width * waveFraction
    let seg = waveW / CGFloat(amps.count)
    p.move(to: CGPoint(x: r.minX, y: mid))
    for (k, a) in amps.enumerated() {
        for j in 1...60 {
            let u = CGFloat(j) / 60
            let x = r.minX + (CGFloat(k) + u) * seg
            let pos = (x - r.minX) / waveW
            var ease: CGFloat = 1
            if taper > 0, pos > 1 - taper {
                let t = (pos - (1 - taper)) / taper
                ease = 1 - t * t * (3 - 2 * t)
            }
            p.addLine(to: CGPoint(x: x, y: mid - a * half * sin(.pi * u) * ease))
        }
    }
    p.addLine(to: CGPoint(x: r.maxX, y: mid))
    return p
}

struct Mark {
    var width: CGFloat, waveHeight: CGFloat, stroke: CGFloat
    var amps: [CGFloat], waveFraction: CGFloat, taper: CGFloat
    var lineWidths: [CGFloat], lineThickness: CGFloat, lineGap: CGFloat, textInset: CGFloat

    var height: CGFloat {
        let textTop = waveHeight / 2 + stroke / 2 + lineGap
        let textBottom = textTop + CGFloat(lineWidths.count) * lineThickness + CGFloat(lineWidths.count - 1) * lineGap
        return max(waveHeight, textBottom)
    }

    /// The wave as a filled outline (stroke converted to shape, round caps and joins).
    func wave(origin: CGPoint) -> CGPath {
        let line = voicePath(in: CGRect(x: origin.x, y: origin.y, width: width, height: waveHeight),
                             amps: amps, waveFraction: waveFraction, taper: taper)
        return line.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// The text lines as capsules.
    func lines(origin: CGPoint) -> CGPath {
        let p = CGMutablePath()
        let textTop = waveHeight / 2 + stroke / 2 + lineGap
        for (i, w) in lineWidths.enumerated() {
            let rect = CGRect(x: origin.x + width * waveFraction + textInset,
                              y: origin.y + textTop + CGFloat(i) * (lineThickness + lineGap),
                              width: w, height: lineThickness)
            p.addRoundedRect(in: rect, cornerWidth: lineThickness / 2, cornerHeight: lineThickness / 2)
        }
        return p
    }
}

// MARK: SVG

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { el in
        let pts = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(f(pts[0].x)) \(f(pts[0].y))"
        case .addLineToPoint: d += "L\(f(pts[0].x)) \(f(pts[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y))"
        case .addCurveToPoint: d += "C\(f(pts[0].x)) \(f(pts[0].y)) \(f(pts[1].x)) \(f(pts[1].y)) \(f(pts[2].x)) \(f(pts[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg(_ paths: [CGPath], viewBox: CGRect, size: CGSize? = nil) -> String {
    let w = size.map { " width=\"\(String(format: "%.2f", $0.width))\" height=\"\(String(format: "%.2f", $0.height))\"" } ?? ""
    let body = paths.map { "  <path fill=\"#000000\" fill-rule=\"nonzero\" d=\"\(svgPathData($0))\"/>" }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(viewBox.minX) \(viewBox.minY) \(viewBox.width) \(viewBox.height)"\(w)>
    \(body)
    </svg>

    """
}

// MARK: Main

@main struct Export {
    static func main() throws {
        let root = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

        // App icon: 1024 canvas, mark centered and nudged (18, 16) for optical balance.
        let icon = Mark(width: 450, waveHeight: 420, stroke: 44, amps: [0.35, -0.82, 1.0, -0.62, 0.4, -0.18],
                        waveFraction: 0.68, taper: 0.38, lineWidths: [180, 110],
                        lineThickness: 36 * 44 / 42, lineGap: 46, textInset: -40)
        let origin = CGPoint(x: (1024 - icon.width) / 2 + 18, y: (1024 - icon.height) / 2 + 16)
        let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let assets = root.appending(path: "Minuta/App/AppIcon.icon/Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        // The drafts drew the icon body as an 824-pt rounded square inside 1024; in Icon Composer the
        // whole 1024 layer is the body (the system masks it), so scale the artwork up to match.
        let k: CGFloat = 1024 / 824
        var toBody = CGAffineTransform(translationX: 512, y: 512).scaledBy(x: k, y: k).translatedBy(x: -512, y: -512)
        let lines = icon.lines(origin: origin).copy(using: &toBody)!
        let wave = icon.wave(origin: origin).copy(using: &toBody)!
        try svg([lines], viewBox: canvas).write(to: assets.appending(path: "1-text.svg"), atomically: true, encoding: .utf8)
        try svg([wave], viewBox: canvas).write(to: assets.appending(path: "2-wave.svg"), atomically: true, encoding: .utf8)

        // Menu bar: fewer swings, relatively heavier, as one template image 18 pt tall.
        let glyph = Mark(width: 300, waveHeight: 300, stroke: 32, amps: [0.5, -1.0, 0.62, -0.25],
                         waveFraction: 0.66, taper: 0.4, lineWidths: [120, 70],
                         lineThickness: 30, lineGap: 34, textInset: -26)
        let gWave = glyph.wave(origin: .zero), gLines = glyph.lines(origin: .zero)
        let bounds = gWave.boundingBoxOfPath.union(gLines.boundingBoxOfPath).insetBy(dx: -4, dy: -4)
        let height: CGFloat = 18
        let size = CGSize(width: bounds.width / bounds.height * height, height: height)
        let set = root.appending(path: "Minuta/App/Assets.xcassets/MenuBarIcon.imageset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try svg([gWave, gLines], viewBox: bounds, size: size).write(to: set.appending(path: "MenuBarIcon.svg"), atomically: true, encoding: .utf8)
        print("icon layers →", assets.path, "\nmenu bar image →", set.path, "size", size)
    }
}
