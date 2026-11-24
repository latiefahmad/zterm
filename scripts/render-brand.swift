// Render aset brand Zterm ke PNG.
// Pakai: swift scripts/render-brand.swift icon <out.png> <size>
//        swift scripts/render-brand.swift og <out.png>
import AppKit

func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    let v = UInt64(s.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

let teal = hex("#66E9D0"), blue = hex("#5B9CF5"), violet = hex("#A78BFA")
let bgTop = hex("#0E2B29"), bgMid = hex("#0A0F18"), bgBottom = hex("#191331")

/// Squircle gaya macOS (superellipse) di dalam rect.
func squircle(_ r: CGRect) -> NSBezierPath {
    let p = NSBezierPath()
    let n: CGFloat = 5, steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let pt = NSPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

/// Gambar ikon Zterm di context saat ini, menempati `rect`.
/// Koordinat mengikuti SVG sumber: badan 80% kanvas, Z + kursor di tengah.
func drawIcon(in rect: CGRect) {
    let ctx = NSGraphicsContext.current!.cgContext
    let s = rect.width
    let body = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
    let shape = squircle(body)

    // Latar gelap dengan bias teal di kiri atas dan ungu di kanan bawah.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [bgTop, bgMid, bgBottom])!.draw(in: body, angle: -45)

    NSGradient(colors: [teal.withAlphaComponent(0.30), .clear])!
        .draw(fromCenter: NSPoint(x: body.minX + body.width * 0.22, y: body.maxY - body.height * 0.18), radius: 0,
              toCenter: NSPoint(x: body.minX + body.width * 0.22, y: body.maxY - body.height * 0.18), radius: body.width * 0.72, options: [])
    NSGradient(colors: [violet.withAlphaComponent(0.26), .clear])!
        .draw(fromCenter: NSPoint(x: body.maxX - body.width * 0.08, y: body.minY + body.height * 0.10), radius: 0,
              toCenter: NSPoint(x: body.maxX - body.width * 0.08, y: body.minY + body.height * 0.10), radius: body.width * 0.62, options: [])

    // Grid titik halus, hanya pada ukuran besar.
    if s >= 128 {
        let dot = s * 0.0032, gap = s * 0.0512
        var y = body.minY + gap / 2
        while y < body.maxY {
            var x = body.minX + gap / 2
            while x < body.maxX {
                NSColor.white.withAlphaComponent(0.055).setFill()
                NSBezierPath(ovalIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)).fill()
                x += gap
            }
            y += gap
        }
    }

    // Kilau tipis di bagian atas.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), .clear])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Huruf Z: batang atas, diagonal, batang bawah, lalu blok kursor.
    let w = body.width, h = body.height
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: body.minX + w * x, y: body.minY + h * y)
    }
    let z = NSBezierPath()
    z.move(to: pt(0.278, 0.659))
    z.line(to: pt(0.656, 0.659))
    z.line(to: pt(0.278, 0.354))
    z.line(to: pt(0.565, 0.354))
    z.lineWidth = w * 0.093
    z.lineCapStyle = .round
    z.lineJoinStyle = .round

    let cursor = NSBezierPath(roundedRect: CGRect(x: body.minX + w * 0.626, y: body.minY + h * 0.307,
                                                  width: w * 0.146, height: h * 0.093),
                              xRadius: w * 0.037, yRadius: w * 0.037)

    // Bayangan gelap tipis di belakang huruf agar kontras di latar terang.
    NSColor.black.withAlphaComponent(0.35).setStroke()
    let outline = z.copy() as! NSBezierPath
    outline.lineWidth = z.lineWidth * 1.22
    outline.stroke()
    let cursorOutline = NSBezierPath(roundedRect: cursor.bounds.insetBy(dx: -w * 0.010, dy: -h * 0.014),
                                     xRadius: w * 0.045, yRadius: w * 0.045)
    NSColor.black.withAlphaComponent(0.35).setFill()
    cursorOutline.fill()

    // Isi gradien teal -> biru -> ungu.
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    NSColor.white.setStroke()
    z.stroke()
    NSColor.white.setFill()
    cursor.fill()
    ctx.setBlendMode(.sourceIn)
    NSGradient(colors: [teal, blue, violet])!.draw(in: body, angle: -45)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Border gradien tipis.
    NSGraphicsContext.saveGraphicsState()
    let border = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.0015, dy: s * 0.0015),
                              xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    border.lineWidth = s * 0.003
    teal.withAlphaComponent(0.55).setStroke()
    border.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ size: NSSize, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[2])
switch args[1] {
case "icon":
    let n = CGFloat(Int(args[3]) ?? 1024)
    try! render(NSSize(width: n, height: n)) { drawIcon(in: CGRect(x: 0, y: 0, width: n, height: n)) }.write(to: out)
case "og":
    // Gambar share 1200x630 untuk media sosial.
    let W: CGFloat = 1200, H: CGFloat = 630
    try! render(NSSize(width: W, height: H)) {
        NSGradient(colors: [hex("#0B1517"), hex("#090C12"), hex("#140F26")])!
            .draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: -35)
        NSGradient(colors: [teal.withAlphaComponent(0.20), .clear])!
            .draw(fromCenter: NSPoint(x: 180, y: 600), radius: 0, toCenter: NSPoint(x: 180, y: 600), radius: 620, options: [])
        NSGradient(colors: [violet.withAlphaComponent(0.22), .clear])!
            .draw(fromCenter: NSPoint(x: 1120, y: 60), radius: 0, toCenter: NSPoint(x: 1120, y: 60), radius: 560, options: [])

        drawIcon(in: CGRect(x: 78, y: 165, width: 300, height: 300))

        let title = NSAttributedString(string: "Zterm", attributes: [
            .font: NSFont.systemFont(ofSize: 104, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: NSNumber(value: -2.0),
        ])
        title.draw(at: NSPoint(x: 438, y: 356))
        let sub = NSAttributedString(string: "Semua servermu, satu terminal.", attributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
            .foregroundColor: teal,
        ])
        sub.draw(at: NSPoint(x: 442, y: 292))
        let meta = NSAttributedString(string: "SSH client native  ·  macOS  ·  Windows  ·  Linux", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.58),
        ])
        meta.draw(at: NSPoint(x: 444, y: 238))
        let badge = NSAttributedString(string: "gratis  ·  open source", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium),
            .foregroundColor: teal,
        ])
        badge.draw(at: NSPoint(x: 456, y: 184))
        let url = NSAttributedString(string: "latiefahmad.github.io/zterm", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.42),
        ])
        url.draw(at: NSPoint(x: 80, y: 58))
    }.write(to: out)
default: break
}
