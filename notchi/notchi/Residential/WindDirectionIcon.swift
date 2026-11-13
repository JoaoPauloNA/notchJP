import SwiftUI
import AppKit

/// User-supplied SVG artwork, rendered locally at 3× to preserve its glow and gradients.
/// Each variant retains the original appliance, circle and palette; only the active jets change.
struct WindDirectionIcon: View {
    enum Axis: String { case vertical, horizontal }
    let axis: Axis
    let direction: Int
    private static let images = NSCache<NSString, NSImage>()

    private var image: NSImage? {
        let choices = axis == .vertical ? [1, 2, 3, 9, 10, 11, 12, 13] : [1, 2, 3, 4, 9, 10, 11, 12, 13]
        let name = "\(axis.rawValue)-\(choices.contains(direction) ? direction : 0)"
        if let cached = Self.images.object(forKey: name as NSString) { return cached }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Artwork/Directions/\(name).png")
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Artwork/Directions") ?? Bundle.main.url(forResource: name, withExtension: "png") ?? source
        guard let image = NSImage(contentsOf: url) else { return nil }
        Self.images.setObject(image, forKey: name as NSString)
        return image
    }

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
