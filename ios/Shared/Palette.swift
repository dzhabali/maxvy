import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// CSS-токены vajra-tracker.html.
enum Palette {
    static let bg = Color(hex: 0xf8f9fa)
    static let surface = Color.white
    static let surface2 = Color(hex: 0xf9fafb)
    static let chip = Color(hex: 0xf3f4f6)
    static let border = Color(hex: 0xe5e7eb)
    static let text = Color(hex: 0x111111)
    static let text2 = Color(hex: 0x6b7280)
    static let text3 = Color(hex: 0x9ca3af)
    static let faint = Color(hex: 0xcbd5e1)

    static let mint = Color(hex: 0x0d4a3a)
    static let crimson = Color(hex: 0xc0185a)
    static let crimson2 = Color(hex: 0x96124a)

    static let greenDark = Color(hex: 0x166534)
    static let greenBg = Color(hex: 0xdcfce7)
    static let greenBorder = Color(hex: 0xbbf7d0)
    static let blueBg = Color(hex: 0xdbeafe)
    static let blueBorder = Color(hex: 0xbfdbfe)
    static let blueText = Color(hex: 0x1e40af)
    static let amberBg = Color(hex: 0xfef9c3)
    static let amberBorder = Color(hex: 0xfde68a)
    static let amberText = Color(hex: 0x92400e)

    static let gemBorder = Color(hex: 0xfda4cf)
    static let gemBg = Color(hex: 0xfff0f6)
    static let gemText = Color(hex: 0x9b1040)
}

/// Алмаз из веба (SVG viewBox 60×60, 8 граней).
struct GemShapeView: View {
    var size: CGFloat = 22

    private static let faces: [([CGPoint], UInt32, Double)] = [
        ([p(30, 4), p(56, 22), p(30, 56), p(4, 22)], 0xf472b6, 0.25),
        ([p(30, 4), p(56, 22), p(30, 32)], 0xfce7f3, 0.95),
        ([p(4, 22), p(30, 32), p(30, 56)], 0x9b1040, 0.92),
        ([p(56, 22), p(30, 32), p(30, 56)], 0xbe1257, 0.92),
        ([p(30, 4), p(56, 22), p(30, 22)], 0xffffff, 0.98),
        ([p(30, 4), p(4, 22), p(30, 22)], 0xfda4cf, 0.9),
        ([p(4, 22), p(30, 22), p(30, 32)], 0xe91a6e, 0.7),
        ([p(56, 22), p(30, 22), p(30, 32)], 0xc0185a, 0.7),
    ]
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    var body: some View {
        Canvas { ctx, sz in
            let k = min(sz.width, sz.height) / 60
            for (pts, hex, op) in Self.faces {
                var path = Path()
                path.addLines(pts.map { CGPoint(x: $0.x * k, y: $0.y * k) })
                path.closeSubpath()
                ctx.fill(path, with: .color(Color(hex: hex, opacity: op)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
