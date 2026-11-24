import SwiftUI

/// Renders authentic TikTok-style secret expression stickers (`[wronged]`, `[lovely]`, `[proud]`, etc.)
/// crisp at any size cleanly offline using vector Canvas art, with graceful fallback for legacy emoji strings.
struct TikTokStickerView: View {
    let rawSticker: String
    var size: CGFloat = 44
    var showCodeBadge: Bool = false

    private var code: String {
        rawSticker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var remoteURL: URL? {
        let trimmed = rawSticker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") else { return nil }
        return URL(string: trimmed)
    }

    private var isTikTokSticker: Bool {
        GroupPlaylistStickerPalette.isTikTokCode(code)
    }

    var body: some View {
        VStack(spacing: 3) {
            if let remoteURL {
                AnimatedTikTokImageView(url: remoteURL, contentMode: .scaleAspectFit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: max(8, size * 0.22), style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: max(2, size * 0.08), y: max(1, size * 0.04))
            } else if isTikTokSticker {
                Canvas { ctx, canvasSize in
                    drawTikTokFace(in: &ctx, size: canvasSize, code: code)
                }
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.22), radius: max(2, size * 0.08), y: max(1, size * 0.04))
            } else {
                Text(rawSticker)
                    .font(.system(size: size * 0.82))
                    .frame(width: size, height: size)
            }

            if showCodeBadge && isTikTokSticker {
                Text(code)
                    .font(.system(size: max(8, size * 0.2), weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func drawTikTokFace(in ctx: inout GraphicsContext, size: CGSize, code: String) {
        let w = size.width
        let h = size.height
        let pad = w * 0.06
        let faceRect = CGRect(x: pad, y: pad, width: w - pad * 2, height: h - pad * 2)
        let cx = w * 0.5
        let cy = h * 0.52

        // TikTok's signature soft dumpling / rounded circle base palette per expression
        let gradientColors: [Color] = {
            switch code {
            case "[cry]", "[scream]":
                return [Color(red: 0.66, green: 0.89, blue: 0.98), Color(red: 1.0, green: 0.88, blue: 0.72)]
            case "[rage]":
                return [Color(red: 0.99, green: 0.42, blue: 0.36), Color(red: 1.0, green: 0.78, blue: 0.55)]
            case "[evil]":
                return [Color(red: 0.68, green: 0.46, blue: 0.96), Color(red: 0.92, green: 0.75, blue: 0.98)]
            case "[nap]":
                return [Color(red: 0.78, green: 0.76, blue: 0.98), Color(red: 0.98, green: 0.86, blue: 0.88)]
            case "[wicked]", "[cool]":
                return [Color(red: 0.72, green: 0.96, blue: 0.84), Color(red: 1.0, green: 0.89, blue: 0.68)]
            case "[lovely]", "[flushed]":
                return [Color(red: 1.0, green: 0.80, blue: 0.86), Color(red: 1.0, green: 0.91, blue: 0.76)]
            default:
                return [Color(red: 1.0, green: 0.90, blue: 0.64), Color(red: 1.0, green: 0.78, blue: 0.58)]
            }
        }()

        // Halo / horns behind or perched above face
        if code == "[angel]" {
            var halo = Path()
            halo.addEllipse(in: CGRect(x: cx - w * 0.28, y: h * 0.015, width: w * 0.56, height: h * 0.13))
            ctx.stroke(halo, with: .color(Color(red: 1.0, green: 0.84, blue: 0.2)), lineWidth: max(2, w * 0.06))
        } else if code == "[evil]" {
            for sign in [-1.0, 1.0] {
                var horn = Path()
                horn.move(to: CGPoint(x: cx + sign * w * 0.22, y: h * 0.17))
                horn.addQuadCurve(
                    to: CGPoint(x: cx + sign * w * 0.35, y: h * 0.02),
                    control: CGPoint(x: cx + sign * w * 0.36, y: h * 0.12)
                )
                horn.addQuadCurve(
                    to: CGPoint(x: cx + sign * w * 0.12, y: h * 0.15),
                    control: CGPoint(x: cx + sign * w * 0.20, y: h * 0.08)
                )
                horn.closeSubpath()
                ctx.fill(horn, with: .color(Color(red: 0.45, green: 0.20, blue: 0.78)))
            }
        }

        let headPath = Path(roundedRect: faceRect, cornerRadius: w * 0.43, style: .continuous)
        ctx.fill(
            headPath,
            with: .linearGradient(
                Gradient(colors: gradientColors),
                startPoint: CGPoint(x: w * 0.5, y: faceRect.minY),
                endPoint: CGPoint(x: w * 0.5, y: faceRect.maxY)
            )
        )
        ctx.stroke(headPath, with: .color(.white.opacity(0.45)), lineWidth: max(1, w * 0.025))

        // Rosy blush cheeks
        if ["[proud]", "[wronged]", "[lovely]", "[flushed]", "[yummy]", "[angel]", "[wow]"].contains(code) {
            let blushW = w * 0.17
            let blushH = h * 0.10
            let blushColor = Color(red: 1.0, green: 0.36, blue: 0.46).opacity(code == "[flushed]" ? 0.65 : 0.42)
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.14, y: h * 0.54, width: blushW, height: blushH)), with: .color(blushColor))
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.69, y: h * 0.54, width: blushW, height: blushH)), with: .color(blushColor))
        }

        let ink = Color(red: 0.18, green: 0.13, blue: 0.16)
        let strokeW = max(1.5, w * 0.048)

        // Eyes & expression details
        switch code {
        case "[cool]":
            // TikTok dark shades
            let leftLens = Path(roundedRect: CGRect(x: w * 0.17, y: h * 0.36, width: w * 0.28, height: h * 0.20), cornerRadius: w * 0.06)
            let rightLens = Path(roundedRect: CGRect(x: w * 0.55, y: h * 0.36, width: w * 0.28, height: h * 0.20), cornerRadius: w * 0.06)
            ctx.fill(leftLens, with: .color(Color(red: 0.10, green: 0.10, blue: 0.13)))
            ctx.fill(rightLens, with: .color(Color(red: 0.10, green: 0.10, blue: 0.13)))
            var bridge = Path()
            bridge.move(to: CGPoint(x: w * 0.44, y: h * 0.42))
            bridge.addLine(to: CGPoint(x: w * 0.56, y: h * 0.42))
            ctx.stroke(bridge, with: .color(Color(red: 0.10, green: 0.10, blue: 0.13)), lineWidth: strokeW)

        case "[lovely]":
            for eyeX in [w * 0.32, w * 0.68] {
                let heart = heartPath(center: CGPoint(x: eyeX, y: h * 0.45), size: w * 0.16)
                ctx.fill(heart, with: .color(Color(red: 0.96, green: 0.18, blue: 0.42)))
            }
            let miniHeart = heartPath(center: CGPoint(x: w * 0.84, y: h * 0.20), size: w * 0.14)
            ctx.fill(miniHeart, with: .color(Color(red: 1.0, green: 0.25, blue: 0.48)))

        case "[laughwithtears]":
            // "> <" eyes + sky-blue tears
            var le = Path()
            le.move(to: CGPoint(x: w * 0.23, y: h * 0.39))
            le.addLine(to: CGPoint(x: w * 0.37, y: h * 0.45))
            le.addLine(to: CGPoint(x: w * 0.23, y: h * 0.51))
            var re = Path()
            re.move(to: CGPoint(x: w * 0.77, y: h * 0.39))
            re.addLine(to: CGPoint(x: w * 0.63, y: h * 0.45))
            re.addLine(to: CGPoint(x: w * 0.77, y: h * 0.51))
            ctx.stroke(le, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))
            ctx.stroke(re, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))

            let tearColor = Color(red: 0.16, green: 0.72, blue: 0.98)
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.10, y: h * 0.50, width: w * 0.13, height: h * 0.18)), with: .color(tearColor))
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.77, y: h * 0.50, width: w * 0.13, height: h * 0.18)), with: .color(tearColor))

        case "[cry]":
            let tearStream = Color(red: 0.20, green: 0.75, blue: 0.98).opacity(0.85)
            ctx.fill(Path(roundedRect: CGRect(x: w * 0.26, y: h * 0.48, width: w * 0.11, height: h * 0.38), cornerRadius: w * 0.05), with: .color(tearStream))
            ctx.fill(Path(roundedRect: CGRect(x: w * 0.63, y: h * 0.48, width: w * 0.11, height: h * 0.38), cornerRadius: w * 0.05), with: .color(tearStream))
            for eyeX in [w * 0.27, w * 0.61] {
                var brow = Path()
                brow.move(to: CGPoint(x: eyeX, y: h * 0.45))
                brow.addQuadCurve(to: CGPoint(x: eyeX + w * 0.12, y: h * 0.45), control: CGPoint(x: eyeX + w * 0.06, y: h * 0.38))
                ctx.stroke(brow, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            }

        case "[nap]":
            for eyeX in [w * 0.26, w * 0.60] {
                var arc = Path()
                arc.move(to: CGPoint(x: eyeX, y: h * 0.46))
                arc.addQuadCurve(to: CGPoint(x: eyeX + w * 0.14, y: h * 0.46), control: CGPoint(x: eyeX + w * 0.07, y: h * 0.52))
                ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            }
            // Translucent snot/sleep bubble
            let bubble = Path(ellipseIn: CGRect(x: w * 0.55, y: h * 0.60, width: w * 0.22, height: h * 0.22))
            ctx.fill(bubble, with: .color(Color.white.opacity(0.65)))
            ctx.stroke(bubble, with: .color(Color(red: 0.55, green: 0.78, blue: 0.98)), lineWidth: max(1, w * 0.03))

        case "[proud]", "[yummy]":
            for (idx, eyeX) in [w * 0.25, w * 0.61].enumerated() {
                var arc = Path()
                if code == "[yummy]" && idx == 1 {
                    arc.move(to: CGPoint(x: eyeX, y: h * 0.46))
                    arc.addLine(to: CGPoint(x: eyeX + w * 0.13, y: h * 0.42))
                } else {
                    arc.move(to: CGPoint(x: eyeX, y: h * 0.47))
                    arc.addQuadCurve(to: CGPoint(x: eyeX + w * 0.14, y: h * 0.47), control: CGPoint(x: eyeX + w * 0.07, y: h * 0.38))
                }
                ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            }

        default:
            // Classic expressive TikTok pupils + crisp catchlights
            let r = (code == "[flushed]" || code == "[wronged]" || code == "[wow]") ? w * 0.095 : w * 0.075
            for eyeX in [w * 0.34, w * 0.66] {
                ctx.fill(Path(ellipseIn: CGRect(x: eyeX - r, y: h * 0.44 - r, width: r * 2, height: r * 2)), with: .color(ink))
                let shine = r * 0.42
                ctx.fill(Path(ellipseIn: CGRect(x: eyeX - r * 0.45, y: h * 0.44 - r * 0.55, width: shine, height: shine)), with: .color(.white))
            }
            if code == "[rage]" || code == "[evil]" {
                var lb = Path()
                lb.move(to: CGPoint(x: w * 0.24, y: h * 0.30))
                lb.addLine(to: CGPoint(x: w * 0.42, y: h * 0.37))
                var rb = Path()
                rb.move(to: CGPoint(x: w * 0.76, y: h * 0.30))
                rb.addLine(to: CGPoint(x: w * 0.58, y: h * 0.37))
                ctx.stroke(lb, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
                ctx.stroke(rb, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            } else if code == "[wronged]" {
                var lb = Path()
                lb.move(to: CGPoint(x: w * 0.24, y: h * 0.35))
                lb.addLine(to: CGPoint(x: w * 0.40, y: h * 0.31))
                var rb = Path()
                rb.move(to: CGPoint(x: w * 0.76, y: h * 0.35))
                rb.addLine(to: CGPoint(x: w * 0.60, y: h * 0.31))
                ctx.stroke(lb, with: .color(ink), style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round))
                ctx.stroke(rb, with: .color(ink), style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round))
            }
        }

        // Mouths & extra TikTok signature touches
        switch code {
        case "[scream]", "[wow]":
            let mouthRect = CGRect(x: cx - w * 0.085, y: h * 0.60, width: w * 0.17, height: code == "[scream]" ? h * 0.21 : h * 0.16)
            ctx.fill(Path(ellipseIn: mouthRect), with: .color(Color(red: 0.45, green: 0.12, blue: 0.20)))
            if code == "[scream]" {
                let drop = Path(ellipseIn: CGRect(x: w * 0.78, y: h * 0.22, width: w * 0.10, height: h * 0.15))
                ctx.fill(drop, with: .color(Color(red: 0.25, green: 0.75, blue: 1.0)))
            }
        case "[wronged]":
            var pout = Path()
            pout.move(to: CGPoint(x: cx - w * 0.07, y: h * 0.66))
            pout.addQuadCurve(to: CGPoint(x: cx + w * 0.07, y: h * 0.66), control: CGPoint(x: cx, y: h * 0.61))
            ctx.stroke(pout, with: .color(ink), style: StrokeStyle(lineWidth: strokeW * 0.85, lineCap: .round))
            // TikTok signature shy poking fingers at bottom center
            let leftFinger = Path(roundedRect: CGRect(x: cx - w * 0.20, y: h * 0.74, width: w * 0.18, height: h * 0.11), cornerRadius: h * 0.055)
            let rightFinger = Path(roundedRect: CGRect(x: cx + w * 0.02, y: h * 0.74, width: w * 0.18, height: h * 0.11), cornerRadius: h * 0.055)
            ctx.fill(leftFinger, with: .color(Color(red: 1.0, green: 0.85, blue: 0.62)))
            ctx.fill(rightFinger, with: .color(Color(red: 1.0, green: 0.85, blue: 0.62)))
            ctx.stroke(leftFinger, with: .color(ink.opacity(0.6)), lineWidth: max(1, w * 0.025))
            ctx.stroke(rightFinger, with: .color(ink.opacity(0.6)), lineWidth: max(1, w * 0.025))
        case "[cry]", "[rage]":
            var frown = Path()
            frown.move(to: CGPoint(x: cx - w * 0.12, y: h * 0.72))
            frown.addQuadCurve(to: CGPoint(x: cx + w * 0.12, y: h * 0.72), control: CGPoint(x: cx, y: h * 0.60))
            ctx.stroke(frown, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
        case "[thinking]", "[wicked]":
            var smirk = Path()
            smirk.move(to: CGPoint(x: cx - w * 0.10, y: h * 0.68))
            smirk.addQuadCurve(to: CGPoint(x: cx + w * 0.12, y: h * 0.62), control: CGPoint(x: cx + w * 0.04, y: h * 0.68))
            ctx.stroke(smirk, with: .color(ink), style: StrokeStyle(lineWidth: strokeW * 0.9, lineCap: .round))
        case "[laughwithtears]":
            var laugh = Path()
            laugh.move(to: CGPoint(x: cx - w * 0.16, y: h * 0.60))
            laugh.addLine(to: CGPoint(x: cx + w * 0.16, y: h * 0.60))
            laugh.addQuadCurve(to: CGPoint(x: cx - w * 0.16, y: h * 0.60), control: CGPoint(x: cx, y: h * 0.82))
            ctx.fill(laugh, with: .color(Color(red: 0.45, green: 0.12, blue: 0.20)))
        case "[nap]":
            var smallO = Path(ellipseIn: CGRect(x: cx - w * 0.05, y: h * 0.63, width: w * 0.10, height: h * 0.09))
            ctx.fill(smallO, with: .color(ink.opacity(0.75)))
        default:
            var smile = Path()
            smile.move(to: CGPoint(x: cx - w * 0.13, y: h * 0.62))
            smile.addQuadCurve(to: CGPoint(x: cx + w * 0.13, y: h * 0.62), control: CGPoint(x: cx, y: cy + h * 0.24))
            ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: strokeW, lineCap: .round))
            if code == "[yummy]" {
                let tongue = Path(roundedRect: CGRect(x: cx + w * 0.02, y: h * 0.65, width: w * 0.11, height: h * 0.13), cornerRadius: w * 0.055)
                ctx.fill(tongue, with: .color(Color(red: 1.0, green: 0.36, blue: 0.48)))
            }
        }
    }

    private func heartPath(center: CGPoint, size: CGFloat) -> Path {
        var p = Path()
        let r = size * 0.5
        p.move(to: CGPoint(x: center.x, y: center.y + r * 0.85))
        p.addCurve(
            to: CGPoint(x: center.x - r, y: center.y - r * 0.15),
            control1: CGPoint(x: center.x - r * 0.25, y: center.y + r * 0.45),
            control2: CGPoint(x: center.x - r, y: center.y + r * 0.20)
        )
        p.addArc(
            center: CGPoint(x: center.x - r * 0.5, y: center.y - r * 0.25),
            radius: r * 0.5,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        p.addArc(
            center: CGPoint(x: center.x + r * 0.5, y: center.y - r * 0.25),
            radius: r * 0.5,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        p.addCurve(
            to: CGPoint(x: center.x, y: center.y + r * 0.85),
            control1: CGPoint(x: center.x + r, y: center.y + r * 0.20),
            control2: CGPoint(x: center.x + r * 0.25, y: center.y + r * 0.45)
        )
        return p
    }
}
