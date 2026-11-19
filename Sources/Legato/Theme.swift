import SwiftUI

/// Cobalto: ink, paper and one flat blue, after the Blue Note record sleeves.
enum Theme {
    static let ink = Color(red: 0x0D / 255, green: 0x10 / 255, blue: 0x17 / 255)
    static let paper = Color(red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF6 / 255)
    static let cobalt = Color(red: 0x24 / 255, green: 0x47 / 255, blue: 0xE0 / 255)
    static let cobaltSoft = Color(red: 0x7D / 255, green: 0x99 / 255, blue: 0xFF / 255)
    static let pill = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255)
}

/// The mark: a slur, the arc that ties notes together in a score.
struct SlurMark: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on a 64-unit square, then fitted to the rect.
        let scale = min(rect.width, rect.height) / 64
        let dx = rect.midX - 32 * scale, dy = rect.midY - 32 * scale
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + x * scale, y: dy + y * scale) }
        var path = Path()
        path.move(to: p(8, 41))
        path.addCurve(to: p(56, 41), control1: p(18, 15), control2: p(46, 15))
        path.addCurve(to: p(8, 41), control1: p(46, 25), control2: p(18, 25))
        path.closeSubpath()
        return path
    }
}

/// The same arc as an open line, used for the "working" animation.
struct SlurLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control1: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY - rect.height * 0.3),
            control2: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY - rect.height * 0.3))
        return path
    }
}
