import SwiftUI

/// «Как вспомнил?» — после засчитанного удержания; 12 с без ответа — закрывается без оценки.
struct QualityOverlay: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.qPending != nil {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { model.qClose() }
                    .transition(.opacity)
                VStack(spacing: 14) {
                    Text("Как вспомнил?").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
                    HStack(spacing: 8) {
                        qButton("Ясно", .qc, bg: 0xecfdf5, border: 0x6ee7b7, fg: 0x065f46)
                        qButton("Средне", .qm, bg: 0xfffbeb, border: 0xfcd34d, fg: 0x92400e)
                        qButton("Автомат", .qa, bg: 0xf3f4f6, border: 0xd1d5db, fg: 0x4b5563)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 18)
                .frame(maxWidth: 520)
                .background(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                    .fill(Palette.surface).ignoresSafeArea(edges: .bottom))
                .shadow(color: .black.opacity(0.15), radius: 15, y: -8)
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.qPending)
    }

    private func qButton(_ t: String, _ k: QKey, bg: UInt32, border: UInt32, fg: UInt32) -> some View {
        Button { model.qPick(k) } label: {
            Text(t).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(hex: fg))
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(Color(hex: bg), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: border)))
        }
        .buttonStyle(.plain)
    }
}

/// Ачивки 25 / 50 / 75 / 100 (Кхечара) — один раз за день, в момент достижения.
struct AchievementOverlay: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            if let m = model.achievement {
                Color.black.opacity(0.55).ignoresSafeArea().transition(.opacity)
                VStack(spacing: 0) {
                    Text(m.label).font(.system(size: 11)).kerning(1.6).foregroundStyle(Palette.text3).padding(.bottom, 4)
                    Text("\(m.n)").font(.system(size: 52, weight: .bold)).foregroundStyle(Color(hex: m.colorHex)).padding(.bottom, 3)
                    Group {
                        if m.khechara { KhecharaScene() } else { MilestoneGem(colorHex: m.colorHex) }
                    }
                    .padding(.vertical, 12)
                    Text(m.sub).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.text).padding(.bottom, 20)
                    Button { model.achievement = nil } label: {
                        Text("Продолжить").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Color(hex: m.colorHex), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 22)
                .frame(maxWidth: 320)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.2), radius: 30, y: 20)
                .padding(20)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.achievement)
    }
}

/// gemSVG(color) из веба.
struct MilestoneGem: View {
    let colorHex: UInt32
    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 72
            let c = Color(hex: colorHex)
            let r = (colorHex >> 16) & 0xFF, g = (colorHex >> 8) & 0xFF, b = colorHex & 0xFF
            let dark = Color(hex: (UInt32(max(0, Int(r) - 60)) << 16) | (UInt32(max(0, Int(g) - 60)) << 8) | UInt32(max(0, Int(b) - 60)))
            let faces: [([(CGFloat, CGFloat)], Color, Double)] = [
                ([(36, 5), (65, 25), (36, 67), (7, 25)], c, 0.2),
                ([(36, 5), (65, 25), (36, 38)], .white, 0.85),
                ([(7, 25), (36, 38), (36, 67)], dark, 0.9),
                ([(65, 25), (36, 38), (36, 67)], c, 0.85),
                ([(36, 5), (65, 25), (36, 25)], .white, 0.95),
                ([(36, 5), (7, 25), (36, 25)], c, 0.7),
                ([(7, 25), (36, 25), (36, 38)], c, 0.5),
                ([(65, 25), (36, 25), (36, 38)], dark, 0.6),
            ]
            for (pts, col, op) in faces {
                var p = Path()
                p.addLines(pts.map { CGPoint(x: $0.0 * k, y: $0.1 * k) })
                p.closeSubpath()
                ctx.fill(p, with: .color(col.opacity(op)))
            }
        }
        .frame(width: 72, height: 72)
    }
}

/// Сцена Кхечары: ночное небо, мерцающие звёзды, свечение, надпись.
struct KhecharaScene: View {
    @State private var glow = false
    private let stars: [(CGFloat, CGFloat, CGFloat)] = (0..<45).map { i in
        let a = Double(i) * 12.9898, b = Double(i) * 78.233
        let x = CGFloat((sin(a) * 43758.5453).truncatingRemainder(dividingBy: 1)).magnitude
        let y = CGFloat((sin(b) * 12345.678).truncatingRemainder(dividingBy: 1)).magnitude * 0.8
        let s = 0.4 + CGFloat((sin(a + b) * 999).truncatingRemainder(dividingBy: 1)).magnitude * 2.2
        return (x, y, s)
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                LinearGradient(stops: [.init(color: Color(hex: 0x04041a), location: 0), .init(color: Color(hex: 0x1a0a60), location: 0.5),
                                       .init(color: Color(hex: 0x7c3aed), location: 0.85), .init(color: Color(hex: 0xddd6fe), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                ForEach(0..<stars.count, id: \.self) { i in
                    let st = stars[i]
                    Circle().fill(.white).frame(width: st.2, height: st.2)
                        .position(x: st.0 * g.size.width, y: st.1 * g.size.height)
                        .opacity(glow ? (i % 2 == 0 ? 1 : 0.2) : (i % 2 == 0 ? 0.2 : 1))
                }
                Circle().fill(RadialGradient(colors: [Color(hex: 0xc4b5fd, opacity: 0.4), .clear], center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 140, height: 140)
                    .scaleEffect(glow ? 1.4 : 1)
                    .position(x: g.size.width / 2, y: g.size.height * 0.35)
                GemShapeView(size: 64).position(x: g.size.width / 2, y: g.size.height * 0.42)
                VStack(spacing: 2) {
                    Text("Кхечара").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                        .shadow(color: Color(hex: 0xa78bfa), radius: 10)
                    Text("небеса открыты").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                .position(x: g.size.width / 2, y: g.size.height - 28)
            }
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { glow = true } }
    }
}
