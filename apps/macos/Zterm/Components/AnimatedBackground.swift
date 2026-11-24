import SwiftUI

/// Background mesh gradient yang bergerak pelan + grid titik berkilau.
struct AnimatedBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var palette: [Color] {
        scheme == .dark
            ? ["#05070B", "#0A1A20", "#07090F", "#0B1A2E", "#0F3B3A", "#160F2A", "#05070B", "#101532", "#05070B"].map(Color.init(hex:))
            : ["#F7FAFC", "#E3F6F2", "#F4F6FB", "#E6EEFB", "#C9F0E7", "#EEE8FB", "#F8FAFC", "#E4E9FA", "#F7F8FB"].map(Color.init(hex:))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [Float(0.5 + 0.18 * sin(t * 0.35)), Float(0.5 + 0.16 * cos(t * 0.28))], [1, 0.5],
                        [0, 1], [Float(0.5 + 0.2 * cos(t * 0.22)), 1], [1, 1],
                    ],
                    colors: palette
                )
                DotGrid(time: t)
                    .blendMode(scheme == .dark ? .plusLighter : .normal)
                    .opacity(scheme == .dark ? 0.55 : 0.4)
            }
        }
        .ignoresSafeArea()
    }
}

private struct DotGrid: View {
    let time: TimeInterval

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 28
            let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
            let maxDist = hypot(size.width, size.height) / 2
            var y: CGFloat = gap / 2
            while y < size.height {
                var x: CGFloat = gap / 2
                while x < size.width {
                    let d = hypot(x - center.x, y - center.y)
                    // Gelombang yang memancar dari tengah
                    let wave = (sin(d / 38 - time * 1.4) + 1) / 2
                    let fade = max(0, 1 - d / maxDist)
                    let a = 0.04 + 0.22 * wave * fade
                    let r: CGFloat = 1 + wave * fade * 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(Theme.accent.opacity(a)))
                    x += gap
                }
                y += gap
            }
        }
    }
}

/// Logo Zterm: squircle gelap, border gradien, simbol `>_` bergradien dengan glow;
/// garis bawah kursor berkedip.
struct ZtermLogo: View {
    var size: CGFloat = 76
    @State private var blink = false
    @State private var glow = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: "#151C2B"), Color(hex: "#080A10")], startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [Theme.accent.opacity(0.45), .clear], center: UnitPoint(x: 0.35, y: -0.05),
                                      startRadius: 0, endRadius: size * 0.75))
            shape.strokeBorder(Theme.brandGradient, lineWidth: max(1, size * 0.03))
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: size * 0.25, y: size * 0.29))
                    p.addLine(to: CGPoint(x: size * 0.46, y: size * 0.50))
                    p.addLine(to: CGPoint(x: size * 0.25, y: size * 0.71))
                }
                .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: size * 0.095, lineCap: .round, lineJoin: .round))
                Capsule()
                    .fill(Theme.brandGradient)
                    .frame(width: size * 0.25, height: size * 0.095)
                    .offset(x: size * 0.50, y: size * 0.66)
                    .opacity(blink ? 0.25 : 1)
            }
            .frame(width: size, height: size, alignment: .topLeading)
            .shadow(color: Theme.accent.opacity(glow ? 0.9 : 0.5), radius: size * 0.08)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(glow ? 0.35 : 0.15), radius: size * 0.2)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { blink = true }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

/// Teks dengan efek mengetik.
struct TypewriterText: View {
    let text: String
    var speed: Double = 0.035
    var delay: Double = 0
    @State private var shown = 0

    var body: some View {
        (Text(String(text.prefix(shown)))
            + Text(shown < text.count ? "▍" : "").foregroundColor(Theme.accent))
            .task {
                try? await Task.sleep(for: .seconds(delay))
                while shown < text.count {
                    shown += 1
                    try? await Task.sleep(for: .seconds(speed))
                }
            }
    }

    init(_ text: String, speed: Double = 0.035, delay: Double = 0) {
        self.text = text
        self.speed = speed
        self.delay = delay
    }
}

/// Muncul berurutan (fade + naik) dengan delay.
struct StaggerIn: ViewModifier {
    let index: Int
    var base: Double = 0.25
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 8)
            .onAppear {
                guard !visible else { return }
                withAnimation(.zterm.delay(base + Double(min(index, 8)) * 0.045)) { visible = true }
            }
    }
}

extension View {
    func staggerIn(_ index: Int, base: Double = 0.25) -> some View { modifier(StaggerIn(index: index, base: base)) }
}
