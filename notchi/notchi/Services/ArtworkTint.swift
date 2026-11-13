import AppKit
import SwiftUI

/// Picks a lively accent colour from album art, so the Spotify page follows the cover.
enum ArtworkPalette {
    /// Neutral covers keep a neutral accent instead of inheriting an unrelated orange.
    static func referenceColor(in image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        if let color = dominantColor(in: image) { return color }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard pixel[3] > 127 else { return nil }
        let average = (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * Double(pixel[3]))
        let grey = min(0.82, max(0.62, average))
        return (grey, grey, grey)
    }

    /// Dominant hue of the picture, pushed into a range that stays readable on black.
    /// Returns nil for (nearly) grey artwork, where the default accent looks better.
    static func dominantColor(in image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bins)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let red = Double(pixels[index]) / 255 / alpha
            let green = Double(pixels[index + 1]) / 255 / alpha
            let blue = Double(pixels[index + 2]) / 255 / alpha
            let (hue, saturation, value) = hsv(red: red, green: green, blue: blue)
            let strength = saturation * value
            guard strength > 0.08 else { continue }
            let bin = min(bins - 1, Int(hue * Double(bins)))
            weight[bin] += strength
            sums[bin].r += red * strength
            sums[bin].g += green * strength
            sums[bin].b += blue * strength
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 1.5 else { return nil }
        let average = (r: sums[best].r / weight[best], g: sums[best].g / weight[best], b: sums[best].b / weight[best])
        var (hue, saturation, value) = hsv(red: average.r, green: average.g, blue: average.b)
        saturation = max(saturation, 0.5)
        value = min(max(value, 0.6), 0.9)
        let rgb = rgb(hue: hue, saturation: saturation, value: value)
        return (rgb.r, rgb.g, rgb.b)
    }

    static func hsv(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == green { hue = (blue - red) / delta + 2 }
            else { hue = (red - green) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum == 0 ? 0 : delta / maximum, maximum)
    }

    static func rgb(hue: Double, saturation: Double, value: Double) -> (r: Double, g: Double, b: Double) {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - floor(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - fraction * saturation)
        let t = value * (1 - (1 - fraction) * saturation)
        switch index {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }
}

@MainActor
final class ArtworkTintLoader {
    static let shared = ArtworkTintLoader()
    private var cache: [String: Color?] = [:]

    func tint(for urlString: String) async -> Color? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        if let cached = cache[urlString] { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let color = ArtworkPalette.referenceColor(in: image).map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        if cache.count > 40 { cache.removeAll() }
        cache[urlString] = color
        return color
    }
}
