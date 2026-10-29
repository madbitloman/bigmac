import AppKit
import SwiftUI

/// The BigMac mark: a burger reduced to three geometric layers, a domed bun with sesame cut-outs,
/// a patty bar and a base. Drawn in a unit square so it scales from the menu bar to the 1024 px icon.
struct BurgerMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2, oy = rect.midY - s / 2
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }
        var p = Path()
        // Dome: half-ellipse on top of a short straight band.
        let dome = r(0.06, 0.12, 0.88, 0.40)
        p.move(to: CGPoint(x: dome.minX, y: dome.maxY - 0.02 * s))
        p.addCurve(to: CGPoint(x: dome.midX, y: dome.minY),
                   control1: CGPoint(x: dome.minX, y: dome.minY + dome.height * 0.42),
                   control2: CGPoint(x: dome.minX + dome.width * 0.2, y: dome.minY))
        p.addCurve(to: CGPoint(x: dome.maxX, y: dome.maxY - 0.02 * s),
                   control1: CGPoint(x: dome.maxX - dome.width * 0.2, y: dome.minY),
                   control2: CGPoint(x: dome.maxX, y: dome.minY + dome.height * 0.42))
        p.addQuadCurve(to: CGPoint(x: dome.maxX - 0.02 * s, y: dome.maxY), control: CGPoint(x: dome.maxX, y: dome.maxY))
        p.addLine(to: CGPoint(x: dome.minX + 0.02 * s, y: dome.maxY))
        p.addQuadCurve(to: CGPoint(x: dome.minX, y: dome.maxY - 0.02 * s), control: CGPoint(x: dome.minX, y: dome.maxY))
        p.closeSubpath()
        // Sesame seeds, cut out with even-odd fill.
        for (x, y, angle) in [(0.33, 0.29, -0.5), (0.5, 0.23, 0.0), (0.67, 0.29, 0.5)] as [(CGFloat, CGFloat, CGFloat)] {
            let seed = Path(ellipseIn: CGRect(x: -0.032 * s, y: -0.017 * s, width: 0.064 * s, height: 0.034 * s))
                .applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: ox + x * s, y: oy + y * s)))
            p.addPath(seed)
        }
        p.addRoundedRect(in: r(0.06, 0.585, 0.88, 0.11), cornerSize: CGSize(width: 0.055 * s, height: 0.055 * s))
        p.addRoundedRect(in: r(0.06, 0.755, 0.88, 0.13), cornerSize: CGSize(width: 0.065 * s, height: 0.065 * s))
        return p
    }
}

/// App icon: white mark on a black macOS squircle (1024 grid, 824 tile).
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.035)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous).strokeBorder(.white.opacity(0.09), lineWidth: 2))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            BurgerMark().fill(.white, style: FillStyle(eoFill: true)).frame(width: 470, height: 470).offset(y: 6)
        }
        .frame(width: 1024, height: 1024)
    }
}

enum Logo {
    /// Template image for the menu bar, so macOS tints it for light/dark bars.
    @MainActor static let menuBarImage = renderMenuBarImage()

    @MainActor private static func renderMenuBarImage() -> NSImage {
        let renderer = ImageRenderer(content: BurgerMark().fill(.black, style: FillStyle(eoFill: true)).frame(width: 18, height: 18))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }

    @MainActor static func writeIcon(to url: URL) throws {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        guard let cg = renderer.cgImage else { throw AWSError(message: "icon render failed") }
        let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        try png?.write(to: url)
    }
}

/// Sidebar/menu logo: the mark on a small black tile, matching the app icon.
struct LogoBadge: View {
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color(white: 0.06))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .overlay(BurgerMark().fill(.white, style: FillStyle(eoFill: true)).padding(size * 0.2))
            .frame(width: size, height: size)
    }
}
