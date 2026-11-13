import AppKit
import SwiftUI

/// Content uses a standard macOS material. Glass belongs to the floating controls,
/// rather than every card and label (Apple HIG, Materials).
struct PanelContentMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        // The notch panel has a dark visual identity, including its collapsed state.
        // Match the native material to its foreground instead of drawing white on light glass.
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PanelNavigationMaterial: ViewModifier {
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled {
            // Apply after padding/foreground styling so the material receives its content.
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
        }
    }
}

struct PanelRailMaterial: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 0)) }
        else { content }
    }
}
