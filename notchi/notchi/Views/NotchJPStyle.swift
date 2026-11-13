import SwiftUI

/// Visual language of notchJP: warm orange accent, capsules and circles, soft cards.
enum NJP {
    /// Chosen in Settings > Aparência; views observe `njp.accentIndex` to redraw.
    static var accent: Color { NJPSettings.accentPalette[NJPSettings.accentIndex].color }
    static let accentSoft = Color(red: 0.93, green: 0.71, blue: 0.55)
    static let good = Color(red: 0.44, green: 0.76, blue: 0.50)
    static let warn = Color(red: 0.91, green: 0.77, blue: 0.28)
    static let bad = Color(red: 0.90, green: 0.39, blue: 0.35)
    static let layer1 = Color(red: 17/255, green: 17/255, blue: 18/255)
    static let layer2 = Color(red: 26/255, green: 26/255, blue: 28/255)
    static let layer3 = Color(red: 37/255, green: 37/255, blue: 40/255)
    static let surface = Color.white.opacity(0.07)
    static let surfaceStrong = Color.white.opacity(0.12)

    /// Colour of a quota bar by how much is left.
    static func level(forRemaining remaining: Int) -> Color {
        remaining > 40 ? good : (remaining > 15 ? warn : bad)
    }
}

/// The notchJP "N" app mark, drawn so it stays sharp at any size.
struct NotchJPMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.88, green: 0.48, blue: 0.30), Color(red: 0.69, green: 0.31, blue: 0.17)],
                    startPoint: .top, endPoint: .bottom))
            Path { path in
                let width = size * 0.40
                let height = size * 0.48
                let originX = size * 0.30
                let originY = size * 0.27
                path.move(to: CGPoint(x: originX, y: originY + height))
                path.addLine(to: CGPoint(x: originX, y: originY))
                path.addLine(to: CGPoint(x: originX + width, y: originY + height))
                path.addLine(to: CGPoint(x: originX + width, y: originY))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: size * 0.095, lineCap: .round, lineJoin: .round))
            UnevenRoundedRectangle(bottomLeadingRadius: size * 0.07, bottomTrailingRadius: size * 0.07)
                .fill(.black)
                .frame(width: size * 0.31, height: size * 0.085)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Rounded surface used for grouped content.
    func njpCard(radius: CGFloat = 20) -> some View {
        background(NJP.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Circular progress used for quotas and Mac health.
struct NJPRing: View {
    var progress: Double
    var color: Color
    var label: String
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(NJP.surfaceStrong, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).font(.system(size: 15, weight: .bold).monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
