import SwiftUI
import AppKit
import WebKit

enum ApplianceArtwork {
    static func resourceName(running: Bool, airflow: ACAirflow) -> String {
        if !running { return "ar-condicionado-desligado" }
        return airflow == .off ? "ar-condicionado-ligado" : "ar-condicionado-direcao-vento"
    }

    static func svg(running: Bool, temperature: Double?, airflow: ACAirflow) -> String {
        let name = resourceName(running: running, airflow: airflow)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Artwork/\(name).svg")
        let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Artwork") ?? Bundle.main.url(forResource: name, withExtension: "svg") ?? source
        guard var document = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let value = temperature.flatMap { $0.isFinite ? "\(Int($0.rounded()))°C" : nil } ?? "—"
        document = document.replacingOccurrences(of: ">21°C</text>", with: ">\(value)</text>")
        document = document.replacingOccurrences(of: "<g opacity=\"0.85\">", with: "<g id=\"horizontal-spread-indicator\" opacity=\"0.85\">")
        return document
    }

    static func html(running: Bool, temperature: Double?, airflow: ACAirflow, reduceMotion: Bool, cropped: Bool = false) -> String {
        var document = svg(running: running, temperature: temperature, airflow: airflow)
        if cropped { document = document.replacingOccurrences(of: "viewBox=\"0 0 400 280\"", with: "viewBox=\"44 28 320 246\"") }
        let directionStyle: String
        switch airflow {
        case .vertical: directionStyle = "#horizontal-spread-indicator{display:none}"
        case .horizontal: directionStyle = "#swing-angle-indicator{display:none}"
        default: directionStyle = ""
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:transparent}
        svg{position:absolute;width:250px;height:175px;left:50%;top:-8px;transform:translateX(-50%);pointer-events:none}
        \(cropped ? "svg{width:100%;height:100%;top:0;object-fit:contain}" : "")
        \(directionStyle)
        \(reduceMotion ? "*{animation:none!important;transition:none!important}" : "")
        @media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
        </style></head><body>\(document)</body></html>
        """
    }
}

/// Displays the supplied SVGs locally, preserving their gradients and CSS animation.
/// This view has no scripts, navigation, cookies, or network resources.
struct ApplianceSVGView: NSViewRepresentable {
    var html: String

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> ArtworkWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = ArtworkWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ nsView: ArtworkWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        nsView.loadHTMLString(html, baseURL: nil)
    }
    static func dismantleNSView(_ nsView: ArtworkWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
    }
}

final class ArtworkWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct AirConditionerVisual: View {
    @Environment(\.panelComposition) private var composition
    var running: Bool
    var temperature: Double?
    var airflow: ACAirflow = .off
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var previewSVG: String {
        let document = ApplianceArtwork.svg(running: running, temperature: temperature, airflow: airflow)
        return composition.isExternal ? document.replacingOccurrences(of: "viewBox=\"0 0 400 280\"", with: "viewBox=\"44 28 320 246\"") : document
    }
    var body: some View {
        Group {
            if CommandLine.arguments.contains("--render-preview"),
               let image = NSImage(data: Data(previewSVG.utf8)) {
                // Static export uses AppKit's SVG representation. The installed
                // panel uses WebKit to preserve the supplied CSS animations.
                Image(nsImage: image).resizable().scaledToFit().frame(width: composition.isExternal ? nil : 250, height: composition.isExternal ? nil : 175).offset(y: composition.isExternal ? 0 : -8)
            } else {
                ApplianceSVGView(html: ApplianceArtwork.html(running: running, temperature: temperature,
                                                            airflow: airflow, reduceMotion: reduceMotion, cropped: composition.isExternal))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(running ? "Ar-condicionado ligado, oscilação \(airflow.label)" : "Ar-condicionado desligado")
    }
}
